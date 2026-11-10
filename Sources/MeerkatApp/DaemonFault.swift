import MeerkatAgent
import MeerkatIPC
import Synchronization

/// A failed request to meerkatd, classified once where it was caught: the
/// client's `DaemonFailure` decides the class, as it does the CLI's exit
/// status, and no model matches errors itself. The text is for display only.
enum DaemonFault: Equatable, CustomStringConvertible {
    /// meerkatd answered: it refused the request or ended the subscription,
    /// in its own words. Only that request failed; the daemon still answers.
    case refused(String)
    /// meerkatd answered, but is a different build from this app, so it
    /// cannot read what the app sends or the other way round. Restarting it
    /// from this build fixes it; asking again does not.
    case differentBuild(String)
    /// The connection: meerkatd did not answer, answered with something
    /// nobody asked for, or lost a subscription across a restart.
    case unreachable(String)

    /// An error that is not the daemon's is the connection's too: whatever
    /// failed, the page has nothing from meerkatd to show.
    init(_ error: any Error) {
        switch DaemonFailure(classifying: error) {
        case .refused?: self = .refused("\(error)")
        case .differentBuild?: self = .differentBuild("\(error)")
        case .unavailable?, nil: self = .unreachable("\(error)")
        }
    }

    var isDifferentBuild: Bool {
        if case .differentBuild = self { true } else { false }
    }

    var description: String {
        switch self {
        case .refused(let text), .differentBuild(let text), .unreachable(let text): text
        }
    }
}

/// What the app was doing when a fault happened, which decides how it is
/// told and what to do next. The one map from a fault to words: every page,
/// banner and panel that shows a fault reads it here.
enum FaultContext: Equatable {
    /// A page's first request, shown in place of the page; with the agent's
    /// registration, which names the likeliest fix for a silent daemon.
    case load(agent: AgentRegistration.Status)
    /// A later poll, over the last good data the page keeps showing.
    case refresh
    case dryRun
    /// The Event Explorer's subscription, whose reason is shown beside the
    /// parameters.
    case subscription
}

extension DaemonFault {
    /// Whether the background agent may be what failed, so that an agent
    /// action (install, restart, reinstall) is worth offering. A refusal is
    /// the daemon answering: no agent action changes it.
    var concernsTheAgent: Bool {
        if case .refused = self { false } else { true }
    }

    func title(_ context: FaultContext) -> String {
        switch (self, context) {
        case (.differentBuild, _): "meerkatd is a different build"
        case (_, .subscription): "Subscription failed"
        case (.refused, .load): "meerkatd refused the request"
        case (.refused, .refresh): "meerkatd refused the last refresh"
        case (.refused, .dryRun): "meerkatd refused the dry run"
        case (.unreachable, .refresh): "Lost contact with meerkatd"
        case (.unreachable, .dryRun): "Couldn't reach meerkatd"
        case (.unreachable, .load(let agent)):
            switch agent {
            case .notRegistered: "meerkatd isn't installed"
            case .requiresApproval: "meerkatd is off in Login Items"
            case .enabled: "meerkatd isn't answering"
            case .notInBundle: "Run Meerkat from Meerkat.app"
            }
        }
    }

    /// What happened and what to do about it. A refusal is the daemon's own
    /// words, except where they are already shown beside the request.
    func explanation(_ context: FaultContext) -> String {
        switch (self, context) {
        case (_, .refresh): description
        case (.differentBuild, _):
            "The running meerkatd was built separately from this app, for example it has not restarted since an "
                + "update. Restart it from this build (`meerkat agent restart`), then \(context.again); if that "
                + "does not help, reinstall it from this copy of Meerkat."
        case (.refused, .subscription): "Check the parameters against the type above, then subscribe again."
        case (.unreachable, .subscription): "meerkatd didn't answer. Subscribe again once it runs."
        case (.refused(let message), _), (.unreachable(let message), .dryRun): message
        case (.unreachable, .load(let agent)):
            switch agent {
            case .notRegistered:
                "The app reads everything from the background agent. Installing it also runs the rules in the "
                    + "rules folder."
            case .requiresApproval: "Turn on Meerkat in System Settings > General > Login Items & Extensions."
            case .enabled:
                "The agent is registered but didn't reply. Reinstalling registers it again from this copy of Meerkat."
            case .notInBundle: "The agent can only be managed from the installed app."
            }
        }
    }
}

extension FaultContext {
    /// Asking again, in the words of what was asked.
    fileprivate var again: String {
        switch self {
        case .load, .refresh: "try again"
        case .dryRun: "run again"
        case .subscription: "subscribe again"
        }
    }
}

/// A page's first request to meerkatd.
enum LoadState: Equatable {
    case loading
    case loaded
    case failed(DaemonFault)
}

/// The wait before following a subscription again once it failed or ended:
/// `first`, doubling with each failure in a row up to `longest`, so a source
/// that keeps failing is asked about once a minute. A subscription that
/// delivered, or stayed up past `grace`, was not a failure, so its end
/// waits `first` again; one the daemon accepts and ends at once (a source
/// whose first tick throws) keeps doubling. Staying up counts as well as
/// delivering because the rare kinds (`meerkat.rule`, `meerkat.dropped`)
/// may send nothing for hours.
struct FeedRetry: Sendable {
    static let longest: Duration = .seconds(60)

    private let first: Duration
    let grace: Duration
    /// What the waits and the grace are measured by; tests drive their own.
    let clock: FeedClock
    private var delay: Duration

    init(first: Duration = .seconds(5), grace: Duration = .seconds(2), clock: FeedClock = .continuous) {
        self.first = first
        self.grace = grace
        self.clock = clock
        delay = first
    }

    mutating func reset() { delay = first }

    /// The wait before the next attempt; each call doubles the one after.
    mutating func next() -> Duration {
        defer { delay = min(delay * 2, Self.longest) }
        return delay
    }

    /// Waits `next()`, or until `back` fires (or has, since it counted
    /// `seen`), which starts the backoff over. False once the task is
    /// cancelled.
    mutating func wait(waking back: DaemonReturn, since seen: UInt64) async -> Bool {
        switch await back.sleep(for: next(), since: seen, on: clock) {
        case .cancelled: return false
        case .elapsed: return true
        case .woken:
            reset()
            return true
        }
    }
}

/// The time a follower waits by: the system's, or a test's.
struct FeedClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    /// Throws once the task is cancelled.
    let sleep: @Sendable (Duration) async throws -> Void

    static let continuous = FeedClock(now: { .now }, sleep: { try await Task.sleep(for: $0) })
}

/// The app-wide word that meerkatd may be back: an agent action succeeded,
/// or the client reached a daemon again after failing to (a new daemon
/// under its subscriptions included). Every follower waiting to retry wakes
/// at once rather than at the end of a backoff that grew while the daemon
/// was away, and every one that is subscribed refreshes what it may have
/// missed meanwhile.
final class DaemonReturn: Sendable {
    enum Wake { case elapsed, woken, cancelled }

    private struct State: Sendable {
        var fired: UInt64 = 0
        var nextWaiter: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    func fire() {
        let waiters = state.withLock { state in
            state.fired += 1
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// How many times it has fired, for `fired(since:)`.
    var count: UInt64 { state.withLock(\.fired) }

    /// Returns once it fires after `count` was `seen`, at once if it
    /// already has, or when the task is cancelled.
    func fired(since seen: UInt64) async {
        let id = state.withLock { state in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    // A cancellation before the waiter is listed found
                    // nothing to resume.
                    guard state.fired == seen, !Task.isCancelled else { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// `delay` on `clock`, or until it fires after `count` was `seen`.
    func sleep(for delay: Duration, since seen: UInt64, on clock: FeedClock) async -> Wake {
        await withTaskGroup(of: Wake.self) { group in
            group.addTask { (try? await clock.sleep(delay)) == nil ? .cancelled : .elapsed }
            group.addTask {
                await self.fired(since: seen)
                return Task.isCancelled ? .cancelled : .woken
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return Task.isCancelled ? .cancelled : first
        }
    }
}

/// How one followed subscription stopped.
enum FeedEnd {
    /// Subscribing failed: the daemon refused, or was not reached.
    case notSubscribed(DaemonFault)
    /// The daemon ended it, with its reason or, nil, without a word.
    case ended(DaemonFault?)
}

/// Follows one subscription for as long as the task runs: subscribes, hands
/// each event to `event`, and when the subscription fails or ends, tells
/// `stopped` and subscribes again after `retry`'s wait (`FeedRetry`). Every
/// successful subscription, and every `back` while subscribed, calls
/// `subscribed`: whatever the owner reads besides the events may have
/// changed while it was not following (the heartbeat recreates a
/// subscription on a new daemon without ending it). `event` and `stopped`
/// return false to stop following for good. The metrics feeds, the process
/// card, the rules and the health page's reports all follow this way; the
/// Event Explorer's one subscription is the user's to start again.
@MainActor
func follow<Element: Sendable>(
    retry: FeedRetry, back: DaemonReturn,
    subscribe: @MainActor () async throws -> AsyncThrowingStream<Element, any Error>,
    subscribed: @escaping @MainActor () async -> Void = {},
    event: @MainActor (Element) -> Bool,
    stopped: @MainActor (FeedEnd) async -> Bool
) async {
    var retry = retry
    while true {
        // From the start of the attempt: the daemon may come back while
        // it fails.
        let seen = back.count
        let end: FeedEnd
        do {
            let events = try await subscribe()
            let started = retry.clock.now()
            var delivered = false
            let refreshing = calling(subscribed, nowAndWhenever: back)
            defer { refreshing.cancel() }
            do {
                for try await element in events {
                    delivered = true
                    guard event(element) else { return }
                }
                end = .ended(nil)
            } catch {
                end = .ended(DaemonFault(error))
            }
            if delivered || retry.clock.now() - started >= retry.grace { retry.reset() }
        } catch {
            end = .notSubscribed(DaemonFault(error))
        }
        // Cancelling the task ends its stream, with or without an error.
        if Task.isCancelled { return }
        guard await stopped(end), await retry.wait(waking: back, since: seen) else { return }
    }
}

/// Calls `action` now, and again each time `back` fires, until the returned
/// task is cancelled.
@MainActor
private func calling(
    _ action: @escaping @MainActor () async -> Void, nowAndWhenever back: DaemonReturn
) -> Task<Void, Never> {
    Task { @MainActor in
        var seen = back.count
        await action()
        while true {
            await back.fired(since: seen)
            if Task.isCancelled { return }
            seen = back.count
            await action()
        }
    }
}
