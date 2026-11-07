import Foundation

/// One complete `SystemSample`: memory, load, a process window and optional
/// path churn. Shared by `meerkat sample` and the daemon's `store.record`
/// effect, so a recorded sample means the same thing whichever took it.
public enum SystemSampler {
    public struct Options: Sendable, Equatable {
        /// The window, in seconds, that CPU, I/O and churn are measured over.
        public var window: Double
        public var top: Int
        /// Keep only processes whose executable ships with macOS.
        public var systemOnly: Bool
        /// Also count FSEvents activity under this directory.
        public var churnPath: String?
        public var churnDepth: Int

        public init(
            window: Double = 10, top: Int = 10, systemOnly: Bool = false,
            churnPath: String? = nil, churnDepth: Int = 5
        ) {
            self.window = window
            self.top = top
            self.systemOnly = systemOnly
            self.churnPath = churnPath
            self.churnDepth = churnDepth
        }
    }

    /// Blocks for the window. Churn, when asked for, is counted over the
    /// same window as the processes and CPU, so a writer in the process rows
    /// is in the same sample's churn; memory and load are read at its end.
    public static func sample(_ options: Options) throws -> SystemSample {
        // System services need the full ranking before filtering, otherwise a
        // user-space process can crowd the daemons out of the top-N cut. The
        // host's tick counters bracket the same window as the snapshots.
        func processWindow() throws -> (before: ProcessSnapshot, after: ProcessSnapshot, cpuPercent: Double?) {
            let ticksBefore = HostSampler.cpuTicks()
            let before = try ProcessSampler.snapshot()
            Thread.sleep(forTimeInterval: options.window)
            let after = try ProcessSampler.snapshot()
            let ticksAfter = HostSampler.cpuTicks()
            let cpuPercent = ticksBefore.flatMap { start in
                ticksAfter.flatMap { end -> Double? in
                    guard end.total > start.total, end.busy >= start.busy else { return nil }
                    return Double(end.busy - start.busy) / Double(end.total - start.total) * 100
                }
            }
            return (before, after, cpuPercent)
        }

        var churn: ChurnResult?
        let window: (before: ProcessSnapshot, after: ProcessSnapshot, cpuPercent: Double?)
        if let churnPath = options.churnPath {
            let expanded = (churnPath as NSString).expandingTildeInPath
            (churn, window) = try PathChurnMonitor(root: expanded, depth: options.churnDepth)
                .measure(during: processWindow)
        } else {
            window = try processWindow()
        }

        let memory = try MemorySampler.sample()
        let load = try MemorySampler.loadAverages()

        let raw = ProcessSampler.deltas(
            previous: window.before, current: window.after, top: options.systemOnly ? .max : options.top)
        let processes =
            options.systemOnly
            ? Array(raw.filter(\.isSystemService).prefix(options.top))
            : raw

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return SystemSample(
            timestamp: formatter.string(from: Date()),
            host: ProcessInfo.processInfo.hostName,
            cpuCount: ProcessInfo.processInfo.processorCount,
            windowSeconds: max(window.after.takenAt.timeIntervalSince(window.before.takenAt), 0.001),
            cpuUsagePercent: window.cpuPercent,
            load1: load.0, load5: load.1, load15: load.2,
            memory: memory,
            processes: processes,
            churn: churn
        )
    }
}
