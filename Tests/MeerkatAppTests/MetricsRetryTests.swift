import Foundation
import MeerkatIPC
import MeerkatKit
import Synchronization
import Testing

@testable import MeerkatApp

/// The Overview's feeds retry while a page shows them, and not after, and
/// carry over from one page to the next.
@MainActor
struct MetricsRetryTests {
    /// Changing pages removes one viewer and adds another in the same
    /// update, in either order: the feed carries over rather than all its
    /// subscriptions being remade.
    @Test func aPageChangeKeepsTheFeed() async throws {
        let daemon = OpenDaemon()
        let model = MetricsModel(client: daemon, isVisible: { true })
        model.start()
        try await waitUntil { daemon.subscriptions > 0 }
        try await Task.sleep(for: .milliseconds(200))
        let feeds = daemon.subscriptions

        model.stop()
        model.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(daemon.subscriptions == feeds)

        // Leaving every page stops it, so coming back subscribes again.
        model.stop()
        try await Task.sleep(for: .milliseconds(100))
        model.start()
        try await waitUntil { daemon.subscriptions == 2 * feeds }
    }

    @Test func aPendingRetryDoesntOutliveTheLastViewer() async throws {
        let daemon = RefusingDaemon()
        let model = MetricsModel(client: daemon, isVisible: { true }, retry: FeedRetry(first: .milliseconds(100)))
        model.start()
        try await waitUntil { model.connection.isUnavailable }
        // While shown, it tries again.
        let first = daemon.subscriptions
        try await waitUntil { daemon.subscriptions > first }
        try await waitUntil { model.connection.isUnavailable }

        model.stop()
        let last = daemon.subscriptions
        try await Task.sleep(for: .milliseconds(500))
        #expect(daemon.subscriptions == last)
    }
}

/// Accepts every subscription and holds it open, counting them.
private final class OpenDaemon: DaemonConnection {
    private let state = Mutex([AsyncThrowingStream<EventEnvelope, any Error>.Continuation]())
    var subscriptions: Int { state.withLock { $0.count } }

    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        throw DaemonClient.ClientError.unexpectedReply("\(request)")
    }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        let (stream, continuation) = AsyncThrowingStream<EventEnvelope, any Error>.makeStream()
        state.withLock { $0.append(continuation) }
        return stream
    }
}

/// Unreachable, counting the subscriptions tried.
private final class RefusingDaemon: DaemonConnection {
    private let count = Mutex(0)
    var subscriptions: Int { count.withLock { $0 } }

    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        throw DaemonClient.ClientError.unreachable("down")
    }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        count.withLock { $0 += 1 }
        throw DaemonClient.ClientError.unreachable("down")
    }
}

/// How every subscription the app keeps is followed (`follow`), seen
/// through the rules' `meerkat.rule`: when it waits, what starts the wait
/// over, and when the report is read again. Time is the test's
/// (`ManualClock`): a wait lasts until the test releases it, so the
/// outcomes do not depend on how fast the machine runs.
@MainActor
struct FollowTests {
    /// A source the daemon accepts and ends at once (its first tick threw)
    /// is a failure like a refusal: the wait doubles rather than asking
    /// every `first`.
    @Test func anImmediateEndKeepsDoubling() async throws {
        let daemon = FollowDaemon(.endAtOnce)
        let clock = ManualClock()
        let model = RulesModel(client: daemon, retry: clock.retry(first: .seconds(5), grace: .seconds(2)))
        let following = Task { await model.followStateChanges() }
        defer { following.cancel() }
        for count in 1...4 {
            try await waitUntil { clock.waits.count == count }
            clock.release()
        }
        // The fifth may already be waiting.
        #expect(Array(clock.waits.prefix(4)) == [.seconds(5), .seconds(10), .seconds(20), .seconds(40)])
    }

    /// One that stayed up past the grace was not a failure: after it ends,
    /// the next try comes after `first`, however long the wait had grown.
    @Test func aSubscriptionThatStayedUpStartsTheWaitOver() async throws {
        let daemon = FollowDaemon(.endAtOnce)
        let clock = ManualClock()
        let model = RulesModel(client: daemon, retry: clock.retry(first: .seconds(5), grace: .seconds(2)))
        let following = Task { await model.followStateChanges() }
        defer { following.cancel() }
        for count in 1...2 {
            try await waitUntil { clock.waits.count == count }
            clock.release()
        }
        try await waitUntil { clock.waits.count == 3 }
        daemon.answer = .hold
        clock.release()
        // Its refresh comes after the subscription noted when it started.
        try await waitUntil { daemon.reportsAskedWhileHolding == 1 }
        clock.advance(by: .seconds(3))
        daemon.endHeld()
        try await waitUntil { clock.waits.count == 4 }
        #expect(clock.waits == [.seconds(5), .seconds(10), .seconds(20), .seconds(5)])
    }

    /// Each subscription reads the report again, for the changes made
    /// while it was not following; so does each failure, which is what
    /// shows why.
    @Test func everyAttemptRefreshes() async throws {
        let daemon = FollowDaemon(.unreachable)
        let clock = ManualClock()
        let model = RulesModel(client: daemon, retry: clock.retry(first: .seconds(5)))
        let following = Task { await model.followStateChanges() }
        defer { following.cancel() }
        try await waitUntil { clock.waits.count == 1 }
        #expect(daemon.reportsAsked == 1)
        daemon.answer = .hold
        clock.release()
        try await waitUntil { daemon.reportsAskedWhileHolding == 1 }
    }

    /// The daemon coming back wakes a follower from its wait at once,
    /// and makes one that is subscribed read the report again: the client
    /// recreates a subscription on a new daemon without ending it.
    @Test func theDaemonComingBackWakesAndRefreshes() async throws {
        let daemon = FollowDaemon(.unreachable)
        let clock = ManualClock()
        let back = DaemonReturn()
        let model = RulesModel(client: daemon, retry: clock.retry(first: .seconds(30)), back: back)
        let following = Task { await model.followStateChanges() }
        defer { following.cancel() }
        try await waitUntil { clock.waits.count == 1 }
        daemon.answer = .hold
        back.fire()
        try await waitUntil { daemon.reportsAskedWhileHolding == 1 }
        #expect(daemon.subscribes == 2)

        back.fire()
        try await waitUntil { daemon.reportsAskedWhileHolding == 2 }
        #expect(daemon.subscribes == 2)
    }

    /// A different build's subscription fails like any other, and the
    /// refresh after it shows why, rather than the failure being dropped.
    @Test func aDifferentBuildShows() async throws {
        let daemon = FollowDaemon(.differentBuild)
        let model = RulesModel(client: daemon, retry: ManualClock().retry(first: .seconds(30)))
        let following = Task { await model.followStateChanges() }
        defer { following.cancel() }
        try await waitUntil { model.loadState != .loading }
        #expect(model.loadState.fault?.isDifferentBuild == true)
    }
}

/// Time the test moves: `now` changes only by `advance`, and each sleep
/// lasts until `release`, or until its task is cancelled.
private final class ManualClock: Sendable {
    private struct State {
        var now = ContinuousClock.now
        var waits: [Duration] = []
        var next: UInt64 = 0
        var pending: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    /// Every sleep asked for, in order, released or not.
    var waits: [Duration] { state.withLock(\.waits) }

    func retry(first: Duration, grace: Duration = .seconds(2)) -> FeedRetry {
        FeedRetry(
            first: first, grace: grace,
            clock: FeedClock(now: { self.state.withLock(\.now) }, sleep: { try await self.sleep($0) }))
    }

    func advance(by duration: Duration) { state.withLock { $0.now += duration } }

    /// Ends every sleep now pending.
    func release() {
        let pending = state.withLock { state in
            defer { state.pending = [:] }
            return Array(state.pending.values)
        }
        for sleep in pending { sleep.resume() }
    }

    private func sleep(_ duration: Duration) async throws {
        let id = state.withLock { state in
            defer { state.next += 1 }
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Listed and counted in one step, so a test that saw the
                // wait can release it.
                let cancelled = state.withLock { state -> Bool in
                    guard !Task.isCancelled else { return true }
                    state.waits.append(duration)
                    state.pending[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}

extension LoadState {
    fileprivate var fault: DaemonFault? {
        if case .failed(let fault) = self { fault } else { nil }
    }
}

/// Answers each subscription as `answer` says and holds the ones it keeps;
/// answers the rules report as `answer` allows. Counts both.
private final class FollowDaemon: DaemonConnection {
    enum Answer { case unreachable, differentBuild, endAtOnce, hold }

    private struct State {
        var answer: Answer
        var subscribes = 0
        var reportsAsked = 0
        var reportsAskedWhileHolding = 0
        var held: [AsyncThrowingStream<EventEnvelope, any Error>.Continuation] = []
    }

    private let state: Mutex<State>

    init(_ answer: Answer) { state = Mutex(State(answer: answer)) }

    var answer: Answer {
        get { state.withLock(\.answer) }
        set { state.withLock { $0.answer = newValue } }
    }
    var subscribes: Int { state.withLock(\.subscribes) }
    var reportsAsked: Int { state.withLock(\.reportsAsked) }
    /// Reports asked for while a subscription is held: the refreshes a
    /// subscription makes, not those its failures do.
    var reportsAskedWhileHolding: Int { state.withLock(\.reportsAskedWhileHolding) }

    /// Ends every held subscription without a word.
    func endHeld() {
        for held in state.withLock({ state in
            defer { state.held = [] }
            return state.held
        }) { held.finish() }
    }

    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        let answer = state.withLock { state in
            state.reportsAsked += 1
            if !state.held.isEmpty { state.reportsAskedWhileHolding += 1 }
            return state.answer
        }
        switch answer {
        case .unreachable: throw DaemonClient.ClientError.unreachable("down")
        case .differentBuild: throw DaemonClient.ClientError.differentBuild("another build")
        case .endAtOnce, .hold:
            return .rules(RulesReport(rulesDirectory: "/rules", rules: [], diagnostics: [], compiledAt: nil))
        }
    }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        let (stream, continuation) = AsyncThrowingStream<EventEnvelope, any Error>.makeStream()
        let answer = state.withLock { state in
            state.subscribes += 1
            if state.answer == .hold { state.held.append(continuation) }
            return state.answer
        }
        switch answer {
        case .unreachable: throw DaemonClient.ClientError.unreachable("down")
        case .differentBuild: throw DaemonClient.ClientError.differentBuild("another build")
        case .endAtOnce: continuation.finish()
        case .hold: break
        }
        return stream
    }
}

/// The wait between attempts: doubling while failures continue, never past
/// a minute, and back to the first on `reset`.
struct FeedRetryTests {
    @Test func backsOffToAMinuteAndStartsOver() {
        var retry = FeedRetry(first: .seconds(5))
        let waits = (0..<6).map { _ in retry.next() }
        #expect(waits == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60)])
        retry.reset()
        #expect(retry.next() == .seconds(5))
    }
}
