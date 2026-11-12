import Foundation
import Synchronization

/// What the provider and the XPC side share: the ledger and the host lease,
/// behind one lock held only to record a report or take a snapshot.
///
/// NetworkExtension reports no flow opening for a flow allowed at once (seen
/// on macOS 27: statistics and closes, never a new-flow report), so the
/// provider records each open as it gives the verdict (`opened`). The verdict
/// path never takes the ledger's lock: an open goes on a short queue of its
/// own, a constant-time append, which the ledger drains before every report
/// and every read. A full queue drops the open, counted, and the flow is then
/// untracked: low, never double.
public final class FilterState: Sendable {
    /// Changes on every start, so a reader never subtracts across two
    /// lifetimes of the extension.
    public let instance = UUID()
    public let build: String
    private let state: Mutex<(ledger: FlowLedger, lease: HostLease)>
    private let opens: Mutex<[FlowReport]>
    private let openCapacity: Int
    private let droppedOpens = Atomic<UInt64>(0)
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant

    public init(build: String, limits: FlowLedger.Limits = .standard) {
        self.build = build
        state = Mutex((FlowLedger(limits: limits), HostLease()))
        opens = Mutex([])
        openCapacity = limits.flows
        started = clock.now
    }

    /// A flow's open, from the verdict path: queued, not yet in the ledger.
    /// Only `.opened` reports belong here; anything else is recorded as is.
    public func opened(_ report: FlowReport) {
        let queued = opens.withLock { queue in
            guard queue.count < openCapacity else { return false }
            queue.append(report)
            return true
        }
        if !queued { droppedOpens.add(1, ordering: .relaxed) }
    }

    /// Opens dropped because the queue was full.
    public var openingsDropped: UInt64 { droppedOpens.load(ordering: .relaxed) }

    /// Moves queued opens into the ledger, in the order they came. Called
    /// with the ledger's lock held, so an open always precedes the flow's
    /// later reports.
    private func drainOpens(into ledger: inout FlowLedger) {
        let queued = opens.withLock { queue in
            defer { queue.removeAll(keepingCapacity: true) }
            return queue
        }
        for open in queued { ledger.record(open) }
    }

    public func record(_ report: FlowReport) { record(report, at: elapsed) }

    /// The reply to one request. Refuses another build's daemon rather than
    /// guessing at its meaning of the totals.
    public func reply(to request: FilterRequest) -> FilterReply { reply(to: request, at: elapsed) }

    /// `record` at monotonic time `now` (seconds since start).
    func record(_ report: FlowReport, at now: Double) {
        state.withLock { state in
            state.ledger.collectsHosts = state.lease.isActive(at: now)
            drainOpens(into: &state.ledger)
            state.ledger.record(report)
        }
    }

    /// `reply(to:)` at monotonic time `now` (seconds since start).
    func reply(to request: FilterRequest, at now: Double) -> FilterReply {
        guard request.build == build else {
            return .refused("the network filter is build \(build), meerkatd build \(request.build)")
        }
        let (snapshot, openFlows) = state.withLock { state in
            state.lease.request(wantsHosts: request.wantsHosts, at: now)
            state.ledger.collectsHosts = state.lease.isActive(at: now)
            drainOpens(into: &state.ledger)
            return (state.ledger.snapshot(), state.ledger.openFlowCount)
        }
        return .snapshot(FilterSnapshot(instance: instance, build: build, snapshot: snapshot, openFlows: openFlows))
    }

    /// The ledger in one line, for the extension's heartbeat: its tables and
    /// everything it set aside.
    public var summary: String {
        state.withLock { state in
            let snapshot = state.ledger.snapshot()
            let counters = snapshot.counters
            return "ledger: open flows \(state.ledger.openFlowCount) processes \(snapshot.processes.count) "
                + "hosts \(snapshot.hosts.count) untracked \(counters.untracked) unattributed \(counters.unattributed) "
                + "inconsistent \(counters.inconsistent) evicted \(counters.evictedFlows)/\(counters.evictedProcesses)/\(counters.evictedHosts) "
                + "opens dropped \(openingsDropped)"
        }
    }

    private var elapsed: Double {
        let duration = clock.now - started
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
