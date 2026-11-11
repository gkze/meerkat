import Foundation
import MeerkatNetworkFilter

extension ProcessSnapshot {
    /// This snapshot with each process's network totals from the network
    /// filter, joined by pid.
    ///
    /// The filter knows a process by pid and pid version (its audit token),
    /// this snapshot by pid and start time, and no public interface gives
    /// one from the other, so the join is by pid alone, and a pid the filter
    /// has seen under two versions (reused within its memory) gets nothing.
    /// That cannot overcount: deltas pair rows by this snapshot's own
    /// identity, so a predecessor's total, joined to a process that took its
    /// pid, never changes and contributes zero; and a total that goes down
    /// between two readings yields no delta (`ProcessSampler.networkDelta`).
    /// The worst case is a reused pid going unaccounted for some windows.
    public func attributing(_ network: FilterSnapshot) -> ProcessSnapshot {
        var versions: [Int32: Int] = [:]
        for entry in network.processes { versions[entry.process.pid, default: 0] += 1 }
        var totals: [Int32: ByteTotals] = [:]
        for entry in network.processes where versions[entry.process.pid] == 1 {
            totals[entry.process.pid] = entry.totals
        }
        let joined = counters.mapValues { counters in
            counters.with(
                network: totals[counters.pid].map {
                    NetworkCounters(filter: network.instance, bytesIn: $0.bytesIn, bytesOut: $0.bytesOut)
                })
        }
        return ProcessSnapshot(takenAt: takenAt, counters: joined)
    }
}
