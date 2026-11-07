import Foundation
import MeerkatKit

/// An effect a handler asked for, decoded from the host's JSON.
///
/// The host is untrusted (it runs user code). The request is first checked
/// against its schema in the effect catalog (`EffectCatalog`): its fields,
/// their types and bounds, and nothing undeclared. The typed decode below
/// then adds the checks a schema cannot express. `EffectExecutor` looks at
/// grants only after both.
struct EffectRequest: Sendable, Equatable {
    /// The effect's catalog entry.
    let descriptor: EffectDescriptor
    /// What an allow-list or path-list grant is checked against: the request
    /// field `descriptor.grant` names, as the rule meant it. Nil for any
    /// other grant.
    let subject: String?
    let action: Action

    var kind: String { descriptor.kind }

    /// Whether the effect acts on the directory entry its path names rather
    /// than on what a symlink there leads to: moving to the Trash moves the
    /// link itself. Its path is checked in that form (`CapabilityGrants.entry`),
    /// against grants and protected paths both.
    var actsOnEntry: Bool {
        if case .trash = action { true } else { false }
    }

    init(_ raw: JSONValue, home: String = NSHomeDirectory()) throws {
        guard var fields = raw.objectValue, let kind = fields.removeValue(forKey: "kind")?.stringValue else {
            throw EffectError.invalid("effect request has no kind")
        }
        let catalog = EffectCatalog.standard
        guard let descriptor = catalog.effect(kind) else { throw EffectError.invalid("unknown effect \"\(kind)\"") }
        let violations = SchemaValidator.violations(of: .object(fields), against: descriptor.request, at: "request")
        guard violations.isEmpty else {
            throw EffectError.invalid("\(kind): " + violations.joined(separator: "; "))
        }
        let reader = FieldReader(fields: fields, context: kind, home: home)
        self.descriptor = descriptor
        action = try Action(kind: kind, reader: reader)
        if case .listed(let key, let field) = descriptor.grant {
            subject = catalog.grant(key)?.shape == .pathList ? try reader.path(field) : try reader.string(field)
        } else {
            subject = nil
        }
    }
}

extension EffectRequest {
    /// What the effect does, typed.
    enum Action: Sendable, Equatable {
        case stateGet(key: String)
        case stateSet(key: String, value: JSONValue)
        case stateDelete(key: String)
        case notify(NotificationSpec)
        case withdrawNotification(id: String)
        case signal(target: ProcessIdentity, signal: ProcessSignal)
        case priority(target: ProcessIdentity, priority: ProcessPriority)
        case nice(target: ProcessIdentity, nice: Int32)
        case exec(ExecSpec)
        case http(HTTPSpec)
        case record(RecordSpec)
        case preventSleep(PreventSleepSpec)
        case allowSleep(id: String)
        case audioDefaultDevice(uid: String, scope: AudioScope)
        case audioVolume(volume: Double, scope: AudioScope, device: String?)
        case audioMute(muted: Bool, scope: AudioScope, device: String?)
        case openApplication(bundleId: String, activate: Bool)
        case controlApplication(bundleId: String, action: AppAction)
        case openURL(URL)
        case ejectVolume(path: String)
        case trash(path: String)
        case setTags(path: String, tags: [String])
        case readDefault(domain: String, key: String)
        case writeDefault(domain: String, key: String, value: JSONValue)
        case deleteDefault(domain: String, key: String)
        case runShortcut(ShortcutSpec)
        case wifiPower(on: Bool)
        case readClipboard
        case writeClipboard(text: String)
        case listWindows(bundleId: String)
        case setWindow(WindowChange)
        case darkMode(on: Bool)

        fileprivate init(kind: String, reader: FieldReader) throws {
            switch kind {
            case "state.get":
                self = .stateGet(key: try reader.key())
            case "state.set":
                let value = reader.fields["value"] ?? .null
                guard value.canonicalString.utf8.count <= 1 << 20 else {
                    throw EffectError.invalid("state.set: values are limited to 1 MiB of JSON")
                }
                self = .stateSet(key: try reader.key(), value: value)
            case "state.delete":
                self = .stateDelete(key: try reader.key())
            case "notify":
                self = .notify(try NotificationSpec(reader))
            case "notify.withdraw":
                self = .withdrawNotification(id: try reader.notificationID("id"))
            case "process.signal":
                self = .signal(target: try reader.target(), signal: try reader.choice("signal"))
            case "process.priority":
                self = .priority(target: try reader.target(), priority: try reader.choice("priority"))
            case "process.nice":
                self = .nice(target: try reader.target(), nice: Int32(try reader.number("nice")))
            case "exec":
                self = .exec(try ExecSpec(reader))
            case "http":
                self = .http(try HTTPSpec(reader))
            case "store.record":
                self = .record(try RecordSpec(reader))
            case "power.preventSleep":
                self = .preventSleep(try PreventSleepSpec(reader))
            case "power.allowSleep":
                self = .allowSleep(id: try reader.identifier("id"))
            case "audio.setDefaultDevice":
                self = .audioDefaultDevice(uid: try reader.string("device"), scope: try reader.scope())
            case "audio.setVolume":
                self = .audioVolume(
                    volume: try reader.number("volume"), scope: try reader.scope(),
                    device: try reader.optionalString("device"))
            case "audio.setMute":
                self = .audioMute(
                    muted: try reader.bool("muted"), scope: try reader.scope(),
                    device: try reader.optionalString("device"))
            case "apps.open":
                self = .openApplication(
                    bundleId: try reader.bundleId(), activate: try reader.optionalBool("activate") ?? true)
            case "apps.activate":
                self = .controlApplication(bundleId: try reader.bundleId(), action: .activate)
            case "apps.hide":
                self = .controlApplication(bundleId: try reader.bundleId(), action: .hide)
            case "apps.unhide":
                self = .controlApplication(bundleId: try reader.bundleId(), action: .unhide)
            case "apps.quit":
                self = .controlApplication(
                    bundleId: try reader.bundleId(), action: .quit(force: try reader.optionalBool("force") ?? false))
            case "urls.open":
                let text = try reader.string("url")
                guard let url = URL(string: text), url.scheme != nil else {
                    throw EffectError.invalid("urls.open: \"\(text)\" is not a URL with a scheme")
                }
                self = .openURL(url)
            case "volumes.eject":
                self = .ejectVolume(path: try reader.path("path"))
            case "files.trash":
                self = .trash(path: try reader.path("path"))
            case "files.setTags":
                let tags = try reader.optionalStrings("tags") ?? []
                guard tags.count <= 64, tags.allSatisfy({ !$0.isEmpty && $0.count <= 255 && !$0.contains("\n") }) else {
                    throw EffectError.invalid("files.setTags: at most 64 tags of 1–255 characters, without line breaks")
                }
                self = .setTags(path: try reader.path("path"), tags: tags)
            case "defaults.read":
                self = .readDefault(domain: try reader.identifier("domain"), key: try reader.identifier("key"))
            case "defaults.write":
                let value = reader.fields["value"] ?? .null
                guard value != .null, value.canonicalString.utf8.count <= 1 << 20 else {
                    throw EffectError.invalid("defaults.write: value must be non-null JSON of at most 1 MiB")
                }
                self = .writeDefault(
                    domain: try reader.identifier("domain"), key: try reader.identifier("key"), value: value)
            case "defaults.delete":
                self = .deleteDefault(domain: try reader.identifier("domain"), key: try reader.identifier("key"))
            case "shortcuts.run":
                self = .runShortcut(try ShortcutSpec(reader))
            case "wifi.setPower":
                self = .wifiPower(on: try reader.bool("on"))
            case "clipboard.read":
                self = .readClipboard
            case "clipboard.write":
                let text = try reader.string("text")
                guard text.utf8.count <= 1 << 20 else {
                    throw EffectError.invalid("clipboard.write: text is limited to 1 MiB")
                }
                self = .writeClipboard(text: text)
            case "windows.list":
                self = .listWindows(bundleId: try reader.bundleId())
            case "windows.set":
                self = .setWindow(
                    WindowChange(
                        bundleId: try reader.bundleId(), index: Int(try reader.number("index")),
                        x: try reader.optionalNumber("x"),
                        y: try reader.optionalNumber("y"), width: try reader.optionalNumber("width"),
                        height: try reader.optionalNumber("height"), minimized: try reader.optionalBool("minimized"),
                        raise: try reader.optionalBool("raise") ?? false))
            case "appearance.setDark":
                self = .darkMode(on: try reader.bool("on"))
            default:
                // In the catalog but not decoded here: a test keeps the two in
                // step, so this is a daemon bug, not a rule's.
                throw EffectError.invalid("\(kind) is not implemented by this daemon")
            }
        }
    }
}

struct PreventSleepSpec: Sendable, Equatable {
    let id: String
    let reason: String
    let display: Bool
    let timeout: Double

    fileprivate init(_ reader: FieldReader) throws {
        id = try reader.identifier("id")
        reason = try reader.string("reason")
        guard !reason.isEmpty, reason.count <= 256 else {
            throw EffectError.invalid("power.preventSleep: reason must be 1–256 characters")
        }
        display = try reader.optionalBool("display") ?? false
        timeout = try reader.number("timeoutSeconds")
    }
}

struct ShortcutSpec: Sendable, Equatable {
    let name: String
    let input: String?
    let timeout: Double

    fileprivate init(_ reader: FieldReader) throws {
        name = try reader.identifier("name")
        input = try reader.optionalString("input")
        guard (input?.utf8.count ?? 0) <= 1 << 20 else {
            throw EffectError.invalid("shortcuts.run: input is limited to 1 MiB")
        }
        timeout = try reader.optionalNumber("timeoutSeconds") ?? 10
    }
}

struct ExecSpec: Sendable, Equatable {
    let path: String
    let arguments: [String]
    let timeout: Double
    let stdin: String?

    init(path: String, arguments: [String], timeout: Double, stdin: String?) {
        self.path = path
        self.arguments = arguments
        self.timeout = timeout
        self.stdin = stdin
    }

    fileprivate init(_ reader: FieldReader) throws {
        path = try reader.string("path")
        arguments = try reader.optionalStrings("args") ?? []
        timeout = try reader.optionalNumber("timeoutSeconds") ?? 10
        stdin = try reader.optionalString("stdin")
    }
}

struct HTTPSpec: Sendable, Equatable {
    let url: URL
    let method: HTTPMethod
    let headers: [String: String]
    let body: String?
    let timeout: Double

    fileprivate init(_ reader: FieldReader) throws {
        let text = try reader.string("url")
        guard let url = URL(string: text), url.scheme != nil, url.host != nil else {
            throw EffectError.invalid("http: \"\(text)\" is not an absolute URL")
        }
        self.url = url
        method = try reader.optionalChoice("method") ?? .get
        headers = try reader.optionalStringMap("headers") ?? [:]
        body = try reader.optionalString("body")
        timeout = try reader.optionalNumber("timeoutSeconds") ?? 10
    }
}

struct NotificationSpec: Sendable, Equatable {
    let title: String
    let subtitle: String?
    let body: String?
    /// The rule's own name for the notification; posting the same id again
    /// replaces it. Nil posts one that cannot be replaced or withdrawn.
    let id: String?
    /// Groups the rule's notifications further; they are always grouped by
    /// rule.
    let group: String?
    let sound: Bool
    let actions: [NotificationAction]
    /// Returned with the response, so a responder needs no lookup.
    let data: JSONValue?

    static let actionLimit = 4
    static let dataLimit = 4096

    init(
        title: String, subtitle: String? = nil, body: String? = nil, id: String? = nil, group: String? = nil,
        sound: Bool = false, actions: [NotificationAction] = [], data: JSONValue? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.id = id
        self.group = group
        self.sound = sound
        self.actions = actions
        self.data = data
    }

    fileprivate init(_ reader: FieldReader) throws {
        title = try reader.string("title")
        guard !title.isEmpty, title.count <= 256 else {
            throw EffectError.invalid("notify: title must be 1–256 characters")
        }
        subtitle = try reader.optionalString("subtitle")
        body = try reader.optionalString("body")
        id = try reader.optionalNotificationID("id")
        group = try reader.optionalNotificationID("group")
        sound = try reader.optionalBool("sound") ?? false
        actions = try (reader.optionalObjects("actions") ?? []).map(NotificationAction.init)
        guard actions.count <= Self.actionLimit else {
            throw EffectError.invalid("notify: at most \(Self.actionLimit) actions")
        }
        guard Set(actions.map(\.id)).count == actions.count else {
            throw EffectError.invalid("notify: action ids must be unique")
        }
        switch reader.fields["data"] {
        case nil, .null?: data = nil
        case let value?:
            guard value.canonicalString.utf8.count <= Self.dataLimit else {
                throw EffectError.invalid("notify: data is limited to \(Self.dataLimit) bytes of JSON")
            }
            data = value
        }
    }
}

/// A button on a notification. Its id comes back as the response's
/// `action`.
struct NotificationAction: Sendable, Hashable, Codable {
    let id: String
    let title: String
    let destructive: Bool
    /// Present for a reply field; its text comes back as the response's
    /// `text`.
    let input: TextInput?

    struct TextInput: Sendable, Hashable, Codable {
        let placeholder: String?
    }

    /// The action names a response uses for the click on the notification
    /// itself and for dismissing it.
    static let reservedIDs: Set<String> = ["default", "dismiss"]

    init(id: String, title: String, destructive: Bool = false, input: TextInput? = nil) {
        self.id = id
        self.title = title
        self.destructive = destructive
        self.input = input
    }

    fileprivate init(_ reader: FieldReader) throws {
        id = try reader.string("id")
        guard !id.isEmpty, id.utf8.count <= 64, !Self.reservedIDs.contains(id) else {
            throw EffectError.invalid(
                "notify: an action id must be 1–64 bytes and not \(Self.reservedIDs.sorted().joined(separator: " or "))"
            )
        }
        title = try reader.string("title")
        guard !title.isEmpty, title.count <= 64 else {
            throw EffectError.invalid("notify: an action title must be 1–64 characters")
        }
        destructive = try reader.optionalBool("destructive") ?? false
        input = try reader.optionalObject("input").map { TextInput(placeholder: try $0.optionalString("placeholder")) }
    }
}

struct RecordSpec: Sendable, Equatable {
    let label: String
    let window: Double
    let top: Int
    let systemOnly: Bool
    let retain: Int?

    fileprivate init(_ reader: FieldReader) throws {
        label = try reader.string("label")
        guard !label.isEmpty else { throw EffectError.invalid("store.record: label must not be empty") }
        window = try reader.optionalNumber("windowSeconds") ?? 20
        top = Int(try reader.optionalNumber("top") ?? 20)
        systemOnly = try reader.optionalBool("systemOnly") ?? false
        retain = try reader.optionalNumber("retain").map(Int.init)
    }
}

enum EffectError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    case notGranted(String)
    case failed(String)

    var description: String {
        switch self {
        case .invalid(let message): return message
        case .notGranted(let grant): return "not granted: add \(grant) to this rule's capabilities"
        case .failed(let message): return message
        }
    }
}

/// Typed reads of request fields with error messages that name the effect.
///
/// `SchemaValidator` has proved each field's type, bounds and enumeration by
/// the time a reader exists, so a value that does not read means the catalog
/// and this decode disagree. That still refuses the request.
private struct FieldReader {
    let fields: [String: JSONValue]
    let context: String
    var home: String = NSHomeDirectory()

    private func mismatch(_ key: String) -> EffectError {
        .invalid("\(context): \(key) does not match the effect catalog")
    }

    func required<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T {
        guard let value = fields[key].flatMap(read) else { throw mismatch(key) }
        return value
    }

    func optional<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T? {
        guard let value = fields[key] else { return nil }
        guard let result = read(value) else { throw mismatch(key) }
        return result
    }

    func number(_ key: String) throws -> Double { try required(key, \.numberValue) }
    func bool(_ key: String) throws -> Bool { try required(key, \.boolValue) }
    func string(_ key: String) throws -> String { try required(key, \.stringValue) }

    func choice<T: RawRepresentable>(_ key: String) throws -> T where T.RawValue == String {
        try required(key) { $0.stringValue.flatMap(T.init(rawValue:)) }
    }

    func optionalChoice<T: RawRepresentable>(_ key: String) throws -> T? where T.RawValue == String {
        try optional(key) { $0.stringValue.flatMap(T.init(rawValue:)) }
    }

    func optionalNumber(_ key: String) throws -> Double? { try optional(key, \.numberValue) }
    func optionalBool(_ key: String) throws -> Bool? { try optional(key, \.boolValue) }
    func optionalString(_ key: String) throws -> String? { try optional(key, \.stringValue) }

    func optionalStrings(_ key: String) throws -> [String]? {
        try optional(key) { $0.arrayValue?.compactMap(\.stringValue) }
    }

    func optionalStringMap(_ key: String) throws -> [String: String]? {
        try optional(key) { $0.objectValue?.compactMapValues(\.stringValue) }
    }

    func optionalObject(_ key: String) throws -> FieldReader? {
        try optional(key) { $0.objectValue.map { FieldReader(fields: $0, context: context) } }
    }

    func optionalObjects(_ key: String) throws -> [FieldReader]? {
        try optional(key) { value in
            value.arrayValue?.compactMap { $0.objectValue.map { FieldReader(fields: $0, context: context) } }
        }
    }

    /// A rule-chosen name: an assertion id, a defaults domain or key, a
    /// shortcut name.
    func identifier(_ key: String) throws -> String {
        let value = try string(key)
        guard !value.isEmpty, value.utf8.count <= 256, !value.contains("\0") else {
            throw EffectError.invalid("\(context): \(key) must be 1–256 bytes")
        }
        return value
    }

    func bundleId() throws -> String {
        let value = try identifier("bundleId")
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw EffectError.invalid("\(context): \"\(value)\" is not a bundle identifier")
        }
        return value
    }

    func scope() throws -> AudioScope { try optionalChoice("direction") ?? .output }

    /// An absolute path, or one starting with `~/`; `..` is refused rather
    /// than resolved, so the grant check sees the path the rule meant.
    func path(_ key: String) throws -> String {
        var path = try string(key)
        if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.count > 1, !components.contains(".."), !path.contains("\0") else {
            throw EffectError.invalid("\(context): \(key) must be an absolute path without ..")
        }
        return path
    }

    /// A rule-chosen notification id or group: short, so the identifiers
    /// built from it stay within what the notification center stores.
    func notificationID(_ key: String) throws -> String {
        let value = try string(key)
        guard !value.isEmpty, value.utf8.count <= 256 else {
            throw EffectError.invalid("\(context): \(key) must be 1–256 bytes")
        }
        return value
    }

    func optionalNotificationID(_ key: String) throws -> String? {
        fields[key] == nil ? nil : try notificationID(key)
    }

    func key() throws -> String {
        let key = try string("key")
        guard !key.isEmpty, key.utf8.count <= 512 else {
            throw EffectError.invalid("\(context): key must be 1–512 bytes")
        }
        return key
    }

    /// A process instance; both fields are required so a reused pid can never
    /// be targeted.
    func target() throws -> ProcessIdentity {
        guard let target = fields["target"]?.objectValue,
            let pid = target["pid"]?.numberValue, pid > 0, pid == pid.rounded(), pid <= Double(Int32.max),
            let startedAt = target["startedAt"]?.numberValue, ProcessIdentity.startedAtRange.contains(startedAt)
        else {
            throw EffectError.invalid("\(context): target must be { pid, startedAt } from an event")
        }
        return ProcessIdentity(pid: pid_t(pid), startedAt: startedAt)
    }
}
