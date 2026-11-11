import Foundation
import MeerkatNetworkFilter
import Testing

/// The ledger's accounting, one rule at a time.
struct FlowLedgerTests {
    let app = ProcessKey.test(100)
    let other = ProcessKey.test(200)

    @Test func runningTotalsBecomeTheBytesMovedSinceTheLastReport() {
        var ledger = FlowLedger()
        let flow = UUID()
        ledger.record(report(flow, .opened, app))
        ledger.record(report(flow, .statistics, app, in: 1_000, out: 100))
        ledger.record(report(flow, .statistics, app, in: 1_500, out: 100))
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: 1_500, bytesOut: 100))
    }

    @Test func aRepeatedReportIsCountedOnce() {
        var ledger = FlowLedger()
        let flow = UUID()
        ledger.record(report(flow, .opened, app))
        for _ in 0..<5 { ledger.record(report(flow, .statistics, app, in: 700, out: 70)) }
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: 700, bytesOut: 70))
    }

    @Test func aCloseKeepsItsLastBytesAndEndsTheFlow() {
        var ledger = FlowLedger()
        let flow = UUID()
        ledger.record(report(flow, .opened, app))
        ledger.record(report(flow, .statistics, app, in: 100))
        ledger.record(report(flow, .closed, app, in: 250, out: 5))
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: 250, bytesOut: 5))
        #expect(ledger.openFlowCount == 0)
        // Anything after the close is about a flow the ledger no longer has.
        ledger.record(report(flow, .statistics, app, in: 9_999))
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: 250, bytesOut: 5))
        #expect(ledger.counters.untracked == 1)
    }

    @Test func aFlowNeverSeenOpeningIsNotCharged() {
        var ledger = FlowLedger()
        ledger.record(report(UUID(), .statistics, app, in: 1_000_000))
        ledger.record(report(UUID(), .closed, app, in: 5))
        #expect(ledger.snapshot().processes.isEmpty)
        #expect(ledger.counters.untracked == 2)
    }

    @Test func totalsThatGoDownDropTheFlow() {
        var ledger = FlowLedger()
        let flow = UUID()
        ledger.record(report(flow, .opened, app))
        ledger.record(report(flow, .statistics, app, in: 1_000, out: 10))
        ledger.record(report(flow, .statistics, app, in: 999, out: 10))
        ledger.record(report(flow, .statistics, app, in: 5_000, out: 10))
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: 1_000, bytesOut: 10))
        #expect(ledger.counters.inconsistent == 1)
        #expect(ledger.counters.untracked == 1)
    }

    @Test func aFlowNeverMovesToAnotherProcess() {
        var ledger = FlowLedger()
        let flow = UUID()
        ledger.record(report(flow, .opened, app))
        ledger.record(report(flow, .statistics, app, in: 10))
        ledger.record(report(flow, .statistics, other, in: 20))
        #expect(ledger.snapshot().processes[other] == nil)
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: 10))
        #expect(ledger.counters.inconsistent == 1)
    }

    @Test func aSecondOpenOfTheSameFlowIsNotTraffic() {
        var ledger = FlowLedger()
        let flow = UUID()
        ledger.record(report(flow, .opened, app))
        ledger.record(report(flow, .statistics, app, in: 10))
        ledger.record(report(flow, .opened, other))
        ledger.record(report(flow, .statistics, app, in: 30))
        #expect(ledger.snapshot().processes == [app: ByteTotals(bytesIn: 30)])
        #expect(ledger.counters.inconsistent == 1)
    }

    @Test func aReportWithNoProcessIsCountedAndEndsTheFlow() {
        var ledger = FlowLedger()
        let flow = UUID()
        ledger.record(report(flow, .opened, app))
        ledger.record(report(flow, .statistics, nil, in: 10))
        ledger.record(report(flow, .statistics, app, in: 20))
        #expect(ledger.snapshot().processes[app] == ByteTotals())
        #expect(ledger.counters.unattributed == 1)
        #expect(ledger.counters.untracked == 1)
    }

    @Test func aReusedPidIsAnotherProcess() {
        var ledger = FlowLedger()
        let first = ProcessKey.test(300, version: 1)
        let second = ProcessKey.test(300, version: 2)
        let (a, b) = (UUID(), UUID())
        ledger.record(report(a, .opened, first))
        ledger.record(report(a, .closed, first, in: 100))
        ledger.record(report(b, .opened, second))
        ledger.record(report(b, .statistics, second, in: 7))
        #expect(ledger.snapshot().processes == [first: ByteTotals(bytesIn: 100), second: ByteTotals(bytesIn: 7)])
    }

    @Test func totalsSaturateInsteadOfTrapping() {
        var ledger = FlowLedger()
        let (a, b) = (UUID(), UUID())
        ledger.record(report(a, .opened, app))
        ledger.record(report(a, .statistics, app, in: .max - 1, out: .max))
        ledger.record(report(b, .opened, app))
        ledger.record(report(b, .statistics, app, in: 10, out: 10))
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: .max, bytesOut: .max))
    }

    @Test func hostsAreKeptOnlyWhileAskedFor() {
        var ledger = FlowLedger()
        let flow = UUID()
        ledger.record(report(flow, .opened, app, remote: endpoint("example.com")))
        ledger.record(report(flow, .statistics, app, in: 10))
        #expect(ledger.snapshot().hosts.isEmpty)

        ledger.collectsHosts = true
        ledger.record(report(flow, .statistics, app, in: 25, out: 3))
        #expect(
            ledger.snapshot().hosts == [
                HostKey(process: app, remote: endpoint("example.com")): ByteTotals(bytesIn: 15, bytesOut: 3)
            ])

        ledger.collectsHosts = false
        #expect(ledger.snapshot().hosts.isEmpty)
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: 25, bytesOut: 3))
    }

    @Test func anEndpointLearnedAfterTheOpenIsUsed() {
        var ledger = FlowLedger()
        ledger.collectsHosts = true
        let flow = UUID()
        ledger.record(report(flow, .opened, app))
        ledger.record(report(flow, .statistics, app, in: 10, remote: endpoint("late.example")))
        #expect(
            ledger.snapshot().hosts[HostKey(process: app, remote: endpoint("late.example"))] == ByteTotals(bytesIn: 10))
    }

    @Test func aFullFlowTableEvictsItsLeastRecentEighthAndCountsIt() {
        var ledger = FlowLedger(limits: FlowLedger.Limits(flows: 16, processes: 64, hosts: 64))
        let flows = (0..<16).map { _ in UUID() }
        for flow in flows { ledger.record(report(flow, .opened, app)) }
        // Keep all but the first two recent.
        for flow in flows.dropFirst(2) { ledger.record(report(flow, .statistics, app, in: 1)) }
        ledger.record(report(UUID(), .opened, app))
        #expect(ledger.openFlowCount == 15)
        #expect(ledger.counters.evictedFlows == 2)
        // The evicted flows' later reports are ignored, not charged from zero.
        ledger.record(report(flows[0], .statistics, app, in: 1_000_000))
        #expect(ledger.snapshot().processes[app] == ByteTotals(bytesIn: 14))
        #expect(ledger.counters.untracked == 1)
    }

    @Test func aFullProcessTableEvictsAndCounts() {
        var ledger = FlowLedger(limits: FlowLedger.Limits(flows: 1_000, processes: 8, hosts: 8))
        for pid in 1...20 {
            let flow = UUID()
            ledger.record(report(flow, .opened, .test(Int32(pid))))
            ledger.record(report(flow, .closed, .test(Int32(pid)), in: 1))
        }
        #expect(ledger.snapshot().processes.count <= 8)
        #expect(ledger.counters.evictedProcesses == 12)
    }
}
