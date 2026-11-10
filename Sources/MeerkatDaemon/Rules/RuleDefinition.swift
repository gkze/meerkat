import Foundation
import MeerkatIPC
import MeerkatKit

/// A rule as the daemon runs it: the author's declarative fields, decoded
/// and checked against the catalog. `handle` stays in the handler host.
///
/// Decoding happens once, when the host reports a loaded file; every later
/// decision (subscribe, match, rate, grant) uses these typed values.
struct RuleDefinition: Sendable, Equatable {
    let id: String
    let file: String
    let name: String
    let event: String
    /// Decoded once, defaults applied: the grant checks, the subscription's
    /// key and its source all read this one value, so equal parameters
    /// compare equal and the source watches exactly what was checked.
    let parameters: NormalizedParameters
    let match: MatchPredicate?
    let rate: RateSpec
    let grants: CapabilityGrants
    let includeOwn: Bool
    let timeout: Duration

    /// The options' names come from their schema, so an option it gains
    /// is never refused as unknown.
    private static let optionFields = Set(RuleLimits.options.fields.map(\.name))
    private static let knownFields = optionFields.union(["name", "on", "params", "match", "capabilities"])

    /// Decodes one definition object from `file`, and refuses it when its
    /// grants do not cover observing its kind (`ObservationScope.require`;
    /// the file scope, which can change while the rule is loaded, is
    /// decided where it subscribes). Throws `RuleDefinitionError` with a
    /// message that names the field.
    init(file: String, raw: JSONValue, catalog: EventCatalog, observation: ObservationScope) throws {
        guard let fields = raw.objectValue else { throw RuleDefinitionError("definition is not an object") }
        let unknown = fields.keys.filter { !Self.knownFields.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw RuleDefinitionError(
                "unknown field\(unknown.count == 1 ? "" : "s") \(unknown.map { "\"\($0)\"" }.joined(separator: ", "))")
        }
        guard let name = fields["name"]?.stringValue, !name.isEmpty else {
            throw RuleDefinitionError("\"name\" must be a non-empty string")
        }
        if let refusal = RuleID.refusal(name: name) { throw RuleDefinitionError(refusal) }
        guard let event = fields["on"]?.stringValue else { throw RuleDefinitionError("\"on\" must name an event") }
        guard let kind = catalog.kind(named: event) else {
            throw RuleDefinitionError("\"on\": unknown event \"\(event)\"")
        }

        self.file = file
        self.name = name
        self.id = RuleID.make(file: file, name: name)
        self.event = event
        do {
            parameters = try kind.normalized(fields["params"] ?? .null)
        } catch {
            throw RuleDefinitionError("\"params\": \(error)")
        }
        match = try fields["match"].map { raw in
            do {
                return try MatchPredicate(raw, schema: kind.payloadSchema)
            } catch let error as MatchError {
                throw RuleDefinitionError("\"match\": \(error.message)")
            }
        }
        let options: Options
        do {
            options = try RuleLimits.options.decode(.object(fields.filter { Self.optionFields.contains($0.key) }))
        } catch {
            throw RuleDefinitionError("\(error)")
        }
        rate = options.rate ?? RateSpec()
        includeOwn = options.includeOwn
        // In range, so the conversion cannot trap.
        timeout = .milliseconds(Int((options.timeoutSeconds * 1000).rounded()))
        grants = try CapabilityGrants(fields["capabilities"], events: catalog)
        try observation.require(kind, parameters: parameters, grants: grants)
    }

    /// The fields `RuleLimits.options` states.
    private struct Options: Decodable {
        let rate: RateSpec?
        let includeOwn: Bool
        let timeoutSeconds: Double
    }
}

struct RuleDefinitionError: Error, CustomStringConvertible, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - Rate

/// `rate` in a rule definition (`RuleLimits.rate`).
struct RateSpec: Sendable, Equatable, Decodable {
    var throttle: Double?
    var debounce: Double?
    var maxPerMinute: Int?

    init(throttle: Double? = nil, debounce: Double? = nil, maxPerMinute: Int? = nil) {
        self.throttle = throttle
        self.debounce = debounce
        self.maxPerMinute = maxPerMinute
    }

    private enum CodingKeys: String, CodingKey {
        case throttle = "throttleSeconds"
        case debounce = "debounceSeconds"
        case maxPerMinute
    }

    /// Decoded once the schema has checked each field's bounds; the one
    /// check between fields is this one's.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        throttle = try container.decodeIfPresent(Double.self, forKey: .throttle)
        debounce = try container.decodeIfPresent(Double.self, forKey: .debounce)
        maxPerMinute = try container.decodeIfPresent(Int.self, forKey: .maxPerMinute)
        if throttle != nil, debounce != nil {
            throw RuleDefinitionError("\"rate\": use throttleSeconds or debounceSeconds, not both")
        }
    }
}

/// Throttle and per-minute caps, as a pure function of time. Debounce needs a
/// timer and lives in the dispatcher.
struct RateLimiter: Sendable {
    let spec: RateSpec
    private var lastAccepted: Double?
    private var acceptedInLastMinute: [Double] = []

    init(spec: RateSpec) {
        self.spec = spec
    }

    /// Whether an event arriving at `now` (seconds) may run the handler.
    mutating func admit(now: Double) -> Bool {
        if let throttle = spec.throttle, let last = lastAccepted, now - last < throttle {
            return false
        }
        if let cap = spec.maxPerMinute {
            acceptedInLastMinute.removeAll { now - $0 >= 60 }
            guard acceptedInLastMinute.count < cap else { return false }
            acceptedInLastMinute.append(now)
        }
        lastAccepted = now
        return true
    }
}

// MARK: - Circuit breaker

/// Disables a rule that keeps failing or runs away.
struct CircuitBreaker: Sendable {
    static let window = 60.0
    static let maximumFailures = 5
    static let maximumInvocations = 120

    private var failures: [Double] = []
    private var invocations: [Double] = []

    /// Records an invocation and returns a reason when the rule must stop.
    mutating func recordInvocation(now: Double) -> String? {
        invocations.removeAll { now - $0 >= Self.window }
        invocations.append(now)
        if invocations.count > Self.maximumInvocations {
            return "more than \(Self.maximumInvocations) invocations within \(Int(Self.window)) s"
        }
        return nil
    }

    mutating func recordFailure(now: Double) -> String? {
        failures.removeAll { now - $0 >= Self.window }
        failures.append(now)
        if failures.count >= Self.maximumFailures {
            return "\(Self.maximumFailures) failures within \(Int(Self.window)) s"
        }
        return nil
    }
}

// MARK: - Grants

/// `capabilities` in a rule definition: what the daemon will do for it, and
/// what it may observe.
///
/// Which grants exist, and the shape of each, is the effect catalog's
/// (`EffectCatalog`); this type parses a rule's grants against it,
/// normalizes their entries, and answers whether a request's subject is
/// allowed.
struct CapabilityGrants: Sendable, Equatable {
    /// Flag grants given, by key (`process.signal`).
    private(set) var flags: Set<String> = []
    /// Allow-list and path-list grants by key, normalized: absolute paths,
    /// origins as `scheme://host:port`, lowercase schemes, names, path
    /// prefixes with `~` expanded.
    private(set) var lists: [String: [String]] = [:]
    /// Level grants by key (`process.observe`): one of the grant's levels.
    private(set) var levels: [String: String] = [:]

    static let none = CapabilityGrants()

    init() {}

    /// `events` is the catalog `observe.allow` names kinds from.
    init(_ raw: JSONValue?, home: String = NSHomeDirectory(), events: EventCatalog = .standard) throws {
        guard let raw, raw != .null else { return }
        guard let fields = raw.objectValue else { throw RuleDefinitionError("\"capabilities\" must be an object") }
        try parse(fields, at: [], home: home, events: events)
    }

    private mutating func parse(
        _ fields: [String: JSONValue], at prefix: [String], home: String, events: EventCatalog
    ) throws {
        let catalog = EffectCatalog.standard
        for (name, value) in fields {
            let path = prefix + [name]
            let key = path.joined(separator: ".")
            let field = "capabilities." + key
            if let grant = catalog.grant(key) {
                switch grant.shape {
                case .flag:
                    guard let flag = value.boolValue else {
                        throw RuleDefinitionError("\"\(field)\" must be a boolean")
                    }
                    if flag { flags.insert(key) } else { flags.remove(key) }
                case .allowList(.eventKind):
                    lists[key] = try Self.allowList(value, field).map { try Self.observedKind($0, field, events) }
                case .allowList(let subject):
                    lists[key] = try Self.allowList(value, field).map { try Self.normalize($0, subject, field) }
                case .pathList:
                    lists[key] = try Self.paths(value, field, home: home)
                case .level(let names):
                    guard let level = value.stringValue, names.contains(level) else {
                        throw RuleDefinitionError(
                            "\"\(field)\" must be \(names.map { "\"\($0)\"" }.joined(separator: " or "))")
                    }
                    levels[key] = level
                }
            } else if catalog.grants.contains(where: { $0.path.starts(with: path) }) {
                guard let nested = value.objectValue else {
                    throw RuleDefinitionError("\"\(field)\" must be an object")
                }
                try parse(nested, at: path, home: home, events: events)
            } else if prefix.isEmpty {
                throw RuleDefinitionError("\"capabilities\": unknown capability \"\(name)\"")
            } else {
                throw RuleDefinitionError(
                    "\"capabilities.\(prefix.joined(separator: "."))\": unknown field \"\(name)\"")
            }
        }
    }

    func has(_ key: String) -> Bool { flags.contains(key) }

    func list(_ key: String) -> [String] { lists[key] ?? [] }

    func level(_ key: String) -> String? { levels[key] }

    /// Path prefixes the rule's file may read or write through Deno's APIs
    /// (`Deno.writeTextFile` and the like).
    var fsRead: [String] { list("fs.read") }
    var fsWrite: [String] { list("fs.write") }

    /// The origins an `http` grant allows, for redirects.
    var httpOrigins: [URLOrigin] { list("http").compactMap(URLOrigin.init) }

    /// Whether the list grant `key` allows `subject`, a request's executable
    /// path, URL, name or file path. `entry` checks a path as the entry it
    /// names, for an effect that acts on a link itself.
    func allows(_ key: String, subject: String, shape: GrantDescriptor.Shape, entry asEntry: Bool = false) -> Bool {
        let entries = list(key)
        switch shape {
        case .flag:
            return has(key)
        case .allowList(.absolutePath), .allowList(.name), .allowList(.eventKind):
            return entries.contains(subject)
        case .level(let names):
            // Each level includes the ones before it.
            guard let given = levels[key].flatMap({ names.firstIndex(of: $0) }),
                let wanted = names.firstIndex(of: subject)
            else { return false }
            return given >= wanted
        case .allowList(.origin):
            guard let url = URL(string: subject), let origin = URLOrigin(url: url) else { return false }
            return entries.contains(origin.description)
        case .allowList(.scheme):
            guard let scheme = URL(string: subject)?.scheme?.lowercased() else { return false }
            return entries.contains(scheme)
        case .pathList:
            // Symlinks resolve on both sides, so a link inside a granted
            // directory cannot reach outside it, and a link outside it is not
            // inside it by pointing there. A grant of the data volume's mount
            // point covers its folders by their firmlinks too.
            let resolved = asEntry ? Self.entry(subject) : Self.resolved(subject)
            let names = [resolved] + dataVolumeNames(of: resolved)
            return entries.contains { entry in
                let prefix = Self.resolved(entry)
                return prefix == "/" || names.contains { $0 == prefix || $0.hasPrefix(prefix + "/") }
            }
        }
    }

    /// `path` as the kernel names it (`canonicalPath`), including the part
    /// that does not exist yet: every symlink resolved, and a folder reached
    /// by another of its names (`/System/Volumes/Data/Users` for `/Users`)
    /// named one way. (`URL`'s own resolution stops at a path that does not
    /// exist, and `realpath` keeps such names.)
    static func resolved(_ path: String) -> String {
        canonicalPath((path as NSString).standardizingPath)
    }

    /// The protected path `target` is at, inside or above, or nil. Each is
    /// compared in every form it has (`forms`), so one reached through a
    /// symlink or a firmlink is still inside or above whatever `target`
    /// names. `target` is in the form the caller acts on or watches, resolved
    /// or as an entry. Compared without case, as the default
    /// (case-insensitive) APFS compares names, so a part that does not exist
    /// yet cannot differ only in case.
    static func protectedPath(touchedBy target: String, in protected: [String]) -> String? {
        let target = target.lowercased()
        return protected.first { protected in
            forms(of: protected).map { $0.lowercased() }.contains { form in
                target == form || target.hasPrefix(form + "/") || form.hasPrefix(target + "/") || target == "/"
            }
        }
    }

    /// Every form of a protected `path`, as the runtime gives them
    /// (protected.rs, `forms`; protected_cases.json holds both to the same
    /// verdicts): as named, each symlink it passes through on the way
    /// (`links(along:)`), and what it resolves to, each with its names on the
    /// data volume. So neither end of its name, nor a link on its way, nor the
    /// folder that holds one, can be moved for a folder of a rule's own to
    /// take its place.
    static func forms(of path: String) -> [String] {
        let named = URL(fileURLWithPath: path).standardizedFileURL.path
        let real = links(along: named) + [resolved(named)]
        return [named] + real + real.flatMap { dataVolumeNames(of: $0) }
    }

    /// The symlinks an absolute `path` passes through, the last part's
    /// included, each as the entry it is (`entry`), followed as the kernel
    /// follows them; at most 32, as the kernel's `MAXSYMLINKS`. Below a part
    /// that does not exist, nothing is a link.
    static func links(along path: String) -> [String] {
        let parts = { (path: String) in (path as NSString).pathComponents.filter { $0 != "/" && $0 != "." } }
        // What is left to walk, last part first; `current` is real throughout.
        var pending = Array(parts(path).reversed())
        var current = "/"
        var links: [String] = []
        while let part = pending.popLast() {
            guard part != ".." else {
                current = (current as NSString).deletingLastPathComponent
                continue
            }
            let candidate = (current as NSString).appendingPathComponent(part)
            if links.count < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                links.append(entry(candidate))
                if target.hasPrefix("/") { current = "/" }
                pending += parts(target).reversed()
            } else {
                current = candidate
            }
        }
        return links
    }

    /// The directory entry `path` names: what it reaches, as the kernel
    /// names it, unless it is a symlink, which is the entry itself, not what
    /// it leads to: then its folder resolved, plus its own name. (Naming
    /// every other entry as the kernel does keeps `~/LIBRARY` from passing
    /// as some other folder than `~/Library`.)
    static func entry(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        var status = stat()
        guard standardized != "/", !parent.isEmpty, lstat(standardized, &status) == 0,
            status.st_mode & S_IFMT == S_IFLNK
        else { return resolved(standardized) }
        return (resolved(parent) as NSString).appendingPathComponent((standardized as NSString).lastPathComponent)
    }

    /// Absolute path prefixes, `~` and `~/…` meaning the home directory.
    /// `..` is refused rather than resolved, so a grant says plainly what it
    /// covers.
    static func paths(_ value: JSONValue, _ field: String, home: String = NSHomeDirectory()) throws -> [String] {
        guard let list = value.arrayValue else { throw RuleDefinitionError("\"\(field)\" must list paths") }
        return try list.map { item in
            guard let text = item.stringValue else { throw RuleDefinitionError("\"\(field)\" must list strings") }
            var path = text
            if path == "~" {
                path = home
            } else if path.hasPrefix("~/") {
                path = home + path.dropFirst(1)
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("/"), !components.contains(".."), !components.contains("."),
                !path.contains("\0"), path == "/" || !path.hasSuffix("/"), !path.contains("//")
            else {
                throw RuleDefinitionError(
                    "\"\(field)\": \"\(text)\" must be an absolute, normalized path (or start with ~/)")
            }
            return path
        }
    }

    /// A kind `observe.allow` may name: one in the catalog that is observed
    /// by name. Any other kind is an error that says what it needs instead,
    /// so a grant never reads as giving what it does not.
    private static func observedKind(_ text: String, _ field: String, _ events: EventCatalog) throws -> String {
        guard let kind = events.kind(named: text) else {
            throw RuleDefinitionError("\"\(field).allow\": unknown event \"\(text)\"")
        }
        guard kind.descriptor.observation == .named else {
            let needs = kind.descriptor.observationGrant.map {
                "it needs capabilities: { \(EffectCatalog.standard.grantText($0.key, entry: $0.entry)) }"
            }
            throw RuleDefinitionError(
                "\"\(field).allow\": \(text) is not observed by name; \(needs ?? "it needs no grant")")
        }
        return text
    }

    private static func normalize(_ text: String, _ subject: GrantDescriptor.Subject, _ field: String) throws -> String
    {
        switch subject {
        case .absolutePath:
            guard text.hasPrefix("/"), (text as NSString).standardizingPath == text else {
                throw RuleDefinitionError("\"\(field).allow\": \"\(text)\" must be an absolute, normalized path")
            }
            return text
        case .origin:
            guard let origin = URLOrigin(text) else {
                throw RuleDefinitionError("\"\(field).allow\": \"\(text)\" is not an origin like https://example.com")
            }
            return origin.description
        case .scheme:
            // RFC 3986: a letter, then letters, digits, "+", "-" or ".".
            let scheme = text.lowercased()
            guard scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil else {
                throw RuleDefinitionError("\"\(field).allow\": \"\(text)\" is not a URL scheme like https")
            }
            return scheme
        case .name:
            guard !text.isEmpty, text.utf8.count <= 256 else {
                throw RuleDefinitionError("\"\(field).allow\": names must be 1–256 bytes")
            }
            return text
        case .eventKind:
            preconditionFailure("event kinds are checked against the event catalog (observedKind)")
        }
    }

    private static func allowList(_ value: JSONValue, _ field: String) throws -> [String] {
        guard let fields = value.objectValue, fields.keys.allSatisfy({ $0 == "allow" }),
            let list = fields["allow"]?.arrayValue
        else {
            throw RuleDefinitionError("\"\(field)\" must be { allow: [...] }")
        }
        return try list.map { item in
            guard let text = item.stringValue else { throw RuleDefinitionError("\"\(field).allow\" must list strings") }
            return text
        }
    }
}

/// Scheme, host and port: the unit an `http` grant allows.
struct URLOrigin: Sendable, Hashable, CustomStringConvertible {
    let scheme: String
    let host: String
    let port: Int

    init?(_ text: String) {
        guard let components = URLComponents(string: text), components.path.isEmpty || components.path == "/",
            components.query == nil, components.fragment == nil, components.user == nil
        else { return nil }
        self.init(components)
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        self.init(components)
    }

    private init?(_ components: URLComponents) {
        guard let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = host
        port = components.port ?? (scheme == "https" ? 443 : 80)
    }

    var description: String { "\(scheme)://\(host):\(port)" }
}

extension HandlerHost.LoadedEntry {
    /// A rule the file exports that is not usable, and why.
    struct RuleFailure: Sendable {
        let file: String
        let name: String
        let event: String?
        let reason: String

        var diagnostic: RuleDiagnostic {
            RuleDiagnostic(tool: .loader, file: file, message: "rule \"\(name)\": \(reason)", fixable: false)
        }

        /// The rule as the engine lists it: failed, with why.
        var summary: RuleSummary {
            RuleSummary(
                id: RuleID.make(file: file, name: name), file: file, event: event, state: .failed, reason: reason,
                invocations: 0, failures: 0, lastInvokedAt: nil, lastError: nil)
        }
    }

    /// The file's rules, decoded and checked: what the host reports is
    /// untrusted, since the host runs user code. Whether one failure fails
    /// the file is the caller's policy.
    func definitions(
        catalog: EventCatalog, observation: ObservationScope
    ) -> (definitions: [RuleDefinition], failures: [RuleFailure]) {
        var definitions: [RuleDefinition] = []
        var failures: [RuleFailure] = []
        var names = Set<String>()
        for raw in rules {
            do {
                let definition = try RuleDefinition(file: file, raw: raw, catalog: catalog, observation: observation)
                guard names.insert(definition.name).inserted else {
                    throw RuleDefinitionError("\"name\" \"\(definition.name)\" is used twice in \(file)")
                }
                definitions.append(definition)
            } catch {
                failures.append(
                    RuleFailure(
                        file: file, name: raw["name"]?.stringValue ?? "?", event: raw["on"]?.stringValue,
                        reason: "\(error)"))
            }
        }
        return (definitions, failures)
    }
}
