import Foundation
import MeerkatNetworkFilter
import Testing

/// The ledger against a plain, unbounded reference over random streams with
/// every irregularity in them. A failure names its seed.
struct LedgerPropertyTests {
    static let seeds: [UInt64] = Array(1...24)

    /// With room for everything, the ledger is the reference: every byte of
    /// every flow it saw open is charged to the right process and endpoint,
    /// exactly once.
    @Test(arguments: seeds) func withRoomItMatchesTheReferenceExactly(seed: UInt64) {
        var stream = ReportStream(seed: seed)
        var ledger = FlowLedger(limits: FlowLedger.Limits(flows: 100_000, processes: 100_000, hosts: 100_000))
        ledger.collectsHosts = true
        var reference = ReferenceLedger()
        for _ in 0..<20_000 {
            let next = stream.next()
            ledger.record(next)
            reference.record(next)
        }
        let snapshot = ledger.snapshot()
        #expect(snapshot.processes == reference.processes, "seed \(seed)")
        #expect(snapshot.hosts == reference.hosts, "seed \(seed)")
        #expect(snapshot.counters.evictedFlows == 0 && snapshot.counters.evictedProcesses == 0, "seed \(seed)")
    }

    /// Under pressure the tables stay within their limits at every step, and
    /// no process or endpoint is ever charged more than it moved.
    @Test(arguments: seeds) func underPressureItStaysBoundedAndNeverOvercounts(seed: UInt64) {
        var stream = ReportStream(seed: seed, processCount: 60, hostCount: 50)
        let limits = FlowLedger.Limits(flows: 32, processes: 12, hosts: 20)
        var ledger = FlowLedger(limits: limits)
        ledger.collectsHosts = true
        var reference = ReferenceLedger()
        for step in 0..<20_000 {
            let next = stream.next()
            ledger.record(next)
            reference.record(next)
            let snapshot = ledger.snapshot()
            guard ledger.openFlowCount <= limits.flows, snapshot.processes.count <= limits.processes,
                snapshot.hosts.count <= limits.hosts
            else {
                Issue.record("seed \(seed) step \(step): a table outgrew its limit")
                return
            }
        }
        let snapshot = ledger.snapshot()
        for (process, totals) in snapshot.processes {
            let moved = reference.processes[process] ?? ByteTotals()
            #expect(totals.bytesIn <= moved.bytesIn && totals.bytesOut <= moved.bytesOut, "seed \(seed): \(process)")
        }
        for (host, totals) in snapshot.hosts {
            let moved = reference.hosts[host] ?? ByteTotals()
            #expect(totals.bytesIn <= moved.bytesIn && totals.bytesOut <= moved.bytesOut, "seed \(seed): \(host)")
        }
        #expect(snapshot.counters.evictedFlows > 0, "seed \(seed): the limits were meant to be hit")
    }

    /// Turning the host table on and off never changes what processes are
    /// charged.
    @Test(arguments: seeds.prefix(8)) func theHostTableNeverChangesProcessTotals(seed: UInt64) {
        var first = ReportStream(seed: seed)
        var second = ReportStream(seed: seed)
        var plain = FlowLedger()
        var toggled = FlowLedger()
        for step in 0..<10_000 {
            if step % 1_000 == 0 { toggled.collectsHosts.toggle() }
            plain.record(first.next())
            toggled.record(second.next())
        }
        #expect(plain.snapshot().processes == toggled.snapshot().processes, "seed \(seed)")
    }

    /// A flood far beyond the tables, as a port scan or a misbehaving app
    /// would cause: bounded throughout, and fast enough that the verdict path,
    /// which never waits on the ledger, is not the concern.
    @Test func aFloodOfFlowsStaysBounded() {
        let limits = FlowLedger.Limits(flows: 1_024, processes: 256, hosts: 512)
        var ledger = FlowLedger(limits: limits)
        ledger.collectsHosts = true
        var rng = SplitMix64(seed: 99)
        let started = ContinuousClock.now
        for index in 0..<300_000 {
            let flow = UUID()
            let process = ProcessKey.test(Int32(1 + index % 5_000))
            ledger.record(
                report(flow, .opened, process, remote: endpoint("h\(Int.random(in: 0..<2_000, using: &rng)).example")))
            ledger.record(report(flow, .statistics, process, in: 10, out: 1))
        }
        let snapshot = ledger.snapshot()
        #expect(ledger.openFlowCount <= limits.flows)
        #expect(snapshot.processes.count <= limits.processes)
        #expect(snapshot.hosts.count <= limits.hosts)
        #expect(ContinuousClock.now - started < .seconds(60))
    }
}
