import Synchronization

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
/// on its way.
///
/// For calls that may never return and don't honour cancellation, such as
/// a request to another process that is alive but silent. A task group
/// would wait for such a call, so it runs unstructured instead: past the deadline it is cancelled and left
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
