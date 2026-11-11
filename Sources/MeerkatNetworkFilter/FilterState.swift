import Foundation
import Synchronization

/// What the provider and the XPC side share: the ledger and the host lease,
/// behind one lock held only to record a report or take a snapshot. The
/// verdict path never takes it (the provider's `handleNewFlow`).
public final class FilterState: Sendable {
    /// Changes on every start, so a reader never subtracts across two
    /// lifetimes of the extension.
    public let instance = UUID()
    public let build: String
    private let state: Mutex<(ledger: FlowLedger, lease: HostLease)>
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant

    public init(build: String, limits: FlowLedger.Limits = .standard) {
        self.build = build
        state = Mutex((FlowLedger(limits: limits), HostLease()))
        started = clock.now
    }

    public func record(_ report: FlowReport) { record(report, at: elapsed) }

    /// The reply to one request. Refuses another build's daemon rather than
    /// guessing at its meaning of the totals.
    public func reply(to request: FilterRequest) -> FilterReply { reply(to: request, at: elapsed) }

    /// `record` at monotonic time `now` (seconds since start).
    func record(_ report: FlowReport, at now: Double) {
        state.withLock { state in
            state.ledger.collectsHosts = state.lease.isActive(at: now)
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
            return (state.ledger.snapshot(), state.ledger.openFlowCount)
        }
        return .snapshot(FilterSnapshot(instance: instance, build: build, snapshot: snapshot, openFlows: openFlows))
    }

    private var elapsed: Double {
        let duration = clock.now - started
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
