import Foundation
import Synchronization

/// A request to the daemon that wasn't answered in time
/// (`DaemonConnection.send(_:within:)`).
public struct DaemonDidNotAnswer: Error, CustomStringConvertible {
    public let limit: Duration

    public var description: String { "meerkatd did not answer within \(limit.formatted())" }
}

extension DaemonConnection {
    /// `request`'s reply, or `DaemonDidNotAnswer` once `limit` passes.
    ///
    /// For a client that must not hang on a daemon that accepted the request
    /// and never replies, which XPC doesn't time out: a health check, a
    /// restart waiting for the new daemon, a bridge watching for one. The
    /// request is left to finish unheard; the session that carries it
    /// stays, since its subscriptions are still good.
    public func send(_ request: DaemonRequest, within limit: Duration) async throws -> DaemonReply {
        do {
            return try await withDeadline(limit) { try await self.send(request) }
        } catch is DeadlineExceeded {
            throw DaemonDidNotAnswer(limit: limit)
        }
    }

    /// `daemonIdentity()`, bounded like `send(_:within:)`.
    public func daemonIdentity(within limit: Duration) async throws -> DaemonIdentity {
        try DaemonIdentity(pong: try await send(.ping, within: limit))
    }
}

extension DaemonIdentity {
    /// The identity in the answer to a ping.
    init(pong reply: DaemonReply) throws {
        guard case .pong(let pid, let startedAt) = reply else {
            throw DaemonClient.ClientError.unexpectedReply("ping")
        }
        self.init(pid: pid, startedAt: startedAt)
    }
}

extension DaemonClient {
    /// How long a ping may take before the daemon counts as not answering:
    /// far longer than a live daemon takes, short enough for a person
    /// waiting on a health check or a restart.
    public static let pingLimit: Duration = .seconds(2)
}

/// An operation didn't finish within its deadline (`withDeadline`).
public struct DeadlineExceeded: Error {
    public init() {}
}

/// `operation`'s result, or `DeadlineExceeded` once `limit` passes, or
/// `CancellationError` as soon as the caller is cancelled.
///
/// `limit` counts time the Mac is awake (the suspending clock): nothing can
/// answer while it sleeps, and a request in flight as it went to sleep
/// would otherwise time out the moment it woke, before the answer that was
/// on its way, and end the MCP bridge's session with it.
///
/// For calls that may never return and don't honour cancellation: an XPC
/// request to a daemon that doesn't reply (`send(_:within:)`), or a JSON-RPC
/// request to a live but silent language server (the app's tsrs client). A task group would wait for such a call, so
/// it runs unstructured instead: past the deadline it is cancelled and left
/// to finish, unheard. Whoever owns the other end (a process to terminate,
/// a session to drop) ends it.
public func withDeadline<T: Sendable>(
    _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = DeadlineOutcome<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            outcome.begin(continuation)
            let work = Task {
                do {
                    outcome.finish(.success(try await operation()))
                } catch {
                    outcome.finish(.failure(error))
                }
            }
            let timer = Task {
                do { try await Task.sleep(for: limit, clock: .suspending) } catch { return }
                outcome.finish(.failure(DeadlineExceeded()))
            }
            outcome.started([work, timer])
        }
    } onCancel: {
        outcome.finish(.failure(CancellationError()))
    }
}

/// Whichever of the result, the deadline and the caller's cancellation
/// comes first resumes the caller, once, and cancels the others' tasks.
private final class DeadlineOutcome<T: Sendable>: Sendable {
    typealias Waiter = CheckedContinuation<T, any Error>

    private struct State {
        var waiter: Waiter?
        /// The outcome when it came before the waiter: a caller cancelled
        /// before it began.
        var early: Result<T, any Error>?
        var tasks: [Task<Void, Never>] = []
        var done = false
    }

    private let state = Mutex(State())

    func begin(_ waiter: Waiter) {
        let early = state.withLock { state in
            if state.early == nil { state.waiter = waiter }
            return state.early
        }
        if let early { waiter.resume(with: early) }
    }

    func started(_ tasks: [Task<Void, Never>]) {
        let done = state.withLock { state in
            if !state.done { state.tasks = tasks }
            return state.done
        }
        guard done else { return }
        for task in tasks { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let (waiter, tasks) = state.withLock { state -> (Waiter?, [Task<Void, Never>]) in
            guard !state.done else { return (nil, []) }
            state.done = true
            if state.waiter == nil { state.early = result }
            defer { (state.waiter, state.tasks) = (nil, []) }
            return (state.waiter, state.tasks)
        }
        for task in tasks { task.cancel() }
        waiter?.resume(with: result)
    }
}
