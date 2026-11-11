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
            throws: NetworkFilterUnavailable("meerkatd is not signed by a team, so it cannot reach the network filter")
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
            #expect(throws: NetworkFilterUnavailable.off) { try client.totals(wantsHosts: false) }
        }
        #expect(first < .seconds(3))
        let second = clock.measure {
            #expect(throws: NetworkFilterUnavailable.off) { try client.totals(wantsHosts: true) }
        }
        #expect(second < .milliseconds(50))
    }
}
