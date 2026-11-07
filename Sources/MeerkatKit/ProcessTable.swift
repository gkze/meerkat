import Darwin
import Foundation

/// A process instance: pid plus start time.
///
/// Pids are reused, so a pid alone cannot tell whether two observations are
/// the same process. The start time comes from `kinfo_proc`, which the kernel
/// returns for every process without privileges.
public struct ProcessIdentity: Sendable, Hashable, Codable, Comparable {
    public let pid: pid_t
    /// Microseconds since the Unix epoch.
    public let startMicroseconds: Int64

    public init(pid: pid_t, startMicroseconds: Int64) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
    }

    /// Unix epoch milliseconds, the time unit every payload uses.
    public var startedAt: Double { Double(startMicroseconds) / 1000 }

    /// `startedAt` values a process can have, in milliseconds, through the
    /// year 2255. A value from outside (a rule, the CLI, MCP) is checked
    /// against this before `init(pid:startedAt:)`, which traps past Int64.
    public static let startedAtRange: ClosedRange<Double> = 1...9e12

    /// The inverse of `startedAt`, for identities carried through JSON.
    /// Exact for every realistic start time: microsecond counts stay far
    /// below 2^53.
    public init(pid: pid_t, startedAt: Double) {
        self.init(pid: pid, startMicroseconds: Int64((startedAt * 1000).rounded()))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.pid, lhs.startMicroseconds) < (rhs.pid, rhs.startMicroseconds)
    }
}

/// One row of the kernel process table.
public struct ProcessRecord: Sendable, Hashable {
    public let identity: ProcessIdentity
    public let parentPid: pid_t
    public let uid: uid_t
    /// `p_comm`: the executable name, truncated by the kernel to 16 bytes.
    public let command: String

    public var pid: pid_t { identity.pid }
}

/// The kernel process table via `sysctl(KERN_PROC_ALL)`: every process,
/// whoever owns it, in one call.
public enum ProcessTable {
    /// Every process. Throws `MeerkatError.processTableUnreadable` when the
    /// kernel does not return the table: an empty list would read as every
    /// process having exited.
    public static func all() throws -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        // The table can grow between sizing and reading; retry with headroom.
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { throw MeerkatError.processTableUnreadable(errno) }
            // There is always at least launchd and this process.
            guard size > 0 else { throw MeerkatError.processTableUnreadable(ESRCH) }
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 64
            var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * MemoryLayout<kinfo_proc>.stride
            let rc = table.withUnsafeMutableBytes { raw in
                sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
            }
            if rc == 0 {
                let count = size / MemoryLayout<kinfo_proc>.stride
                return table.prefix(count).compactMap(Self.record(from:))
            }
            guard errno == ENOMEM else { throw MeerkatError.processTableUnreadable(errno) }
        }
        throw MeerkatError.processTableUnreadable(ENOMEM)
    }

    public static func record(pid: pid_t) -> ProcessRecord? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return record(from: info)
    }

    private static func record(from info: kinfo_proc) -> ProcessRecord? {
        let pid = info.kp_proc.p_pid
        guard pid > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessRecord(
            identity: ProcessIdentity(
                pid: pid,
                startMicroseconds: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
            ),
            parentPid: info.kp_eproc.e_ppid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            command: command
        )
    }
}
