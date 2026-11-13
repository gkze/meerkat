import Foundation
import Synchronization

/// What sources share with each other and with their host process.
///
/// Expensive observers that several event kinds read (the process tracker)
/// live here so they run once, reference-counted by the sources using them.
public final class SourceEnvironment: Sendable {
    public let homeDirectory: String
    /// Processes whose actions count as the daemon's own (`origin: meerkat`):
    /// this process plus anything it spawned or signalled for a rule.
    public let ownProcesses: OwnProcesses
    /// Events the host process raises about itself (`meerkat.*`).
    public let internalEvents: Broadcaster<InternalEvent>
    let processTracker: Shared<ProcessTracker>
    /// Full process-table snapshots, shared by the sources that enumerate
    /// every process (`process.top`'s ranking, `process.hot`).
    public let processSnapshots = SharedProcessSnapshot()
    private let hub = Mutex<WeakHub>(WeakHub())
    private let fileScopeProvider = Mutex<@Sendable () -> FileScope>({ .standard })
    private let networkFilterReader = Mutex<any NetworkFilterReading>(NoNetworkFilter())

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
        let ownProcesses = OwnProcesses()
        self.ownProcesses = ownProcesses
        internalEvents = Broadcaster()
        processTracker = Shared { ProcessTracker(ownProcesses: ownProcesses) }
    }

    /// What `fs.churn` measures when a subscription names no root. The host
    /// supplies it from its live configuration; read once per window.
    public var fileScope: FileScope { fileScopeProvider.withLock { $0 }() }

    public func provideFileScope(_ provider: @escaping @Sendable () -> FileScope) {
        fileScopeProvider.withLock { $0 = provider }
    }

    /// The network filter's totals, for the process sources' network fields
    /// and `network.flows`. The daemon supplies its client; until then (and
    /// in any other process) the filter reads as absent.
    public var networkFilter: any NetworkFilterReading { networkFilterReader.withLock { $0 } }

    public func provideNetworkFilter(_ reader: any NetworkFilterReading) {
        networkFilterReader.withLock { $0 = reader }
    }

    func attach(hub: EventHub) {
        self.hub.withLock { $0.value = hub }
    }

    var attachedHub: EventHub? {
        hub.withLock { $0.value }
    }

    private struct WeakHub: @unchecked Sendable {
        weak var value: EventHub?
    }
}

/// Events the daemon raises about itself and its rules' effects.
public enum InternalEvent: Sendable {
    case rule(RuleStatusPayload)
    case notification(NotificationResponsePayload)
}

/// Process instances whose actions are the daemon's own: this process plus
/// anything it spawned for a rule, and the exits of processes it asked to
/// end. Keyed by identity, so a pid reused after one of them exits is not
/// mistaken for it.
public final class OwnProcesses: Sendable {
    private let identities: Mutex<Set<ProcessIdentity>>

    /// Above this many entries, identities of processes that no longer run
    /// are pruned (their exits may have gone unobserved).
    static let pruneThreshold = 1024

    public init() {
        identities = Mutex(Set(ProcessTable.record(pid: getpid()).map { [$0.identity] } ?? []))
    }

    public func insert(_ identity: ProcessIdentity) {
        let count = identities.withLock { set -> Int in
            set.insert(identity)
            return set.count
        }
        // An unreadable table prunes nothing; the next insert tries again.
        if count > Self.pruneThreshold, let table = try? ProcessTable.all() {
            let alive = Set(table.map(\.identity))
            identities.withLock { $0.formIntersection(alive) }
        }
    }

    /// Forgets the process: it exited.
    public func remove(_ identity: ProcessIdentity) {
        _ = identities.withLock { $0.remove(identity) }
        _ = exits.withLock { $0.removeValue(forKey: identity) }
    }

    public func contains(_ identity: ProcessIdentity) -> Bool { identities.withLock { $0.contains(identity) } }

    /// Processes the daemon asked to end, and since when. Only their exit
    /// is the daemon's doing, and only soon after: one that handles the
    /// signal and keeps running stays the system's, as do its children.
    private let exits = Mutex<[ProcessIdentity: ContinuousClock.Instant]>([:])
    static let exitWindow = Duration.seconds(30)

    /// Returns false when the exit was already expected, so a caller that
    /// must undo only what it added can tell.
    @discardableResult
    public func expectExit(_ identity: ProcessIdentity) -> Bool {
        exits.withLock { exits in
            let now = ContinuousClock.now
            exits = exits.filter { now - $0.value < Self.exitWindow }
            return exits.updateValue(now, forKey: identity) == nil
        }
    }

    public func withdrawExpectedExit(_ identity: ProcessIdentity) {
        _ = exits.withLock { $0.removeValue(forKey: identity) }
    }

    public func expectsExit(of identity: ProcessIdentity) -> Bool {
        exits.withLock { exits in exits[identity].map { ContinuousClock.now - $0 < Self.exitWindow } ?? false }
    }
}

/// Fan-out of values to registered handlers, for in-process event streams.
public final class Broadcaster<Value: Sendable>: Sendable {
    private let handlers = Mutex<(next: UInt64, all: [UInt64: @Sendable (Value) -> Void])>((1, [:]))

    public init() {}

    /// Returns a token for `remove`.
    @discardableResult
    public func add(_ handler: @escaping @Sendable (Value) -> Void) -> UInt64 {
        handlers.withLock { state in
            let token = state.next
            state.next += 1
            state.all[token] = handler
            return token
        }
    }

    public func remove(_ token: UInt64) {
        _ = handlers.withLock { $0.all.removeValue(forKey: token) }
    }

    public func send(_ value: Value) {
        let all = handlers.withLock { Array($0.all.values) }
        for handler in all { handler(value) }
    }
}

/// A reference-counted, lazily started resource shared by sources.
///
/// `acquire` creates and starts the resource for the first user; `release`
/// stops and drops it after the last one.
final class Shared<Resource: SharedResource>: Sendable {
    private let make: @Sendable () -> Resource
    private let state = Mutex<(resource: Resource?, users: Int)>((nil, 0))

    init(_ make: @escaping @Sendable () -> Resource) {
        self.make = make
    }

    func acquire() throws -> Resource {
        let (resource, isNew) = state.withLock { state -> (Resource, Bool) in
            state.users += 1
            if let resource = state.resource { return (resource, false) }
            let resource = make()
            state.resource = resource
            return (resource, true)
        }
        if isNew {
            do {
                try resource.start()
            } catch {
                release()
                throw error
            }
        }
        return resource
    }

    func release() {
        let stopping = state.withLock { state -> Resource? in
            state.users -= 1
            guard state.users == 0 else { return nil }
            defer { state.resource = nil }
            return state.resource
        }
        stopping?.stop()
    }
}

protocol SharedResource: AnyObject, Sendable {
    func start() throws
    func stop()
}

/// One recent full snapshot of the process table for every source that
/// needs one. Enumerating ~1000 processes (`proc_pid_rusage` each, and `ps`
/// for other users') is the daemon's largest steady cost, and `process.top`
/// and `process.hot` each did it on their own timer. A snapshot taken by one
/// serves the other while it is at most `maxAge` old; deltas use each
/// snapshot's own `takenAt`, so a reused snapshot keeps rates exact and only
/// shifts when the reading was taken.
public final class SharedProcessSnapshot: Sendable {
    private let latest = Mutex<ProcessSnapshot?>(nil)

    public init() {}

    /// A snapshot no older than `maxAge` seconds, taken now when the last one
    /// is older, with each process's network totals where `network` has them.
    /// Concurrent callers may both take one; the later one wins. Throws when
    /// the process table cannot be read; a network filter that cannot be read
    /// leaves the network fields unknown and the rest stands. `network` has
    /// no default: the snapshot is shared, and one taken without the
    /// filter's totals would serve the next caller that wants them.
    public func current(maxAge: TimeInterval, network: any NetworkFilterReading) throws -> ProcessSnapshot {
        if let snapshot = latest.withLock({ $0 }), Date().timeIntervalSince(snapshot.takenAt) <= maxAge {
            return snapshot
        }
        var fresh = try ProcessSampler.snapshot()
        if let totals = try? network.totals(wantsHosts: false) { fresh = fresh.attributing(totals) }
        latest.withLock { $0 = fresh }
        return fresh
    }
}
