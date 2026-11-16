import Foundation
import MeerkatNetworkFilter

/// Reads the network filter's totals (docs/design/network-filter.md). The
/// daemon supplies the client that asks the system extension; anything else
/// (the CLI, tests) has `NoNetworkFilter`.
public protocol NetworkFilterReading: Sendable {
    /// The filter's totals now, validated. `wantsHosts` keeps its
    /// per-endpoint table alive for `network.flows`.
    func totals(wantsHosts: Bool) throws(NetworkFilterUnavailable) -> FilterSnapshot

    /// Whether the filter answers: the outcome of a read within `maxAge`
    /// when there was one, so asking costs nothing while sources read it,
    /// or else of one read now.
    func reachability(within maxAge: Duration) -> Result<Void, NetworkFilterUnavailable>
}

extension NetworkFilterReading {
    /// For readers that keep no record of their reads: one read now.
    public func reachability(within _: Duration) -> Result<Void, NetworkFilterUnavailable> {
        Result { () throws(NetworkFilterUnavailable) in _ = try totals(wantsHosts: false) }
    }
}

/// Why there are no totals: the cause, for the app to act on, and the words
/// for a rule's error or `meerkat status`.
public struct NetworkFilterUnavailable: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Cause: String, Sendable, Codable, Equatable {
        /// Nothing answered: the filter is off, not running, or running
        /// without its listener, which a filter left by an in-place upgrade
        /// can be. Only the app can tell these apart, from the content
        /// filter's configuration.
        case notAnswering
        /// It answered without totals this daemon can use: another build's,
        /// or out of range.
        case refused
        /// This process cannot ask: an unsigned daemon, or not the daemon.
        case unreachable
    }

    public let cause: Cause
    public let reason: String

    public init(_ cause: Cause, _ reason: String) {
        self.cause = cause
        self.reason = reason
    }

    public var description: String { reason }

    /// No answer. meerkatd cannot tell a filter that is off from one that is
    /// on and not listening, so the remedy names both.
    public static let notAnswering = NetworkFilterUnavailable(
        .notAnswering,
        "the network filter is off or not answering; turn it on in Meerkat › Settings › General › Network, "
            + "or, if it is on, turn it off and on again there")
}

public struct NoNetworkFilter: NetworkFilterReading {
    public init() {}

    public func totals(wantsHosts _: Bool) throws(NetworkFilterUnavailable) -> FilterSnapshot {
        throw NetworkFilterUnavailable(.unreachable, "this process has no network filter; meerkatd reads it")
    }
}
