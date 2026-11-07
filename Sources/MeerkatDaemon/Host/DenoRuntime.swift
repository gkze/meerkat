import Foundation
import MeerkatRuntimeBindings
import Synchronization

/// The embedded Deno runtime (Sources/meerkat-runtime, linked as a static library) as a
/// handler host's transport. Each instance is one host; a reload makes a new
/// one.
public final class DenoRuntime: HandlerHostTransport {
    /// The runtime, with the declarations of its globals that rules are
    /// compiled against.
    public static let handlerRuntime = HandlerRuntime(
        declarations: runtimeDeclarations(), makeHost: { DenoRuntime() })

    /// The running host; nil before `start`. Releasing it (with this
    /// transport) stops the host.
    private let host = Mutex<RuntimeHost?>(nil)

    public init() {}

    public func start(
        receive: @escaping @Sendable (HostToDaemon) -> Void, terminated: @escaping @Sendable (String) -> Void
    ) throws {
        let started = RuntimeHost.start(delegate: Delegate(receive: receive, terminated: terminated))
        host.withLock { $0 = started }
    }

    // The runtime's calls never block: they queue for its control thread.

    public func send(_ message: DaemonToHost) {
        host.withLock { $0 }?.send(message: message)
    }

    public func stop(reason: String) {
        host.withLock { $0 }?.stop(reason: reason)
    }

    /// Called from the runtime's delivery thread, one call at a time. The
    /// runtime holds it until `terminated`, after every message.
    private final class Delegate: HostDelegate {
        let receive: @Sendable (HostToDaemon) -> Void
        let finished: @Sendable (String) -> Void

        init(receive: @escaping @Sendable (HostToDaemon) -> Void, terminated: @escaping @Sendable (String) -> Void) {
            self.receive = receive
            finished = terminated
        }

        func receive(message: HostToDaemon) {
            receive(message)
        }

        func terminated(reason: String) {
            finished(reason)
        }
    }
}

extension DenoRuntime {
    /// `body`, run while no rule's code renames anything or is between a
    /// file call's check and its end (meerkat-runtime, protected.rs,
    /// `NAMESPACE`): a path `body` checks still leads where it did when it
    /// acts. On a thread of its own, since a rule's call under way holds it
    /// up.
    static func holdingRuleRenames<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                holdRuleRenames(work: Work { continuation.resume(with: Result(catching: body)) })
            }
        }
    }

    private final class Work: PathWork {
        let body: @Sendable () -> Void

        init(_ body: @escaping @Sendable () -> Void) { self.body = body }

        func run() { body() }
    }
}
