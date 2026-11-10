import Foundation
import MeerkatKit

/// An effect a handler asked for, decoded from the host's JSON.
///
/// The host is untrusted (it runs user code). The request is first checked
/// against its schema in the effect catalog (`EffectCatalog`): its fields,
/// their types, bounds and lengths, and nothing undeclared; then the
/// schema's defaults fill what it left out. The typed decode below adds only
/// the checks a schema cannot express. `EffectAuthorizer` looks at grants
/// only after both.
struct EffectRequest: Sendable, Equatable {
    let descriptor: EffectDescriptor
    /// What an allow-list or path-list grant is checked against: the request
    /// field `descriptor.grant` names, as the rule meant it. Nil for any
    /// other grant.
    let subject: String?
    /// The path the effect acts on, from the field its descriptor declares
    /// (`EffectDescriptor.Traits.path`); nil for an effect without one.
    let path: String?
    /// The request's fields, defaults included.
    let fields: [String: JSONValue]
    let action: Action

    var kind: String { descriptor.kind }

    init(_ raw: JSONValue, home: String = NSHomeDirectory()) throws {
        guard var fields = raw.objectValue, let kind = fields.removeValue(forKey: "kind")?.stringValue else {
            throw EffectError.invalid("effect request has no kind")
        }
        let catalog = EffectCatalog.standard
        guard let descriptor = catalog.effect(kind) else { throw EffectError.invalid("unknown effect \"\(kind)\"") }
        let admitted: [String: JSONValue]
        do {
            admitted = try descriptor.request.admit(.object(fields), at: "request")
        } catch {
            throw EffectError.invalid("\(kind): \(error)")
        }
        let reader = FieldReader(fields: admitted, context: kind, home: home)
        self.descriptor = descriptor
        self.fields = reader.fields
        path = try descriptor.traits.path.map { try reader.path($0.field) }
        action = try Action(descriptor.id, reader, path: path)
        switch descriptor.grant {
        case .listed(let key, _) where catalog.grant(key)?.shape == .pathList:
            // The catalog has a path grant name the path the effect acts
            // on, checked in the form protected paths are checked in.
            subject = path
        case .listed(_, let field):
            subject = try reader.string(field)
        case .none, .flag:
            subject = nil
        }
    }
}

extension EffectRequest {
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

        /// `path` is the request's (`EffectRequest.path`), decoded once from
        /// the field its descriptor declares.
        fileprivate init(_ kind: EffectKind, _ reader: FieldReader, path: String?) throws {
            func declaredPath() throws -> String {
                guard let path else { throw EffectError.invalid("\(kind.rawValue): declares no path to act on") }
                return path
            }
            switch kind {
            case .stateGet:
                self = .stateGet(key: try reader.string("key"))
            case .stateSet:
                self = .stateSet(
                    key: try reader.string("key"), value: try reader.value("value", limit: EffectLimits.valueBytes))
            case .stateDelete:
                self = .stateDelete(key: try reader.string("key"))
            case .notify:
                self = .notify(try NotificationSpec(reader))
            case .notifyWithdraw:
                self = .withdrawNotification(id: try reader.string("id"))
            case .processSignal:
                self = .signal(target: try reader.target(), signal: try reader.choice("signal"))
            case .processPriority:
                self = .priority(target: try reader.target(), priority: try reader.choice("priority"))
            case .processNice:
                self = .nice(target: try reader.target(), nice: try reader.int32("nice"))
            case .exec:
                self = .exec(try ExecSpec(reader))
            case .http:
                self = .http(try HTTPSpec(reader))
            case .storeRecord:
                self = .record(try RecordSpec(reader))
            case .preventSleep:
                self = .preventSleep(try PreventSleepSpec(reader))
            case .allowSleep:
                self = .allowSleep(id: try reader.string("id"))
            case .audioDefaultDevice:
                self = .audioDefaultDevice(uid: try reader.string("device"), scope: try reader.choice("direction"))
            case .audioVolume:
                self = .audioVolume(
                    volume: try reader.number("volume"), scope: try reader.choice("direction"),
                    device: try reader.optionalString("device"))
            case .audioMute:
                self = .audioMute(
                    muted: try reader.bool("muted"), scope: try reader.choice("direction"),
                    device: try reader.optionalString("device"))
            case .appsOpen:
                self = .openApplication(bundleId: try reader.bundleId(), activate: try reader.bool("activate"))
            case .appsActivate:
                self = .controlApplication(bundleId: try reader.bundleId(), action: .activate)
            case .appsHide:
                self = .controlApplication(bundleId: try reader.bundleId(), action: .hide)
            case .appsUnhide:
                self = .controlApplication(bundleId: try reader.bundleId(), action: .unhide)
            case .appsQuit:
                self = .controlApplication(
                    bundleId: try reader.bundleId(), action: .quit(force: try reader.bool("force")))
            case .urlsOpen:
                let text = try reader.string("url")
                guard let url = URL(string: text), url.scheme != nil else {
                    throw EffectError.invalid("urls.open: \"\(text)\" is not a URL with a scheme")
                }
                self = .openURL(url)
            case .volumesEject:
                self = .ejectVolume(path: try declaredPath())
            case .filesTrash:
                self = .trash(path: try declaredPath())
            case .filesSetTags:
                self = .setTags(path: try declaredPath(), tags: try reader.strings("tags"))
            case .defaultsRead:
                self = .readDefault(domain: try reader.string("domain"), key: try reader.string("key"))
            case .defaultsWrite:
                let value = try reader.value("value", limit: EffectLimits.valueBytes)
                guard value != .null else { throw EffectError.invalid("defaults.write: value must not be null") }
                self = .writeDefault(domain: try reader.string("domain"), key: try reader.string("key"), value: value)
            case .defaultsDelete:
                self = .deleteDefault(domain: try reader.string("domain"), key: try reader.string("key"))
            case .shortcutsRun:
                self = .runShortcut(try ShortcutSpec(reader))
            case .wifiPower:
                self = .wifiPower(on: try reader.bool("on"))
            case .clipboardRead:
                self = .readClipboard
            case .clipboardWrite:
                self = .writeClipboard(text: try reader.string("text"))
            case .windowsList:
                self = .listWindows(bundleId: try reader.bundleId())
            case .windowsSet:
                self = .setWindow(
                    WindowChange(
                        bundleId: try reader.bundleId(), index: try reader.integer("index"),
                        x: try reader.optionalNumber("x"), y: try reader.optionalNumber("y"),
                        width: try reader.optionalNumber("width"), height: try reader.optionalNumber("height"),
                        minimized: try reader.optionalBool("minimized"), raise: try reader.bool("raise")))
            case .appearanceDark:
                self = .darkMode(on: try reader.bool("on"))
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
        id = try reader.string("id")
        reason = try reader.string("reason")
        display = try reader.bool("display")
        timeout = try reader.number("timeoutSeconds")
    }
}

struct ShortcutSpec: Sendable, Equatable {
    let name: String
    let input: String?
    let timeout: Double

    fileprivate init(_ reader: FieldReader) throws {
        name = try reader.string("name")
        input = try reader.optionalString("input")
        timeout = try reader.number("timeoutSeconds")
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
        arguments = try reader.strings("args")
        timeout = try reader.number("timeoutSeconds")
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
        method = try reader.choice("method")
        headers = try reader.stringMap("headers")
        body = try reader.optionalString("body")
        timeout = try reader.number("timeoutSeconds")
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
        subtitle = try reader.optionalString("subtitle")
        body = try reader.optionalString("body")
        id = try reader.optionalString("id")
        group = try reader.optionalString("group")
        sound = try reader.bool("sound")
        actions = try reader.objects("actions").map(NotificationAction.init)
        guard Set(actions.map(\.id)).count == actions.count else {
            throw EffectError.invalid("notify: action ids must be unique")
        }
        // Null carries nothing back, so it is left out as an absent field is.
        data =
            (reader.fields["data"] ?? .null) == .null
            ? nil : try reader.value("data", limit: EffectLimits.notificationDataBytes)
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

    init(id: String, title: String, destructive: Bool = false, input: TextInput? = nil) {
        self.id = id
        self.title = title
        self.destructive = destructive
        self.input = input
    }

    fileprivate init(_ reader: FieldReader) throws {
        id = try reader.string("id")
        guard !NotificationResponse.reserved.contains(id) else {
            throw EffectError.invalid(
                "notify: an action id may not be \(NotificationResponse.reserved.joined(separator: " or "))")
        }
        title = try reader.string("title")
        destructive = try reader.bool("destructive")
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
        window = try reader.number("windowSeconds")
        top = try reader.integer("top")
        systemOnly = try reader.bool("systemOnly")
        retain = reader.fields["retain"] == nil ? nil : try reader.integer("retain")
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

/// Typed reads of request fields.
///
/// `SchemaValidator` has proved each field's type, bounds and length by the
/// time a reader exists, so a value that does not read means the catalog
/// and this decode disagree. That still refuses the request.
private struct FieldReader {
    /// Defaults filled at every depth (`ObjectSchema.admit`).
    let fields: [String: JSONValue]
    let context: String
    let home: String

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

    /// A whole number; `Int(exactly:)` is nil rather than a trap for one out
    /// of range, though the schema's bounds keep it in.
    func integer(_ key: String) throws -> Int { try required(key) { $0.numberValue.flatMap { Int(exactly: $0) } } }
    func int32(_ key: String) throws -> Int32 { try required(key) { $0.numberValue.flatMap { Int32(exactly: $0) } } }

    func choice<T: RawRepresentable>(_ key: String) throws -> T where T.RawValue == String {
        try required(key) { $0.stringValue.flatMap(T.init(rawValue:)) }
    }

    func optionalNumber(_ key: String) throws -> Double? { try optional(key, \.numberValue) }
    func optionalBool(_ key: String) throws -> Bool? { try optional(key, \.boolValue) }
    func optionalString(_ key: String) throws -> String? { try optional(key, \.stringValue) }

    func strings(_ key: String) throws -> [String] {
        try required(key) { value in
            value.arrayValue.flatMap { items in
                let strings = items.compactMap(\.stringValue)
                return strings.count == items.count ? strings : nil
            }
        }
    }

    func stringMap(_ key: String) throws -> [String: String] {
        try required(key) { value in
            value.objectValue.flatMap { object in
                let strings = object.compactMapValues(\.stringValue)
                return strings.count == object.count ? strings : nil
            }
        }
    }

    /// A JSON value, absent being null, within `limit` bytes as stored.
    func value(_ key: String, limit: Int) throws -> JSONValue {
        let value = fields[key] ?? .null
        guard value.canonicalString.utf8.count <= limit else {
            throw EffectError.invalid("\(context): \(key) is limited to \(TextBounds.size(limit)) of JSON")
        }
        return value
    }

    private func reader(_ fields: [String: JSONValue]) -> FieldReader {
        FieldReader(fields: fields, context: context, home: home)
    }

    func optionalObject(_ key: String) throws -> FieldReader? {
        try optional(key) { $0.objectValue.map(reader) }
    }

    func objects(_ key: String) throws -> [FieldReader] {
        try required(key) { value in
            value.arrayValue.flatMap { items in
                let objects = items.compactMap(\.objectValue)
                return objects.count == items.count ? objects.map(reader) : nil
            }
        }
    }

    func bundleId() throws -> String {
        let value = try string("bundleId")
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw EffectError.invalid("\(context): \"\(value)\" is not a bundle identifier")
        }
        return value
    }

    /// The effect's path, from the field its descriptor declares: absolute,
    /// or starting with `~/`; `..` is refused rather than resolved, so the
    /// grant and protected-path checks see the path the rule meant. Only
    /// that field is read, so an effect cannot act on a path those checks
    /// never see.
    func path(_ pathField: String) throws -> String {
        var path = try string(pathField)
        if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.count > 1, !components.contains(".."), !path.contains("\0") else {
            throw EffectError.invalid("\(context): \(pathField) must be an absolute path without ..")
        }
        return path
    }

    /// A process instance; both fields are required so a reused pid can never
    /// be targeted.
    func target() throws -> ProcessIdentity {
        let refusal = EffectError.invalid("\(context): target must be { pid, startedAt } from an event")
        guard let target = try optionalObject("target") else { throw refusal }
        guard let pid = Int32(exactly: try target.number("pid")), pid > 0,
            let identity = ProcessIdentity(pid: pid, startedAt: try target.number("startedAt"))
        else { throw refusal }
        return identity
    }
}
