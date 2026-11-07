import CoreWLAN
import Foundation
import Network
import Synchronization
import Testing

@testable import MeerkatKit

/// Live tests of the power-management, throughput, session, device, network
/// link, volume and unified-log sources at the real OS boundary, plus the
/// permission-gated sources' behaviour in a process that has no grant (a test
/// runner has no bundle, but Accessibility follows the responsible process,
/// so it holds one when what launched it does).
@Suite(.serialized)
struct ExtendedSourceTests {
    let hub = EventHub(catalog: EventCatalog.standard)

    /// Subscribes and returns the first event, checked against its schema.
    private func first<Payload: EventPayload>(
        _ kind: String, _ parameters: JSONValue = .null, as type: Payload.Type, within timeout: Duration = .seconds(10)
    ) async throws -> (HardwareEventRecorder, Payload) {
        let recorder = HardwareEventRecorder(try hub.subscribe(kind, parameters: parameters))
        let event = try #require(await recorder.next(within: timeout), "\(kind): no event")
        let schema = try #require(hub.catalog.kind(named: kind)).payloadSchema
        #expect(SchemaValidator.violations(of: event.payload, against: schema).isEmpty, "\(kind)")
        return (recorder, try event.payload.decode(as: Payload.self))
    }

    // MARK: power.assertions

    /// `caffeinate -i` takes a PreventUserIdleSystemSleep assertion for as
    /// long as it runs.
    @Test func assertionHeldByCaffeinateComesAndGoes() async throws {
        let (recorder, initial) = try await first(
            "power.assertions", ["interval": 0.5], as: PowerAssertionsPayload.self)
        defer { recorder.cancel() }
        #expect(initial.assertions == initial.assertions.sorted { ($0.pid, $0.id) < ($1.pid, $1.id) })

        let caffeinate = Process()
        caffeinate.executableURL = URL(filePath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-i", "-t", "30"]
        try caffeinate.run()
        defer { if caffeinate.isRunning { caffeinate.terminate() } }
        let pid = caffeinate.processIdentifier
        func holds(_ event: EventEnvelope) -> Bool {
            (try? event.payload.decode(as: PowerAssertionsPayload.self))?.assertions.contains { $0.pid == pid } ?? false
        }
        let held = try #require(await recorder.next(within: .seconds(5), where: holds))
        let payload = try held.payload.decode(as: PowerAssertionsPayload.self)
        let assertion = try #require(payload.assertions.first { $0.pid == pid })
        #expect(assertion.type == "PreventUserIdleSystemSleep")
        #expect(assertion.process == "caffeinate")
        #expect(payload.active.contains("PreventUserIdleSystemSleep"))

        caffeinate.terminate()
        #expect(await recorder.next(within: .seconds(5)) { !holds($0) } != nil)
    }

    // MARK: power.lid, battery.sample

    @Test func lidStateMatchesTheRegistry() async throws {
        guard let expected = LidPayload.read() else {
            #expect(throws: EventError.self) { try hub.subscribe("power.lid") }
            return
        }
        let (recorder, lid) = try await first("power.lid", as: LidPayload.self)
        defer { recorder.cancel() }
        #expect(lid == expected)
    }

    @Test func batterySampleReadsHealthAndDraw() async throws {
        guard BatterySamplePayload.read() != nil else {
            #expect(throws: EventError.self) { try hub.subscribe("battery.sample") }
            return
        }
        let (recorder, sample) = try await first("battery.sample", ["interval": 5], as: BatterySamplePayload.self)
        defer { recorder.cancel() }
        #expect((sample.cycleCount ?? 0) > 0)
        #expect((1...120).contains(sample.healthPercent ?? 0))
        #expect((5...30).contains(sample.voltage ?? 0))
        #expect((sample.systemPowerWatts ?? 0) > 0)
    }

    @Test func batteryTranslationHandlesSignedAmperageAndMissingKeys() {
        let discharging = BatterySamplePayload.from(
            properties: { key in
                switch key {
                case "Amperage": NSNumber(value: UInt64(bitPattern: -7248))
                case "Voltage": 10_573
                case "BatteryData": ["DesignCapacity": 8000, "NominalChargeCapacity": 6000]
                case "PowerTelemetryData": ["SystemLoad": 75_720]
                default: nil
                }
            }, adapter: nil)
        #expect(discharging.amperage == -7.248)
        #expect(discharging.voltage == 10.573)
        #expect(discharging.healthPercent == 75)
        #expect(discharging.systemPowerWatts == 75.72)
        #expect(discharging.adapterWatts == nil)

        let empty = BatterySamplePayload.from(properties: { _ in nil }, adapter: ["Watts": 96])
        #expect(empty.cycleCount == nil && empty.healthPercent == nil && empty.amperage == nil)
        #expect(empty.adapterWatts == 96)
    }

    // MARK: disk.sample, network.sample

    @Test func diskSampleSeesSyncedWrites() async throws {
        let recorder = HardwareEventRecorder(try hub.subscribe("disk.sample", parameters: ["interval": 0.5]))
        defer { recorder.cancel() }
        let url = temporaryURL("meerkat-disk")
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = Data(repeating: 0xA5, count: 8 << 20)
        let handle = try { () throws -> FileHandle in
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
            return try FileHandle(forWritingTo: url)
        }()
        // Uncached writes, flushed to the device, so the driver sees them.
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        for _ in 0..<4 {
            try handle.write(contentsOf: chunk)
            _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        }
        try handle.close()

        // The temporary directory is on the internal disk, so the writes
        // reach the physical total, not only some disk's row.
        let event = try #require(
            await recorder.next(within: .seconds(5)) { event in
                ((try? event.payload.decode(as: DiskSamplePayload.self))?.writeBytesPerSecond ?? 0) > 0
            })
        let sample = try event.payload.decode(as: DiskSamplePayload.self)
        #expect(!sample.disks.isEmpty)
        #expect(Set(sample.disks.map(\.bsdName)).count == sample.disks.count)
        for disk in sample.disks where disk.writesPerSecond > 0 {
            #expect((disk.writeLatencyMs ?? 0) >= 0)
        }
    }

    @Test func diskRatesSkipCountersThatWentBackwards() {
        let old: [UInt64: DiskCounters] = [
            1: DiskCounters(
                bsdName: "disk0", isVirtual: false, bytesRead: 1000, bytesWritten: 0, reads: 10, writes: 0,
                readTime: 5_000_000, writeTime: 0, errors: 0),
            2: DiskCounters(
                bsdName: "disk4", isVirtual: true, bytesRead: 5000, bytesWritten: 0, reads: 5, writes: 0, readTime: 0,
                writeTime: 0, errors: 0),
        ]
        let new: [UInt64: DiskCounters] = [
            1: DiskCounters(
                bsdName: "disk0", isVirtual: false, bytesRead: 3000, bytesWritten: 0, reads: 20, writes: 0,
                readTime: 15_000_000, writeTime: 0, errors: 1),
            // Reset: a different driver reuses nothing, but a counter that
            // shrinks must not produce a huge rate.
            2: DiskCounters(
                bsdName: "disk4", isVirtual: true, bytesRead: 10, bytesWritten: 0, reads: 1, writes: 0, readTime: 0,
                writeTime: 0, errors: 0),
            // Appeared during the interval: no baseline, not reported.
            3: DiskCounters(
                bsdName: "disk5", isVirtual: false, bytesRead: 10, bytesWritten: 0, reads: 1, writes: 0, readTime: 0,
                writeTime: 0, errors: 0),
        ]
        let rates = DiskCounters.rates(from: old, to: new, seconds: 2)
        #expect(
            rates == [
                DiskRate(
                    bsdName: "disk0", isVirtual: false, readBytesPerSecond: 1000, writeBytesPerSecond: 0,
                    readsPerSecond: 5, writesPerSecond: 0, readLatencyMs: 1, writeLatencyMs: nil, errors: 1)
            ])
    }

    /// A disk image's reads and writes also cross the disk that holds the
    /// image file, so the totals count physical disks only.
    @Test func diskTotalsLeaveOutVirtualDisks() {
        func disk(_ name: String, virtual: Bool, read: Double, write: Double) -> DiskRate {
            DiskRate(
                bsdName: name, isVirtual: virtual, readBytesPerSecond: read, writeBytesPerSecond: write,
                readsPerSecond: 1, writesPerSecond: 1, readLatencyMs: nil, writeLatencyMs: nil, errors: 0)
        }
        let sample = DiskSamplePayload(disks: [
            disk("disk0", virtual: false, read: 4_000, write: 10_000),
            disk("disk4", virtual: true, read: 3_000, write: 2_000),
            disk("disk6", virtual: false, read: 1_000, write: 0),
        ])
        #expect(sample.readBytesPerSecond == 5_000)
        #expect(sample.writeBytesPerSecond == 10_000)
        #expect(DiskSamplePayload(disks: []).readBytesPerSecond == 0)
    }

    /// The internal SSD is a real controller; every Mac this runs on has one.
    @Test func internalDiskIsNotVirtual() throws {
        let disks = try DiskCounters.read().values
        #expect(disks.contains { !$0.isVirtual })
    }

    /// UDP to 127.0.0.1 crosses lo0 only, which is reported per interface but
    /// left out of the totals.
    @Test func networkSampleSeesLoopbackTraffic() async throws {
        let recorder = HardwareEventRecorder(try hub.subscribe("network.sample", parameters: ["interval": 0.5]))
        defer { recorder.cancel() }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian  // discard
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let datagram = [UInt8](repeating: 1, count: 1200)
        for _ in 0..<2000 {
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, datagram, datagram.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let event = try #require(
            await recorder.next(within: .seconds(5)) { event in
                (try? event.payload.decode(as: NetworkSamplePayload.self))?.interfaces.contains { $0.name == "lo0" }
                    ?? false
            })
        let sample = try event.payload.decode(as: NetworkSamplePayload.self)
        let loopback = try #require(sample.interfaces.first { $0.name == "lo0" })
        #expect(loopback.sentBytesPerSecond > 0)
        #expect(sample.sentBytesPerSecond < loopback.sentBytesPerSecond || sample.interfaces.count > 1)
        let counters = try InterfaceCounters.read()
        #expect(counters.values.first { $0.name == "lo0" }?.countsTowardTotal == false)
        #expect(counters.values.first { $0.name == "en0" }?.countsTowardTotal ?? true)
    }

    // MARK: network.link, network.configuration

    @Test func primaryInterfaceHasAnActiveLink() async throws {
        let (configurationRecorder, configuration) = try await first(
            "network.configuration",
            as: NetworkConfigurationPayload.self)
        defer { configurationRecorder.cancel() }
        let (recorder, links) = try await first("network.link", as: NetworkLinkPayload.self)
        defer { recorder.cancel() }
        #expect(!links.links.isEmpty)
        if let primary = configuration.primaryInterface, !primary.hasPrefix("utun") {
            #expect(links.links.contains(.init(interface: primary, active: true)), "\(links)")
        }
        // IPv6 can be off entirely; addresses that are present are IPv6 ones.
        for address in configuration.ipv6Addresses { #expect(address.address.contains(":")) }
    }

    @Test func proxiesKeepOnlyEnabledEntries() {
        let proxies = NetworkConfigurationPayload.Proxies([
            "HTTPEnable": 1, "HTTPProxy": "proxy.example.net", "HTTPPort": 3128,
            "HTTPSEnable": 0, "HTTPSProxy": "stale.example.net", "HTTPSPort": 443,
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://wpad/wpad.dat",
            "ExceptionsList": ["*.local"],
        ])
        #expect(
            proxies
                == .init(
                    http: .init(host: "proxy.example.net", port: 3128), https: nil, socks: nil,
                    autoConfigURL: "http://wpad/wpad.dat", exceptions: ["*.local"]))
        #expect(NetworkConfigurationPayload.Proxies([:]) == .none)
    }

    @Test func linkTranslationReadsActiveFlags() {
        let links = NetworkLinkEvent.payload(from: [
            "State:/Network/Interface/en10/Link": ["Active": true],
            "State:/Network/Interface/en2/Link": ["Active": false],
            "State:/Network/Interface/en0/IPv4": ["Addresses": ["10.0.0.2"]],
        ])
        #expect(links.links == [.init(interface: "en2", active: false), .init(interface: "en10", active: true)])
    }

    // MARK: session.logins, input.idle

    @Test func consoleSessionOfThisUserIsListed() async throws {
        let (recorder, logins) = try await first("session.logins", as: LoginSessionsPayload.self)
        defer { recorder.cancel() }
        #expect(logins.sessions.contains { $0.line == "console" && $0.user == NSUserName() }, "\(logins)")
        #expect(logins.sessions == logins.sessions.sorted { ($0.startedAt, $0.line) < ($1.startedAt, $1.line) })
    }

    @Test func idleReportsTransitionsOnly() async throws {
        let seconds = Mutex(0.0)
        let events = Mutex<[InputIdlePayload]>([])
        let source = InputIdleEvent.makeSource(
            InputIdleParameters(threshold: 10), idleSeconds: { seconds.withLock { $0 } },
            emit: Emitter { value, _ in
                if let payload = try? value.decode(as: InputIdlePayload.self) { events.withLock { $0.append(payload) } }
            })
        try source.start()
        defer { source.stop() }
        func waitFor(_ count: Int) async {
            for _ in 0..<200 where events.withLock({ $0.count }) < count {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await waitFor(1)
        seconds.withLock { $0 = 12 }
        await waitFor(2)
        seconds.withLock { $0 = 15 }
        try await Task.sleep(for: .milliseconds(1200))
        seconds.withLock { $0 = 0.1 }
        await waitFor(3)
        #expect(events.withLock { $0.map(\.idle) } == [false, true, false])
        #expect(throws: EventError.self) { try hub.subscribe("input.idle", parameters: ["threshold": 1]) }
    }

    // MARK: hid.*, iokit.*

    @Test func hidKindsFollowTheUsageTables() {
        #expect(HIDDevicePayload.kind(usagePage: 1, usage: 6) == .keyboard)
        #expect(HIDDevicePayload.kind(usagePage: 1, usage: 2) == .mouse)
        #expect(HIDDevicePayload.kind(usagePage: 0x0D, usage: 5) == .trackpad)
        #expect(HIDDevicePayload.kind(usagePage: 1, usage: 5) == .gameController)
        #expect(HIDDevicePayload.kind(usagePage: 0xFF00, usage: 1) == .other)
        #expect(HIDDevicePayload.kind(usagePage: nil, usage: nil) == .other)
    }

    @Test func iokitEscapeHatchReportsAttachedDiskImage() async throws {
        try await DiskImageGate.shared.run { try await self.iokitEscapeHatchBody() }
    }

    private func iokitEscapeHatchBody() async throws {
        let parameters: JSONValue = ["className": "IOMedia", "properties": ["BSD Name", "Whole", "Size", "NoSuchKey"]]
        let attached = HardwareEventRecorder(try hub.subscribe("iokit.attached", parameters: parameters))
        let detached = HardwareEventRecorder(try hub.subscribe("iokit.detached", parameters: parameters))
        defer {
            attached.cancel()
            detached.cancel()
        }
        let image = try HardwareDiskImage()
        defer { image.remove() }
        let devices = try image.attach(mount: false)
        func named(_ event: EventEnvelope) -> IOKitServicePayload? {
            guard let service = try? event.payload.decode(as: IOKitServicePayload.self),
                let name = service.properties["BSD Name"]?.stringValue, devices.contains(name)
            else { return nil }
            return service
        }
        let shown = try #require(await attached.next(within: .seconds(10)) { named($0) != nil })
        let service = try #require(named(shown))
        #expect(service.className.hasSuffix("Media"))
        #expect(service.properties["NoSuchKey"] == nil)
        #expect(service.properties["Whole"]?.boolValue != nil)
        #expect((service.properties["Size"]?.numberValue ?? 0) > 0)

        try image.detach()
        let gone = try #require(await detached.next(within: .seconds(10)) { named($0) != nil })
        #expect(try gone.payload.decode(as: IOKitServicePayload.self).registryEntryId != 0)
        #expect(throws: EventError.self) {
            try hub.subscribe("iokit.attached", parameters: ["className": "not a class"])
        }
    }

    // MARK: log.entry

    @Test func logEntryStreamsMatchingMessages() async throws {
        let token = "meerkat-\(UUID().uuidString)"
        let recorder = HardwareEventRecorder(
            try hub.subscribe(
                "log.entry",
                parameters: ["predicate": .string(#"process == "logger" AND eventMessage CONTAINS "\#(token)""#)]))
        defer { recorder.cancel() }
        // A message logged before the stream is live never arrives (see
        // `LogStreamSource`), so this logs until one does.
        var pids: [Int32] = []
        var received: EventEnvelope?
        for _ in 0..<20 where received == nil {
            let logger = Process()
            logger.executableURL = URL(filePath: "/usr/bin/logger")
            logger.arguments = [token]
            try logger.run()
            logger.waitUntilExit()
            pids.append(logger.processIdentifier)
            received = await recorder.next(within: .milliseconds(500))
        }
        let event = try #require(received)
        let entry = try event.payload.decode(as: LogEntryPayload.self)
        #expect(entry.process == "logger")
        #expect(entry.message.contains(token))
        #expect(pids.contains(entry.pid))
        #expect(abs(entry.timestamp - Date().timeIntervalSince1970 * 1000) < 60_000)
    }

    /// `log` exiting while the source runs fails the source, rather than
    /// leaving its subscribers waiting for entries that will never come.
    @Test func logEntryFailsWhenLogExits() async throws {
        let failure = Mutex<String?>(nil)
        let source = try #require(
            try LogEntryEvent.makeSource(
                LogStreamParameters(predicate: #"subsystem == "com.gkze.meerkat.tests""#),
                environment: hub.environment,
                emit: Emitter(sink: { _, _ in }, fail: { reason in failure.withLock { $0 = reason } }))
                as? LogStreamSource)
        try source.start()
        defer { source.stop() }
        let pid = try #require(source.processIdentifier)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await eventually { failure.withLock { $0 } != nil })
    }

    @Test func logEntryRejectsAPredicateLogCannotParse() throws {
        #expect {
            try hub.subscribe("log.entry", parameters: ["predicate": "process =="])
        } throws: { error in
            "\(error)".contains("predicate")
        }
    }

    /// `log` reads a lone word as a message search; the source refuses it
    /// and says what `log` would have applied.
    @Test func logEntryRejectsABareWordPredicate() throws {
        for predicate in ["TRUE", "TRUEPREDICATE", "\"error\""] {
            #expect {
                try hub.subscribe("log.entry", parameters: ["predicate": .string(predicate)])
            } throws: { error in
                guard case .invalidParameters(let message) = error as? EventError else { return false }
                return message.contains("composedMessage CONTAINS[cd]") && message.contains("eventMessage CONTAINS[cd]")
            }
        }
    }

    @Test func logEntryReportsTheAppliedPredicate() throws {
        let subscription = try hub.subscribe(
            "log.entry", parameters: ["predicate": .string(#"subsystem == "com.gkze.meerkat.tests""#)])
        defer { subscription.cancel() }
        let detail = hub.statistics().first { $0.kind == "log.entry" }?.detail
        #expect(detail?.hasPrefix(#"log applies: subsystem == "com.gkze.meerkat.tests""#) == true)
    }

    @Test func appliedPredicateComesFromTheHeader() {
        #expect(
            LogStreamSource.appliedPredicate(
                inHeader: #"Filtering the log data using "subsystem == "x" AND type == 1024""# + "\r")
                == #"subsystem == "x" AND type == 1024"#)
        #expect(LogStreamSource.appliedPredicate(inHeader: "Filtering the log data") == nil)
        #expect(LogStreamSource.appliedPredicate(inHeader: #"Filtering the log data using ""#) == nil)
    }

    /// Cases observed from `log stream --predicate` on macOS 27.
    @Test func searchedWordOnlyForALoneWord() {
        let search = { (word: String) in "composedMessage CONTAINS[cd] \"\(word)\" AND type == 1024" }
        #expect(LogStreamSource.searchedWord(in: "TRUE", applied: search("TRUE")) == "TRUE")
        #expect(LogStreamSource.searchedWord(in: " \"error\" ", applied: search("error")) == "error")
        // Written as a search on purpose: applied as the same string.
        #expect(LogStreamSource.searchedWord(in: #"eventMessage CONTAINS[cd] "TRUE""#, applied: search("TRUE")) == nil)
        #expect(
            LogStreamSource.searchedWord(in: #"composedMessage CONTAINS[cd] "TRUE""#, applied: search("TRUE")) == nil)
        #expect(
            LogStreamSource.searchedWord(
                in: #"subsystem == "com.apple.bluetooth""#,
                applied: #"subsystem == "com.apple.bluetooth" AND type == 1024"#) == nil)
    }

    @Test func lineBufferSplitsAcrossReadsAndDropsOverlongLines() {
        var buffer = LineBuffer(maximumLineBytes: 8)
        #expect(buffer.append(Data("ab".utf8)).isEmpty)
        #expect(buffer.append(Data("c\nde\nf".utf8)) == [Data("abc".utf8), Data("de".utf8)])
        #expect(buffer.append(Data("\n".utf8)) == [Data("f".utf8)])
        // Longer than 8 bytes with no newline yet: discarded through its
        // newline, and the next line comes through intact.
        #expect(buffer.append(Data("0123456789".utf8)).isEmpty)
        #expect(buffer.append(Data("xyz\nok\n".utf8)) == [Data("ok".utf8)])
        #expect(buffer.append(Data("\n".utf8)) == [Data()])
    }

    @Test func logLineParsing() throws {
        let formatter = LogEntryPayload.timestampFormatter()
        let decoder = JSONDecoder()
        func parse(_ line: String) throws -> LogEntryPayload? {
            try LogEntryPayload.parse(Data(line.utf8), decoder: decoder, timestamps: formatter)
        }
        let entry = try #require(
            try parse(
                #"{"eventType":"logEvent","messageType":"Error","processImagePath":"/usr/libexec/bluetoothd","senderImagePath":"/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth","processID":412,"subsystem":"com.apple.bluetooth","category":"","timestamp":"2026-10-24 21:17:20.302696-0700","eventMessage":"timed out"}"#
            ))
        // 2026-10-25T04:17:20.302696Z; DateFormatter keeps millisecond precision.
        #expect(abs(entry.timestamp - 1_792_901_840_302.696) < 1)
        #expect(entry.process == "bluetoothd" && entry.pid == 412 && entry.sender == "CoreBluetooth")
        #expect(entry.subsystem == "com.apple.bluetooth" && entry.category == nil)
        #expect(entry.level == .error && entry.message == "timed out")
        #expect(try parse(#"{"eventType":"activityCreateEvent","eventMessage":"x"}"#) == nil)
    }

    /// What a log event doesn't state is not invented: a line without its
    /// pid, with an unreadable timestamp or not JSON at all is refused, so
    /// the source skips and counts it.
    @Test(arguments: [
        #"{"eventType":"logEvent","processImagePath":"/usr/bin/logger","timestamp":"2026-10-24 21:17:20.302696-0700","eventMessage":"x"}"#,
        #"{"eventType":"logEvent","processImagePath":"/usr/bin/logger","processID":7,"timestamp":"yesterday","eventMessage":"x"}"#,
        #"{"eventType":"logEvent","processImagePath":"/usr/bin/logger","processID":7.5,"timestamp":"2026-10-24 21:17:20.302696-0700","eventMessage":"x"}"#,
        "Filtering the log data",
    ])
    func malformedLogLinesAreRefused(_ line: String) {
        #expect(throws: LogEntryPayload.MalformedLine.self) {
            try LogEntryPayload.parse(
                Data(line.utf8), decoder: JSONDecoder(), timestamps: LogEntryPayload.timestampFormatter())
        }
    }

    // MARK: audio.volume

    @Test func volumeFollowsTheDefaultDevices() async throws {
        let (defaultsRecorder, defaults) = try await first("audio.defaultDevice", as: AudioDefaultDevicePayload.self)
        defer { defaultsRecorder.cancel() }
        let (recorder, volume) = try await first("audio.volume", as: AudioVolumePayload.self)
        defer { recorder.cancel() }
        #expect(volume.output?.device.id == defaults.output?.id)
        #expect(volume.input?.device.id == defaults.input?.id)
        for level in [volume.output?.volume, volume.input?.volume].compactMap({ $0 }) {
            #expect((0...1).contains(level))
        }
    }

    // MARK: Permission-gated sources

    @Test func permissionGatedSourcesExplainWhatIsMissing() throws {
        for (kind, permission) in [
            ("window.focused", EventDescriptor.Permission.accessibility),
            ("input.activity", .inputMonitoring), ("bluetooth.devices", .bluetooth),
        ] {
            #expect(hub.catalog.kind(named: kind)?.descriptor.permission == permission)
            guard permission.status != .granted else { continue }
            #expect {
                try hub.subscribe(kind)
            } throws: { error in
                "\(error)".contains(permission.rawValue)
            }
        }
        // No bundle, so no usage description: these can never be asked for.
        #expect(EventDescriptor.Permission.bluetooth.status == .unavailable)
        #expect(EventDescriptor.Permission.location.status == .unavailable)
    }

    static var hasWiFiInterface: Bool { CWWiFiClient.shared().interface() != nil }

    @Test(.enabled(if: hasWiFiInterface, "this Mac has no Wi-Fi interface"))
    func wifiWithoutLocationOmitsNetworkNames() async throws {
        let (recorder, wifi) = try await first("network.wifi", as: WiFiPayload.self)
        defer { recorder.cancel() }
        #expect(!wifi.interface.isEmpty)
        #expect(wifi.locationAuthorized == false)
        #expect(wifi.ssid == nil && wifi.bssid == nil)
        if wifi.associated {
            #expect((-120...0).contains(wifi.rssi ?? 1))
            #expect(wifi.channel != nil)
        }
    }
}
