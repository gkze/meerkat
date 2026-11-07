import Foundation
import MeerkatAgent
import MeerkatIPC
import MeerkatKit
import Synchronization
import Testing

@testable import MeerkatApp

/// Waits on things that may never answer: a daemon that takes a request and
/// says nothing, and a feed that keeps failing.
struct DeadlineTests {
    @Test func aResultInTimeIsTheResult() async throws {
        #expect(try await withDeadline(.seconds(5)) { 7 } == 7)
    }

    @Test func anErrorInTimeIsTheError() async {
        await #expect(throws: DaemonClient.ClientError.self) {
            try await withDeadline(.seconds(5)) { () async throws -> Int in
                throw DaemonClient.ClientError.unreachable("down")
            }
        }
    }

    /// The case it is for: an operation that ignores cancellation and never
    /// returns still lets the caller go at the deadline.
    @Test func aCallThatNeverReturnsEndsAtTheDeadline() async {
        let started = ContinuousClock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(100)) { await neverReturns() }
        }
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func theCallersCancellationEndsTheWait() async {
        let waiting = Task { try await withDeadline(.seconds(3600)) { await neverReturns() } }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func aCallerCancelledBeforeItWaitsDoesntWait() async {
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withDeadline(.seconds(3600)) { await neverReturns() }
        }
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}

/// Restart and Reinstall must work against a daemon that doesn't answer,
/// which is when they're most useful.
struct AgentControlTests {
    /// The wait every action that registers or restarts shares
    /// (`AgentRegistration.newDaemon`) ends at its limit, though no ping is
    /// ever answered.
    @Test func aSilentDaemonIsNoNewDaemon() async throws {
        let started = ContinuousClock.now
        let found = try await AgentRegistration.newDaemon(
            replacing: nil, client: SilentDaemon(), within: .milliseconds(300))
        #expect(found == nil)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    /// The daemon from before, still answering after the registration, is
    /// not the one that started.
    @Test func theDaemonFromBeforeIsNoNewDaemon() async throws {
        let found = try await AgentRegistration.newDaemon(
            replacing: Self.old, client: AnsweringDaemon(Self.old), within: .milliseconds(1_200))
        #expect(found == nil)
    }

    @Test func anotherDaemonEndsTheWait() async throws {
        let daemon = AnsweringDaemon(Self.old)
        let replaced = Task {
            try await Task.sleep(for: .milliseconds(200))
            daemon.answer(as: Self.new)
        }
        let found = try await AgentRegistration.newDaemon(replacing: Self.old, client: daemon, within: .seconds(10))
        try await replaced.value
        #expect(found == Self.new)
    }

    /// A cancelled caller stops waiting at once, and stops pinging.
    @Test func aCancelledWaitEnds() async throws {
        let daemon = AnsweringDaemon(Self.old)
        let waiting = Task {
            try await AgentRegistration.newDaemon(replacing: Self.old, client: daemon, within: .seconds(3600))
        }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        let pings = daemon.pings
        try await Task.sleep(for: .milliseconds(300))
        #expect(daemon.pings == pings)
        #expect(pings < 5)
    }

    // MARK: Registering

    /// Success is a daemon other than the one that answered before the
    /// registration, so `before` must be read before registering: the
    /// registration replaces the daemon here.
    @Test func aNewDaemonAfterRegisteringIsAnswering() async throws {
        let daemon = AnsweringDaemon(Self.old)
        let started = try await AgentRegistration.installAndAwait(client: daemon, within: .seconds(10)) {
            daemon.answer(as: Self.new)
            return .enabled
        }
        #expect(started == .answering(Self.new))
    }

    /// The old daemon still answering after `unregister`/`register` is the
    /// launch constraint case: registered, nothing new started.
    @Test func theOldDaemonAfterRegisteringIsSilent() async throws {
        let started = try await AgentRegistration.installAndAwait(
            client: AnsweringDaemon(Self.old), within: .milliseconds(1_200)
        ) { .enabled }
        #expect(started == .silent)
    }

    @Test func aRegistrationAwaitingApprovalWaitsForNothing() async throws {
        let daemon = AnsweringDaemon(Self.old)
        let started = try await AgentRegistration.installAndAwait(client: daemon, within: .seconds(3600)) {
            .requiresApproval
        }
        #expect(started == .requiresApproval)
        #expect(daemon.pings == 1)
    }

    @Test(arguments: [AgentRegistration.Status.notRegistered, .notInBundle])
    func aRegistrationThatDidntTakeFails(_ status: AgentRegistration.Status) async {
        await #expect(throws: AgentRegistration.RegistrationError.self) {
            try await AgentRegistration.installAndAwait(client: AnsweringDaemon(Self.old)) { status }
        }
    }

    @Test func aRegistrationErrorIsTheError() async {
        await #expect(throws: AgentRegistration.RegistrationError.self) {
            try await AgentRegistration.installAndAwait(client: AnsweringDaemon(Self.old)) {
                throw AgentRegistration.RegistrationError.failed("refused")
            }
        }
    }

    static let old = DaemonIdentity(pid: 100, startedAt: 1_792_900_000_000)
    static let new = DaemonIdentity(pid: 200, startedAt: 1_792_900_060_000)
}

/// `events`, the typed form of a subscription.
@MainActor
struct TypedEventsTests {
    private static func envelope(_ payload: JSONValue) -> EventEnvelope {
        EventEnvelope(
            kind: ProcessSampleEvent.descriptor.name, sequence: 1, time: 0, origin: .system, replayed: false,
            payload: payload)
    }

    /// It reads the subscription as it is read, and a consumer that stops
    /// reading ends the subscription.
    @Test func itDecodesAndEndsWithItsConsumer() async throws {
        let daemon = StreamingDaemon(sending: [Self.envelope(.object(["running": .bool(false)]))])
        let parameters = ProcessSampleParameters(pid: 1, startedAt: 1)
        for try await (payload, _) in try await daemon.client.events(ProcessSampleEvent.self, parameters: parameters) {
            #expect(!payload.running && payload.process == nil)
            break
        }
        try await waitUntil { daemon.ended }
    }

    @Test func aPayloadOfAnotherShapeIsADifferentBuild() async throws {
        let daemon = StreamingDaemon(sending: [Self.envelope(.object(["running": .string("yes")]))])
        let parameters = ProcessSampleParameters(pid: 1, startedAt: 1)
        await #expect(throws: DaemonClient.ClientError.self) {
            for try await _ in try await daemon.client.events(ProcessSampleEvent.self, parameters: parameters) {}
        }
    }
}

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
        let model = MetricsModel(client: daemon, isVisible: { true }, retryDelay: .milliseconds(100))
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

extension MetricsModel.Connection {
    fileprivate var isUnavailable: Bool {
        if case .unavailable = self { true } else { false }
    }
}

/// Never returns, and ignores cancellation, like an XPC reply that never
/// comes.
private func neverReturns() async -> Int {
    await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
}

/// Takes requests and never answers them.
private final class SilentDaemon: DaemonConnection {
    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        throw CancellationError()
    }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        AsyncThrowingStream { _ in }
    }
}

/// Answers every ping as one daemon, until told it is another; counts the
/// pings.
private final class AnsweringDaemon: DaemonConnection {
    private let state: Mutex<(identity: DaemonIdentity, pings: Int)>
    var pings: Int { state.withLock { $0.pings } }

    init(_ identity: DaemonIdentity) { state = Mutex((identity, 0)) }

    func answer(as identity: DaemonIdentity) { state.withLock { $0.identity = identity } }

    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        guard case .ping = request else { throw DaemonClient.ClientError.unexpectedReply("\(request)") }
        let identity = state.withLock { state in
            state.pings += 1
            return state.identity
        }
        return .pong(pid: identity.pid, startedAt: identity.startedAt)
    }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        throw DaemonClient.ClientError.unexpectedReply("subscribe")
    }
}

/// One subscription, sending `envelopes` and then holding it open; says
/// when it ended.
private final class StreamingDaemon: Sendable {
    private let envelopes: [EventEnvelope]
    private let state = Mutex(false)
    var ended: Bool { state.withLock { $0 } }
    var client: Client { Client(daemon: self) }

    init(sending envelopes: [EventEnvelope]) { self.envelopes = envelopes }

    struct Client: DaemonConnection {
        let daemon: StreamingDaemon

        func send(_ request: DaemonRequest) async throws -> DaemonReply {
            throw DaemonClient.ClientError.unexpectedReply("\(request)")
        }

        func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<
            EventEnvelope, any Error
        > {
            let (stream, continuation) = AsyncThrowingStream<EventEnvelope, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(DaemonClient.subscriptionBuffer))
            continuation.onTermination = { [daemon] _ in daemon.state.withLock { $0 = true } }
            for envelope in daemon.envelopes { continuation.yield(envelope) }
            return stream
        }
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
