import Foundation
import MeerkatNetworkFilter

/// Reads the network filter's totals (docs/design/network-filter.md). The
/// daemon supplies the client that asks the system extension; anything else
/// (the CLI, tests) has `NoNetworkFilter`.
public protocol NetworkFilterReading: Sendable {
    /// The filter's totals now, validated. `wantsHosts` keeps its
    /// per-endpoint table alive for `network.flows`.
    func totals(wantsHosts: Bool) throws(NetworkFilterUnavailable) -> FilterSnapshot
}

/// Why there are no totals, in words for a rule's error or `meerkat status`.
public struct NetworkFilterUnavailable: Error, Equatable, CustomStringConvertible, Sendable {
    public let reason: String

    public init(_ reason: String) { self.reason = reason }

    public var description: String { reason }

    /// The filter is not turned on, or not running.
    public static let off = NetworkFilterUnavailable(
        "the network filter is off; turn it on in Meerkat › Settings › Network")
}

public struct NoNetworkFilter: NetworkFilterReading {
    public init() {}

    public func totals(wantsHosts _: Bool) throws(NetworkFilterUnavailable) -> FilterSnapshot {
        throw NetworkFilterUnavailable("this process has no network filter; meerkatd reads it")
    }
}
