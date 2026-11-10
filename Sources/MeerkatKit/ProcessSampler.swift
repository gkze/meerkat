import Darwin
import Foundation
import Synchronization

/// Per-process counters via `proc_pid_rusage`.
///
/// Unprivileged: works for any process owned by the same user, returns EPERM
/// for others (e.g. WindowServer). Those rows fall back to `ps` for CPU time
/// and carry no footprint, disk or energy counters (`usage` is nil).
public enum ProcessSampler {
    // RUSAGE_INFO_V6 == 6. Hardcoded because the C macro does not always
    // import; the value is ABI-stable and documented in sys/resource.h.
    private static let rusageInfoV6: Int32 = 6

    /// Runs `ps` (a one-shot call per snapshot, not per process). Throws
    /// when it cannot be run, prints what isn't text, or fails without
    /// printing a row, so its rows are not mistaken for processes that are
    /// gone. `ps -p` exits 1 when one of the processes it was given is gone,
    /// and still prints the others.
    private static func ps(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw MeerkatError.cpuTimesUnreadable("/bin/ps could not be run: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            throw MeerkatError.cpuTimesUnreadable("/bin/ps printed something other than UTF-8")
        }
        guard process.terminationStatus == 0 || !output.isEmpty else {
            throw MeerkatError.cpuTimesUnreadable("/bin/ps exited with status \(process.terminationStatus)")
        }
        return output
    }

    // MARK: - Identity cache
    //
    // proc_name() and proc_pidpath() are a syscall each per process. With ~500
    // processes sampled every couple of seconds that dominated the tool's own
    // CPU cost, so both are cached and only fetched for new processes. The key
    // includes the start time, so a reused pid misses the cache; exec keeps
    // the start time, so `invalidateNames(of:)` exists for observers of exec.
    private struct Names: Sendable {
        /// Nil when neither `proc_name`, the path nor `p_comm` gave one.
        let name: String?
        let path: String?
    }

    /// What a row is called when nothing gave the process a name.
    static let unnamed = "?"

    private static let nameCache = Mutex<[ProcessIdentity: Names]>([:])

    /// Drops cached names for `pid` after it called exec.
    public static func invalidateNames(of pid: pid_t) {
        nameCache.withLock { cache in
            for identity in cache.keys where identity.pid == pid { cache[identity] = nil }
        }
    }

    /// Short name and executable path. `proc_name` refuses processes owned by
    /// other users while `proc_pidpath` does not, so the name falls back to
    /// the path's last component, then to the kernel's `p_comm`.
    private static func names(of record: ProcessRecord) -> Names {
        if let cached = nameCache.withLock({ $0[record.identity] }) { return cached }

        let path = executablePath(of: record.pid)
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let nameLength = nameBuffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_name(record.pid, raw.baseAddress, UInt32(raw.count))
        }
        let name =
            nameLength > 0
            ? String(nulTerminated: nameBuffer)
            : path.map { ($0 as NSString).lastPathComponent } ?? record.command

        let resolved = Names(name: name.isEmpty ? nil : name, path: path)
        nameCache.withLock { cache in
            if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
            cache[record.identity] = resolved
        }
        return resolved
    }

    /// `proc_pidpath`, which works for every user's processes.
    public static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro does not import.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = pathBuffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        return pathLength > 0 ? String(nulTerminated: pathBuffer) : nil
    }

    public static func name(of record: ProcessRecord) -> String {
        names(of: record).name ?? unnamed
    }

    public static func path(of record: ProcessRecord) -> String? {
        names(of: record).path
    }

    /// Absolute counters for one process, or nil if it exited or we lack access.
    public static func counters(for record: ProcessRecord) -> ProcessCounters? {
        var info = rusage_info_v6()
        let rc: Int32 = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(record.pid, rusageInfoV6, rebound)
            }
        }
        guard rc == 0 else { return nil }

        let cpu =
            MachTime.seconds(fromTicks: info.ri_user_time)
            + MachTime.seconds(fromTicks: info.ri_system_time)

        let names = names(of: record)
        return ProcessCounters(
            identity: record.identity,
            uid: record.uid,
            name: names.name ?? unnamed,
            path: names.path,
            cpuSeconds: cpu,
            usage: ResourceUsage(
                footprintBytes: info.ri_phys_footprint,
                diskReadBytes: info.ri_diskio_bytesread,
                diskWriteBytes: info.ri_diskio_byteswritten,
                energyNanojoules: info.ri_energy_nj)
        )
    }

    /// Fallback for processes that refuse `proc_pid_rusage` (root-owned daemons
    /// such as WindowServer, fseventsd, mds_stores).
    ///
    /// `ps` exposes cumulative CPU time for every process without privileges,
    /// at 10 ms resolution — coarse per sample, but over a multi-second window
    /// that is well under 1% error. Footprint, disk bytes and energy are
    /// unavailable this way. `pids` limits it to those processes; `ps`
    /// leaves out the ones that are gone.
    public static func psCpuTimes(of pids: [pid_t]? = nil) throws -> [pid_t: (name: String, cpuSeconds: Double)] {
        let selection = pids.map { ["-p", $0.map(String.init).joined(separator: ",")] } ?? ["-A"]
        let out = try ps(selection + ["-o", "pid=,time=,comm="])
        var table: [pid_t: (name: String, cpuSeconds: Double)] = [:]
        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]) else { continue }
            guard let seconds = parseCPUTime(String(fields[1])) else { continue }
            table[pid] = (name: String(fields[2]), cpuSeconds: seconds)
        }
        return table
    }

    /// `[[dd-]hh:]mm:ss[.cc]` -> seconds.
    static func parseCPUTime(_ text: String) -> Double? {
        var s = text
        var days = 0.0
        if let dash = s.firstIndex(of: "-") {
            guard let d = Double(s[s.startIndex..<dash]) else { return nil }
            days = d
            s = String(s[s.index(after: dash)...])
        }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        var seconds = 0.0
        for (index, value) in parts.enumerated() {
            seconds += value * pow(60, Double(parts.count - 1 - index))
        }
        return days * 86400 + seconds
    }

    /// One instant snapshot of every process, timestamped so callers can
    /// derive a true window. Throws when the process table cannot be read,
    /// or when `ps` cannot be run for the processes `proc_pid_rusage` refuses.
    public static func snapshot() throws -> ProcessSnapshot {
        let now = Date()
        let records = try ProcessTable.all()
        var counters: [ProcessIdentity: ProcessCounters] = [:]
        counters.reserveCapacity(records.count)
        var refused: [pid_t: ProcessRecord] = [:]
        for record in records {
            if let c = Self.counters(for: record) {
                counters[record.identity] = c
            } else {
                refused[record.pid] = record
            }
        }
        if !refused.isEmpty { try fill(&counters, refused: refused, from: psCpuTimes()) }
        return ProcessSnapshot(takenAt: now, counters: counters)
    }

    /// Re-reads only `identities`, for refreshing a few displayed rows without
    /// enumerating the whole table. A process the table no longer has under
    /// that identity is in `exited`; one this user may not read is filled
    /// from `ps`, as in `snapshot()`, so being refused never reads as being
    /// gone. Throws when a running process could be read neither way.
    public static func snapshot(
        of identities: some Sequence<ProcessIdentity>
    ) throws -> (snapshot: ProcessSnapshot, exited: Set<ProcessIdentity>) {
        let now = Date()
        var counters: [ProcessIdentity: ProcessCounters] = [:]
        var exited: Set<ProcessIdentity> = []
        var refused: [pid_t: ProcessRecord] = [:]
        for identity in identities {
            // Re-check the identity: the pid may now belong to another process.
            guard let record = ProcessTable.record(of: identity) else {
                exited.insert(identity)
                continue
            }
            if let c = Self.counters(for: record) {
                counters[identity] = c
            } else {
                refused[record.pid] = record
            }
        }
        if !refused.isEmpty {
            try fill(&counters, refused: refused, from: psCpuTimes(of: Array(refused.keys)))
            // A refused process `ps` did not list either exited after the
            // table read or is unreadable; the next read tells which.
            let unread = refused.values.filter { counters[$0.identity] == nil }.map(\.pid)
            guard unread.isEmpty else {
                throw MeerkatError.cpuTimesUnreadable("ps did not report process(es) \(unread.sorted())")
            }
        }
        return (ProcessSnapshot(takenAt: now, counters: counters), exited)
    }

    /// Fills the rows `proc_pid_rusage` refused with the unprivileged
    /// fallback. `ps` runs a few milliseconds after the table read and is
    /// joined by pid; a pid reused inside that gap would attribute one
    /// sample's CPU time to the new process, which the next snapshot's
    /// identity check then discards. `ps` prints the executable path as
    /// `comm`; keep it out of `name`.
    private static func fill(
        _ counters: inout [ProcessIdentity: ProcessCounters], refused: [pid_t: ProcessRecord],
        from times: [pid_t: (name: String, cpuSeconds: Double)]
    ) {
        for (pid, info) in times {
            guard let record = refused[pid] else { continue }
            let names = names(of: record)
            counters[record.identity] = ProcessCounters(
                identity: record.identity,
                uid: record.uid,
                name: names.name ?? (info.name as NSString).lastPathComponent,
                path: names.path ?? (info.name.hasPrefix("/") ? info.name : nil),
                cpuSeconds: info.cpuSeconds,
                usage: nil
            )
        }
    }

    /// Diff two snapshots into per-process deltas, busiest CPU first.
    ///
    /// Pure arithmetic — no syscalls — so callers can snapshot once per tick
    /// instead of blocking for a fixed window. The real elapsed time between
    /// the two snapshots is the window, which keeps rates honest even when
    /// sampling jitters. Rows pair by identity, so a pid that was reused
    /// between the snapshots yields no row instead of a wrapped delta.
    /// Processes that did nothing in the window are omitted unless
    /// `includeIdle` is set.
    public static func deltas(
        previous: ProcessSnapshot,
        current: ProcessSnapshot,
        top: Int = 10,
        includeIdle: Bool = false
    ) -> [ProcessDelta] {
        let window = current.window(since: previous)

        var rows: [ProcessDelta] = []
        rows.reserveCapacity(current.counters.count)

        for (identity, a) in current.counters {
            guard let b = previous.counters[identity] else { continue }
            // Counters are cumulative for one process instance; a decrease
            // means the sample is not comparable, not negative work. Usage
            // is known for the window only when both ends have it.
            let usage = a.usage.flatMap { end in b.usage.map { (end: end, start: $0) } }
            if let (end, start) = usage {
                guard end.diskReadBytes >= start.diskReadBytes, end.diskWriteBytes >= start.diskWriteBytes,
                    end.energyNanojoules >= start.energyNanojoules
                else { continue }
            }
            let cpuDelta = max(a.cpuSeconds - b.cpuSeconds, 0)
            let readDelta = usage.map { Double($0.end.diskReadBytes - $0.start.diskReadBytes) }
            let writeDelta = usage.map { Double($0.end.diskWriteBytes - $0.start.diskWriteBytes) }
            guard includeIdle || cpuDelta > 0 || (readDelta ?? 0) > 0 || (writeDelta ?? 0) > 0 else { continue }

            rows.append(
                ProcessDelta(
                    pid: identity.pid,
                    name: a.name,
                    path: a.path,
                    cpuPct: (cpuDelta / window) * 100.0,
                    cpuSeconds: cpuDelta,
                    windowSeconds: window,
                    footprintMB: usage.map { Double($0.end.footprintBytes) / 1_000_000.0 },
                    diskReadMB: readDelta.map { $0 / 1_000_000.0 },
                    diskWriteMB: writeDelta.map { $0 / 1_000_000.0 },
                    energyJoules: usage.map { Double($0.end.energyNanojoules - $0.start.energyNanojoules) / 1e9 },
                    startedAt: identity.startedAt,
                    uid: a.uid
                ))
        }

        rows.sort { $0.cpuPct > $1.cpuPct }
        return Array(rows.prefix(top))
    }
}
