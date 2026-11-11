import Foundation

/// Bytes moved, in and out. Additions saturate: a total that cannot grow
/// further stays at its maximum rather than trapping in the extension.
public struct ByteTotals: Hashable, Sendable, Codable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(bytesIn: UInt64 = 0, bytesOut: UInt64 = 0) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    mutating func add(_ other: ByteTotals) {
        bytesIn = bytesIn.addingReportingOverflow(other.bytesIn).overflow ? .max : bytesIn &+ other.bytesIn
        bytesOut = bytesOut.addingReportingOverflow(other.bytesOut).overflow ? .max : bytesOut &+ other.bytesOut
    }
}

/// One process's traffic to one remote endpoint.
public struct HostKey: Hashable, Sendable, Codable {
    public let process: ProcessKey
    public let remote: RemoteEndpoint

    public init(process: ProcessKey, remote: RemoteEndpoint) {
        self.process = process
        self.remote = remote
    }
}

/// What the ledger set aside instead of counting, so a total that is low says
/// why. Each only grows.
public struct LedgerCounters: Hashable, Sendable, Codable {
    /// Reports macOS gave no process for.
    public var unattributed: UInt64 = 0
    /// Reports for a flow the ledger did not see open: opened before the
    /// extension started, or evicted since. Ignored rather than counted from
    /// zero, which would charge the flow's whole history again.
    public var untracked: UInt64 = 0
    /// Reports whose running totals went down, or that named another process
    /// than the flow opened with: not traffic. The flow is dropped.
    public var inconsistent: UInt64 = 0
    public var evictedFlows: UInt64 = 0
    public var evictedProcesses: UInt64 = 0
    public var evictedHosts: UInt64 = 0

    public init() {}
}

/// The extension's whole state: each open flow's last running totals, and the
/// bytes charged to each process (and, while asked for, to each process and
/// remote endpoint) since the extension started.
///
/// Pure and bounded. Totals only grow, so any number of readers can each
/// take the difference between two snapshots, and a read changes nothing.
/// When a table is full, the least recently reported eighth of it goes, and
/// the eviction is counted: under pressure totals come out low, visibly,
/// never high.
public struct FlowLedger: Sendable {
    public struct Limits: Sendable, Equatable {
        public var flows: Int
        public var processes: Int
        public var hosts: Int

        public init(flows: Int, processes: Int, hosts: Int) {
            precondition(flows > 0 && processes > 0 && hosts > 0, "a table must hold something")
            self.flows = flows
            self.processes = processes
            self.hosts = hosts
        }

        /// Room for every connection a busy Mac holds open, at well under
        /// 10 MB: a flow entry is about 120 bytes, a host entry about 330.
        public static let standard = Limits(flows: 32_768, processes: 4_096, hosts: 16_384)
    }

    public struct Snapshot: Sendable, Equatable {
        public let processes: [ProcessKey: ByteTotals]
        public let hosts: [HostKey: ByteTotals]
        public let counters: LedgerCounters

        public init(processes: [ProcessKey: ByteTotals], hosts: [HostKey: ByteTotals], counters: LedgerCounters) {
            self.processes = processes
            self.hosts = hosts
            self.counters = counters
        }
    }

    private struct OpenFlow {
        let process: ProcessKey
        var remote: RemoteEndpoint?
        var totals: ByteTotals
        var lastSeen: UInt64
    }

    private struct Charged {
        var totals = ByteTotals()
        var lastSeen: UInt64 = 0
    }

    public let limits: Limits
    public private(set) var counters = LedgerCounters()
    private var flows: [UUID: OpenFlow] = [:]
    private var processes: [ProcessKey: Charged] = [:]
    private var hosts: [HostKey: Charged] = [:]
    private var tick: UInt64 = 0

    /// Whether to keep the per-endpoint table. Off by default; turning it off
    /// drops the table, so no destinations are kept when nobody asks.
    public var collectsHosts = false {
        didSet { if !collectsHosts { hosts = [:] } }
    }

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    public var openFlowCount: Int { flows.count }

    public mutating func record(_ report: FlowReport) {
        tick &+= 1
        guard let process = report.process else {
            counters.unattributed &+= 1
            flows[report.flow] = nil
            return
        }
        guard case .opened = report.event else {
            account(report, process: process)
            return
        }
        guard flows[report.flow] == nil else {
            // Opened twice: the first open stands, the second is not traffic.
            counters.inconsistent &+= 1
            return
        }
        counters.evictedFlows &+= Self.makeRoom(in: &flows, limit: limits.flows, lastSeen: \.lastSeen)
        flows[report.flow] = OpenFlow(process: process, remote: report.remote, totals: ByteTotals(), lastSeen: tick)
        account(report, process: process)
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            processes: processes.mapValues(\.totals), hosts: hosts.mapValues(\.totals), counters: counters)
    }

    private mutating func account(_ report: FlowReport, process: ProcessKey) {
        guard var flow = flows[report.flow] else {
            counters.untracked &+= 1
            return
        }
        guard flow.process == process, report.bytesIn >= flow.totals.bytesIn, report.bytesOut >= flow.totals.bytesOut
        else {
            counters.inconsistent &+= 1
            flows[report.flow] = nil
            return
        }
        let delta = ByteTotals(
            bytesIn: report.bytesIn - flow.totals.bytesIn, bytesOut: report.bytesOut - flow.totals.bytesOut)
        flow.totals = ByteTotals(bytesIn: report.bytesIn, bytesOut: report.bytesOut)
        flow.lastSeen = tick
        if flow.remote == nil { flow.remote = report.remote }
        flows[report.flow] = report.event == .closed ? nil : flow
        charge(process: process, remote: flow.remote, delta: delta)
    }

    private mutating func charge(process: ProcessKey, remote: RemoteEndpoint?, delta: ByteTotals) {
        if processes[process] == nil {
            counters.evictedProcesses &+= Self.makeRoom(in: &processes, limit: limits.processes, lastSeen: \.lastSeen)
        }
        processes[process, default: Charged()].totals.add(delta)
        processes[process]?.lastSeen = tick
        guard collectsHosts, let remote else { return }
        let key = HostKey(process: process, remote: remote)
        if hosts[key] == nil {
            counters.evictedHosts &+= Self.makeRoom(in: &hosts, limit: limits.hosts, lastSeen: \.lastSeen)
        }
        hosts[key, default: Charged()].totals.add(delta)
        hosts[key]?.lastSeen = tick
    }

    /// Before an insert into a full table, drops its least recently seen
    /// eighth (at least one entry) and returns how many went: one sort per
    /// eighth of the table's inserts, not one scan per insert.
    private static func makeRoom<Key: Hashable, Value>(
        in table: inout [Key: Value], limit: Int, lastSeen: KeyPath<Value, UInt64>
    ) -> UInt64 {
        guard table.count >= limit else { return 0 }
        let victims = table.sorted { $0.value[keyPath: lastSeen] < $1.value[keyPath: lastSeen] }
            .prefix(max(1, limit / 8))
        for (key, _) in victims { table[key] = nil }
        return UInt64(victims.count)
    }
}
