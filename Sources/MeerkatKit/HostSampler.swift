import Darwin
import Foundation

/// Machine-wide CPU load from mach host statistics.
///
/// This is one syscall returning cumulative tick counters for the whole
/// machine, so the UI can refresh at display speed for effectively zero cost —
/// unlike enumerating ~1000 processes and diffing `proc_pid_rusage`, which is
/// the expensive part of process-level attribution.
public enum HostSampler {
    private static let hostCPULoadInfo: Int32 = 3  // HOST_CPU_LOAD_INFO

    /// Cumulative (busy, total) ticks. Subtract two reads to get utilisation.
    public static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), hostCPULoadInfo, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        return (busy: user + system + nice, total: user + system + idle + nice)
    }

    /// Percent of all cores busy between two `cpuTicks` reads; nil when
    /// no tick passed or the counters went backwards, which would trap the
    /// subtraction.
    public static func usagePercent(from start: (busy: UInt64, total: UInt64), to end: (busy: UInt64, total: UInt64))
        -> Double?
    {
        guard end.total > start.total, end.busy >= start.busy else { return nil }
        return Double(end.busy - start.busy) / Double(end.total - start.total) * 100
    }

    /// The 1, 5 and 15 minute load averages. Throws rather than report an
    /// idle machine.
    public static func loadAverages() throws -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { throw MeerkatError.loadAverageUnavailable }
        return (loads[0], loads[1], loads[2])
    }
}
