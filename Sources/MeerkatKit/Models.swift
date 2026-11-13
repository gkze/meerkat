import Foundation

// MARK: - Public output types
//
// What a sample produces. The types that leave the process (a delta, a
// sample, churn) are Codable: the JSON the CLI prints and payloads carry.
// Counters and snapshots stay in memory. Each carries an
// explicit public initializer: Swift's memberwise init is internal, which
// would hide these from clients.

/// Absolute CPU/IO counters for a single process at one instant.
public struct ProcessCounters: Sendable, Equatable {
    public let identity: ProcessIdentity
    public let uid: uid_t
    /// Short process name for display, never a path.
    public let name: String
    /// Executable path from `proc_pidpath`; nil when the process exited or
    /// the kernel refused. Classification uses this, never `name`.
    public let path: String?
    /// user + system, in seconds. Timebase-corrected (see MachTime).
    public let cpuSeconds: Double
    /// nil when the kernel refuses `proc_pid_rusage`, which it does for every
    /// other user's process: unknown, not zero.
    public let usage: ResourceUsage?
    /// Bytes this process moved over the network since the network filter
    /// started; nil while the filter is off or cannot tell this process from
    /// another with the same pid (`ProcessSnapshot.attributing`).
    public let network: NetworkCounters?

    public var pid: pid_t { identity.pid }

    public init(
        identity: ProcessIdentity, uid: uid_t, name: String, path: String?,
        cpuSeconds: Double, usage: ResourceUsage?, network: NetworkCounters? = nil
    ) {
        self.identity = identity
        self.uid = uid
        self.name = name
        self.path = path
        self.cpuSeconds = cpuSeconds
        self.usage = usage
        self.network = network
    }

    /// These counters with the network's added.
    func with(network: NetworkCounters?) -> ProcessCounters {
        ProcessCounters(
            identity: identity, uid: uid, name: name, path: path, cpuSeconds: cpuSeconds, usage: usage,
            network: network)
    }
}

/// A process's network bytes since the network filter started, under the
/// filter's instance: totals from two instances are not comparable.
public struct NetworkCounters: Sendable, Equatable {
    public let filter: UUID
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(filter: UUID, bytesIn: UInt64, bytesOut: UInt64) {
        self.filter = filter
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// The `proc_pid_rusage` counters beyond CPU time, which the kernel gives
/// together or not at all.
public struct ResourceUsage: Sendable, Equatable {
    /// Physical memory footprint, matching what Activity Monitor reports.
    public let footprintBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let energyNanojoules: UInt64

    public init(footprintBytes: UInt64, diskReadBytes: UInt64, diskWriteBytes: UInt64, energyNanojoules: UInt64) {
        self.footprintBytes = footprintBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.energyNanojoules = energyNanojoules
    }
}

/// A timestamped set of per-process counters. Diffing two of these yields
/// deltas without blocking, which is what lets a UI sample cheaply.
public struct ProcessSnapshot: Sendable {
    public let takenAt: Date
    public let counters: [ProcessIdentity: ProcessCounters]

    public init(takenAt: Date, counters: [ProcessIdentity: ProcessCounters]) {
        self.takenAt = takenAt
        self.counters = counters
    }

    /// Seconds since `previous`, never zero: what a window's totals are
    /// rates over, even for two snapshots taken at one instant.
    public func window(since previous: ProcessSnapshot) -> Double {
        max(takenAt.timeIntervalSince(previous.takenAt), Self.shortestWindow)
    }

    /// The least window a rate is taken over, in seconds.
    static let shortestWindow = 0.001
}

/// A process measured across a window: deltas plus the absolute footprint.
public struct ProcessDelta: Codable, Sendable, Equatable {
    public let pid: Int32
    public let name: String
    /// nil when the executable path is unknown; JSON omits the key then.
    public let path: String?
    /// Percent of one core over the window. Additive across processes.
    public let cpuPct: Double
    public let cpuSeconds: Double
    /// Actual elapsed time between the two snapshots that produced this delta.
    public let windowSeconds: Double
    /// The four below are nil when the kernel refused this process's
    /// counters (another user's process): unknown, not zero.
    public let footprintMB: Double?
    public let diskReadMB: Double?
    public let diskWriteMB: Double?
    public let energyJoules: Double?
    /// Unix epoch milliseconds when the process started; with `pid` this
    /// identifies the process instance.
    public let startedAt: Double
    /// Owning user id.
    public let uid: UInt32
    /// Received and sent over the network during the window; nil while the
    /// network filter is off, or for a window it cannot account for this
    /// process (it restarted, or the pid was reused). Unlike disk and energy,
    /// known for every user's processes.
    public let networkInMB: Double?
    public let networkOutMB: Double?

    public init(
        pid: Int32, name: String, path: String?, cpuPct: Double,
        cpuSeconds: Double, windowSeconds: Double,
        footprintMB: Double?, diskReadMB: Double?, diskWriteMB: Double?,
        energyJoules: Double?, startedAt: Double, uid: UInt32,
        networkInMB: Double? = nil, networkOutMB: Double? = nil
    ) {
        self.pid = pid
        self.name = name
        self.path = path
        self.cpuPct = cpuPct
        self.cpuSeconds = cpuSeconds
        self.windowSeconds = windowSeconds
        self.footprintMB = footprintMB
        self.diskReadMB = diskReadMB
        self.diskWriteMB = diskWriteMB
        self.energyJoules = energyJoules
        self.startedAt = startedAt
        self.uid = uid
        self.networkInMB = networkInMB
        self.networkOutMB = networkOutMB
    }

    /// Whether the executable ships as part of macOS. Decided by path,
    /// regardless of which user the process runs as; a process with no known
    /// path is not classified as a service.
    public var isSystemService: Bool {
        path.map(Self.isSystemExecutable) ?? false
    }

    /// macOS's own executables live on the sealed system volume, in Apple's
    /// slice of /Library, or in a cryptex, which mounts OS and Safari content
    /// outside /System but mirrors its layout. Apple's apps, /usr/local and
    /// third-party software in /Library sit under the same roots and are
    /// excluded. Code signatures are not read: this is a path rule only.
    public static func isSystemExecutable(_ path: String) -> Bool {
        let osPath = withoutCryptexMount(path)
        if systemExclusions.contains(where: { osPath.hasPrefix($0) }) { return false }
        return systemRoots.contains { osPath.hasPrefix($0) }
    }

    private static let systemRoots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
    /// `/System/Volumes/` also reaches the Data volume (`/System/Volumes/Data/
    /// usr/local/...`), so only cryptex mounts, stripped first, get through.
    private static let systemExclusions = ["/System/Applications/", "/System/Volumes/", "/usr/local/"]
    private static let cryptexMounts = ["/System/Volumes/Preboot/Cryptexes/", "/System/Cryptexes/"]

    /// "/System/Volumes/Preboot/Cryptexes/OS/System/Library/x" -> "/System/Library/x".
    /// Paths outside a cryptex are returned unchanged.
    static func withoutCryptexMount(_ path: String) -> String {
        guard let mount = cryptexMounts.first(where: { path.hasPrefix($0) }) else { return path }
        let inside = path.dropFirst(mount.count)  // "OS/System/Library/x"
        guard let slash = inside.firstIndex(of: "/") else { return "" }
        return String(inside[slash...])
    }
}

public struct MemorySample: Codable, Sendable, Equatable {
    public let pageSize: UInt64
    public let freeMB: Double
    public let activeMB: Double
    public let inactiveMB: Double
    public let wiredMB: Double
    public let compressedMB: Double
    public let swapUsedMB: Double
    public let swapTotalMB: Double

    public init(
        pageSize: UInt64, freeMB: Double, activeMB: Double,
        inactiveMB: Double, wiredMB: Double, compressedMB: Double,
        swapUsedMB: Double, swapTotalMB: Double
    ) {
        self.pageSize = pageSize
        self.freeMB = freeMB
        self.activeMB = activeMB
        self.inactiveMB = inactiveMB
        self.wiredMB = wiredMB
        self.compressedMB = compressedMB
        self.swapUsedMB = swapUsedMB
        self.swapTotalMB = swapTotalMB
    }
}

public struct ChurnBucket: Codable, Sendable, Equatable {
    public let path: String
    public let events: Int

    public init(path: String, events: Int) {
        self.path = path
        self.events = events
    }
}

/// Per-path change activity recorded with FSEvents over a window.
public struct ChurnResult: Codable, Sendable, Equatable {
    public let root: String
    public let windowSeconds: Double
    public let totalEvents: Int
    public let created: Int
    public let modified: Int
    public let removed: Int
    public let renamed: Int
    public let buckets: [ChurnBucket]
    /// Same events, classified by file kind (authored vs generated vs cache).
    public let categories: [ChurnBucket]
    /// Paths under `root` whose events were left out.
    public let excluded: [String]

    public init(
        root: String, windowSeconds: Double, totalEvents: Int,
        created: Int, modified: Int, removed: Int, renamed: Int,
        buckets: [ChurnBucket], categories: [ChurnBucket] = [], excluded: [String] = []
    ) {
        self.root = root
        self.windowSeconds = windowSeconds
        self.totalEvents = totalEvents
        self.created = created
        self.modified = modified
        self.removed = removed
        self.renamed = renamed
        self.buckets = buckets
        self.categories = categories
        self.excluded = excluded
    }
}

public struct SystemSample: Codable, Sendable {
    public let timestamp: String
    public let host: String
    public let cpuCount: Int
    /// Measured time between the two process snapshots, which every
    /// process row and `cpuUsagePercent` cover.
    public let windowSeconds: Double
    /// Percent of all cores busy over the window, from the host's tick
    /// counters; nil when `host_statistics` failed.
    public let cpuUsagePercent: Double?
    public let load1: Double
    public let load5: Double
    public let load15: Double
    public let memory: MemorySample
    public let processes: [ProcessDelta]
    public let churn: ChurnResult?

    public init(
        timestamp: String, host: String, cpuCount: Int,
        windowSeconds: Double, cpuUsagePercent: Double?, load1: Double, load5: Double,
        load15: Double, memory: MemorySample,
        processes: [ProcessDelta], churn: ChurnResult?
    ) {
        self.timestamp = timestamp
        self.host = host
        self.cpuCount = cpuCount
        self.windowSeconds = windowSeconds
        self.cpuUsagePercent = cpuUsagePercent
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.memory = memory
        self.processes = processes
        self.churn = churn
    }
}

// MARK: - Errors

public enum MeerkatError: Error, CustomStringConvertible {
    case streamCreationFailed
    case hostStatisticsFailed(kern_return_t)
    case swapUnavailable
    case loadAverageUnavailable
    /// `sysctl(KERN_PROC_ALL)` failed with this errno.
    case processTableUnreadable(Int32)
    /// `ps`, the CPU time of the processes `proc_pid_rusage` refuses, failed.
    case cpuTimesUnreadable(String)

    public var description: String {
        switch self {
        case .streamCreationFailed:
            return "could not create an FSEvents stream for the requested path"
        case .hostStatisticsFailed(let kr):
            return "host_statistics64 failed with kern_return_t \(kr)"
        case .swapUnavailable:
            return "vm.swapusage sysctl unavailable"
        case .loadAverageUnavailable:
            return "getloadavg failed"
        case .processTableUnreadable(let code):
            return "the process table could not be read: \(String(cString: strerror(code)))"
        case .cpuTimesUnreadable(let reason):
            return "other users' CPU times could not be read: \(reason)"
        }
    }
}

// MARK: - Mach timebase
//
// Empirical finding on macOS 27 / Apple Silicon: the CPU-time fields returned
// by proc_pid_rusage are in mach absolute-time ticks, NOT nanoseconds, despite
// reading like nanoseconds. On a 24 MHz timebase that means dividing by 1e9
// undercounts by 41.666x. Verified against `ps` with a known-cost process.
public enum MachTime {
    /// Nanoseconds per tick. 41.666667 on Apple Silicon.
    public static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1.0 }
        return Double(info.numer) / Double(info.denom)
    }()

    /// Convert a raw tick count to seconds.
    public static func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * nanosPerTick / 1_000_000_000.0
    }
}

/// The sample store's own budget, whoever records into it: `meerkat.json`'s
/// `samples`, which the store keeps (`SampleStore.Limits`). A rule's
/// `store.record({ retain })` bounds its own label within this.
public struct SampleBudget: Codable, Sendable, Equatable {
    /// Samples older than this are deleted.
    public var maxAgeDays: Int
    /// The store is trimmed, oldest first, when it grows past this.
    public var maxMegabytes: Int

    public init(maxAgeDays: Int = 30, maxMegabytes: Int = 500) {
        self.maxAgeDays = maxAgeDays
        self.maxMegabytes = maxMegabytes
    }
}

extension [Double] {
    /// The middle value, or the mean of the middle two; nil when empty.
    public var median: Double? {
        guard !isEmpty else { return nil }
        let sorted = sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

extension Date {
    /// A time as the daemon reports it: Unix epoch milliseconds.
    public init(epochMilliseconds: Double) {
        self.init(timeIntervalSince1970: epochMilliseconds / 1000)
    }
}
