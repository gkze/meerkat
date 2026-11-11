import Foundation
import MeerkatNetworkFilter
import Testing

@testable import MeerkatKit

/// How the network filter's totals join the process snapshot and become each
/// window's network bytes.
struct NetworkAttributionTests {
    let filter = UUID()

    func counters(_ pid: Int32, started: Int64 = 1_000, cpu: Double = 1) -> ProcessCounters {
        ProcessCounters(
            identity: ProcessIdentity(pid: pid, startMicroseconds: started), uid: 501, name: "p\(pid)", path: nil,
            cpuSeconds: cpu, usage: nil)
    }

    func snapshot(at seconds: Double, _ rows: [ProcessCounters]) -> ProcessSnapshot {
        ProcessSnapshot(
            takenAt: Date(timeIntervalSince1970: seconds),
            counters: Dictionary(uniqueKeysWithValues: rows.map { ($0.identity, $0) }))
    }

    func network(
        _ totals: [(pid: Int32, version: Int32, bytesIn: UInt64, bytesOut: UInt64)], instance: UUID? = nil
    )
        -> FilterSnapshot
    {
        var processes: [ProcessKey: ByteTotals] = [:]
        for entry in totals {
            processes[ProcessKey(pid: entry.pid, version: entry.version, uid: 501)] = ByteTotals(
                bytesIn: entry.bytesIn, bytesOut: entry.bytesOut)
        }
        return FilterSnapshot(
            instance: instance ?? filter, build: "b",
            snapshot: FlowLedger.Snapshot(processes: processes, hosts: [:], counters: LedgerCounters()), openFlows: 0)
    }

    @Test func joinsByPid() {
        let joined = snapshot(at: 0, [counters(10), counters(11)]).attributing(network([(10, 1, 500, 50)]))
        #expect(
            joined.counters.values.first { $0.pid == 10 }?.network
                == NetworkCounters(filter: filter, bytesIn: 500, bytesOut: 50))
        #expect(joined.counters.values.first { $0.pid == 11 }?.network == nil)
    }

    /// A pid the filter knows under two versions was reused: neither total is
    /// joined, since either could be someone else's.
    @Test func aPidSeenUnderTwoVersionsGetsNothing() {
        let joined = snapshot(at: 0, [counters(10)]).attributing(network([(10, 1, 500, 0), (10, 2, 7, 0)]))
        #expect(joined.counters.values.first?.network == nil)
    }

    @Test func aWindowsBytesAreTheDifference() throws {
        let before = snapshot(at: 0, [counters(10, cpu: 1)]).attributing(network([(10, 1, 1_000_000, 0)]))
        let after = snapshot(at: 5, [counters(10, cpu: 1)]).attributing(network([(10, 1, 6_000_000, 500_000)]))
        let row = try #require(ProcessSampler.deltas(previous: before, current: after).first)
        #expect(row.networkInMB == 5)
        #expect(row.networkOutMB == 0.5)
        #expect(row.networkMBps == 1.1)
        #expect(row.cpuPct == 0, "a process moving only network data is still listed")
    }

    @Test func aRestartedFilterIsUnknownForTheWindowNotNegative() throws {
        let before = snapshot(at: 0, [counters(10, cpu: 1)]).attributing(network([(10, 1, 9_000_000, 0)]))
        let after = snapshot(at: 5, [counters(10, cpu: 2)]).attributing(network([(10, 1, 1_000, 0)], instance: UUID()))
        let row = try #require(ProcessSampler.deltas(previous: before, current: after).first)
        #expect(row.networkInMB == nil)
        #expect(row.cpuSeconds == 1, "the rest of the row stands")
    }

    @Test func aTotalThatWentDownIsUnknown() {
        #expect(
            ProcessSampler.networkDelta(
                from: NetworkCounters(filter: filter, bytesIn: 10, bytesOut: 10),
                to: NetworkCounters(filter: filter, bytesIn: 9, bytesOut: 20)) == nil)
    }

    /// A process that took a pid whose previous owner's total the filter still
    /// holds: the stale total never changes, so it adds nothing.
    @Test func aPredecessorsTotalAddsNothingToTheProcessThatTookItsPid() {
        let stale = network([(10, 1, 50_000_000, 0)])
        let before = snapshot(at: 0, [counters(10, started: 2_000, cpu: 1)]).attributing(stale)
        let after = snapshot(at: 5, [counters(10, started: 2_000, cpu: 2)]).attributing(stale)
        #expect(ProcessSampler.deltas(previous: before, current: after).first?.networkInMB == 0)
    }

    @Test func withoutTheFilterTheFieldsAreAbsent() throws {
        let before = snapshot(at: 0, [counters(10, cpu: 1)])
        let after = snapshot(at: 5, [counters(10, cpu: 2)])
        let row = try #require(ProcessSampler.deltas(previous: before, current: after).first)
        #expect(row.networkInMB == nil && row.networkMBps == nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]
        #expect(json?["networkInMB"] == nil, "absent, not null or zero")
    }

    @Test(arguments: [ProcessHotParameters.Metric.networkInMBps, .networkOutMBps, .networkMBps])
    func aNetworkMetricIsRefusedWithoutTheFilter(metric: ProcessHotParameters.Metric) {
        #expect(metric.needsNetworkFilter)
        #expect(throws: EventError.self) {
            try source(metric, in: SourceEnvironment())
        }
    }

    @Test func otherMetricsNeedNoFilter() {
        for metric in ProcessHotParameters.Metric.allCases where !metric.needsNetworkFilter {
            #expect(throws: Never.self) {
                _ = try source(metric, in: SourceEnvironment())
            }
        }
    }

    func source(_ metric: ProcessHotParameters.Metric, in environment: SourceEnvironment) throws -> any EventSource {
        let kind = AnyEventKind(ProcessHotEvent.self)
        let parameters = try kind.normalized(.object(["metric": .string(metric.rawValue), "above": .number(1)]))
        return try kind.makeSource(parameters, environment: environment) { _ in }
    }

    struct FixedFilter: NetworkFilterReading {
        let snapshot: FilterSnapshot
        func totals(wantsHosts _: Bool) throws(NetworkFilterUnavailable) -> FilterSnapshot { snapshot }
    }

    @Test func aNetworkMetricStartsWithTheFilter() {
        let environment = SourceEnvironment()
        environment.provideNetworkFilter(FixedFilter(snapshot: network([])))
        #expect(throws: Never.self) {
            _ = try source(.networkMBps, in: environment)
        }
    }
}
