import Carbon
import Foundation
import Synchronization
import SystemConfiguration
import Testing
import notify

@testable import MeerkatKit

/// Live tests for the notification-backed event kinds, at the real OS
/// boundary where it can be triggered without privileges or side effects on
/// the user's session. System names (screen lock, screen saver, theme) are
/// never posted from here: other apps in the session would react to them.
@Suite(.serialized)
struct NotificationSourceTests {
    let hub = EventHub(
        catalog: EventCatalog([
            AnyEventKind(SessionLockEvent.self),
            AnyEventKind(ScreensaverEvent.self),
            AnyEventKind(InputSourceEvent.self),
            AnyEventKind(AppearanceThemeEvent.self),
            AnyEventKind(ThermalPressureEvent.self),
            AnyEventKind(HostNameEvent.self),
            AnyEventKind(PasteboardChangedEvent.self),
            AnyEventKind(DistributedNotificationEvent.self),
            AnyEventKind(DarwinNotificationEvent.self),
        ]))

    // MARK: Live delivery

    @Test func distributedNotificationIsDeliveredWithConvertedUserInfo() async throws {
        let name = uniqueName()
        let subscription = try hub.subscribe(
            "distributed.notification",
            parameters: .object(["names": .array([.string(name)])]))
        defer { subscription.cancel() }
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: "com.gkze.meerkat.tests",
            userInfo: [
                "text": "hi", "count": 3, "flag": true, "when": date,
                "blob": Data([0xDE, 0xAD]), "list": [1, "two"], "nested": ["k": false],
            ],
            deliverImmediately: true
        )
        let event = try #require(await nextEvent(subscription, timeout: .seconds(5)))
        let payload = try event.payload.decode(as: DistributedNotificationPayload.self)
        #expect(payload.name == name)
        #expect(payload.object == "com.gkze.meerkat.tests")
        #expect(
            payload.userInfo == [
                "text": .string("hi"), "count": .number(3), "flag": .bool(true),
                "when": .number(1_700_000_000_500), "blob": .string("3q0="),
                "list": .array([.number(1), .string("two")]), "nested": .object(["k": .bool(false)]),
            ])
    }

    @Test func darwinNotificationCarriesTheNameState() async throws {
        let name = uniqueName()
        let subscription = try hub.subscribe(
            "darwin.notification",
            parameters: .object(["names": .array([.string(name)])]))
        defer { subscription.cancel() }
        var token: Int32 = 0
        #expect(notify_register_check(name, &token) == UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(token) }
        #expect(notify_set_state(token, 42) == UInt32(NOTIFY_STATUS_OK))
        #expect(notify_post(name) == UInt32(NOTIFY_STATUS_OK))
        let event = try #require(await nextEvent(subscription, timeout: .seconds(5)))
        #expect(event.payload == .object(["name": .string(name), "state": .number(42)]))
    }

    // MARK: Initial state values, compared with independent readers

    @Test func sessionLockReportsTheCurrentState() async throws {
        let subscription = try hub.subscribe("session.lock")
        defer { subscription.cancel() }
        let event = try #require(await nextEvent(subscription, timeout: .seconds(5)))
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        #expect(event.payload == .object(["locked": .bool(locked)]))
    }

    @Test func inputSourceReportsTheSelectedSource() async throws {
        let subscription = try hub.subscribe("input.source")
        defer { subscription.cancel() }
        let event = try #require(await nextEvent(subscription, timeout: .seconds(5)))
        let payload = try event.payload.decode(as: InputSourcePayload.self)
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let id =
            Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(source, kTISPropertyInputSourceID))
            .takeUnretainedValue() as String
        #expect(payload.id == id)
        #expect(payload.name?.isEmpty == false)
    }

    @Test func appearanceThemeMatchesTheGlobalDefault() async throws {
        let subscription = try hub.subscribe("appearance.theme")
        defer { subscription.cancel() }
        let event = try #require(await nextEvent(subscription, timeout: .seconds(5)))
        // `defaults` is a separate process reading through cfprefsd. In
        // Light mode the key is absent and it exits 1.
        let style = try? notificationTestRun("/usr/bin/defaults", ["read", "-g", "AppleInterfaceStyle"])
        #expect(event.payload == .object(["dark": .bool(style == "Dark")]))
    }

    @Test func thermalPressureReportsTheNotifyState() async throws {
        let subscription = try hub.subscribe("thermal.pressure")
        defer { subscription.cancel() }
        let event = try #require(await nextEvent(subscription, timeout: .seconds(5)))
        let raw = try #require(DarwinNotifySource.state(of: "com.apple.system.thermalpressurelevel"))
        #expect(try event.payload.decode(as: ThermalPressurePayload.self) == ThermalPressurePayload(raw: raw))
    }

    @Test func hostNamesMatchScutil() async throws {
        let subscription = try hub.subscribe("network.hostname")
        defer { subscription.cancel() }
        let event = try #require(await nextEvent(subscription, timeout: .seconds(5)))
        let payload = try event.payload.decode(as: HostNamesPayload.self)
        #expect(payload.localHostName == (try? notificationTestRun("/usr/sbin/scutil", ["--get", "LocalHostName"])))
        #expect(payload.computerName == (try? notificationTestRun("/usr/sbin/scutil", ["--get", "ComputerName"])))
    }

    // MARK: Sources that cannot be triggered here

    @Test(arguments: ["session.screensaver", "pasteboard.changed"])
    func untriggerableSourcesStartAndStop(_ kind: String) throws {
        let subscription = try hub.subscribe(kind)
        #expect(hub.statistics().map(\.kind) == [kind])
        subscription.cancel()
        #expect(hub.statistics().isEmpty)
    }

    /// Every source is released after stop: no OS registration or callback
    /// context keeps it alive.
    @Test(arguments: [
        "session.lock", "session.screensaver", "input.source", "appearance.theme",
        "thermal.pressure", "network.hostname", "pasteboard.changed",
    ])
    func sourceIsReleasedAfterStop(_ kind: String) throws {
        let eventKind = try #require(hub.catalog.kind(named: kind))
        weak var released: (any EventSource)?
        try {
            let source = try eventKind.makeSource(eventKind.normalized(.null), environment: SourceEnvironment()) {
                _ in
            }
            try source.start()
            source.stop()
            released = source
        }()
        #expect(released == nil)
    }

    // MARK: Pure logic

    @Test func pasteboardEmitsOnlyChangesAfterTheBaseline() async throws {
        let counter = Mutex(5)
        let emitted = Mutex<[Int]>([])
        let source = PasteboardChangedEvent.makeSource(
            interval: 0.25, changeCount: { counter.withLock { $0 } },
            emit: Emitter { payload, _ in
                if let count = payload["changeCount"]?.numberValue { emitted.withLock { $0.append(Int(count)) } }
            }
        )
        try source.start()
        defer { source.stop() }
        try await Task.sleep(for: .milliseconds(600))
        #expect(emitted.withLock { $0 }.isEmpty)
        counter.withLock { $0 = 6 }
        #expect(await eventually { emitted.withLock { $0 } == [6] })
    }

    @Test func notificationNamesAreDeduplicatedSortedAndValidated() throws {
        let kind = try #require(hub.catalog.kind(named: "darwin.notification"))
        let normalized = try kind.normalized(.object(["names": .array([.string("b"), .string("a"), .string("b")])]))
            .json
        #expect(normalized == .object(["names": .array([.string("a"), .string("b")])]))
        #expect(throws: EventError.self) { try kind.normalized(.object(["names": .array([])])).json }
        #expect(throws: EventError.self) { try kind.normalized(.object(["names": .array([.string("")])])).json }
        #expect(throws: EventError.self) { try kind.normalized(.object([:])).json }
        let tooMany = (0...NotificationNamesParameters.maximumNames).map { JSONValue.string("n\($0)") }
        #expect(throws: EventError.self) { try kind.normalized(.object(["names": .array(tooMany)])).json }
        // The limit counts names, not how often one is listed.
        let repeated = (1...NotificationNamesParameters.maximumNames).map { JSONValue.string("n\($0)") } + ["n1"]
        #expect(try kind.normalized(.object(["names": .array(repeated)])).json["names"]?.arrayValue?.count == 64)
    }

    @Test func thermalLevelsFollowTheMacOSHeader() {
        #expect(
            (0...4).map { ThermalPressurePayload(raw: UInt64($0)).level }
                == [.nominal, .moderate, .heavy, .trapping, .sleeping])
        // An unknown number keeps its raw value and has no level.
        let unknown = ThermalPressurePayload(raw: 10)
        #expect(unknown.level == nil && unknown.raw == 10)
    }

    /// The one property-list conversion, for notifications, the IORegistry
    /// and `defaults.read` alike.
    @Test func plistConversionOmitsWhatJSONCannotHold() {
        let converted = JSONValue(propertyList: [
            "nan": Double.nan, "url": URL(fileURLWithPath: "/"), 7: "int key", "ok": 1.5,
            "date": Date(timeIntervalSince1970: 2), "data": Data([1, 2]),
        ])
        #expect(converted == ["ok": .number(1.5), "date": .number(2000), "data": .string("AQI=")])
    }

    /// The current value first, then each value a notification reports,
    /// marked as what it is: the hub, not the source, leaves out a repeat.
    /// A notification without a value reports nothing.
    @Test func notificationStateSourceMarksTheCurrentValueThenChanges() throws {
        let center = NotificationCenter()
        let name = Notification.Name("meerkat.test.state")
        let emitted = Mutex<[Emission]>([])
        let source = notificationStateSource(
            center: center, names: [name],
            emit: Emitter<DisplaySleepPayload>(sink: { emission in emitted.withLock { $0.append(emission) } }),
            current: { DisplaySleepPayload(asleep: false) },
            changed: { ($0.object as? Bool).map(DisplaySleepPayload.init(asleep:)) })
        try source.start()
        defer { source.stop() }
        for value in [false, true, true, false] { center.post(name: name, object: value) }
        center.post(name: name, object: nil)
        func event(_ asleep: Bool, _ value: Emission.ReportedValue) -> Emission {
            .event(["asleep": .bool(asleep)], origin: .system, value: value)
        }
        #expect(
            emitted.withLock { $0 } == [
                event(false, .current), event(false, .change), event(true, .change), event(true, .change),
                event(false, .change),
            ])
    }
}

/// A tool's trimmed standard output; throws on a nonzero exit (for example
/// `defaults read` of an absent key).
private func notificationTestRun(_ path: String, _ arguments: [String]) throws -> String {
    String(decoding: try runTool(path, arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
