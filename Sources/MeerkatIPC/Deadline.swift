import Foundation
import MeerkatKit

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

    /// The daemon's process id and start time, which change when launchd
    /// replaces it. Every ping is a liveness check, so there is no unbounded
    /// one: a daemon that takes it and never answers is not alive.
    public func daemonIdentity(within limit: Duration = DaemonClient.pingLimit) async throws -> DaemonIdentity {
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
