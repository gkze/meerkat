import Foundation

/// Bytes moved between two of the extension's snapshots, per process and per
/// process and endpoint.
public struct UsageDelta: Sendable, Equatable {
    public var processes: [ProcessKey: ByteTotals] = [:]
    public var hosts: [HostKey: ByteTotals] = [:]
    /// True when there was nothing to subtract from: the first snapshot, or
    /// the first from a restarted extension. The deltas are then empty, and the
    /// window is skipped rather than reported as zero traffic.
    public var baseline = false
    /// Keys whose totals went down since the last snapshot (evicted, then
    /// charged again): no delta is reported for them this window.
    public var restarted = 0

    public init() {}
}

/// The daemon's side of the totals: keeps the last snapshot and subtracts.
/// One per reader, so readers never interfere with each other.
public struct UsageDiffer: Sendable {
    private var last: FilterSnapshot?

    public init() {}

    public mutating func next(_ snapshot: FilterSnapshot) -> UsageDelta {
        defer { last = snapshot }
        var delta = UsageDelta()
        guard let last, last.instance == snapshot.instance else {
            delta.baseline = true
            return delta
        }
        let before = Dictionary(uniqueKeysWithValues: last.processes.map { ($0.process, $0.totals) })
        for entry in snapshot.processes {
            switch Self.difference(entry.totals, since: before[entry.process]) {
            case .some(let moved) where moved != ByteTotals(): delta.processes[entry.process] = moved
            case .some: break
            case .none: delta.restarted += 1
            }
        }
        let hostsBefore = Dictionary(uniqueKeysWithValues: last.hosts.map { ($0.key, $0.totals) })
        for entry in snapshot.hosts {
            switch Self.difference(entry.totals, since: hostsBefore[entry.key]) {
            case .some(let moved) where moved != ByteTotals(): delta.hosts[entry.key] = moved
            case .some: break
            case .none: delta.restarted += 1
            }
        }
        return delta
    }

    /// `now - before`, or nil when either total went down. A key that is new
    /// since the last snapshot moved all its bytes since it.
    static func difference(_ now: ByteTotals, since before: ByteTotals?) -> ByteTotals? {
        guard let before else { return now }
        guard now.bytesIn >= before.bytesIn, now.bytesOut >= before.bytesOut else { return nil }
        return ByteTotals(bytesIn: now.bytesIn - before.bytesIn, bytesOut: now.bytesOut - before.bytesOut)
    }
}
