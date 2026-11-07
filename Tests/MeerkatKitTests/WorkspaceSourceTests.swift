import AppKit
import Foundation
import Synchronization
import Testing

@testable import MeerkatKit

/// The NSWorkspace and Foundation system-state kinds, exercised at the real
/// OS boundary where an unprivileged test can trigger them.
///
/// NSWorkspace delivers through the main run loop, on the main thread. The
/// test runner happens to run that loop already; waits spin it anyway, the
/// way the daemon's `CFRunLoopRun()` does, so the tests do not depend on it.
@Suite(.serialized)
struct WorkspaceSourceTests {
    static let kinds: [AnyEventKind] = [
        AnyEventKind(AppLaunchedEvent.self),
        AnyEventKind(AppTerminatedEvent.self),
        AnyEventKind(AppActivatedEvent.self),
        AnyEventKind(AppDeactivatedEvent.self),
        AnyEventKind(AppHiddenEvent.self),
        AnyEventKind(AppUnhiddenEvent.self),
        AnyEventKind(SpaceChangedEvent.self),
        AnyEventKind(PowerSleepEvent.self),
        AnyEventKind(PowerWillPowerOffEvent.self),
        AnyEventKind(DisplaySleepEvent.self),
        AnyEventKind(SessionActiveEvent.self),
        AnyEventKind(VolumeMountedEvent.self),
        AnyEventKind(VolumeWillUnmountEvent.self),
        AnyEventKind(VolumeUnmountedEvent.self),
        AnyEventKind(VolumeRenamedEvent.self),
        AnyEventKind(AccessibilityDisplayEvent.self),
        AnyEventKind(ThermalStateEvent.self),
        AnyEventKind(LowPowerModeEvent.self),
        AnyEventKind(ClockSetEvent.self),
        AnyEventKind(TimeZoneEvent.self),
        AnyEventKind(DayChangedEvent.self),
        AnyEventKind(LocaleChangedEvent.self),
    ]

    let hub = EventHub(catalog: EventCatalog(Self.kinds))

    // MARK: State kinds report their current value first

    @Test func displaySleepStartsWithTheMainDisplayState() async throws {
        let event = try #require(try await workspaceFirstEvent(hub, "display.sleep"))
        #expect(event.payload == .object(["asleep": .bool(CGDisplayIsAsleep(CGMainDisplayID()) != 0)]))
        // The first value of a push `state` source is its current value.
        #expect(event.replayed)
    }

    @Test func sessionActiveStartsWithTheConsoleState() async throws {
        let expected = try #require(
            SessionActiveEvent.currentSession(),
            "the test process has no window-server session")
        let event = try #require(try await workspaceFirstEvent(hub, "session.active"))
        #expect(event.payload == .object(["active": .bool(expected.active)]))
    }

    @Test func accessibilityDisplayStartsWithTheCurrentOptions() async throws {
        let event = try #require(try await workspaceFirstEvent(hub, "accessibility.display"))
        #expect(event.payload == (try JSONValue(encoding: AccessibilityDisplayPayload.current())))
    }

    @Test func thermalStateStartsWithTheCurrentState() async throws {
        let event = try #require(try await workspaceFirstEvent(hub, "thermal.state"))
        let expected = try #require(ThermalStatePayload(ProcessInfo.processInfo.thermalState))
        #expect(event.payload == (try JSONValue(encoding: expected)))
    }

    @Test func lowPowerModeStartsWithTheCurrentSetting() async throws {
        let event = try #require(try await workspaceFirstEvent(hub, "power.lowPowerMode"))
        #expect(event.payload == .object(["enabled": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)]))
    }

    @Test func timeZoneStartsWithTheCurrentZone() async throws {
        let event = try #require(try await workspaceFirstEvent(hub, "time.zone"))
        guard case .object(let fields) = event.payload else {
            Issue.record("not an object")
            return
        }
        // The system's setting, read past Foundation's per-process cache,
        // which a source that didn't reset it would report instead.
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime")
        let identifier = try #require(link.components(separatedBy: "/zoneinfo/").last)
        let zone = try #require(TimeZone(identifier: identifier))
        #expect(fields["identifier"] == .string(identifier))
        #expect(fields["secondsFromGMT"] == .number(Double(zone.secondsFromGMT())))
    }

    @Test func localeStartsWithTheCurrentIdentifier() async throws {
        let event = try #require(try await workspaceFirstEvent(hub, "locale.changed"))
        #expect(event.payload == .object(["identifier": .string(Locale.current.identifier)]))
    }

    // MARK: Pure payload mapping

    @Test func dayChangedFormatsTheLocalDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2027, month: 3, day: 4, hour: 23, minute: 59)))
        #expect(DayChangedPayload(now: date).date == "2027-03-04")
    }

    /// time.dayChanged keeps its own midnight, in the zone as it is when the
    /// timer is armed, including a day whose midnight a clock change skips.
    @Test func theNextDayStartsAtTheZonesMidnight() throws {
        let iso = ISO8601DateFormatter()
        let stJohns = try #require(TimeZone(identifier: "America/St_Johns"))
        let evening = try #require(iso.date(from: "2026-11-05T02:00:00Z"))
        #expect(DayChangeSource.nextMidnight(after: evening, in: stJohns) == iso.date(from: "2026-11-05T03:30:00Z"))
        // São Paulo's clocks went from 00:00 to 01:00 on 2018-11-04.
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let before = try #require(iso.date(from: "2018-11-03T12:00:00Z"))
        #expect(DayChangeSource.nextMidnight(after: before, in: saoPaulo) == iso.date(from: "2018-11-04T03:00:00Z"))
    }

    // MARK: Volumes: a disk image mounted, renamed and detached

    @Test func volumeLifecycleOfADiskImage() async throws {
        try await DiskImageGate.shared.run { try await self.volumeLifecycleOfADiskImageBody() }
    }

    private func volumeLifecycleOfADiskImageBody() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "meerkat-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appending(path: "probe.dmg").path(percentEncoded: false)
        let name = "SPW\(UUID().uuidString.prefix(8))"
        let renamed = name + "R"

        let mounted = try hub.subscribe("volume.mounted")
        let renames = try hub.subscribe("volume.renamed")
        let willUnmount = try hub.subscribe("volume.willUnmount")
        let unmounted = try hub.subscribe("volume.unmounted")
        defer { for subscription in [mounted, renames, willUnmount, unmounted] { subscription.cancel() } }
        // The same kind observed directly, to see which thread delivers.
        let deliveryThreads = Mutex<[Bool]>([])
        let direct = try VolumeMountedEvent.makeSource(
            NoParameters(), environment: SourceEnvironment(),
            emit: Emitter { _, _ in
                deliveryThreads.withLock { $0.append(Thread.isMainThread) }
            })
        try direct.start()
        defer { direct.stop() }

        try await workspaceRun("/usr/bin/hdiutil", ["create", "-size", "2m", "-fs", "APFS", "-volname", name, image])
        let attach = try await workspaceRun("/usr/bin/hdiutil", ["attach", "-nobrowse", "-plist", image])
        let device = try #require(workspaceDevice(fromAttachPlist: attach))
        var detached = false
        defer {
            if !detached {
                _ = try? Process.run(URL(filePath: "/usr/bin/hdiutil"), arguments: ["detach", "-force", device])
            }
        }

        let mount = try #require(try await workspaceNextEvent(mounted) { $0.payload.field("name") == .string(name) })
        let mountPath = try #require(mount.payload.field("path"))
        #expect(mountPath == .string("/Volumes/\(name)"))
        #expect(deliveryThreads.withLock { $0 }.allSatisfy { $0 }, "NSWorkspace delivered off the main thread")
        #expect(!deliveryThreads.withLock { $0 }.isEmpty)

        try await workspaceRun("/usr/sbin/diskutil", ["rename", device, renamed])
        let rename = try #require(
            try await workspaceNextEvent(renames) { $0.payload.field("name") == .string(renamed) })
        #expect(rename.payload.field("oldName") == .string(name))
        #expect(rename.payload.field("oldPath") == mountPath)

        try await workspaceRun("/usr/bin/hdiutil", ["detach", device])
        detached = true
        #expect(try await workspaceNextEvent(willUnmount) { $0.payload.field("name") == .string(renamed) } != nil)
        #expect(try await workspaceNextEvent(unmounted) { $0.payload.field("name") == .string(renamed) } != nil)
    }

    // MARK: Applications (launches a GUI app; opt in)

    /// Launches a hidden, separate Calculator instance and quits it. Opt in
    /// with `MEERKAT_LIVE_APP_TESTS=1`: it briefly starts a GUI application.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEERKAT_LIVE_APP_TESTS"] == "1"))
    func appLaunchHideUnhideTerminate() async throws {
        let launched = try hub.subscribe("app.launched")
        let hidden = try hub.subscribe("app.hidden")
        let unhidden = try hub.subscribe("app.unhidden")
        let terminated = try hub.subscribe("app.terminated")
        defer { for subscription in [launched, hidden, unhidden, terminated] { subscription.cancel() } }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        let app = try await NSWorkspace.shared.openApplication(
            at: URL(filePath: "/System/Applications/Calculator.app"), configuration: configuration)
        let pid = app.processIdentifier
        defer { if !app.isTerminated { app.forceTerminate() } }
        let byPid: @Sendable (EventEnvelope) -> Bool = { $0.payload.field("pid") == .number(Double(pid)) }

        let launch = try #require(try await workspaceNextEvent(launched, where: byPid))
        #expect(launch.payload.field("bundleId") == .string("com.apple.calculator"))
        #expect(launch.payload.field("bundlePath") == .string("/System/Applications/Calculator.app"))
        #expect(launch.payload.field("activationPolicy") == .string("regular"))

        // Launching with `hides` posts didHide once launched; unhiding before
        // that would be undone by it.
        #expect(try await workspaceNextEvent(hidden, where: byPid) != nil)
        // unhide() and hide() return false here even though they take effect.
        await MainActor.run { _ = app.unhide() }
        #expect(try await workspaceNextEvent(unhidden, where: byPid) != nil)
        await MainActor.run { _ = app.hide() }
        #expect(try await workspaceNextEvent(hidden, where: byPid) != nil)
        await MainActor.run { _ = app.terminate() }
        #expect(try await workspaceNextEvent(terminated, where: byPid) != nil)
    }

    // MARK: Kinds a test cannot trigger: start and stop cleanly

    @Test(arguments: [
        "app.activated", "app.deactivated", "space.changed", "power.sleep",
        "power.willPowerOff", "time.clockSet", "time.dayChanged",
    ])
    func untriggerableKindsStartAndStop(_ name: String) throws {
        let subscription = try hub.subscribe(name)
        #expect(hub.statistics().map(\.kind) == [name])
        subscription.cancel()
        #expect(hub.statistics().isEmpty)
    }

    @Test func stoppedSourcesAreReleased() throws {
        // A source kept alive by its own observer block would leak one OS
        // registration per subscribe/cancel cycle.
        weak var released: (any EventSource)?
        do {
            let source = try DisplaySleepEvent.makeSource(
                NoParameters(), environment: SourceEnvironment(),
                emit: Emitter { _, _ in })
            try source.start()
            source.stop()
            released = source
        }
        #expect(released == nil)
    }
}

// MARK: - Helpers (named for this suite to avoid clashes)

/// The first event of a fresh subscription, which a state kind emits on start.
private func workspaceFirstEvent(_ hub: EventHub, _ kind: String) async throws -> EventEnvelope? {
    let subscription = try hub.subscribe(kind)
    defer { subscription.cancel() }
    return try await workspaceNextEvent(subscription) { _ in true }
}

/// The next event matching `predicate`, or nil after `timeout`. Spins the
/// main run loop while waiting, as the daemon's `CFRunLoopRun()` does.
private func workspaceNextEvent(
    _ subscription: EventSubscription, timeout: Duration = .seconds(10),
    where predicate: @escaping @Sendable (EventEnvelope) -> Bool
) async throws -> EventEnvelope? {
    let events = subscription.events
    return try await withThrowingTaskGroup(of: EventEnvelope?.self) { group in
        group.addTask {
            for await event in events where predicate(event) { return event }
            return nil
        }
        group.addTask {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                await MainActor.run { _ = CFRunLoopRunInMode(.defaultMode, 0.05, false) }
                try Task.checkCancellation()
            }
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Runs a tool off the cooperative pool and returns its standard output;
/// throws on a non-zero exit.
@discardableResult
private func workspaceRun(_ tool: String, _ arguments: [String]) async throws -> Data {
    try await Task.detached { try runTool(tool, arguments) }.value
}

/// The device node of the mounted volume in `hdiutil attach -plist` output.
private func workspaceDevice(fromAttachPlist data: Data) -> String? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let entities = plist["system-entities"] as? [[String: Any]]
    else { return nil }
    return entities.first { $0["mount-point"] != nil }?["dev-entry"] as? String
}

extension JSONValue {
    fileprivate func field(_ name: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[name]
    }
}
