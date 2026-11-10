import Foundation
import Synchronization
import Testing

@testable import MeerkatKit

struct MeerkatKitTests {
    /// Guards the bug found during prototyping: on Apple Silicon the rusage
    /// CPU fields are mach ticks at ~41.67 ns/tick. If this ever reads 1.0,
    /// every CPU number silently undercounts by a factor of 41.
    @Test func timebaseIsTicksNotNanoseconds() {
        #expect(MachTime.nanosPerTick > 1.0, "timebase should be ~41.67ns/tick on Apple Silicon")
        #expect(abs(MachTime.seconds(fromTicks: 24_000_000) - 1.0) < 0.01)
    }

    @Test func bucketKeyCollapsesToCluster() {
        let path = "/Users/example/Library/Application Support/Linear/Cache/js/abc_0"
        #expect(
            PathChurnMonitor.bucketKey(for: path, depth: 5, home: "/Users/example")
                == "~/Library/Application Support/Linear"
        )
    }

    @Test func bucketKeyKeepsShallowPathsIntact() {
        #expect(
            PathChurnMonitor.bucketKey(for: "/etc/hosts", depth: 5, home: "/Users/example")
                == "/etc/hosts"
        )
    }

    @Test func bucketKeyIsStableForRootItself() {
        #expect(
            PathChurnMonitor.bucketKey(for: "/Users/example", depth: 5, home: "/Users/example") == "~"
        )
    }

    @Test func memorySampleIsPlausible() throws {
        let m = try MemorySampler.sample()
        #expect(m.pageSize > 0)
        #expect(m.wiredMB > 0)
        #expect(m.activeMB > 0)
        #expect(m.freeMB < 100_000)
    }

    private func ownCounters() throws -> ProcessCounters {
        try #require(ProcessTable.record(pid: getpid()).flatMap(ProcessSampler.counters(for:)))
    }

    @Test func countersForOwnProcess() throws {
        let counters = try ownCounters()
        #expect(counters.pid == getpid())
        #expect(try #require(counters.usage).footprintBytes > 0)
    }

    /// `name` is a short name for every row; the path lives in `path`.
    /// Classifying by name once hid every Apple agent running as the user.
    @Test func countersSeparateNameFromPath() throws {
        let counters = try ownCounters()
        let expected = try #require(Bundle.main.executableURL).resolvingSymlinksInPath().path
        #expect(counters.path == expected)
        #expect(!counters.name.contains("/"))
    }

    @Test func systemServiceIsDecidedByPath() {
        func row(_ name: String, _ path: String?) -> ProcessDelta {
            ProcessDelta(
                pid: 1, name: name, path: path, cpuPct: 0, cpuSeconds: 0,
                windowSeconds: 1, footprintMB: 0, diskReadMB: 0,
                diskWriteMB: 0, energyJoules: 0, startedAt: 0, uid: 0)
        }
        #expect(
            row("cloudd", "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd").isSystemService)
        #expect(row("cfprefsd", "/usr/sbin/cfprefsd").isSystemService)
        #expect(!row("Safari", "/Applications/Safari.app/Contents/MacOS/Safari").isSystemService)
        #expect(!row("/usr/sbin/cfprefsd", nil).isSystemService)
    }

    /// Paths taken from a live process list. Each excluded case sits under a
    /// root that is otherwise system, which is what makes it worth pinning.
    @Test(arguments: [
        ("/usr/libexec/duetexpertd", true),
        ("/sbin/launchd", true),
        ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", true),
        ("/Library/Apple/usr/libexec/oah/oahd", true),
        (
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            true
        ),
        ("/System/Cryptexes/App/usr/libexec/SafariBookmarksSyncAgent", true),
        ("/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor", false),
        ("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari", false),
        ("/usr/local/rippling/daemon", false),
        (
            "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent",
            false
        ),
        (
            "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/PrivateApplications/CoreDeviceExtensions.app/Contents/Extensions/DeviceFS.appex/Contents/MacOS/DeviceFS",
            false
        ),
        ("/System/Volumes/Data/usr/local/bin/tool", false),
        ("/System/Volumes/Preboot/Cryptexes/OS", false),
    ])
    func systemExecutableRule(path: String, isSystem: Bool) {
        #expect(ProcessDelta.isSystemExecutable(path) == isSystem)
    }

    /// A process whose executable path is unknown has no `path` key, and is
    /// not mistaken for a system service.
    @Test func processDeltaDecodesWithoutPath() throws {
        let json = """
            {"pid":1,"name":"launchd","cpuPct":0,"cpuSeconds":0,"windowSeconds":1,
             "footprintMB":0,"diskReadMB":0,"diskWriteMB":0,"energyJoules":0,"startedAt":1,"uid":0}
            """
        let row = try JSONDecoder().decode(ProcessDelta.self, from: Data(json.utf8))
        #expect(row.path == nil)
        #expect(!row.isSystemService)
    }

    @Test func deltaWindowRespectsTopLimit() throws {
        let before = try ProcessSampler.snapshot()
        Thread.sleep(forTimeInterval: 0.3)
        let rows = ProcessSampler.deltas(previous: before, current: try ProcessSampler.snapshot(), top: 5)
        #expect(rows.count <= 5)
        #expect(rows.allSatisfy { $0.cpuPct >= 0 && ($0.footprintMB ?? 0) >= 0 })
    }

    @Test func churnMonitorRecordsWrites() throws {
        let dir = temporaryURL("meerkat-churn")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let monitor = PathChurnMonitor(root: dir.path, depth: 5, home: "/Users/example")

        // Write from a background thread for as long as the window lasts.
        // FSEvents reports only what happens after `measure` starts its
        // stream, and nothing says when that is, so writing until the
        // measurement ends puts writes inside the window however late the
        // stream starts.
        let measuring = Atomic(true)
        let writer = Thread {
            var i = 0
            while measuring.load(ordering: .acquiring) {
                let f = dir.appendingPathComponent("f\(i % 20).txt")
                try? "hello \(i)".write(to: f, atomically: false, encoding: .utf8)
                i += 1
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        writer.start()
        defer { measuring.store(false, ordering: .releasing) }

        let (result, _) = try monitor.measure(topBuckets: 12) { Thread.sleep(forTimeInterval: 2.0) }
        #expect(result.totalEvents > 0, "FSEvents should observe the writes")
        #expect(!result.buckets.isEmpty)
    }

    /// FSEvents holds changes back for the latency window (1 s) after it
    /// delivers, and fseventsd reads them behind time, so files written
    /// just before the window ends are all counted only if the window
    /// waits for them. The first write starts a latency window, so the
    /// burst after it is held past the end.
    @Test func churnCountsWritesInTheWindowsLastSecond() throws {
        let dir = temporaryURL("meerkat-churn-end")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let monitor = PathChurnMonitor(root: dir.path, depth: 5, home: "/Users/example")
        let (result, _) = try monitor.measure(topBuckets: 12) {
            // Well after the stream's start, which nothing reports.
            Thread.sleep(forTimeInterval: 1.0)
            try? "x".write(to: dir.appendingPathComponent("first.txt"), atomically: false, encoding: .utf8)
            Thread.sleep(forTimeInterval: 0.5)
            for i in 0..<20 {
                try? "x".write(to: dir.appendingPathComponent("end\(i).txt"), atomically: false, encoding: .utf8)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        #expect(result.created >= 21, "every file of a burst 0.2 s before the end is in the window")
    }
}

struct PropertyListConversionTests {
    /// What `defaults.write` stores reads back as the same JSON, with whole
    /// numbers stored as integers.
    @Test func aWrittenValueReadsBackTheSame() throws {
        let value: JSONValue = [
            "count": 3, "ratio": 1.5, "on": true, "name": "x", "list": [1, "two", false], "nested": ["a": [0.25]],
        ]
        let stored = try #require(value.propertyList)
        #expect(JSONValue(propertyList: stored, strict: true) == value)
        let count = try #require((stored as? [String: Any])?["count"] as? NSNumber)
        #expect(CFNumberIsFloatType(count) == false)
    }

    @Test func nullCannotBeStored() {
        #expect(JSONValue.null.propertyList == nil)
        #expect(JSONValue.array([1, .null]).propertyList == nil)
    }

    /// An observation leaves out what JSON can't hold; a value a rule may
    /// write back is refused whole instead, so no index shifts.
    @Test func strictConversionRefusesWhatLenientConversionOmits() {
        let list: [Any] = [1.0, Double.nan, 3.0]
        #expect(JSONValue(propertyList: list) == [1, 3])
        #expect(JSONValue(propertyList: list, strict: true) == nil)
        let dictionary: [String: Any] = ["a": 1, "b": Double.infinity]
        #expect(JSONValue(propertyList: dictionary) == ["a": 1])
        #expect(JSONValue(propertyList: dictionary, strict: true) == nil)
        #expect(JSONValue(propertyList: [1, 2] as [Any], strict: true) == [1, 2])
    }
}

struct WindowRequestTests {
    /// A size of zero or less is refused by the request's schema, before
    /// any grant or Accessibility call; a coordinate may be negative.
    @Test func windowSizesMustBePositive() throws {
        let effect = try #require(EffectCatalog.standard.effects.first { $0.kind == "windows.set" })
        func violations(_ fields: [String: JSONValue]) -> [String] {
            SchemaValidator.violations(
                of: .object(fields.merging(["bundleId": "com.example", "index": 0]) { $1 }),
                against: .object(effect.request))
        }
        #expect(!violations(["width": -50]).isEmpty)
        #expect(!violations(["height": 0]).isEmpty)
        #expect(violations(["width": 1, "height": 800, "x": -1_200, "y": 0]).isEmpty)
    }
}

/// Waits on things that may never answer: a daemon that takes a request and
/// says nothing, a language server that stops replying.
struct DeadlineTests {
    private struct Refused: Error {}

    @Test func aResultInTimeIsTheResult() async throws {
        #expect(try await withDeadline(.seconds(5)) { 7 } == 7)
    }

    @Test func anErrorInTimeIsTheError() async {
        await #expect(throws: Refused.self) {
            try await withDeadline(.seconds(5)) { () async throws -> Int in throw Refused() }
        }
    }

    /// The case it is for: an operation that ignores cancellation and never
    /// returns still lets the caller go at the deadline.
    @Test func aCallThatNeverReturnsEndsAtTheDeadline() async {
        let started = ContinuousClock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(100)) { await neverReturns() }
        }
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func theCallersCancellationEndsTheWait() async {
        let waiting = Task { try await withDeadline(.seconds(3600)) { await neverReturns() } }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func aCallerCancelledBeforeItWaitsDoesntWait() async {
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withDeadline(.seconds(3600)) { await neverReturns() }
        }
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}

/// Never returns, and ignores cancellation, like an XPC reply that never
/// comes.
private func neverReturns() async -> Int {
    await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
}

/// What crosses from another process: a row whose start time no process
/// can have names no process, rather than trap where it is used.
struct ProcessDeltaDecodingTests {
    private static func row(startedAt: Double) -> Data {
        Data(
            """
            {"pid":7,"name":"x","cpuPct":0,"cpuSeconds":0,"windowSeconds":1,"startedAt":\(startedAt),"uid":0}
            """.utf8)
    }

    @Test(arguments: [0, -1, 1e300, 9.1e12])
    func aStartTimeNoProcessCanHaveNamesNoProcess(startedAt: Double) throws {
        let row = try JSONDecoder().decode(ProcessDelta.self, from: Self.row(startedAt: startedAt))
        #expect(row.identity == nil)
        #expect(ProcessIdentity(pid: 7, startedAt: startedAt) == nil)
    }

    @Test func aRowRoundTripsWithItsIdentity() throws {
        let row = try JSONDecoder().decode(ProcessDelta.self, from: Self.row(startedAt: 1_792_870_301_000))
        #expect(row.identity == ProcessIdentity(pid: 7, startedAt: 1_792_870_301_000))
        #expect(try JSONDecoder().decode(ProcessDelta.self, from: JSONEncoder().encode(row)) == row)
    }
}

struct LogLineTests {
    /// The runtime counts a line's limit in UTF-8 bytes; a cut never splits
    /// a character, even one of several scalars.
    @Test func aLineIsCutToBytesOnACharacterBoundary() {
        #expect("abc".prefix(utf8Bytes: 3) == "abc")
        #expect("abcd".prefix(utf8Bytes: 3) == "abc")
        // "é" is 2 bytes, the flag 8.
        #expect("aé".prefix(utf8Bytes: 2) == "a")
        #expect("a🇨🇦b".prefix(utf8Bytes: 8) == "a")
        #expect("a🇨🇦b".prefix(utf8Bytes: 9) == "a🇨🇦")
        #expect("".prefix(utf8Bytes: 0) == "")
    }
}
