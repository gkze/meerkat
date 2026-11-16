import Foundation
import MeerkatKit
import Testing

@testable import MeerkatDaemon

/// The daemon's client for the network filter, where no filter runs: the
/// signed exchange itself is covered by the end-to-end check
/// (docs/design/network-filter.md, "Integrity tests").
struct NetworkFilterClientTests {
    @Test func anUnsignedDaemonSaysWhyItCannotReachTheFilter() {
        let client = NetworkFilterClient(team: nil, build: "b")
        #expect(
            throws: NetworkFilterUnavailable(
                .unreachable, "meerkatd is not signed by a team, so it cannot reach the network filter")
        ) {
            try client.totals(wantsHosts: false)
        }
    }

    /// An absent extension costs one bounded wait, then nothing until the
    /// backoff ends.
    @Test func anAbsentFilterFailsWithinTheTimeoutThenBacksOff() {
        let client = NetworkFilterClient(
            team: "NOSUCHTEAM", build: "b", timeout: .milliseconds(500), backoff: .seconds(30))
        let clock = ContinuousClock()
        let first = clock.measure {
            #expect(throws: NetworkFilterUnavailable.notAnswering) { try client.totals(wantsHosts: false) }
        }
        #expect(first < .seconds(3))
        let second = clock.measure {
            #expect(throws: NetworkFilterUnavailable.notAnswering) { try client.totals(wantsHosts: true) }
        }
        #expect(second < .milliseconds(50))
    }

    /// `meerkat status` and the app's health page ask often: a recent read,
    /// whoever made it, answers without another; an old one costs one read.
    @Test func reachabilityReusesARecentReadAndReadsOnceWhenItIsOld() throws {
        let client = NetworkFilterClient(
            team: "NOSUCHTEAM", build: "b", timeout: .milliseconds(500), backoff: .seconds(30))
        #expect(throws: NetworkFilterUnavailable.notAnswering) { try client.totals(wantsHosts: true) }
        let read = try #require(client.lastReadAt)
        #expect(failure(client.reachability(within: .seconds(60))) == .notAnswering)
        #expect(client.lastReadAt == read)
        #expect(failure(client.reachability(within: .zero)) == .notAnswering)
        #expect(try #require(client.lastReadAt) > read)
    }

    @Test func anUnsignedDaemonIsUnreachableWithoutAsking() {
        let client = NetworkFilterClient(team: nil, build: "b")
        #expect(failure(client.reachability(within: .seconds(10)))?.cause == .unreachable)
    }

    /// `Result<Void, _>` is not Equatable: Void is not.
    func failure(_ reachability: Result<Void, NetworkFilterUnavailable>) -> NetworkFilterUnavailable? {
        guard case .failure(let unavailable) = reachability else { return nil }
        return unavailable
    }
}
