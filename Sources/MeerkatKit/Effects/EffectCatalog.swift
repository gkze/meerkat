import Foundation

/// Every grant and every effect a rule can use, declared once.
///
/// The TypeScript `Grants` and `Context` types, the daemon's grant parsing
/// and authorization, the request shape checks and the runtime's `ctx` are
/// all derived from this catalog (docs/design/effects.md). The daemon's
/// typed decode and the code that performs each effect stay hand-written; a
/// test keeps them and the catalog in step.
public struct EffectCatalog: Sendable {
    public let grants: [GrantDescriptor]
    public let effects: [EffectDescriptor]
    private let grantsByPath: [String: GrantDescriptor]
    private let effectsByKind: [String: EffectDescriptor]

    public init(grants: [GrantDescriptor], effects: [EffectDescriptor]) {
        self.grants = grants
        self.effects = effects
        grantsByPath = Dictionary(grants.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        effectsByKind = Dictionary(effects.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func grant(_ key: String) -> GrantDescriptor? { grantsByPath[key] }
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

// MARK: - Effects

public struct EffectDescriptor: Sendable, Equatable {
    /// The wire name in effect requests: `process.signal`.
    public let kind: String
    /// Where the method is on `ctx`: `["process", "signal"]`.
    public let method: [String]
    public let arguments: Arguments
    /// The request: an object, named when the declarations should name it
    /// (`ExecRequest`). `kind` is added on the wire.
    public let request: TypeSchema
    public let result: Result
    public let grant: GrantRequirement
    /// A privacy permission the effect needs besides its grant.
    public let permission: EventDescriptor.Permission?
    public let summary: String

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

    public init(
        _ kind: String, method: [String], arguments: Arguments = .request,
        request: TypeSchema = .object(ObjectSchema([])),
        result: Result = .none, grant: GrantRequirement, permission: EventDescriptor.Permission? = nil,
        summary: String
    ) {
        precondition(request.objectSchema != nil, "\(kind): a request is an object")
        self.kind = kind
        self.method = method
        self.arguments = arguments
        self.request = request
        self.result = result
        self.grant = grant
        self.permission = permission
        self.summary = summary
    }

    public init(
        _ kind: String, method: [String], arguments: Arguments = .request, request: ObjectSchema,
        result: Result = .none, grant: GrantRequirement, permission: EventDescriptor.Permission? = nil,
        summary: String
    ) {
        self.init(
            kind, method: method, arguments: arguments, request: .object(request), result: result, grant: grant,
            permission: permission, summary: summary)
    }

    /// The request's fields.
    public var fields: [ObjectSchema.Field] { request.objectSchema?.fields ?? [] }
}

// MARK: - The standard catalog

extension EffectCatalog {
    public static let standard = EffectCatalog(grants: StandardEffects.grants, effects: StandardEffects.effects)
}

private enum StandardEffects {
    typealias Field = ObjectSchema.Field

    static let grants: [GrantDescriptor] = [
        GrantDescriptor(["notify"], .flag, doc: "Post and withdraw notifications."),
        GrantDescriptor(["process", "signal"], .flag, doc: "Signal your own processes."),
        GrantDescriptor(["process", "priority"], .flag, doc: "Lower the priority of your own processes."),
        GrantDescriptor(
            ["process", "observe"], .level(["own", "all"]),
            doc:
                "Observe processes and applications: `\"own\"` your own processes (events about other users' are not delivered, and their rows are left out), `\"all\"` every user's."
        ),
        GrantDescriptor(
            ["observe"], .allowList(.eventKind),
            doc:
                "Event kinds that carry what you are doing, text other programs wrote, or other people (window titles, the log, notifications, nearby devices), which the rule may observe."
        ),
        GrantDescriptor(["exec"], .allowList(.absolutePath), doc: "Absolute executable paths the rule may run."),
        GrantDescriptor(
            ["http"], .allowList(.origin), doc: "Origins (`https://host[:port]`) the rule may send requests to."),
        GrantDescriptor(["store", "record"], .flag, doc: "Record system samples in the sample store."),
        GrantDescriptor(
            ["fs", "read"], .pathList,
            doc:
                "Path prefixes the rule's file may read with Deno's file APIs. Absolute, or starting with `~/`. The file is the unit: its code may use any of its rules' grants. The daemon's own state and the rules directory are never granted, and a symlink inside a granted directory is followed."
        ),
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
            doc: "List, move, resize, minimize and raise other applications' windows (Accessibility permission)."),
        GrantDescriptor(
            ["appearance", "set"], .flag,
            doc: "Switch between light and dark mode (Automation permission for System Events)."
        ),
    ]

    // MARK: Shared schemas

    static let processTarget = TypeSchema.named(
        "ProcessTarget",
        ObjectSchema([
            .field("pid", Double.self), .field("startedAt", Double.self),
        ]))

    static let timeout = Field(
        "timeoutSeconds", .bounded(NumberBounds(minimum: 0.1, maximum: 60)), optional: true, doc: "Default 10.")

    static let execResult = TypeSchema.named(
        "ExecResult",
        ObjectSchema([
            Field("status", .number, optional: true, doc: "Exit status; absent when a signal ended the process."),
            Field("signal", .number, optional: true, doc: "The signal that ended the process."),
            .field("stdout", String.self, doc: "Standard output as UTF-8, cut at its first 1 MiB."),
            .field("stderr", String.self, doc: "Standard error as UTF-8, cut at its first 1 MiB."),
            .field("timedOut", Bool.self),
        ]))

    static let direction = Field.optional("direction", AudioScope.self, doc: "Default \"output\".")

    static let device = Field(
        "device", .string, optional: true,
        doc: "The device's UID, from `audio.devices` events; default the current default device.")

    static let notificationAction = TypeSchema.named(
        "NotificationAction",
        ObjectSchema([
            Field(
                "id", .string,
                doc:
                    "Comes back as the response's `action`; not \"default\" or \"dismiss\", which mean a click on the notification and closing it."
            ),
            .field("title", String.self),
            .optional("destructive", Bool.self),
            Field(
                "input", .object(ObjectSchema([.optional("placeholder", String.self)])), optional: true,
                doc: "Makes the action a reply field; the typed text comes back as the response's `text`."),
        ]))

    static let windowInfo = TypeSchema.named(
        "WindowInfo",
        ObjectSchema([
            .field("index", Int.self, doc: "Position in the application's window list; pass it to `windows.set`."),
            .optional("title", String.self),
            .field("x", Double.self), .field("y", Double.self),
            .field("width", Double.self), .field("height", Double.self),
            .field("minimized", Bool.self),
            .field("main", Bool.self, doc: "The application's main window."),
        ]))

    /// A window coordinate, in points.
    static func windowPoint(_ name: String) -> Field {
        Field(name, .bounded(NumberBounds(minimum: -100_000, maximum: 100_000)), optional: true)
    }

    /// A window size, in points: a window has one, so zero or less is a
    /// mistake the request names rather than one the app is left to handle.
    static func windowSize(_ name: String) -> Field {
        Field(name, .bounded(NumberBounds(minimum: 1, maximum: 100_000)), optional: true)
    }

    // MARK: Effects

    static let effects: [EffectDescriptor] = [
        // state
        EffectDescriptor(
            "state.get", method: ["state", "get"], arguments: .positional(["key"]),
            request: ObjectSchema([.field("key", String.self)]), result: .optional(.json, generic: true), grant: .none,
            summary: "Read a value from the rule's persistent storage."),
        EffectDescriptor(
            "state.set", method: ["state", "set"], arguments: .positional(["key", "value"]),
            request: ObjectSchema([
                .field("key", String.self), Field("value", .json, optional: true, doc: "Absent stores null."),
            ]), grant: .none,
            summary:
                "Store a JSON value in the rule's persistent storage: at most 1024 keys and 8 MiB of JSON, 1 MiB per value."
        ),
        EffectDescriptor(
            "state.delete", method: ["state", "delete"], arguments: .positional(["key"]),
            request: ObjectSchema([.field("key", String.self)]), grant: .none,
            summary: "Remove a value from the rule's persistent storage."),

        // notify
        EffectDescriptor(
            "notify", method: ["notify"],
            request: ObjectSchema([
                .field("title", String.self), .optional("subtitle", String.self), .optional("body", String.self),
                .optional(
                    "id", String.self,
                    doc:
                        "Posting the same id again replaces the notification; `notify.withdraw(id)` removes it. Ids are the rule's own: another rule's never collide."
                ),
                .optional(
                    "group", String.self,
                    doc: "Groups the rule's notifications further; they are always grouped by rule."),
                .optional("sound", Bool.self, doc: "Play the default sound. Default false."),
                Field(
                    "actions", .array(notificationAction), optional: true,
                    doc:
                        "At most 4. A click arrives as a `meerkat.notification` event, delivered only to rules in this file."
                ),
                .optional("data", JSONValue.self, doc: "Returned in the response event; at most 4096 bytes of JSON."),
            ]).named("NotificationRequest"), grant: .flag("notify"), summary: "Post a notification."),
        EffectDescriptor(
            "notify.withdraw", method: ["notify", "withdraw"], arguments: .positional(["id"]),
            request: ObjectSchema([.field("id", String.self)]), grant: .flag("notify"),
            summary:
                "Remove this rule's notification with that id, delivered or not; nothing happens when there is none."
        ),

        // process
        EffectDescriptor(
            "process.signal", method: ["process", "signal"], arguments: .positional(["target", "signal"]),
            request: ObjectSchema([
                Field("target", processTarget), .field("signal", ProcessSignal.self),
            ]), grant: .flag("process.signal"), summary: "Send a signal to one of your own processes."),
        EffectDescriptor(
            "process.priority", method: ["process", "setPriority"], arguments: .positional(["target", "priority"]),
            request: ObjectSchema([
                Field("target", processTarget), .field("priority", ProcessPriority.self),
            ]), grant: .flag("process.priority"),
            summary: "Move one of your own processes to background priority (CPU and I/O) or back."),
        EffectDescriptor(
            "process.nice", method: ["process", "setNice"], arguments: .positional(["target", "nice"]),
            request: ObjectSchema([
                Field("target", processTarget), Field("nice", .bounded(.integer(0...20))),
            ]), grant: .flag("process.priority"),
            summary:
                "Set the nice value of one of your own processes, 0–20. Only lowering priority (raising the value) is allowed."
        ),

        // exec, http, store
        EffectDescriptor(
            "exec", method: ["exec"],
            request: ObjectSchema([
                .field("path", String.self, doc: "Must be listed in `capabilities.exec.allow`."),
                .optional("args", [String].self), timeout, .optional("stdin", String.self),
            ]).named("ExecRequest"), result: .value(execResult), grant: .listed("exec", subject: "path"),
            summary: "Run an allowed executable with an argument array and no shell."),
        EffectDescriptor(
            "http", method: ["http"],
            request: ObjectSchema([
                .field("url", String.self),
                .optional("method", HTTPMethod.self),
                .optional("headers", [String: String].self), .optional("body", String.self), timeout,
            ]).named("HttpRequest"),
            result: .value(
                .named(
                    "HttpResponse",
                    ObjectSchema([
                        .field("status", Int.self), .field("headers", [String: String].self),
                        .field("body", String.self, doc: "The body as UTF-8, cut at its first 1 MiB."),
                    ]))), grant: .listed("http", subject: "url"),
            summary: "Send an HTTP request to an allowed origin; redirects must stay within allowed origins."),
        EffectDescriptor(
            "store.record", method: ["store", "record"],
            request: ObjectSchema([
                .field("label", String.self, doc: "Label stored with the sample, as `meerkat sample --label`."),
                Field(
                    "windowSeconds", .bounded(NumberBounds(minimum: 1, maximum: 120)), optional: true,
                    doc: "CPU and I/O window, less than the rule's `timeoutSeconds`. Default 20."),
                Field("top", .bounded(.integer(1...200)), optional: true, doc: "Processes kept. Default 20."),
                .optional("systemOnly", Bool.self, doc: "Only processes whose executable ships with macOS."),
                Field(
                    "retain", .bounded(.integer(1...10_000_000)), optional: true,
                    doc: "Keep only the newest N samples under this label afterwards; other labels are untouched."),
            ]).named("RecordRequest"), grant: .flag("store.record"),
            summary: "Measure the system and store the sample."),

        // power
        EffectDescriptor(
            "power.preventSleep", method: ["power", "preventSleep"],
            request: ObjectSchema([
                .field("id", String.self, doc: "The rule's own name for the assertion; reusing it replaces it."),
                .field("reason", String.self, doc: "Shown by `pmset -g assertions`."),
                .optional("display", Bool.self, doc: "Keep the display on too. Default false."),
                Field(
                    "timeoutSeconds", .bounded(NumberBounds(minimum: 1, maximum: 86_400)),
                    doc: "macOS releases the assertion after this long."),
            ]).named("PreventSleepRequest"), grant: .flag("power.awake"),
            summary:
                "Keep the Mac (and optionally its display) awake until the timeout, `power.allowSleep(id)`, or the rule set reloads."
        ),
        EffectDescriptor(
            "power.allowSleep", method: ["power", "allowSleep"], arguments: .positional(["id"]),
            request: ObjectSchema([.field("id", String.self)]), grant: .flag("power.awake"),
            summary: "Release this rule's assertion with that id; nothing happens when there is none."),

        // audio
        EffectDescriptor(
            "audio.setDefaultDevice", method: ["audio", "setDefaultDevice"],
            request: ObjectSchema([
                Field("device", .string, doc: "The device's UID, from `audio.devices` events."), direction,
            ]), grant: .flag("audio"), summary: "Make a device the default output or input."),
        EffectDescriptor(
            "audio.setVolume", method: ["audio", "setVolume"],
            request: ObjectSchema([
                Field("volume", .bounded(NumberBounds(minimum: 0, maximum: 1)), doc: "0 to 1."), direction, device,
            ]), grant: .flag("audio"), summary: "Set a device's volume."),
        EffectDescriptor(
            "audio.setMute", method: ["audio", "setMute"],
            request: ObjectSchema([.field("muted", Bool.self), direction, device]), grant: .flag("audio"),
            summary: "Mute or unmute a device."),

        // apps and URLs
        EffectDescriptor(
            "apps.open", method: ["apps", "open"],
            request: ObjectSchema([
                .field("bundleId", String.self),
                .optional("activate", Bool.self, doc: "Bring it to the front. Default true."),
            ]), grant: .flag("apps.open"), summary: "Open an application, or bring it to the front."),
        EffectDescriptor(
            "apps.activate", method: ["apps", "activate"], arguments: .positional(["bundleId"]),
            request: ObjectSchema([.field("bundleId", String.self)]), grant: .flag("apps.control"),
            summary: "Bring a running application to the front."),
        EffectDescriptor(
            "apps.hide", method: ["apps", "hide"], arguments: .positional(["bundleId"]),
            request: ObjectSchema([.field("bundleId", String.self)]), grant: .flag("apps.control"),
            summary: "Hide every running instance of an application."),
        EffectDescriptor(
            "apps.unhide", method: ["apps", "unhide"], arguments: .positional(["bundleId"]),
            request: ObjectSchema([.field("bundleId", String.self)]), grant: .flag("apps.control"),
            summary: "Unhide every running instance of an application."),
        EffectDescriptor(
            "apps.quit", method: ["apps", "quit"], arguments: .positional(["bundleId", "force"]),
            request: ObjectSchema([
                .field("bundleId", String.self),
                .optional(
                    "force", Bool.self, doc: "Terminate without asking. Default false: ask, and the app may refuse."),
            ]), grant: .flag("apps.control"),
            summary: "Ask every running instance of an application to quit; does not wait for it."),
        EffectDescriptor(
            "urls.open", method: ["urls", "open"], arguments: .positional(["url"]),
            request: ObjectSchema([.field("url", String.self)]), grant: .listed("urls", subject: "url"),
            summary: "Open a URL with its default application."),

        // volumes and files
        EffectDescriptor(
            "volumes.eject", method: ["volumes", "eject"], arguments: .positional(["path"]),
            request: ObjectSchema([.field("path", String.self, doc: "The volume's mount point.")]),
            grant: .flag("volumes.eject"),
            summary: "Unmount and eject a removable or external volume, and the other volumes on its disk."),
        EffectDescriptor(
            "files.trash", method: ["files", "trash"], arguments: .positional(["path"]),
            request: ObjectSchema([.field("path", String.self)]),
            result: .value(.object(ObjectSchema([.field("trashedPath", String.self)]))),
            grant: .listed("files.trash", subject: "path"), summary: "Move a file or folder to the Trash."),
        EffectDescriptor(
            "files.setTags", method: ["files", "setTags"], arguments: .positional(["path", "tags"]),
            request: ObjectSchema([.field("path", String.self), .field("tags", [String].self)]),
            grant: .listed("files.tag", subject: "path"),
            summary: "Replace a file's Finder tags; an empty list removes them."),

        // defaults
        EffectDescriptor(
            "defaults.read", method: ["defaults", "read"], arguments: .positional(["domain", "key"]),
            request: ObjectSchema([.field("domain", String.self), .field("key", String.self)]),
            result: .optional(.json, generic: true), grant: .listed("defaults", subject: "domain"),
            summary: "Read a user default; dates become Unix epoch milliseconds and data base64."),
        EffectDescriptor(
            "defaults.write", method: ["defaults", "write"], arguments: .positional(["domain", "key", "value"]),
            request: ObjectSchema([
                .field("domain", String.self), .field("key", String.self),
                Field("value", .json, doc: "Not null; numbers that are whole are stored as integers."),
            ]), grant: .listed("defaults", subject: "domain"),
            summary: "Write a user default for the current user. Apps read it at their next launch or when they look."),
        EffectDescriptor(
            "defaults.delete", method: ["defaults", "delete"], arguments: .positional(["domain", "key"]),
            request: ObjectSchema([.field("domain", String.self), .field("key", String.self)]),
            grant: .listed("defaults", subject: "domain"), summary: "Remove a user default."),

        // shortcuts
        EffectDescriptor(
            "shortcuts.run", method: ["shortcuts", "run"],
            request: ObjectSchema([
                .field("name", String.self, doc: "Must be listed in `capabilities.shortcuts.allow`."),
                .optional("input", String.self, doc: "Text passed to the shortcut as its input."), timeout,
            ]).named("ShortcutRequest"), result: .value(execResult), grant: .listed("shortcuts", subject: "name"),
            summary: "Run one of your shortcuts with `/usr/bin/shortcuts` and wait for it."),

        // Wi-Fi
        EffectDescriptor(
            "wifi.setPower", method: ["wifi", "setPower"], arguments: .positional(["on"]),
            request: ObjectSchema([.field("on", Bool.self)]), grant: .flag("wifi.power"),
            summary: "Turn the Wi-Fi interface on or off. macOS may ask for an administrator's password."),

        // clipboard
        EffectDescriptor(
            "clipboard.read", method: ["clipboard", "read"], arguments: .none, result: .optional(.string),
            grant: .flag("clipboard.read"),
            summary: "The clipboard's text, if it has any. macOS may ask before the first read."),
        EffectDescriptor(
            "clipboard.write", method: ["clipboard", "write"], arguments: .positional(["text"]),
            request: ObjectSchema([.field("text", String.self)]), grant: .flag("clipboard.write"),
            summary: "Replace the clipboard's contents with text."),

        // windows (Accessibility)
        EffectDescriptor(
            "windows.list", method: ["windows", "list"], arguments: .positional(["bundleId"]),
            request: ObjectSchema([.field("bundleId", String.self)]), result: .value(.array(windowInfo)),
            grant: .flag("windows.control"), permission: .accessibility,
            summary: "The windows of a running application, front to back."),
        EffectDescriptor(
            "windows.set", method: ["windows", "set"],
            request: ObjectSchema([
                .field("bundleId", String.self),
                Field("index", .bounded(.integer(0...100_000)), doc: "From `windows.list`."),
                windowPoint("x"), windowPoint("y"), windowSize("width"), windowSize("height"),
                .optional("minimized", Bool.self),
                .optional("raise", Bool.self, doc: "Bring it to the front of its app."),
            ]).named("WindowChange"), grant: .flag("windows.control"), permission: .accessibility,
            summary: "Move, resize, minimize, restore or raise one window. Coordinates are global, top-left origin."),

        // appearance (Apple Events)
        EffectDescriptor(
            "appearance.setDark", method: ["appearance", "setDark"], arguments: .positional(["on"]),
            request: ObjectSchema([.field("on", Bool.self)]), grant: .flag("appearance.set"),
            summary: "Switch to dark mode, or back to light mode, through System Events."),
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

extension EffectDescriptor.Result {
    /// What an `optional` result is on the wire.
    public static func found(_ value: JSONValue?) -> JSONValue {
        .object(["found": .bool(value != nil), "value": value ?? .null])
    }
}

extension ObjectSchema {
    /// This object as a named interface in the generated declarations.
    fileprivate func named(_ name: String) -> TypeSchema { .named(name, self) }
}
