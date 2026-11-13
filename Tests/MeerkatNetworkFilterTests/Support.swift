import Foundation
import MeerkatNetworkFilter

/// A seeded generator, so a failing property run can be replayed by its seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension ProcessKey {
    static func test(_ pid: Int32, version: Int32 = 1, uid: UInt32 = 501) -> ProcessKey {
        ProcessKey(pid: pid, version: version, uid: uid)
    }
}

func endpoint(_ host: String, _ port: UInt16 = 443) -> RemoteEndpoint {
    guard let endpoint = RemoteEndpoint(host: host, port: port, transport: .tcp) else {
        preconditionFailure("test endpoint \(host) is invalid")
    }
    return endpoint
}

func report(
    _ flow: UUID, _ event: FlowReport.Event, _ process: ProcessKey?, in bytesIn: UInt64 = 0, out bytesOut: UInt64 = 0,
    remote: RemoteEndpoint? = nil
) -> FlowReport {
    FlowReport(flow: flow, event: event, process: process, remote: remote, bytesIn: bytesIn, bytesOut: bytesOut)
}

/// The ledger's semantics with no limits, written as plainly as possible: the
/// reference the property tests hold the real ledger to.
struct ReferenceLedger {
    private struct Flow {
        let process: ProcessKey
        var remote: RemoteEndpoint?
        var totals: ByteTotals
    }

    private var flows: [UUID: Flow] = [:]
    private(set) var processes: [ProcessKey: ByteTotals] = [:]
    private(set) var hosts: [HostKey: ByteTotals] = [:]

    mutating func record(_ report: FlowReport) {
        guard let process = report.process else {
            flows[report.flow] = nil
            return
        }
        if report.event == .opened {
            guard flows[report.flow] == nil else { return }
            flows[report.flow] = Flow(process: process, remote: report.remote, totals: ByteTotals())
        }
        guard var flow = flows[report.flow] else { return }
        guard flow.process == process, report.bytesIn >= flow.totals.bytesIn, report.bytesOut >= flow.totals.bytesOut
        else {
            flows[report.flow] = nil
            return
        }
        let moved = ByteTotals(
            bytesIn: report.bytesIn - flow.totals.bytesIn, bytesOut: report.bytesOut - flow.totals.bytesOut)
        flow.totals = ByteTotals(bytesIn: report.bytesIn, bytesOut: report.bytesOut)
        if flow.remote == nil { flow.remote = report.remote }
        flows[report.flow] = report.event == .closed ? nil : flow
        processes[process, default: ByteTotals()].bytesIn += moved.bytesIn
        processes[process, default: ByteTotals()].bytesOut += moved.bytesOut
        if let remote = flow.remote {
            hosts[HostKey(process: process, remote: remote), default: ByteTotals()].bytesIn += moved.bytesIn
            hosts[HostKey(process: process, remote: remote), default: ByteTotals()].bytesOut += moved.bytesOut
        }
    }
}

/// Random report streams with every irregularity NetworkExtension, a restart
/// or a bug could produce: interleaved flows, statistics before an open,
/// reordered and repeated reports, totals that go down, a flow that changes
/// process, reports with no process, reused pids.
struct ReportStream {
    var rng: SplitMix64
    let processes: [ProcessKey]
    let hosts: [RemoteEndpoint]
    private var open: [(flow: UUID, process: ProcessKey, totals: ByteTotals)] = []
    private var recent: [FlowReport] = []

    init(seed: UInt64, processCount: Int = 40, hostCount: Int = 30) {
        rng = SplitMix64(seed: seed)
        // Pairs of keys share a pid with different versions: a reused pid.
        processes = (0..<processCount).map { ProcessKey.test(Int32(100 + $0 / 2), version: Int32($0 % 2)) }
        hosts = (0..<hostCount).map { endpoint("host\($0).example", UInt16(1000 + $0)) }
    }

    mutating func next() -> FlowReport {
        let roll = Int.random(in: 0..<100, using: &rng)
        switch roll {
        case 0..<25 where open.count < 400:
            let flow = UUID()
            let process = processes.randomElement(using: &rng)!
            open.append((flow, process, ByteTotals()))
            return remember(
                report(
                    flow, .opened, process, remote: Bool.random(using: &rng) ? hosts.randomElement(using: &rng) : nil))
        case 0..<70 where !open.isEmpty:
            let index = Int.random(in: 0..<open.count, using: &rng)
            open[index].totals.bytesIn += UInt64.random(in: 0...50_000, using: &rng)
            open[index].totals.bytesOut += UInt64.random(in: 0...20_000, using: &rng)
            let flow = open[index]
            return remember(
                report(flow.flow, .statistics, flow.process, in: flow.totals.bytesIn, out: flow.totals.bytesOut))
        case 70..<82 where !open.isEmpty:
            let flow = open.remove(at: Int.random(in: 0..<open.count, using: &rng))
            return remember(
                report(flow.flow, .closed, flow.process, in: flow.totals.bytesIn, out: flow.totals.bytesOut))
        case 82..<88 where !recent.isEmpty:
            // A repeat or a late, reordered report.
            return recent.randomElement(using: &rng)!
        case 88..<91 where !open.isEmpty:
            // Totals that went down.
            let flow = open[Int.random(in: 0..<open.count, using: &rng)]
            return report(flow.flow, .statistics, flow.process, in: flow.totals.bytesIn / 2, out: 0)
        case 91..<93 where !open.isEmpty:
            // The same flow, another process.
            let flow = open[Int.random(in: 0..<open.count, using: &rng)]
            return report(flow.flow, .statistics, processes.randomElement(using: &rng)!, in: flow.totals.bytesIn &+ 1)
        case 93..<96:
            // Statistics for a flow never seen opening.
            return report(UUID(), .statistics, processes.randomElement(using: &rng)!, in: 1_000, out: 1_000)
        case 96..<98 where !open.isEmpty:
            let flow = open[Int.random(in: 0..<open.count, using: &rng)]
            return report(flow.flow, .statistics, nil, in: flow.totals.bytesIn)
        default:
            let flow = UUID()
            let process = processes.randomElement(using: &rng)!
            open.append((flow, process, ByteTotals()))
            return remember(report(flow, .opened, process, remote: hosts.randomElement(using: &rng)))
        }
    }

    private mutating func remember(_ report: FlowReport) -> FlowReport {
        recent.append(report)
        if recent.count > 64 { recent.removeFirst() }
        return report
    }
}
