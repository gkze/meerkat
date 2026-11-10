import Foundation

/// Every grant and every effect a rule can use, declared once.
///
/// The TypeScript `Grants` and `Context` types, the daemon's grant parsing
/// and authorization, the request checks and defaults, and the runtime's
/// `ctx` are all derived from this catalog (docs/design/effects.md). Each
/// effect's typed decode and the code that performs it stay hand-written in
/// the daemon, which switches over `EffectKind`, so neither can miss one.
public struct EffectCatalog: Sendable {
    public let grants: [GrantDescriptor]
    public let effects: [EffectDescriptor]
    private let grantsByPath: [String: GrantDescriptor]
    private let effectsByKind: [String: EffectDescriptor]

    /// Private: `.standard` is the only catalog, so nothing takes one as a
    /// parameter. Every fact the daemon relies on about the catalog's data
    /// is checked here, as it is made, so a catalog that breaks one never
    /// runs. Where the daemon reads such a fact it still fails closed rather
    /// than trusting it (`EffectAuthorizer.declared`, the path guards in
    /// `EffectRequest` and `EffectExecutor`).
    private init(grants: [GrantDescriptor], effects: [EffectDescriptor]) {
        self.grants = grants
        self.effects = effects
        let grantsByPath = Dictionary(grants.map { ($0.key, $0) }) { first, _ in
            preconditionFailure("grant \(first.key) declared twice")
        }
        self.grantsByPath = grantsByPath
        effectsByKind = Dictionary(effects.map { ($0.kind, $0) }) { first, _ in
            preconditionFailure("effect \(first.kind) declared twice")
        }
        let missing = EffectKind.allCases.filter { effectsByKind[$0.rawValue] == nil }
        precondition(missing.isEmpty, "effects without a descriptor: \(missing)")
        for grant in [GrantDescriptor.fsRead, .processObserve, .observe] {
            precondition(grantsByPath[grant.key] == grant, "observation grant \(grant.key) is not listed")
        }
        for effect in effects {
            let fields = Dictionary(effect.request.fields.map { ($0.name, $0.schema) }) { first, _ in first }
            switch effect.grant {
            case .none:
                break
            case .flag(let key):
                precondition(grantsByPath[key]?.shape == .flag, "\(effect.kind): \(key) is not a flag grant")
            case .listed(let key, let subject):
                let shape = grantsByPath[key]?.shape
                precondition(shape != nil && shape != .flag, "\(effect.kind): \(key) is not a list grant")
                precondition(
                    fields[subject].map { $0 != .boolean } == true, "\(effect.kind): \(subject) is not a subject field")
                // A grant of paths is checked against the path the effect
                // acts on, which protected paths are checked against too.
                precondition(
                    shape != .pathList
                        || (effect.traits.path?.field == subject && effect.traits.path?.isProtected == true),
                    "\(effect.kind): its path grant does not name its protected path")
            }
            if effect.traits.path?.isProtected == true {
                precondition(
                    effect.grant.grantKey.flatMap { grantsByPath[$0]?.shape } == .pathList,
                    "\(effect.kind): a protected path without a path grant")
                // It runs under the rename hold, which cannot wait for a
                // permission to be asked.
                precondition(effect.automation == nil, "\(effect.kind): Automation on a protected path")
            }
            if case .positional(let names) = effect.arguments {
                for name in names { precondition(fields[name] != nil, "\(effect.kind): no field \(name)") }
            }
            // Each check a trait declares reads its field, which must be
            // there for the check to happen: required, or defaulted.
            for field in [
                effect.traits.path?.field, effect.traits.changesDefaultsDomain, effect.traits.lastsWithinTimeout,
            ]
            .compactMap({ $0 }) {
                let declared = effect.request.fields.first { $0.name == field }
                precondition(
                    declared.map { !$0.optional || $0.default != nil } == true,
                    "\(effect.kind): \(field) is not always present")
            }
        }
    }

    public func grant(_ key: String) -> GrantDescriptor? { grantsByPath[key] }
    /// By wire name, as a request names it.
    public func effect(_ kind: String) -> EffectDescriptor? { effectsByKind[kind] }

    /// The `capabilities` text that would grant `key`, with `entry` in its
    /// list or as its level: `process: { signal: true }`,
    /// `exec: { allow: ["/usr/bin/true"] }`, `process: { observe: "own" }`.
    /// Refusals name it, so the fix is in the message.
    public func grantText(_ key: String, entry: String?) -> String {
        let path = key.split(separator: ".").map(String.init)
        let leaf: String =
            switch grant(key)?.shape {
            case .allowList?: "{ allow: [\"\(entry ?? "…")\"] }"
            case .pathList?: "[\"\(entry ?? "…")\"]"
            case .level(let levels)?: "\"\(entry ?? levels.first ?? "…")\""
            case .flag?, nil: "true"
            }
        return path.dropLast().reversed().reduce("\(path.last ?? key): \(leaf)") { inner, name in
            "\(name): { \(inner) }"
        }
    }

    /// What the runtime needs to build `ctx`: each effect's wire name, its
    /// place on `ctx`, how its arguments map to request fields and how its
    /// result comes back. Sent with every `Load`.
    public var runtimeTable: JSONValue {
        .array(
            effects.map { effect in
                let arguments: JSONValue =
                    switch effect.arguments {
                    case .request: .null
                    case .none: .array([])
                    case .positional(let names): .array(names.map(JSONValue.string))
                    }
                let result: String =
                    switch effect.result {
                    case .none: "none"
                    case .value: "value"
                    case .optional: "optional"
                    }
                return .object([
                    "kind": .string(effect.kind),
                    "method": .array(effect.method.map(JSONValue.string)),
                    "arguments": arguments,
                    "result": .string(result),
                ])
            })
    }
}

// MARK: - Grants

/// One entry in a rule's `capabilities`, by path (`process.signal`): what
/// a rule may do, or, for the observation grants (`process.observe`,
/// `observe`), which events it may see (`EventDescriptor.Observation`).
public struct GrantDescriptor: Sendable, Equatable {
    public let path: [String]
    public let shape: Shape
    public let doc: String

    public enum Shape: Sendable, Equatable {
        /// `true` grants it.
        case flag
        /// `{ allow: [...] }`: the request's subject must be listed.
        case allowList(Subject)
        /// `[...]` of absolute path prefixes (`~/` is home): the request's
        /// path must be inside one.
        case pathList
        /// One of these names, each including the ones before it.
        case level([String])
    }

    /// How an allow list's entries are written and matched.
    public enum Subject: String, Sendable, Equatable {
        /// An absolute, normalized executable path, matched exactly.
        case absolutePath
        /// `scheme://host[:port]`, matched against the request URL's origin.
        case origin
        /// A URL scheme such as `https`, matched against the request URL's.
        case scheme
        /// A name matched exactly: a defaults domain, a shortcut.
        case name
        /// An event kind in the event catalog whose observation is `named`.
        case eventKind
    }

    public init(_ path: [String], _ shape: Shape, doc: String) {
        self.path = path
        self.shape = shape
        self.doc = doc
    }

    /// `process.signal`.
    public var key: String { path.joined(separator: ".") }
}

extension GrantDescriptor {
    /// The grants observation needs (`EventDescriptor.observationGrant`),
    /// declared here and listed in the catalog, so an event kind refers to
    /// the grant itself.
    public static let fsRead = GrantDescriptor(
        ["fs", "read"], .pathList,
        doc:
            "Path prefixes the rule's file may read with Deno's file APIs. Absolute, or starting with `~/`. The file is the unit: its code may use any of its rules' grants. The daemon's own state and the rules directory are never granted, and a symlink inside a granted directory is followed."
    )
    /// `process.observe`'s levels, least first.
    public enum ProcessLevel: String, Sendable, CaseIterable {
        case own, all
    }

    public static let processObserve = GrantDescriptor(
        ["process", "observe"], .level(ProcessLevel.allCases.map(\.rawValue)),
        doc:
            "Observe processes and applications: `\"own\"` your own processes (events about other users' are not delivered, and their rows are left out), `\"all\"` every user's."
    )
    public static let observe = GrantDescriptor(
        ["observe"], .allowList(.eventKind),
        doc:
            "Event kinds that carry what you are doing, text other programs wrote, or other people (window titles, the log, notifications, nearby devices), which the rule may observe."
    )
}

// MARK: - Effects

/// Every effect, by its wire name. The daemon's decode and its executor
/// switch over it, so an effect the catalog declares cannot go unhandled;
/// the catalog refuses to exist without a descriptor for each.
public enum EffectKind: String, Sendable, CaseIterable {
    case stateGet = "state.get"
    case stateSet = "state.set"
    case stateDelete = "state.delete"
    case notify
    case notifyWithdraw = "notify.withdraw"
    case processSignal = "process.signal"
    case processPriority = "process.priority"
    case processNice = "process.nice"
    case exec
    case http
    case storeRecord = "store.record"
    case preventSleep = "power.preventSleep"
    case allowSleep = "power.allowSleep"
    case audioDefaultDevice = "audio.setDefaultDevice"
    case audioVolume = "audio.setVolume"
    case audioMute = "audio.setMute"
    case appsOpen = "apps.open"
    case appsActivate = "apps.activate"
    case appsHide = "apps.hide"
    case appsUnhide = "apps.unhide"
    case appsQuit = "apps.quit"
    case urlsOpen = "urls.open"
    case volumesEject = "volumes.eject"
    case filesTrash = "files.trash"
    case filesSetTags = "files.setTags"
    case defaultsRead = "defaults.read"
    case defaultsWrite = "defaults.write"
    case defaultsDelete = "defaults.delete"
    case shortcutsRun = "shortcuts.run"
    case wifiPower = "wifi.setPower"
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case windowsList = "windows.list"
    case windowsSet = "windows.set"
    case appearanceDark = "appearance.setDark"
}

public struct EffectDescriptor: Sendable, Equatable {
    public let id: EffectKind
    /// Where the method is on `ctx`: `["process", "signal"]`.
    public let method: [String]
    public let arguments: Arguments
    /// The request, with each field's bounds and default. `kind` is added
    /// on the wire.
    public let request: ObjectSchema
    /// The interface the declarations name the request (`ExecRequest`); nil
    /// to write it out where it is used.
    public let requestName: String?
    public let result: Result
    public let grant: GrantRequirement
    /// A privacy permission the effect needs besides its grant.
    public let permission: EventDescriptor.Permission?
    /// The app the effect sends Apple Events to, which Meerkat needs
    /// Automation permission for.
    public let automation: AutomationTarget?
    public let traits: Traits
    public let summary: String

    /// The wire name in effect requests: `process.signal`.
    public var kind: String { id.rawValue }

    public enum Arguments: Sendable, Equatable {
        /// The method takes the request object: `exec(request)`.
        case request
        /// The method takes no arguments.
        case none
        /// The method takes these request fields in order: `signal(target, signal)`.
        case positional([String])
    }

    public enum Result: Sendable, Equatable {
        case none
        case value(TypeSchema)
        /// A value that may be absent: `{ found, value }` on the wire,
        /// `T | undefined` in JavaScript. `generic` declares the method's
        /// type parameter `T extends JSONValue`, as `state.get<T>` has.
        case optional(TypeSchema, generic: Bool = false)
    }

    public enum GrantRequirement: Sendable, Equatable {
        /// Always available.
        case none
        /// The flag grant at this key.
        case flag(String)
        /// The allow-list or path-list grant at this key, checked against
        /// the request field `subject`.
        case listed(String, subject: String)

        public var grantKey: String? {
            switch self {
            case .none: nil
            case .flag(let key), .listed(let key, _): key
            }
        }
    }

    /// What the daemon checks besides the grant, declared here so an effect
    /// that has one of these cannot leave out its check
    /// (docs/design/effects.md, "Protected state").
    public struct Traits: Sendable, Equatable {
        /// The request field naming the path the effect acts on. The daemon
        /// decodes a path only from this field.
        public var path: PathField?
        /// The request field naming a defaults domain the effect changes:
        /// Meerkat's own is refused, whatever the grant.
        public var changesDefaultsDomain: String?
        /// The request field, in seconds, that must be less than the rule's
        /// `timeoutSeconds`: the effect waits that long within the
        /// invocation, so as long a wait can only time it out.
        public var lastsWithinTimeout: String?

        public init(path: PathField? = nil, changesDefaultsDomain: String? = nil, lastsWithinTimeout: String? = nil) {
            self.path = path
            self.changesDefaultsDomain = changesDefaultsDomain
            self.lastsWithinTimeout = lastsWithinTimeout
        }
    }

    public struct PathField: Sendable, Equatable {
        public let field: String
        public let form: Form

        public init(_ field: String, _ form: Form) {
            self.field = field
            self.form = form
        }

        public enum Form: Sendable, Equatable {
            /// Acts on the directory entry itself: a link there is moved,
            /// not followed. Checked in that form against grants and
            /// protected paths, and done with rules' renames held off.
            case entry
            /// Acts on what the path leads to, links followed. Checked and
            /// done as `entry` is.
            case target
            /// A volume's mount point: the volume is acted on, not a file in
            /// it. The `volumes.eject` grant covers any removable volume, so
            /// the path is not a protected path's to refuse.
            case mountPoint
        }

        /// Whether protected paths are refused and renames held off.
        public var isProtected: Bool { form != .mountPoint }
    }

    public init(
        _ kind: EffectKind, method: [String], arguments: Arguments = .request,
        request: ObjectSchema = ObjectSchema([]), requestName: String? = nil, result: Result = .none,
        grant: GrantRequirement,
        permission: EventDescriptor.Permission? = nil, automation: AutomationTarget? = nil, traits: Traits = Traits(),
        summary: String
    ) {
        id = kind
        self.method = method
        self.arguments = arguments
        self.request = request
        self.requestName = requestName
        self.result = result
        self.grant = grant
        self.permission = permission
        self.automation = automation
        self.traits = traits
        self.summary = summary
    }

    /// The request as the declarations show it: by name when it has one.
    public var requestType: TypeSchema { requestName.map { .named($0, request) } ?? .object(request) }
}

/// An app an effect sends Apple Events to (Privacy & Security › Automation).
public struct AutomationTarget: Sendable, Equatable {
    public let bundleId: String
    public let name: String

    public static let systemEvents = AutomationTarget(bundleId: "com.apple.systemevents", name: "System Events")
}

/// Size limits a request's schema cannot state: those on JSON values.
public enum EffectLimits {
    /// A stored state value, a written default.
    public static let valueBytes = 1 << 20
    /// The data a notification carries back in its response.
    public static let notificationDataBytes = 4096
    /// What one rule's persistent state may hold in all.
    public static let stateKeys = 1024
    public static let stateBytes = 8 << 20
}

// MARK: - The standard catalog

extension EffectCatalog {
    public static let standard = EffectCatalog(grants: StandardEffects.grants, effects: StandardEffects.effects)
}

private enum StandardEffects {
    typealias Field = ObjectSchema.Field
    typealias Traits = EffectDescriptor.Traits
    typealias PathField = EffectDescriptor.PathField

    static let grants: [GrantDescriptor] = [
        GrantDescriptor(["notify"], .flag, doc: "Post and withdraw notifications."),
        GrantDescriptor(["process", "signal"], .flag, doc: "Signal your own processes."),
        GrantDescriptor(["process", "priority"], .flag, doc: "Lower the priority of your own processes."),
        .processObserve,
        .observe,
        GrantDescriptor(["exec"], .allowList(.absolutePath), doc: "Absolute executable paths the rule may run."),
        GrantDescriptor(
            ["http"], .allowList(.origin), doc: "Origins (`https://host[:port]`) the rule may send requests to."),
        GrantDescriptor(["store", "record"], .flag, doc: "Record system samples in the sample store."),
        .fsRead,
        GrantDescriptor(
            ["fs", "write"], .pathList, doc: "Path prefixes the rule's file may write with Deno's file APIs, as `read`."
        ),
        GrantDescriptor(["power", "awake"], .flag, doc: "Keep the Mac or its display awake."),
        GrantDescriptor(["audio"], .flag, doc: "Change the default audio devices, their volume and mute."),
        GrantDescriptor(["apps", "open"], .flag, doc: "Open applications by bundle identifier."),
        GrantDescriptor(["apps", "control"], .flag, doc: "Activate, hide, unhide and quit running applications."),
        GrantDescriptor(["urls"], .allowList(.scheme), doc: "URL schemes (`https`, `mailto`) the rule may open."),
        GrantDescriptor(["volumes", "eject"], .flag, doc: "Eject removable and external volumes."),
        GrantDescriptor(
            ["files", "trash"], .pathList, doc: "Path prefixes inside which the rule may move files to the Trash."),
        GrantDescriptor(["files", "tag"], .pathList, doc: "Path prefixes inside which the rule may set Finder tags."),
        GrantDescriptor(
            ["defaults"], .allowList(.name),
            doc: "User defaults domains (`com.apple.dock`) the rule may read and write."
        ),
        GrantDescriptor(["shortcuts"], .allowList(.name), doc: "Names of the shortcuts the rule may run."),
        GrantDescriptor(["wifi", "power"], .flag, doc: "Turn Wi-Fi on and off."),
        GrantDescriptor(["clipboard", "read"], .flag, doc: "Read text from the clipboard."),
        GrantDescriptor(["clipboard", "write"], .flag, doc: "Put text on the clipboard."),
        GrantDescriptor(
            ["windows", "control"], .flag,
            doc: "List, move, resize, minimize and raise other applications' windows."),
        GrantDescriptor(
            ["appearance", "set"], .flag,
            doc: "Switch between light and dark mode."
        ),
    ]

    // MARK: Shared schemas

    static let processTarget = TypeSchema.named(
        "ProcessTarget",
        ObjectSchema([
            Field("pid", .bounded(.integer(1...Int(Int32.max)))),
            Field("startedAt", .bounded(NumberBounds(ProcessIdentity.startedAtRange))),
        ]))

    static let timeout = Field("timeoutSeconds", .bounded(NumberBounds(0.1...60)), default: 10)

    /// A rule-chosen name: a key, an id, a defaults domain, a shortcut.
    static let name = TypeSchema.text(TextBounds(1...256))
    /// Text a person reads: four bytes for each of the 256 characters it
    /// was once counted in, so any script fits as much.
    static let displayText = TypeSchema.text(TextBounds(1...1024))
    static let bundleId = Field("bundleId", name)
    static let path = Field("path", .string, doc: "Absolute, or starting with `~/`; `..` is refused.")

    static let direction = Field("direction", AudioScope.schema, default: .string(AudioScope.output.rawValue))

    static let device = Field(
        "device", .string, optional: true,
        doc: "The device's UID, from `audio.devices` events; default the current default device.")

    static let notificationAction = TypeSchema.named(
        "NotificationAction",
        ObjectSchema([
            Field(
                "id", .text(TextBounds(1...64)),
                doc:
                    "Comes back as the response's `action`; not \(NotificationResponse.reserved.map { "\"\($0)\"" }.joined(separator: " or ")), which mean a click on the notification and closing it."
            ),
            // 64 characters, as `displayText` counts them.
            Field("title", .text(TextBounds(1...256))),
            Field("destructive", .boolean, default: false),
            Field(
                "input", .object(ObjectSchema([.optional("placeholder", String.self)])), optional: true,
                doc: "Makes the action a reply field; the typed text comes back as the response's `text`."),
        ]))

    /// A window coordinate, in points.
    static func windowPoint(_ name: String) -> Field {
        Field(name, .bounded(NumberBounds(-100_000...100_000)), optional: true)
    }

    /// A window size, in points: a window has one, so zero or less is a
    /// mistake the request names rather than one the app is left to handle.
    static func windowSize(_ name: String) -> Field {
        Field(name, .bounded(NumberBounds(1...100_000)), optional: true)
    }

    static func key(_ doc: String? = nil) -> Field { Field("key", .text(TextBounds(1...512)), doc: doc) }

    // MARK: Effects

    static let effects: [EffectDescriptor] = [
        // state
        EffectDescriptor(
            .stateGet, method: ["state", "get"], arguments: .positional(["key"]),
            request: ObjectSchema([key()]), result: .optional(.json, generic: true), grant: .none,
            summary: "Read a value from the rule's persistent storage."),
        EffectDescriptor(
            .stateSet, method: ["state", "set"], arguments: .positional(["key", "value"]),
            request: ObjectSchema([
                key(),
                Field(
                    "value", .json, optional: true,
                    doc: "Absent stores null; at most \(TextBounds.size(EffectLimits.valueBytes)) of JSON."),
            ]), grant: .none,
            summary:
                "Store a JSON value in the rule's persistent storage: at most \(EffectLimits.stateKeys) keys and \(TextBounds.size(EffectLimits.stateBytes)) of JSON."
        ),
        EffectDescriptor(
            .stateDelete, method: ["state", "delete"], arguments: .positional(["key"]),
            request: ObjectSchema([key()]), grant: .none,
            summary: "Remove a value from the rule's persistent storage."),

        // notify
        EffectDescriptor(
            .notify, method: ["notify"],
            request: ObjectSchema([
                Field("title", displayText), .optional("subtitle", String.self), .optional("body", String.self),
                Field(
                    "id", name, optional: true,
                    doc:
                        "Posting the same id again replaces the notification; `notify.withdraw(id)` removes it. Ids are the rule's own: another rule's never collide."
                ),
                Field(
                    "group", name, optional: true,
                    doc: "Groups the rule's notifications further; they are always grouped by rule."),
                Field("sound", .boolean, default: false, doc: "Play the default sound."),
                Field(
                    "actions", .array(notificationAction, .atMost(4)), default: [],
                    doc: "A click arrives as a `meerkat.notification` event, delivered only to rules in this file."
                ),
                .optional(
                    "data", JSONValue.self,
                    doc:
                        "Returned in the response event; at most \(TextBounds.size(EffectLimits.notificationDataBytes)) of JSON."
                ),
            ]), requestName: "NotificationRequest", grant: .flag("notify"), summary: "Post a notification."),
        EffectDescriptor(
            .notifyWithdraw, method: ["notify", "withdraw"], arguments: .positional(["id"]),
            request: ObjectSchema([Field("id", name)]), grant: .flag("notify"),
            summary:
                "Remove this rule's notification with that id, delivered or not; nothing happens when there is none."
        ),

        // process
        EffectDescriptor(
            .processSignal, method: ["process", "signal"], arguments: .positional(["target", "signal"]),
            request: ObjectSchema([
                Field("target", processTarget), .field("signal", ProcessSignal.self),
            ]), grant: .flag("process.signal"), summary: "Send a signal to one of your own processes."),
        EffectDescriptor(
            .processPriority, method: ["process", "setPriority"], arguments: .positional(["target", "priority"]),
            request: ObjectSchema([
                Field("target", processTarget), .field("priority", ProcessPriority.self),
            ]), grant: .flag("process.priority"),
            summary: "Move one of your own processes to background priority (CPU and I/O) or back."),
        EffectDescriptor(
            .processNice, method: ["process", "setNice"], arguments: .positional(["target", "nice"]),
            request: ObjectSchema([
                Field("target", processTarget), Field("nice", .bounded(.integer(0...20))),
            ]), grant: .flag("process.priority"),
            summary:
                "Set the nice value of one of your own processes. Only lowering priority (raising the value) is allowed."
        ),

        // exec, http, store
        EffectDescriptor(
            .exec, method: ["exec"],
            request: ObjectSchema([
                .field("path", String.self, doc: "Must be listed in `capabilities.exec.allow`."),
                Field("args", .array(.string), default: []), timeout, .optional("stdin", String.self),
            ]), requestName: "ExecRequest", result: .value(ExecResult.schema), grant: .listed("exec", subject: "path"),
            summary: "Run an allowed executable with an argument array and no shell."),
        EffectDescriptor(
            .http, method: ["http"],
            request: ObjectSchema([
                .field("url", String.self),
                Field("method", HTTPMethod.schema, default: .string(HTTPMethod.get.rawValue)),
                Field("headers", .record(.string), default: [:]), .optional("body", String.self), timeout,
            ]), requestName: "HttpRequest",
            result: .value(HTTPResponse.schema), grant: .listed("http", subject: "url"),
            summary: "Send an HTTP request to an allowed origin; redirects must stay within allowed origins."),
        EffectDescriptor(
            .storeRecord, method: ["store", "record"],
            request: ObjectSchema([
                Field("label", displayText, doc: "Label stored with the sample, as `meerkat sample --label`."),
                Field(
                    "windowSeconds", .bounded(NumberBounds(1...120)), default: 20,
                    doc: "CPU and I/O window, less than the rule's `timeoutSeconds`"),
                Field("top", .bounded(.integer(1...200)), default: 20, doc: "Processes kept"),
                Field(
                    "systemOnly", .boolean, default: .bool(SystemSampler.Options().systemOnly),
                    doc: SystemSampler.Options.systemOnlyDoc),
                Field(
                    "retain", .bounded(.integer(1...10_000_000)), optional: true,
                    doc: "Keep only the newest N samples under this label afterwards; other labels are untouched."),
            ]), requestName: "RecordRequest", grant: .flag("store.record"),
            traits: Traits(lastsWithinTimeout: "windowSeconds"),
            summary: "Measure the system and store the sample."),

        // power
        EffectDescriptor(
            .preventSleep, method: ["power", "preventSleep"],
            request: ObjectSchema([
                Field("id", name, doc: "The rule's own name for the assertion; reusing it replaces it."),
                Field("reason", displayText, doc: "Shown by `pmset -g assertions`."),
                Field("display", .boolean, default: false, doc: "Keep the display on too."),
                Field(
                    "timeoutSeconds", .bounded(NumberBounds(1...86_400)),
                    doc: "macOS releases the assertion after this long."),
            ]), requestName: "PreventSleepRequest", grant: .flag("power.awake"),
            summary:
                "Keep the Mac (and optionally its display) awake until the timeout, `power.allowSleep(id)`, or the rule set reloads."
        ),
        EffectDescriptor(
            .allowSleep, method: ["power", "allowSleep"], arguments: .positional(["id"]),
            request: ObjectSchema([Field("id", name)]), grant: .flag("power.awake"),
            summary: "Release this rule's assertion with that id; nothing happens when there is none."),

        // audio
        EffectDescriptor(
            .audioDefaultDevice, method: ["audio", "setDefaultDevice"],
            request: ObjectSchema([
                Field("device", .string, doc: "The device's UID, from `audio.devices` events."), direction,
            ]), grant: .flag("audio"), summary: "Make a device the default output or input."),
        EffectDescriptor(
            .audioVolume, method: ["audio", "setVolume"],
            request: ObjectSchema([Field("volume", .bounded(NumberBounds(0...1))), direction, device]),
            grant: .flag("audio"), summary: "Set a device's volume."),
        EffectDescriptor(
            .audioMute, method: ["audio", "setMute"],
            request: ObjectSchema([.field("muted", Bool.self), direction, device]), grant: .flag("audio"),
            summary: "Mute or unmute a device."),

        // apps and URLs
        EffectDescriptor(
            .appsOpen, method: ["apps", "open"],
            request: ObjectSchema([bundleId, Field("activate", .boolean, default: true, doc: "Bring it to the front.")]
            ),
            grant: .flag("apps.open"), summary: "Open an application, or bring it to the front."),
        EffectDescriptor(
            .appsActivate, method: ["apps", "activate"], arguments: .positional(["bundleId"]),
            request: ObjectSchema([bundleId]), grant: .flag("apps.control"),
            summary: "Bring a running application to the front."),
        EffectDescriptor(
            .appsHide, method: ["apps", "hide"], arguments: .positional(["bundleId"]),
            request: ObjectSchema([bundleId]), grant: .flag("apps.control"),
            summary: "Hide every running instance of an application."),
        EffectDescriptor(
            .appsUnhide, method: ["apps", "unhide"], arguments: .positional(["bundleId"]),
            request: ObjectSchema([bundleId]), grant: .flag("apps.control"),
            summary: "Unhide every running instance of an application."),
        EffectDescriptor(
            .appsQuit, method: ["apps", "quit"], arguments: .positional(["bundleId", "force"]),
            request: ObjectSchema([
                bundleId,
                Field(
                    "force", .boolean, default: false, doc: "Terminate without asking; otherwise the app may refuse."),
            ]), grant: .flag("apps.control"),
            summary: "Ask every running instance of an application to quit; does not wait for it."),
        EffectDescriptor(
            .urlsOpen, method: ["urls", "open"], arguments: .positional(["url"]),
            request: ObjectSchema([.field("url", String.self)]), grant: .listed("urls", subject: "url"),
            summary: "Open a URL with its default application."),

        // volumes and files
        EffectDescriptor(
            .volumesEject, method: ["volumes", "eject"], arguments: .positional(["path"]),
            request: ObjectSchema([Field("path", .string, doc: "The volume's mount point.")]),
            grant: .flag("volumes.eject"), traits: Traits(path: PathField("path", .mountPoint)),
            summary: "Unmount and eject a removable or external volume, and the other volumes on its disk."),
        EffectDescriptor(
            .filesTrash, method: ["files", "trash"], arguments: .positional(["path"]),
            request: ObjectSchema([path]), result: .value(TrashResult.schema),
            grant: .listed("files.trash", subject: "path"), traits: Traits(path: PathField("path", .entry)),
            summary: "Move a file or folder to the Trash; a symlink is moved, not what it leads to."),
        EffectDescriptor(
            .filesSetTags, method: ["files", "setTags"], arguments: .positional(["path", "tags"]),
            // Each tag 255 characters, as `displayText` counts them.
            request: ObjectSchema([path, Field("tags", .array(.text(.name(1020)), .atMost(64)))]),
            grant: .listed("files.tag", subject: "path"), traits: Traits(path: PathField("path", .target)),
            summary: "Replace a file's Finder tags; an empty list removes them."),

        // defaults
        EffectDescriptor(
            .defaultsRead, method: ["defaults", "read"], arguments: .positional(["domain", "key"]),
            request: ObjectSchema([Field("domain", name), Field("key", name)]),
            result: .optional(.json, generic: true), grant: .listed("defaults", subject: "domain"),
            summary: "Read a user default; dates become Unix epoch milliseconds and data base64."),
        EffectDescriptor(
            .defaultsWrite, method: ["defaults", "write"], arguments: .positional(["domain", "key", "value"]),
            request: ObjectSchema([
                Field("domain", name), Field("key", name),
                Field(
                    "value", .json,
                    doc:
                        "Not null, at most \(TextBounds.size(EffectLimits.valueBytes)) of JSON; numbers that are whole are stored as integers."
                ),
            ]), grant: .listed("defaults", subject: "domain"), traits: Traits(changesDefaultsDomain: "domain"),
            summary: "Write a user default for the current user. Apps read it at their next launch or when they look."),
        EffectDescriptor(
            .defaultsDelete, method: ["defaults", "delete"], arguments: .positional(["domain", "key"]),
            request: ObjectSchema([Field("domain", name), Field("key", name)]),
            grant: .listed("defaults", subject: "domain"), traits: Traits(changesDefaultsDomain: "domain"),
            summary: "Remove a user default."),

        // shortcuts
        EffectDescriptor(
            .shortcutsRun, method: ["shortcuts", "run"],
            request: ObjectSchema([
                Field("name", name, doc: "Must be listed in `capabilities.shortcuts.allow`."),
                Field(
                    "input", .text(TextBounds(0...(1 << 20))), optional: true,
                    doc: "Text passed to the shortcut as its input."),
                timeout,
            ]), requestName: "ShortcutRequest", result: .value(ExecResult.schema),
            grant: .listed("shortcuts", subject: "name"),
            summary: "Run one of your shortcuts with `/usr/bin/shortcuts` and wait for it."),

        // Wi-Fi
        EffectDescriptor(
            .wifiPower, method: ["wifi", "setPower"], arguments: .positional(["on"]),
            request: ObjectSchema([.field("on", Bool.self)]), grant: .flag("wifi.power"),
            summary: "Turn the Wi-Fi interface on or off. macOS may ask for an administrator's password."),

        // clipboard
        EffectDescriptor(
            .clipboardRead, method: ["clipboard", "read"], arguments: .none, result: .optional(.string),
            grant: .flag("clipboard.read"),
            summary: "The clipboard's text, if it has any. macOS may ask before the first read."),
        EffectDescriptor(
            .clipboardWrite, method: ["clipboard", "write"], arguments: .positional(["text"]),
            request: ObjectSchema([Field("text", .text(TextBounds(0...(1 << 20))))]), grant: .flag("clipboard.write"),
            summary: "Replace the clipboard's contents with text."),

        // windows (Accessibility)
        EffectDescriptor(
            .windowsList, method: ["windows", "list"], arguments: .positional(["bundleId"]),
            request: ObjectSchema([bundleId]), result: .value(.array(WindowInfo.schema)),
            grant: .flag("windows.control"), permission: .accessibility,
            summary: "The windows of a running application, front to back."),
        EffectDescriptor(
            .windowsSet, method: ["windows", "set"],
            request: ObjectSchema([
                bundleId,
                Field("index", .bounded(.integer(0...100_000)), doc: "From `windows.list`."),
                windowPoint("x"), windowPoint("y"), windowSize("width"), windowSize("height"),
                .optional("minimized", Bool.self),
                Field("raise", .boolean, default: false, doc: "Bring it to the front of its app."),
            ]), requestName: "WindowChange", grant: .flag("windows.control"), permission: .accessibility,
            summary: "Move, resize, minimize, restore or raise one window. Coordinates are global, top-left origin."),

        // appearance (Apple Events)
        EffectDescriptor(
            .appearanceDark, method: ["appearance", "setDark"], arguments: .positional(["on"]),
            request: ObjectSchema([.field("on", Bool.self)]), grant: .flag("appearance.set"),
            automation: .systemEvents,
            summary: "Switch to dark mode, or back to light mode, through \(AutomationTarget.systemEvents.name)."),
    ]
}

// MARK: - Request values

/// A signal `process.signal` can send.
public enum ProcessSignal: String, Sendable, CaseIterable, SchemaDescribed {
    case stop, `continue`, terminate, kill, hangup, interrupt

    public var number: Int32 {
        switch self {
        case .stop: return SIGSTOP
        case .continue: return SIGCONT
        case .terminate: return SIGTERM
        case .kill: return SIGKILL
        case .hangup: return SIGHUP
        case .interrupt: return SIGINT
        }
    }

    /// Whether the signal's purpose is to end the process. Hangup is not:
    /// daemons commonly take it as "reload".
    public var terminates: Bool {
        switch self {
        case .terminate, .kill, .interrupt: true
        case .stop, .continue, .hangup: false
        }
    }
}

public enum ProcessPriority: String, Sendable, CaseIterable, SchemaDescribed {
    case background, normal
}

public enum HTTPMethod: String, Sendable, CaseIterable, SchemaDescribed {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
}

public enum AudioScope: String, Sendable, CaseIterable, SchemaDescribed {
    case output, input
}

/// The response `action` names that are not a rule's buttons: a click on the
/// notification itself, and closing it.
public enum NotificationResponse {
    public static let click = "default"
    public static let dismiss = "dismiss"
    public static let reserved: [String] = [click, dismiss]
}

// MARK: - Result values

/// What `exec` and `shortcuts.run` return: an absent status or signal is
/// left out, never null.
public struct ExecResult: Sendable, Equatable, Codable, SchemaDescribed {
    /// Exit status, or nil when a signal ended the process.
    public var status: Int32?
    public var signal: Int32?
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    /// Each output is cut at this many bytes, as is an `http` body.
    public static let outputLimit = 1 << 20

    public init(status: Int32?, signal: Int32?, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public static var schema: TypeSchema {
        let limit = TextBounds.size(outputLimit)
        return .named(
            "ExecResult",
            ObjectSchema([
                .optional("status", Int32.self, doc: "Exit status; absent when a signal ended the process."),
                .optional("signal", Int32.self, doc: "The signal that ended the process."),
                .field("stdout", String.self, doc: "Standard output as UTF-8, cut at its first \(limit)."),
                .field("stderr", String.self, doc: "Standard error as UTF-8, cut at its first \(limit)."),
                .field("timedOut", Bool.self),
            ]))
    }
}

public struct HTTPResponse: Sendable, Equatable, Codable, SchemaDescribed {
    public let status: Int
    /// Lowercased names.
    public let headers: [String: String]
    public let body: String

    public init(status: Int, headers: [String: String], body: String) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static var schema: TypeSchema {
        .named(
            "HttpResponse",
            ObjectSchema([
                .field("status", Int.self), .field("headers", [String: String].self),
                .field(
                    "body", String.self,
                    doc: "The body as UTF-8, cut at its first \(TextBounds.size(ExecResult.outputLimit))."),
            ]))
    }
}

public struct TrashResult: Sendable, Equatable, Codable, SchemaDescribed {
    /// Where the item is in the Trash; nil when macOS did not say.
    public let trashedPath: String?

    public init(trashedPath: String?) { self.trashedPath = trashedPath }

    public static var schema: TypeSchema {
        .object(ObjectSchema([.optional("trashedPath", String.self, doc: "Absent when macOS does not say.")]))
    }
}

public struct WindowInfo: Sendable, Equatable, Codable, SchemaDescribed {
    public let index: Int
    public let title: String?
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let minimized: Bool
    public let main: Bool

    public init(
        index: Int, title: String?, x: Double, y: Double, width: Double, height: Double, minimized: Bool, main: Bool
    ) {
        self.index = index
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.minimized = minimized
        self.main = main
    }

    public static var schema: TypeSchema {
        .named(
            "WindowInfo",
            ObjectSchema([
                .field("index", Int.self, doc: "Position in the application's window list; pass it to `windows.set`."),
                .optional("title", String.self),
                .field("x", Double.self), .field("y", Double.self),
                .field("width", Double.self), .field("height", Double.self),
                .field("minimized", Bool.self),
                .field("main", Bool.self, doc: "The application's main window."),
            ]))
    }
}

extension EffectDescriptor.Result {
    /// What an `optional` result is on the wire.
    public static func found(_ value: JSONValue?) -> JSONValue {
        .object(["found": .bool(value != nil), "value": value ?? .null])
    }
}
