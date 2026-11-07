import AppKit
import Carbon
import CoreGraphics
import Foundation
import Synchronization
import SystemConfiguration
import notify

// Events backed by named notifications: distributed (NSDistributedNotificationCenter),
// Darwin notify(3), and SCDynamicStore keys, plus the pasteboard change counter.
//
// Delivery thread: DistributedNotificationCenter delivers to `queue: nil`
// observers on the main run loop (observed on macOS 27: a notification this
// process posted was not delivered while the main run loop was idle, and was
// delivered once it ran). The daemon runs the main run loop; nothing here
// blocks it.

// MARK: - Escape-hatch parameters

/// `{ names: string[] }` for the notification escape hatches.
///
/// Names are deduplicated and sorted when decoded, so subscriptions to the
/// same set in any order share one source.
public struct NotificationNamesParameters: EventParameters {
    public static let maximumNames = 64

    public var names: [String]

    public init(names: [String]) {
        self.names = Array(Set(names)).sorted()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(names: try container.decode([String].self, forKey: .names))
    }

    public func validate() throws {
        guard (1...Self.maximumNames).contains(names.count) else {
            throw EventError.invalidParameters(
                "\"names\" must list 1–\(Self.maximumNames) distinct names, got \(names.count)")
        }
        guard !names.contains(where: \.isEmpty) else {
            throw EventError.invalidParameters("\"names\" must not contain an empty name")
        }
    }

    public static var schema: TypeSchema {
        .object(
            ObjectSchema([
                .field(
                    "names", [String].self,
                    doc: "Notification names to observe, 1–\(maximumNames); duplicates are ignored.")
            ]))
    }

    public static var examples: [Self] {
        [Self(names: ["com.example.ping"]), Self(names: ["b.example", "a.example"])]
    }
}

// MARK: - session.lock

public struct SessionLockPayload: EventPayload, Equatable {
    public let locked: Bool

    public static var schema: TypeSchema {
        .named("SessionLock", ObjectSchema([.field("locked", Bool.self, doc: "True while the screen is locked.")]))
    }

    public static var examples: [Self] { [Self(locked: true), Self(locked: false)] }
}

public enum SessionLockEvent: EventKind {
    static let lockedName = Notification.Name("com.apple.screenIsLocked")
    static let unlockedName = Notification.Name("com.apple.screenIsUnlocked")

    public static let descriptor = EventDescriptor(
        "session.lock",
        "The login session's screen was locked or unlocked. The current state is delivered first. Does not say how it was locked or unlocked.",
        mechanism: .push, semantics: .state, loss: .none, stability: .undocumented,
        observation: .open,
        source:
            "DistributedNotificationCenter com.apple.screenIsLocked / com.apple.screenIsUnlocked; CGSessionCopyCurrentDictionary"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<SessionLockPayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        return NotificationSource(
            center: DistributedNotificationCenter.default(),
            names: [lockedName, unlockedName],
            initial: { reporter.report { SessionLockPayload(locked: currentlyLocked()) } },
            handler: { notification in
                let locked = notification.name == lockedName
                reporter.report { SessionLockPayload(locked: locked) }
            })
    }

    /// `CGSSessionScreenIsLocked` is present (and true) only while locked.
    static func currentlyLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

// MARK: - session.screensaver

public struct ScreensaverPayload: EventPayload, Equatable {
    public let running: Bool

    public static var schema: TypeSchema {
        .named(
            "Screensaver",
            ObjectSchema([
                .field("running", Bool.self, doc: "True when the screen saver started, false when it stopped.")
            ]))
    }

    public static var examples: [Self] { [Self(running: true), Self(running: false)] }
}

public enum ScreensaverEvent: EventKind {
    static let startedName = Notification.Name("com.apple.screensaver.didstart")
    static let stoppedName = Notification.Name("com.apple.screensaver.didstop")

    public static let descriptor = EventDescriptor(
        "session.screensaver",
        "The screen saver started or stopped. Whether it is running at subscription time is not reported.",
        mechanism: .push, semantics: .occurrence, loss: .none, stability: .undocumented,
        observation: .open,
        source: "DistributedNotificationCenter com.apple.screensaver.didstart / didstop"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<ScreensaverPayload>
    ) throws -> any EventSource {
        NotificationSource(center: DistributedNotificationCenter.default(), names: [startedName, stoppedName]) {
            notification in
            emit(ScreensaverPayload(running: notification.name == startedName))
        }
    }
}

// MARK: - input.source

public struct InputSourcePayload: EventPayload, Equatable {
    /// Text Input Sources identifier, e.g. `com.apple.keylayout.US`.
    public let id: String
    public let name: String?
    public let languages: [String]

    public static var schema: TypeSchema {
        .named(
            "InputSource",
            ObjectSchema([
                .field("id", String.self, doc: "Input source identifier, e.g. \"com.apple.keylayout.US\"."),
                .optional("name", String.self, doc: "Localized display name."),
                .field(
                    "languages", [String].self,
                    doc: "BCP 47 language codes the source supports, most preferred first; empty if it declares none."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(id: "com.apple.keylayout.US", name: "U.S.", languages: ["en"]),
            Self(id: "com.example.inputmethod", name: nil, languages: []),
        ]
    }
}

public enum InputSourceEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "input.source",
        "The selected keyboard input source (layout or input method) changed. The current source is delivered first. Keystrokes are not reported.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source:
            "DistributedNotificationCenter kTISNotifySelectedKeyboardInputSourceChanged; TISCopyCurrentKeyboardInputSource"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<InputSourcePayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        // Text Input Sources is a HIToolbox API that Apple has historically
        // required on the main thread; distributed notifications arrive there
        // anyway, so both reads hop to the main queue.
        let report: @Sendable () -> Void = {
            DispatchQueue.main.async { reporter.report(current) }
        }
        return NotificationSource(
            center: DistributedNotificationCenter.default(),
            names: [Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)],
            initial: report
        ) { _ in report() }
    }

    static func current() -> InputSourcePayload? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func property(_ key: CFString) -> AnyObject? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            // TISGetInputSourceProperty follows the Get rule: not retained.
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }
        guard let id = property(kTISPropertyInputSourceID) as? String else { return nil }
        return InputSourcePayload(
            id: id,
            name: property(kTISPropertyLocalizedName) as? String,
            languages: (property(kTISPropertyInputSourceLanguages) as? [String]) ?? []
        )
    }
}

// MARK: - appearance.theme

public struct AppearanceThemePayload: EventPayload, Equatable {
    public let dark: Bool

    public static var schema: TypeSchema {
        .named(
            "AppearanceTheme",
            ObjectSchema([.field("dark", Bool.self, doc: "True when the system appearance is Dark.")]))
    }

    public static var examples: [Self] { [Self(dark: true), Self(dark: false)] }
}

public enum AppearanceThemeEvent: EventKind {
    static let changedName = Notification.Name("AppleInterfaceThemeChangedNotification")

    public static let descriptor = EventDescriptor(
        "appearance.theme",
        "The system appearance switched between Light and Dark (including Auto switching). The current appearance is delivered first. Accent and highlight colors are not reported.",
        mechanism: .push, semantics: .state, loss: .none, stability: .undocumented,
        observation: .open,
        source:
            "DistributedNotificationCenter AppleInterfaceThemeChangedNotification; global default AppleInterfaceStyle"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<AppearanceThemePayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        return NotificationSource(
            center: DistributedNotificationCenter.default(),
            names: [changedName],
            initial: { reporter.report { AppearanceThemePayload(dark: currentlyDark()) } },
            handler: { _ in
                reporter.report { AppearanceThemePayload(dark: currentlyDark()) }
            })
    }

    /// `AppleInterfaceStyle` in the global domain is "Dark" in Dark mode and
    /// absent in Light mode. `UserDefaults(suiteName: NSGlobalDomain)` returns
    /// nil, so this reads CFPreferences directly, synchronizing first so a
    /// value written by another process since the last read is seen.
    static func currentlyDark() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication)
        return (style as? String) == "Dark"
    }
}

// MARK: - distributed.notification

public struct DistributedNotificationPayload: EventPayload, Equatable {
    public let name: String
    public let object: String?
    public let userInfo: [String: JSONValue]?

    public static var schema: TypeSchema {
        .named(
            "DistributedNotification",
            ObjectSchema([
                .field("name", String.self),
                .optional(
                    "object", String.self, doc: "The notification's object string, usually the poster's identifier."),
                .optional(
                    "userInfo", [String: JSONValue].self,
                    doc:
                        "Property-list userInfo as JSON: dates become epoch milliseconds, data becomes base64; other values are omitted."
                ),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                name: "com.example.ping", object: "com.example.app",
                userInfo: ["count": .number(2), "ok": .bool(true), "tags": .array([.string("a")])]),
            Self(name: "com.example.ping", object: nil, userInfo: nil),
        ]
    }
}

extension DistributedNotificationPayload {
    init(_ notification: Notification) {
        name = notification.name.rawValue
        object = notification.object as? String
        userInfo = notification.userInfo.flatMap { JSONValue(propertyList: $0)?.objectValue }
    }
}

public enum DistributedNotificationEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "distributed.notification",
        "A distributed notification with one of `names` was posted by any process in this login session. Names must be listed: macOS does not let an unprivileged process observe every name. Sandboxed posters cannot attach userInfo.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .named,
        source: "DistributedNotificationCenter"
    )

    public static func makeSource(
        _ parameters: NotificationNamesParameters, environment: SourceEnvironment,
        emit: Emitter<DistributedNotificationPayload>
    ) throws -> any EventSource {
        NotificationSource(
            center: DistributedNotificationCenter.default(),
            names: parameters.names.map { Notification.Name($0) }
        ) { notification in
            emit(DistributedNotificationPayload(notification))
        }
    }
}

// MARK: - darwin.notification

public struct DarwinNotificationPayload: EventPayload, Equatable {
    public let name: String
    public let state: UInt64

    public static var schema: TypeSchema {
        .named(
            "DarwinNotification",
            ObjectSchema([
                .field("name", String.self),
                .field(
                    "state", UInt64.self,
                    doc:
                        "The name's 64-bit notify state when the event was handled; 0 also means the poster never set one. Values above 2^53 lose precision."
                ),
            ]))
    }

    public static var examples: [Self] {
        [Self(name: "com.example.ping", state: 0), Self(name: "com.example.level", state: 3)]
    }
}

public enum DarwinNotificationEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "darwin.notification",
        "A notify(3) name in `names` was posted. notify(3) coalesces posts that arrive before the previous one was handled, and `state` is read when handled, so it may be newer than the post.",
        mechanism: .push, semantics: .occurrence, loss: .coalesced,
        observation: .named,
        source: "notify_register_dispatch, notify_get_state"
    )

    public static func makeSource(
        _ parameters: NotificationNamesParameters, environment: SourceEnvironment,
        emit: Emitter<DarwinNotificationPayload>
    ) throws -> any EventSource {
        DarwinNotifySource(names: parameters.names) { name, token in
            var state: UInt64 = 0
            // A failed read leaves 0, the same value as "never set".
            _ = notify_get_state(token, &state)
            emit(DarwinNotificationPayload(name: name, state: state))
        }
    }
}

// MARK: - thermal.pressure

public struct ThermalPressurePayload: EventPayload, Equatable {
    /// `OSThermalPressureLevel` as declared for macOS in
    /// <libkern/OSThermalNotification.h>: nominal 0, moderate 1, heavy 2,
    /// trapping 3, sleeping 4. (The "light" level exists only in the
    /// non-macOS branch of that header, with different numbers.)
    public enum Level: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case nominal, moderate, heavy, trapping, sleeping

        init?(raw: UInt64) {
            switch raw {
            case 0: self = .nominal
            case 1: self = .moderate
            case 2: self = .heavy
            case 3: self = .trapping
            case 4: self = .sleeping
            default: return nil
            }
        }
    }

    public let level: Level?
    public let raw: UInt64

    public init(raw: UInt64) {
        level = Level(raw: raw)
        self.raw = raw
    }

    public static var schema: TypeSchema {
        .named(
            "ThermalPressure",
            ObjectSchema([
                .optional("level", Level.self, doc: "Absent when `raw` is not a level macOS declares."),
                .field("raw", UInt64.self, doc: "The notify state as posted (OSThermalPressureLevel)."),
            ]))
    }

    public static var examples: [Self] { [Self(raw: 0), Self(raw: 2), Self(raw: 99)] }
}

public enum ThermalPressureEvent: EventKind {
    static let name = String(cString: kOSThermalNotificationPressureLevelName)

    public static let descriptor = EventDescriptor(
        "thermal.pressure",
        "The system thermal pressure level changed. The current level is delivered first. Finer-grained than thermal.state; temperatures and fan speeds are not reported.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source: "notify(3) kOSThermalNotificationPressureLevelName (com.apple.system.thermalpressurelevel)"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<ThermalPressurePayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        return DarwinNotifySource(
            names: [name],
            initial: { reporter.report { DarwinNotifySource.state(of: name).map(ThermalPressurePayload.init(raw:)) } },
            handler: { _, token in
                reporter.report {
                    var state: UInt64 = 0
                    guard notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK) else { return nil }
                    return ThermalPressurePayload(raw: state)
                }
            })
    }
}

// MARK: - network.hostname

public struct HostNamesPayload: EventPayload, Equatable {
    public let localHostName: String?
    public let computerName: String?

    public static var schema: TypeSchema {
        .named(
            "HostNames",
            ObjectSchema([
                .optional(
                    "localHostName", String.self,
                    doc: "Bonjour name without \".local\", e.g. \"studio\". Absent when unset."),
                .optional("computerName", String.self, doc: "User-visible computer name. Absent when unset."),
            ]))
    }

    public static var examples: [Self] {
        [Self(localHostName: "studio", computerName: "Studio"), Self(localHostName: nil, computerName: nil)]
    }

    static func current() -> Self {
        Self(
            localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
            computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?)
    }
}

public enum HostNameEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "network.hostname",
        "The local host name (Bonjour) or the computer name changed. Current names are delivered first. The BSD hostname and DNS names are not reported.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source:
            "SCDynamicStore notification keys ComputerName and HostNames; SCDynamicStoreCopyLocalHostName, SCDynamicStoreCopyComputerName"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<HostNamesPayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        return DynamicStoreKeySource(
            keys: [SCDynamicStoreKeyCreateComputerName(nil) as String, SCDynamicStoreKeyCreateHostNames(nil) as String]
        ) { _ in
            reporter.report(HostNamesPayload.current)
        }
    }
}

// MARK: - pasteboard.changed

public struct PasteboardChangePayload: EventPayload, Equatable {
    public let changeCount: Int

    public static var schema: TypeSchema {
        .named(
            "PasteboardChange",
            ObjectSchema([
                .field(
                    "changeCount", Int.self,
                    doc: "The general pasteboard's change counter; it increases each time any app writes to it.")
            ]))
    }

    public static var examples: [Self] { [Self(changeCount: 117)] }
}

public enum PasteboardChangedEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 1.0
    public static let intervalRange = 0.25...60.0

    public static let descriptor = EventDescriptor(
        "pasteboard.changed",
        "Something was written to the general pasteboard (clipboard). Checked every `interval` seconds, so several writes between checks are one event. The contents, their types and the writing app are never read or reported.",
        mechanism: .poll, semantics: .occurrence, loss: .lossy,
        observation: .named,
        source: "NSPasteboard.general.changeCount"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<PasteboardChangedEvent>, environment: SourceEnvironment,
        emit: Emitter<PasteboardChangePayload>
    ) throws -> any EventSource {
        // Only the counter is read: reading contents or types can raise the
        // macOS pasteboard privacy alert.
        makeSource(interval: parameters.interval, changeCount: { NSPasteboard.general.changeCount }, emit: emit)
    }

    /// The first tick records the baseline; later ticks emit when the
    /// counter differs from the previous tick's.
    static func makeSource(
        interval: Double, changeCount: @escaping @Sendable () -> Int,
        emit: Emitter<PasteboardChangePayload>
    ) -> PollingSource {
        let last = Mutex<Int?>(nil)
        return PollingSource(label: "pasteboard", interval: interval) {
            let count = changeCount()
            let changed = last.withLock { last -> Bool in
                defer { last = count }
                return last.map { $0 != count } ?? false
            }
            if changed { emit(PasteboardChangePayload(changeCount: count)) }
        }
    }
}
