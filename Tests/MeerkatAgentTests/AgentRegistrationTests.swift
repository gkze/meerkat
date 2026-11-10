import Foundation
import MeerkatAgent
import MeerkatIPC
import MeerkatKit
import Synchronization
import Testing

/// Restart and Reinstall must work against a daemon that doesn't answer,
/// which is when they're most useful.
struct AgentRegistrationTests {
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
    /// launch constraint case: registered, nothing new started, which is a
    /// failure the CLI and the app report in the same words.
    @Test func theOldDaemonAfterRegisteringIsSilent() async throws {
        let failure = await #expect(throws: AgentRegistration.RegistrationError.self) {
            try await AgentRegistration.installAndAwait(
                client: AnsweringDaemon(Self.old), within: .milliseconds(1_200)
            ) { .enabled }
        }
        guard let failure, case .silent(let limit) = failure else {
            Issue.record("not silent: \(String(describing: failure))")
            return
        }
        #expect(limit == .milliseconds(1_200))
        #expect("\(failure)".contains("install the agent again"))
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

    // MARK: Restarting

    /// launchd took the restart, but the daemon answering is still the one
    /// from before: a failure, which the app shows, not a success.
    @Test func aRestartThatOnlyTheOldDaemonAnswersFails() async {
        let failure = await #expect(throws: AgentRegistration.RegistrationError.self) {
            try await AgentRegistration.restartAndAwait(
                client: AnsweringDaemon(Self.old), within: .milliseconds(1_200)
            ) {}
        }
        guard let failure, case .restartUnanswered(let limit) = failure else {
            Issue.record("not unanswered: \(String(describing: failure))")
            return
        }
        #expect(limit == .milliseconds(1_200))
    }

    @Test func aRestartEndsWithTheNewDaemon() async throws {
        let daemon = AnsweringDaemon(Self.old)
        let found = try await AgentRegistration.restartAndAwait(client: daemon, within: .seconds(10)) {
            daemon.answer(as: Self.new)
        }
        #expect(found == Self.new)
    }

    static let old = DaemonIdentity(pid: 100, startedAt: 1_792_900_000_000)
    static let new = DaemonIdentity(pid: 200, startedAt: 1_792_900_060_000)
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
