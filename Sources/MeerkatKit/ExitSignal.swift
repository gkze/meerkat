import Synchronization

/// A one-shot signal to an async waiter, independent of task cancellation:
/// a process's termination handler fires it, or a task waits for something
/// to be registered first.
public final class ExitSignal: Sendable {
    private let state = Mutex<(fired: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    public init() {}

    public func fire() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.fired = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    public func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let fired = state.withLock { state -> Bool in
                if !state.fired { state.waiter = continuation }
                return state.fired
            }
            if fired { continuation.resume() }
        }
    }
}
