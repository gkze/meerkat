import Foundation
import MeerkatKit

/// Whether a rule may observe what it subscribes to, and what it sees of
/// each event: the rule's side of `EventDescriptor.Observation`
/// (docs/design/effects.md, "Observation").
///
/// The catalog says what each kind needs; this decides it from the rule's
/// grants and from the facts outside the rule that the decision reads,
/// which a test replaces. Rule loading and the dry run both decide the
/// grant through `RuleDefinition`, so a draft is refused as the saved rule
/// would be. The daemon's file scope, which changes while rules run, is
/// decided apart, by `requireFileScope`: wherever a rule subscribes
/// (`RuleEngine.subscribe`), when the scope changes
/// (`RuleEngine.recheckFileScope`), and in the dry run (`RuleDryRunner`).
struct ObservationScope: Sendable {
    /// What no rule may watch, nor anything inside or above it: the daemon's
    /// state (`RuleEngine.ProtectedPaths.read`), as named and resolved.
    var protectedRead: [String]
    /// The user whose processes `process.observe: "own"` covers: the
    /// daemon's, which is the user's.
    var user: uid_t = getuid()
    /// What `fs.churn` without a root measures: `meerkat.json`'s `files`.
    var fileScope: @Sendable () -> FileScope = { .standard }
    /// Who owns a running process; nil when no such process runs.
    var owner: @Sendable (ProcessIdentity) -> uid_t? = { identity in
        ProcessTable.record(of: identity)?.uid
    }

    /// Throws when `grants` do not cover observing `kind` with `parameters`,
    /// naming the grant to add. The daemon's file scope is left to
    /// `requireFileScope`.
    func require(_ kind: AnyEventKind, parameters: NormalizedParameters, grants: CapabilityGrants) throws {
        let descriptor = kind.descriptor
        guard let needed = descriptor.observationGrant else { return }
        // The least grant the kind needs, from the descriptor, so what is
        // checked is what the catalog says; a path is the rule's to name,
        // and is checked below.
        if let entry = needed.entry, !grants.allows(needed.key, subject: entry, shape: needed.grant.shape) {
            throw RuleDefinitionError(
                "\"on\": observing \(descriptor.name) needs capabilities: { \(EffectCatalog.standard.grantText(needed.key, entry: entry)) }"
            )
        }
        switch descriptor.observation {
        case .open, .named:
            return
        case .processes:
            // A process named in `params` is decided now when it is running;
            // one that is not cannot start again under the same start time.
            guard !Self.observes(.all, grants), let process = parameters.observedProcess,
                let owner = owner(process), owner != user
            else { return }
            throw RuleDefinitionError(
                "\"params\": pid \(process.pid) is another user's process: observing it needs capabilities: { \(EffectCatalog.standard.grantText(needed.key, entry: GrantDescriptor.ProcessLevel.all.rawValue)) }"
            )
        case .paths:
            guard let observed = parameters.observedPaths else {
                throw RuleDefinitionError("\"on\": \(descriptor.name) does not say which paths it watches")
            }
            if let paths = observed.paths {
                try requireWatching(paths, excluding: observed.exclude, kind: descriptor.name, grants: grants)
            }
        }
    }

    /// Throws when `kind` with `parameters` watches the daemon's file scope
    /// (`fs.churn` without a root) and `grants` do not cover the scope as it
    /// is now. `meerkat.json` can change the scope under a decoded rule, so
    /// this is decided where a rule subscribes, each time it does
    /// (`RuleEngine.subscribe`, and the dry run), not where it decodes.
    func requireFileScope(_ kind: AnyEventKind, parameters: NormalizedParameters, grants: CapabilityGrants) throws {
        guard Self.watchesFileScope(kind, parameters: parameters), let observed = parameters.observedPaths
        else { return }
        // As the source measures it (`FSChurnParameters.scope`).
        let scope = fileScope()
        do {
            try requireWatching(
                [scope.root], excluding: scope.exclude + observed.exclude, kind: kind.descriptor.name, grants: grants)
        } catch let error as RuleDefinitionError {
            throw RuleDefinitionError("\(error.message) (it measures meerkat.json's files scope)")
        }
    }

    /// `requireFileScope` for a decoded rule.
    func requireFileScope(of definition: RuleDefinition, in catalog: EventCatalog) throws {
        guard let kind = catalog.kind(named: definition.event) else { return }
        try requireFileScope(kind, parameters: definition.parameters, grants: definition.grants)
    }

    /// Whether `grants` reach `level`, in the order the grant's shape gives
    /// its levels (`GrantDescriptor.processObserve`), so that order is
    /// decided in one place.
    private static func observes(_ level: GrantDescriptor.ProcessLevel, _ grants: CapabilityGrants) -> Bool {
        let grant = GrantDescriptor.processObserve
        return grants.allows(grant.key, subject: level.rawValue, shape: grant.shape)
    }

    /// Whether `kind` with `parameters` watches the daemon's file scope,
    /// which `meerkat.json` can change under a loaded rule.
    static func watchesFileScope(_ kind: AnyEventKind, parameters: NormalizedParameters) -> Bool {
        guard kind.descriptor.observation == .paths, let observed = parameters.observedPaths else {
            return false
        }
        return observed.paths == nil
    }

    /// Each path inside `fs.read`, and none at, inside or above a protected
    /// path, unless that path is excluded and so never reported.
    private func requireWatching(
        _ paths: [String], excluding exclude: [String], kind: String, grants: CapabilityGrants
    ) throws {
        // Excluded events are matched by real path (`ChurnAccumulator`).
        let excluded = exclude.map(CapabilityGrants.resolved)
        let protected = protectedRead.filter { path in
            let real = CapabilityGrants.resolved(path)
            return !excluded.contains { real == $0 || real.hasPrefix($0 + "/") }
        }
        for path in paths {
            let read = GrantDescriptor.fsRead
            guard grants.allows(read.key, subject: path, shape: read.shape) else {
                throw RuleDefinitionError(
                    "\"on\": watching \(path) with \(kind) needs capabilities: { \(EffectCatalog.standard.grantText(read.key, entry: path)) }"
                )
            }
            // As FSEvents watches it: symlinks resolved.
            if let touched = CapabilityGrants.protectedPath(
                touchedBy: CapabilityGrants.resolved(path), in: protected)
            {
                throw RuleDefinitionError(
                    "\"params\": \(path) is at, inside or above \(touched), which holds Meerkat's state; no rule may watch it"
                )
            }
        }
    }

    /// What `definition`'s rule sees of each event of `kind`; nil when it
    /// sees every event whole.
    func view(of kind: AnyEventKind, for definition: RuleDefinition) -> EventView? {
        guard let view = kind.view else { return nil }
        let rule: RuleView
        if kind.descriptor.observation == .processes {
            // Seen whole, a process kind needs no decoding per event.
            guard !Self.observes(.all, definition.grants) else { return nil }
            rule = RuleView(file: definition.file, user: user)
        } else {
            rule = RuleView(file: definition.file, user: nil)
        }
        return EventView { envelope in
            view(envelope.payload, rule).map {
                EventEnvelope(
                    kind: envelope.kind, sequence: envelope.sequence, time: envelope.time, origin: envelope.origin,
                    replayed: envelope.replayed, payload: $0)
            }
        }
    }
}

/// One rule's view of its events: the event as the rule may see it, or nil
/// when it may see none of it. Applied in Swift before `match`, so what it
/// leaves out never reaches JavaScript.
struct EventView: Sendable {
    let apply: @Sendable (EventEnvelope) -> EventEnvelope?

    func callAsFunction(_ envelope: EventEnvelope) -> EventEnvelope? { apply(envelope) }
}

extension ObservationScope {
    /// The scope the engine and the dry run decide with.
    init(protected: RuleEngine.ProtectedPaths, environment: SourceEnvironment) {
        self.init(protectedRead: protected.read, fileScope: { environment.fileScope })
    }
}
