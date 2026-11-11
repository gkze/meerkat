import Foundation
import MeerkatNetworkFilter
import Synchronization
import Testing

@testable import MeerkatKit

/// `network.flows`: what a window lists, what each rule sees of it, and that
/// it needs the filter.
struct NetworkFlowsTests {
    func key(_ pid: Int32, uid: UInt32 = 501, _ host: String, _ port: UInt16 = 443) -> HostKey {
        guard let remote = RemoteEndpoint(host: host, port: port, transport: .tcp) else {
            preconditionFailure("bad test host")
        }
        return HostKey(process: ProcessKey(pid: pid, version: 1, uid: uid), remote: remote)
    }

    @Test func listsTheLargestFirstAndNamesTheProcesses() {
        var delta = UsageDelta()
        delta.hosts = [
            key(1, "small.example"): ByteTotals(bytesIn: 1_000),
            key(2, "big.example"): ByteTotals(bytesIn: 9_000_000, bytesOut: 1_000_000),
        ]
        let payload = NetworkFlowsPayload.make(
            from: delta, windowSeconds: 5, names: [2: ("Safari", "/Applications/Safari.app/Contents/MacOS/Safari")])
        #expect(payload.flows.map(\.host) == ["big.example", "small.example"])
        #expect(payload.flows[0].name == "Safari" && payload.flows[0].receivedMB == 9 && payload.flows[0].sentMB == 1)
        #expect(payload.flows[1].name == nil, "an exited process is listed by pid alone")
        #expect(payload.omitted == 0)
    }

    @Test func capsTheWindowAndCountsWhatItLeftOut() {
        var delta = UsageDelta()
        for index in 0..<(NetworkFlowsPayload.maximumFlows + 25) {
            delta.hosts[key(Int32(index + 1), "h\(index).example")] = ByteTotals(bytesIn: UInt64(index + 1))
        }
        delta.restarted = 3
        let payload = NetworkFlowsPayload.make(from: delta, windowSeconds: 5, names: [:])
        #expect(payload.flows.count == NetworkFlowsPayload.maximumFlows)
        #expect(payload.omitted == 28)
        #expect(payload.flows.first?.receivedMB == Double(NetworkFlowsPayload.maximumFlows + 25) / 1_000_000)
    }

    @Test func aRuleSeesOnlyItsUsersProcessesUnlessItObservesAll() {
        let payload = NetworkFlowsPayload(
            windowSeconds: 5,
            flows: [
                NetworkFlow(
                    pid: 1, uid: 501, name: nil, path: nil, host: "a", port: 1, transport: .tcp, receivedMB: 1,
                    sentMB: 0),
                NetworkFlow(
                    pid: 2, uid: 0, name: nil, path: nil, host: "b", port: 1, transport: .udp, receivedMB: 1, sentMB: 0),
            ], omitted: 0)
        #expect(payload.viewed(by: RuleView(file: "r.ts", user: 501))?.flows.map(\.pid) == [1])
        #expect(payload.viewed(by: RuleView(file: "r.ts", user: nil)) == payload)
        #expect(payload.viewed(by: RuleView(file: "r.ts", user: 777)) == nil, "nothing visible, no event")
    }

    @Test func isRefusedWithoutTheFilter() throws {
        let kind = AnyEventKind(NetworkFlowsEvent.self)
        let parameters = try kind.normalized(.object([:]))
        #expect(throws: EventError.self) { try kind.makeSource(parameters, environment: SourceEnvironment()) { _ in } }
    }

    @Test func isANamedObservation() {
        #expect(NetworkFlowsEvent.descriptor.observation == .named)
        #expect(EventCatalog.standard.kind(named: "network.flows") != nil)
    }

    /// Readings from a stand-in filter whose totals the test advances.
    final class SteppingFilter: NetworkFilterReading {
        let instance = UUID()
        let totals = Mutex<[HostKey: ByteTotals]>([:])

        func totals(wantsHosts: Bool) throws(NetworkFilterUnavailable) -> FilterSnapshot {
            #expect(wantsHosts, "network.flows keeps the host table alive")
            return FilterSnapshot(
                instance: instance, build: "b",
                snapshot: FlowLedger.Snapshot(
                    processes: [:], hosts: totals.withLock { $0 }, counters: LedgerCounters()),
                openFlows: 0)
        }
    }

    /// The first reading is a baseline taken at subscription; each later window
    /// reports what moved since.
    @Test func reportsWhatMovedEachWindow() async throws {
        let filter = SteppingFilter()
        let flow = key(9, "example.com")
        filter.totals.withLock { $0 = [flow: ByteTotals(bytesIn: 5_000_000)] }
        let environment = SourceEnvironment()
        environment.provideNetworkFilter(filter)
        let kind = AnyEventKind(NetworkFlowsEvent.self)
        let received = Mutex<[JSONValue]>([])
        let source = try kind.makeSource(
            try kind.normalized(.object(["interval": .number(5)])), environment: environment
        ) {
            emission in
            if case .event(let value, _, _) = emission { received.withLock { $0.append(value) } }
        }
        filter.totals.withLock { $0 = [flow: ByteTotals(bytesIn: 7_000_000, bytesOut: 1_000_000)] }
        try source.start()
        defer { source.stop() }
        try await Task.sleep(for: .seconds(6))
        let first = try #require(received.withLock { $0.first })
        guard case .object(let payload) = first, case .array(let flows) = payload["flows"],
            case .object(let entry) = flows.first
        else {
            Issue.record("unexpected payload \(first)")
            return
        }
        #expect(entry["receivedMB"] == .number(2))
        #expect(entry["sentMB"] == .number(1))
    }
}
