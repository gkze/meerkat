import Foundation

// MARK: - Descriptor

/// What a handler can rely on for one event kind. This is the single authority
/// for an event's name and guarantees: `meerkat events list` and the
/// generated TypeScript documentation are derived from it.
public struct EventDescriptor: Sendable, Codable, Hashable {
    /// Dotted name, `family.event`, as rules write it in `on:`.
    public let name: String
    public let summary: String
    public let mechanism: Mechanism
    public let semantics: Semantics
    public let loss: Loss
    public let stability: Stability
    /// The privacy permission the event needs, and what it does without it;
    /// nil for events any unprivileged process can observe. Rendered by
    /// `PermissionNeed.note` and gated by `PermissionNeed.require` and
    /// `clientRefusal` (Permissions.swift), wherever a subscription starts.
    public let permission: PermissionNeed?
    /// What a rule must declare in its `capabilities` to observe the kind
    /// (docs/design/effects.md, "Observation"). The permission is the
    /// daemon's; this grant is the rule's, and a kind behind both needs both.
    public let observation: Observation
    /// The OS facility behind the event, for diagnostics and documentation.
    public let source: String

    public var family: String {
        String(name.split(separator: ".", maxSplits: 1).first ?? Substring(name))
    }

    /// The grant observing this kind needs, with the entry the least grant
    /// adds; nil for an open kind. `EffectCatalog.grantText` renders it.
    public var observationGrant: ObservationGrant? {
        switch observation {
        case .open: nil
        case .paths: ObservationGrant(grant: .fsRead, entry: nil)
        case .processes: ObservationGrant(grant: .processObserve, entry: GrantDescriptor.ProcessLevel.own.rawValue)
        case .named: ObservationGrant(grant: .observe, entry: name)
        }
    }

    public struct ObservationGrant: Sendable, Equatable {
        /// The catalog's grant itself, not its name, so the two cannot part.
        public let grant: GrantDescriptor
        /// Nil for a path, which only the rule knows.
        public let entry: String?

        public var key: String { grant.key }
    }

    public init(
        _ name: String, _ summary: String, mechanism: Mechanism, semantics: Semantics,
        loss: Loss, stability: Stability = .documented, permission: PermissionNeed? = nil,
        observation: Observation, source: String
    ) {
        self.name = name
        self.summary = summary
        self.mechanism = mechanism
        self.semantics = semantics
        self.loss = loss
        self.stability = stability
        self.permission = permission
        self.observation = observation
        self.source = source
    }

    public enum Mechanism: String, Sendable, Codable, CaseIterable, SchemaDescribed {
        /// The OS notifies us.
        case push
        /// We sample at an interval.
        case poll
        /// Computed from other observations (for example, a threshold held
        /// over several samples).
        case derived
    }

    public enum Semantics: String, Sendable, Codable, CaseIterable, SchemaDescribed {
        /// Something happened.
        case occurrence
        /// The current value of something; the latest event is replayed to
        /// each new subscriber.
        case state
    }

    public enum Loss: String, Sendable, Codable, CaseIterable, SchemaDescribed {
        /// Every change produces an event while the source runs.
        case none
        /// One event can stand for several changes.
        case coalesced
        /// Some changes are never seen, and nothing reports the loss: those
        /// between two observations of a polled source, or those a push
        /// source's provider discards when the source falls behind
        /// (`log.entry`).
        case lossy
    }

    public enum Stability: String, Sendable, Codable, CaseIterable, SchemaDescribed {
        case documented
        /// Stable in practice but not a documented Apple interface.
        case undocumented
    }

    /// A TCC (Privacy & Security) permission. It is checked, and asked for,
    /// only when a source starts, which happens only when something
    /// subscribes: no subscription, no prompt. See `Permissions.swift`.
    public enum Permission: String, Sendable, Codable, CaseIterable, SchemaDescribed {
        case accessibility
        case inputMonitoring
        case location
        case bluetooth
    }

    /// A permission a kind needs, and what it does without it.
    public struct PermissionNeed: Sendable, Codable, Hashable {
        public let permission: Permission
        public let without: Absence

        public enum Absence: String, Sendable, Codable, CaseIterable, SchemaDescribed {
            /// The subscription is refused.
            case refused
            /// The source runs and reports less, as the summary says.
            case reportsLess
        }

        public static func required(_ permission: Permission) -> Self {
            Self(permission: permission, without: .refused)
        }
        public static func improves(_ permission: Permission) -> Self {
            Self(permission: permission, without: .reportsLess)
        }
    }

    /// The grant a rule needs to observe a kind. Rules run inside meerkatd
    /// as the user, so the OS's file permissions narrow nothing: what a
    /// rule may see is what it declares, as with what it may do.
    public enum Observation: String, Sendable, Codable, CaseIterable, SchemaDescribed {
        /// Ambient state about this Mac, not about other people, files or
        /// what the user is doing: no grant.
        case open
        /// The paths its parameters watch, each inside the rule's `fs.read`
        /// grant and none at, inside or above the daemon's state.
        case paths
        /// Processes: `process.observe`, `"own"` for the user's own and
        /// `"all"` for every user's. Applications are the user's own, so
        /// either level covers them.
        case processes
        /// The kind's name in `observe.allow`: what the user is doing, text
        /// other programs wrote, or other people.
        case named
    }
}

// MARK: - Payloads and parameters

/// An event payload: what a handler receives.
public protocol EventPayload: Codable, Sendable, SchemaDescribed {
    /// Representative values, run through `schema` by the conformance tests.
    static var examples: [Self] { get }
}

/// Source configuration for a subscription: which paths, which interval.
///
/// Subscribers whose normalized parameters are equal share one source. The
/// schema is the authority for each field's bounds and default: decoding
/// fills the defaults from it and checks the bounds against it.
public protocol EventParameters: Codable, Sendable, Hashable, SchemaDescribed {
    /// Parameters are always an object, so their schema is one: what
    /// decodes them reads its fields with nothing to unwrap.
    static var objectSchema: ObjectSchema { get }
    static var examples: [Self] { get }
    /// Checks between fields, which a schema cannot express. Throw
    /// `EventError.invalidParameters` with a message a rule author can act on.
    func validateRelations() throws
}

extension EventParameters {
    public static var schema: TypeSchema { .object(objectSchema) }

    public func validateRelations() throws {}

    /// Whether a subscription accepts these parameters: the schema's bounds,
    /// then the checks between fields. For parameters built in Swift; those
    /// a rule sends are checked as they decode (`AnyEventKind.normalized`).
    public func validate() throws {
        let value: JSONValue
        do {
            value = try JSONValue(encoding: self)
        } catch {
            // Only a NaN or infinite number fails to encode.
            throw EventError.invalidParameters("a number is not finite")
        }
        try Self.checkSchema(value)
        try validateRelations()
    }

    static func checkSchema(_ value: JSONValue) throws {
        let problems = SchemaValidator.violations(of: value, against: schema, at: "")
        guard problems.isEmpty else { throw EventError.invalidParameters(problems.joined(separator: "; ")) }
    }
}

/// Parameters of a kind a rule observes through its `fs.read` grant
/// (`EventDescriptor.Observation.paths`).
public protocol PathObservingParameters: EventParameters {
    var observedPaths: ObservedPaths { get }
}

/// Parameters of a kind whose source reads the network filter, and refuses
/// to start, or ends, while it is off.
public protocol NetworkFilterParameters: EventParameters {
    var needsNetworkFilter: Bool { get }
}

/// What a subscription watches.
public struct ObservedPaths: Sendable, Equatable {
    /// As decoded; nil when it measures the daemon's file scope
    /// (`SourceEnvironment.fileScope`), which `meerkat.json` can change while
    /// the subscription runs.
    public let paths: [String]?
    /// Paths under them whose events it never reports, in the form FSEvents
    /// reports paths; added to the scope's own when `paths` is nil.
    public let exclude: [String]

    public init(paths: [String]?, exclude: [String] = []) {
        self.paths = paths
        self.exclude = exclude
    }
}

/// Parameters that name one process, so a rule that may observe only its
/// user's processes can be refused at load rather than filtered.
public protocol ProcessObservingParameters: EventParameters {
    /// Nil when the parameters name no process that can exist.
    var observedProcess: ProcessIdentity? { get }
}

/// What one rule may see of an event.
public struct RuleView: Sendable, Equatable {
    /// The rule's entry file.
    public let file: String
    /// The user whose processes alone the rule may see; nil for every
    /// user's (`process.observe: "all"`).
    public let user: uid_t?

    public init(file: String, user: uid_t?) {
        self.file = file
        self.user = user
    }
}

/// A payload a rule may see only part of: one about another user's process,
/// or a `meerkat.*` event about another file's rules (a status, a dropped
/// subscription, a notification response). The source stays shared; each
/// rule's view is taken as the event reaches it. The file is the unit that
/// shares grants, so one file never sees what another file's rules caused,
/// and this is the one place that rule is kept.
public protocol RuleViewedPayload: EventPayload {
    /// What `view` may see of this event; nil for nothing.
    func viewed(by view: RuleView) -> Self?
}

/// For events that take no parameters.
public struct NoParameters: EventParameters {
    public init() {}
    public static var objectSchema: ObjectSchema { ObjectSchema([]) }
    public static var examples: [NoParameters] { [NoParameters()] }
}

/// Payload for events whose occurrence is the whole message.
public struct EmptyPayload: EventPayload, Equatable {
    public init() {}
    public static var schema: TypeSchema { .object(ObjectSchema([])) }
    public static var examples: [EmptyPayload] { [EmptyPayload()] }
}

public enum EventError: Error, CustomStringConvertible, Equatable {
    case unknownEvent(String)
    case invalidParameters(String)
    case sourceUnavailable(String)
    /// The kind's audience excludes this subscriber.
    case restricted(String)

    public var description: String {
        switch self {
        case .unknownEvent(let name): return "unknown event \"\(name)\""
        case .invalidParameters(let message): return "invalid parameters: \(message)"
        case .sourceUnavailable(let message): return "event source unavailable: \(message)"
        case .restricted(let message): return message
        }
    }
}

// MARK: - Sources

/// A running observation of one event kind with one parameter set.
///
/// `start` is called once; `stop` is called once after a successful start and
/// must release every OS resource. Both may be called from any thread.
///
/// A source that stops observing after a successful start (its child process
/// exits, a measurement it repeats keeps failing) calls `Emitter.fail` rather
/// than going quiet, so its subscribers learn that no more events will come.
/// Polling sources take `PollingSource`'s policy: a failed tick is skipped
/// and shown in `detail`, and a run of them ends the subscription.
public protocol EventSource: AnyObject, Sendable {
    func start() throws
    func stop()
    /// What a running instance wants its operator to know about how it
    /// interprets its parameters (shown in daemon status). Read under the
    /// hub's lock, so it must not call into the hub.
    var detail: String? { get }
}

extension EventSource {
    public var detail: String? { nil }
}

/// Who caused an event.
public enum EventOrigin: String, Sendable, Codable, CaseIterable, SchemaDescribed {
    case system
    /// The daemon itself (an effect a rule requested). Rules do not receive
    /// these unless they opt in, which breaks handler feedback loops.
    case meerkat
}

/// What an emitter hands the hub.
public enum Emission: Sendable, Equatable {
    /// - Parameter value: set when the payload is a value the source
    ///   reports, not an occurrence or a measurement: the hub leaves out one
    ///   equal to the latest, and marks a push `state` kind's current value
    ///   `replayed`.
    case event(JSONValue, origin: EventOrigin, value: ReportedValue?)
    /// A payload JSON cannot carry, such as one with a NaN or infinite
    /// number: a measurement gone wrong, which the hub counts in the
    /// source's statistics instead of losing it unseen.
    case unencodable(String)

    public enum ReportedValue: Sendable, Equatable {
        /// What the source read as it started (its documented "current
        /// value first").
        case current
        /// What it read after observing a change.
        case change
    }
}

/// Delivers typed payloads from a source into the hub.
public struct Emitter<Payload: EventPayload>: Sendable {
    let sink: @Sendable (Emission) -> Void
    let failure: @Sendable (String) -> Void

    /// The hub passes both; a test that drives a source directly may leave
    /// out `fail`.
    public init(
        sink: @escaping @Sendable (Emission) -> Void,
        fail: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.sink = sink
        failure = fail
    }

    /// For a test that drives a source directly: each payload, as JSON, and
    /// its origin; a payload JSON cannot carry is left out.
    public init(_ received: @escaping @Sendable (JSONValue, EventOrigin) -> Void) {
        self.init(sink: { emission in
            if case .event(let value, let origin, _) = emission { received(value, origin) }
        })
    }

    /// Reports that the source stopped observing for good, after a
    /// successful start. The hub ends every subscriber's stream with
    /// `reason` and then stops the source, so it may be called from any
    /// thread, the source's own queue included. Events emitted afterwards
    /// are discarded.
    public func fail(_ reason: String) {
        failure(reason)
    }

    /// An occurrence or a measurement.
    public func callAsFunction(_ payload: Payload, origin: EventOrigin = .system) {
        send(payload, origin: origin, value: nil)
    }

    /// The value a source read as it started.
    public func current(_ payload: Payload) {
        send(payload, origin: .system, value: .current)
    }

    /// The value a source read after observing a change, which may turn out
    /// to be the value it already reported.
    public func changed(_ payload: Payload) {
        send(payload, origin: .system, value: .change)
    }

    private func send(_ payload: Payload, origin: EventOrigin, value: Emission.ReportedValue?) {
        do {
            sink(.event(try JSONValue(encoding: payload), origin: origin, value: value))
        } catch {
            sink(.unencodable("\(error)"))
        }
    }
}

/// Who may subscribe to an event kind. The hub enforces it
/// (`EventHub.subscribe`); which of the kind's events a rule then sees is
/// the payload's view (`RuleViewedPayload`).
public enum EventAudience: Sendable, Equatable {
    case everyone
    /// Only rules: no client of the daemon may subscribe.
    case rules
}

/// Who is subscribing, for kinds whose audience is restricted.
public enum EventSubscriber: Sendable, Hashable {
    /// A client of the daemon (the app, the CLI, MCP) or the daemon itself.
    case external
    /// A rule, by its entry file.
    case rule(file: String)
}

/// One event kind: its descriptor, its types, and how to observe it.
public protocol EventKind: Sendable {
    associatedtype Payload: EventPayload
    associatedtype Parameters: EventParameters

    static var descriptor: EventDescriptor { get }
    static var audience: EventAudience { get }

    static func makeSource(
        _ parameters: Parameters,
        environment: SourceEnvironment,
        emit: Emitter<Payload>
    ) throws -> any EventSource
}

extension EventKind {
    public static var audience: EventAudience { .everyone }
}

// MARK: - Type erasure

/// A kind's parameters, decoded and validated once (`AnyEventKind.normalized`),
/// with defaults applied. Decoding can resolve paths against the live file
/// system (`eventPath`), so everything about one subscription is read from
/// this value rather than decoded again. Two are equal when their JSON is:
/// equal JSON means the same source, and what they observe was decoded from it.
public struct NormalizedParameters: Sendable, Equatable {
    /// The kind they are for.
    public let kind: String
    /// The parameters re-encoded: equal values mean the same source.
    public let json: JSONValue
    /// What they watch, for a kind whose parameters watch paths.
    public let observedPaths: ObservedPaths?
    /// The process they name, for a kind whose parameters name one.
    public let observedProcess: ProcessIdentity?
    /// Whether their source reads the network filter, so a subscription
    /// refused or ended while it is off can start once it is on again.
    public let needsNetworkFilter: Bool
    fileprivate let instantiate:
        @Sendable (
            SourceEnvironment, @escaping @Sendable (Emission) -> Void, @escaping @Sendable (String) -> Void
        ) throws -> any EventSource

    fileprivate init<K: EventKind>(_ parameters: K.Parameters, of kind: K.Type) throws {
        self.kind = K.descriptor.name
        json = try JSONValue(encoding: parameters)
        observedPaths = (parameters as? any PathObservingParameters)?.observedPaths
        observedProcess = (parameters as? any ProcessObservingParameters).flatMap(\.observedProcess)
        needsNetworkFilter = (parameters as? any NetworkFilterParameters)?.needsNetworkFilter ?? false
        instantiate = { environment, sink, fail in
            // Before the source exists, on the one path to every source:
            // some touch the framework the permission guards as they are
            // made, and touching IOBluetooth without its usage description
            // kills the process.
            try K.descriptor.permission?.require(for: K.descriptor.name)
            return try K.makeSource(parameters, environment: environment, emit: Emitter(sink: sink, fail: fail))
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind && lhs.json == rhs.json }
}

/// An `EventKind` with its types erased, so the catalog can be a list and the
/// hub can work with parameters and payloads as JSON.
public struct AnyEventKind: Sendable {
    public let descriptor: EventDescriptor
    public let audience: EventAudience
    public let payloadSchema: TypeSchema
    public let parametersSchema: ObjectSchema
    public let payloadExamples: @Sendable () throws -> [JSONValue]
    public let parameterExamples: @Sendable () throws -> [JSONValue]
    /// Whether this kind's parameters watch paths, and so whether
    /// `NormalizedParameters.observedPaths` is set for it.
    public let watchesPaths: Bool
    /// For a kind whose payloads a rule may see only part of: what a rule
    /// with that view sees of a payload, nil for nothing. A payload that does
    /// not decode is nothing, so a broken source cannot show more.
    public let view: (@Sendable (JSONValue, RuleView) -> JSONValue?)?
    private let normalizeParameters: @Sendable (JSONValue) throws -> NormalizedParameters

    public init<K: EventKind>(_ kind: K.Type) {
        descriptor = K.descriptor
        audience = K.audience
        payloadSchema = K.Payload.schema
        parametersSchema = K.Parameters.objectSchema
        payloadExamples = { try K.Payload.examples.map { try JSONValue(encoding: $0) } }
        parameterExamples = { try K.Parameters.examples.map { try JSONValue(encoding: $0) } }
        watchesPaths = K.Parameters.self is any PathObservingParameters.Type
        view = (K.Payload.self as? any RuleViewedPayload.Type).map { Self.viewer($0) }
        normalizeParameters = { raw in
            try NormalizedParameters(Self.decodeParameters(K.Parameters.self, raw), of: K.self)
        }
    }

    public var name: String { descriptor.name }

    /// Decodes and validates parameters once, applying defaults: the value
    /// a subscription's key, the paths and process it observes, and its
    /// source all come from, so they are one resolution of what was given.
    public func normalized(_ parameters: JSONValue) throws -> NormalizedParameters {
        try normalizeParameters(parameters)
    }

    /// `fail` may be left out by a test that drives a source directly, as
    /// with `Emitter`.
    func makeSource(
        _ parameters: NormalizedParameters, environment: SourceEnvironment,
        fail: @escaping @Sendable (String) -> Void = { _ in },
        sink: @escaping @Sendable (Emission) -> Void
    ) throws -> any EventSource {
        try parameters.instantiate(environment, sink, fail)
    }

    private static func viewer<P: RuleViewedPayload>(_ type: P.Type) -> @Sendable (JSONValue, RuleView) -> JSONValue? {
        { raw, view in
            guard let payload = try? raw.decode(as: P.self) else { return nil }
            return payload.viewed(by: view).flatMap { try? JSONValue(encoding: $0) }
        }
    }

    /// A rule without `params` sends null, which means "all defaults".
    private static func decodeParameters<P: EventParameters>(_ type: P.Type, _ given: JSONValue) throws -> P {
        let parameters: P
        do {
            parameters = try P.objectSchema.decode(given, as: P.self)
        } catch let mismatch as SchemaMismatch {
            throw EventError.invalidParameters(mismatch.description)
        }
        try parameters.validateRelations()
        return parameters
    }
}
