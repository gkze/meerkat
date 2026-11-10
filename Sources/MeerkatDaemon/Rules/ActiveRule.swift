import Foundation
import MeerkatIPC
import MeerkatKit
import Synchronization

/// A loaded rule's running state. Owned by `RuleEngine` and only touched on
/// its actor; the dispatch task it starts holds nothing but Sendable values.
final class ActiveRule {
    let definition: RuleDefinition
    /// Identifies this instance across reloads that keep the same rule id.
    let token = UUID()
    var breaker = CircuitBreaker()
    var stats = Stats()
    /// Set when an event was dropped because the host was being replaced.
    var missedDuringRestart = false
    /// Set when the rule was failed because `meerkat.json`'s file scope is
    /// outside its `fs.read` grant, as it subscribed or later
    /// (`RuleEngine.subscribe`); it resumes once the grant covers the scope
    /// again (`RuleEngine.recheckFileScope`).
    var outOfScope = false
    /// Serializes this rule's invocations.
    let gate = AsyncGate()
    /// Increases with every `run()`, so a dispatcher that ends can tell
    /// whether it is still the current one.
    private(set) var runID = 0

    private(set) var state: RuleSummary.State = .loaded
    private(set) var reason: String?
    private var subscription: EventSubscription?
    private var task: Task<Void, Never>?

    struct Stats {
        var invocations = 0
        var failures = 0
        var lastInvokedAt: Double?
        var lastError: String?
        var droppedWhileRestarting = 0
    }

    init(definition: RuleDefinition) {
        self.definition = definition
    }

    var isStopped: Bool { task == nil || state != .loaded }
    var isFailed: Bool { state == .failed }
    var isDisabled: Bool { state == .disabled }

    /// Starts dispatching. `view` is what the rule may see of each event
    /// (`ObservationScope.view`); `invoke` runs the handler and returns false
    /// when dispatch must stop.
    func run(
        subscription: EventSubscription,
        view: EventView?,
        invoke: @escaping @Sendable (EventEnvelope) async -> Bool,
        warn: @escaping @Sendable (String) async -> Void,
        ended: @escaping @Sendable (_ run: Int) async -> Void
    ) {
        self.subscription = subscription
        state = .loaded
        reason = nil
        runID += 1
        let run = runID
        task = Task.detached(priority: .utility) { [definition] in
            await Dispatcher(definition: definition, view: view, invoke: invoke, warn: warn).run(subscription.events)
            await ended(run)
        }
    }

    /// Feeds the hub's latest event back into this rule's own subscription,
    /// as a replay.
    func replayLatest(in hub: EventHub) {
        if let subscription { hub.replayLatest(to: subscription) }
    }

    func stop() {
        // A dispatcher ending after this is expected, not a failure.
        runID += 1
        task?.cancel()
        task = nil
        subscription?.cancel()
        subscription = nil
    }

    func markDisabled(_ reason: String) {
        state = .disabled
        self.reason = reason
    }

    func markFailed(_ reason: String) {
        stop()
        state = .failed
        self.reason = reason
    }

    func reset() {
        breaker = CircuitBreaker()
        state = .loaded
        reason = nil
    }

    var summary: RuleSummary {
        RuleSummary(
            id: definition.id, file: definition.file, event: definition.event, state: state, reason: reason,
            invocations: stats.invocations, failures: stats.failures, lastInvokedAt: stats.lastInvokedAt,
            lastError: stats.lastError)
    }
}

extension RuleDefinition {
    /// Whether an event gets past the rule's origin filter and `match`.
    enum Admission: Equatable {
        case admitted
        /// The daemon's own event, for a rule without `includeOwn`.
        case ownOrigin
        case noMatch
        case regexAborted(pattern: String, reason: String)

        /// Why the event was not admitted, as the rule's log and a dry run
        /// say it; nil when it was.
        var refusal: String? {
            switch self {
            case .admitted: nil
            case .ownOrigin: "the daemon's own event (no includeOwn)"
            case .noMatch: "match: not matched"
            case .regexAborted(let pattern, let reason): "match regex \"\(pattern)\" \(reason)"
            }
        }
    }

    func admission(of envelope: EventEnvelope) -> Admission {
        if envelope.origin == .meerkat, !includeOwn { return .ownOrigin }
        guard let match else { return .admitted }
        switch match.evaluate(envelope.payload) {
        case .match: return .admitted
        case .noMatch: return .noMatch
        case .regexAborted(let pattern, let reason): return .regexAborted(pattern: pattern, reason: reason)
        }
    }
}

/// Filters, rate-limits and serializes one rule's events. Invocations of
/// one rule never overlap, which keeps a handler's view of its own state
/// sequential; events that arrive while a handler runs wait in the source's
/// event ring.
private struct Dispatcher: Sendable {
    let definition: RuleDefinition
    let view: EventView?
    let invoke: @Sendable (EventEnvelope) async -> Bool
    let warn: @Sendable (String) async -> Void

    func run(_ events: EventStream) async {
        if let debounce = definition.rate.debounce {
            await runDebounced(events, quiet: debounce)
            return
        }
        var limiter = RateLimiter(spec: definition.rate)
        for await event in events {
            guard let envelope = viewed(event), await admits(envelope) else { continue }
            guard limiter.admit(now: ContinuousClock.now.secondsSinceStart) else { continue }
            guard await invoke(envelope) else { return }
        }
    }

    /// The event as the rule may see it; nil when it may see none of it.
    private func viewed(_ envelope: EventEnvelope) -> EventEnvelope? {
        guard let view else { return envelope }
        return view(envelope)
    }

    private func admits(_ envelope: EventEnvelope) async -> Bool {
        let admission = definition.admission(of: envelope)
        switch admission {
        case .admitted:
            return true
        case .ownOrigin, .noMatch:
            return false
        case .regexAborted:
            await warn("\(admission.refusal ?? ""); the event was treated as not matching")
            return false
        }
    }

    /// Invokes with the latest admitted event once `quiet` seconds pass
    /// without another.
    private func runDebounced(_ events: EventStream, quiet: Double) async {
        let (ready, readyContinuation) = AsyncStream.makeStream(
            of: EventEnvelope.self, bufferingPolicy: .bufferingNewest(1))
        let collector = Task {
            var pending: Task<Void, Never>?
            for await event in events {
                guard let envelope = viewed(event), await admits(envelope) else { continue }
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(Int(quiet * 1000)))
                    guard !Task.isCancelled else { return }
                    readyContinuation.yield(envelope)
                }
            }
            pending?.cancel()
            readyContinuation.finish()
        }
        var limiter = RateLimiter(spec: RateSpec(maxPerMinute: definition.rate.maxPerMinute))
        for await envelope in ready {
            guard limiter.admit(now: ContinuousClock.now.secondsSinceStart) else { continue }
            guard await invoke(envelope) else { break }
        }
        collector.cancel()
    }
}

extension ContinuousClock.Instant {
    /// Monotonic seconds, for rate windows that must not move with the wall
    /// clock.
    fileprivate var secondsSinceStart: Double {
        (self - ContinuousClock.Instant.zero) / .seconds(1)
    }

    fileprivate static let zero = ContinuousClock.now
}

/// An async mutex: one holder at a time, waiters resumed in order.
final class AsyncGate: Sendable {
    private let state = Mutex<(held: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { state -> Bool in
                guard state.held else {
                    state.held = true
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.held = false
                return nil
            }
            // Ownership passes straight to the next waiter.
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
