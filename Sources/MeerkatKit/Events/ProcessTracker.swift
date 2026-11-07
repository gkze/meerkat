import Darwin
import Foundation
import Synchronization

/// What the tracker observed about one process.
enum ProcessLifecycleEvent: Sendable, Equatable {
    case spawned(ProcessRef)
    case exited(ProcessRef)
    case exec(ProcessRef, previousPath: String?)
}

/// Watches every process on the system for exit, fork and exec.
///
/// kqueue `EVFILT_PROC` attaches to any pid without privileges, including
/// root's. Forks carry no child pid on macOS, so each `NOTE_FORK` triggers a
/// rescan of the process table (one `sysctl`), which is how new processes are
/// found; a slow periodic rescan catches anything a missed fork would hide.
/// A process that both starts and exits between two rescans is never seen,
/// which is why `process.spawned` is marked lossy while `process.exited` is
/// not (for processes the tracker already knew).
final class ProcessTracker: SharedResource {
    let events = Broadcaster<ProcessLifecycleEvent>()

    private let ownProcesses: OwnProcesses
    private let queue = DispatchQueue(label: "com.gkze.meerkat.process-tracker", qos: .utility)
    private let state = Mutex<State>(State())

    private struct State {
        var kqueue: Int32 = -1
        var known: [pid_t: ProcessRef] = [:]
        var readSource: DispatchSourceBox?
        var periodic: DispatchSourceBox?
        var rescanPending = false
    }

    /// Safety-net rescan interval; forks trigger rescans immediately.
    static let periodicRescan: DispatchTimeInterval = .seconds(2)

    init(ownProcesses: OwnProcesses) {
        self.ownProcesses = ownProcesses
    }

    func start() throws {
        // The first scan registers every existing process without reporting
        // them as spawned: they were already running. Without it the next
        // scan would report every process on the machine as spawned, so a
        // table that can't be read fails the start instead of skipping.
        let existing: [ProcessRecord]
        do {
            existing = try ProcessTable.all()
        } catch {
            throw EventError.sourceUnavailable("the process table could not be read: \(error)")
        }
        let kq = kqueue()
        guard kq >= 0 else { throw EventError.sourceUnavailable("kqueue() failed: errno \(errno)") }

        let read = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        let periodic = DispatchSource.makeTimerSource(queue: queue)
        periodic.schedule(
            deadline: .now() + Self.periodicRescan, repeating: Self.periodicRescan, leeway: .milliseconds(500))
        periodic.setEventHandler { [weak self] in self?.rescan() }

        state.withLock { state in
            state.kqueue = kq
            state.readSource = DispatchSourceBox(value: read)
            state.periodic = DispatchSourceBox(value: periodic)
        }
        queue.sync { register(existing, reporting: false) }
        read.resume()
        periodic.resume()
    }

    func stop() {
        let (read, periodic, kq) = state.withLock { state -> (DispatchSourceBox?, DispatchSourceBox?, Int32) in
            defer {
                state = State()
            }
            return (state.readSource, state.periodic, state.kqueue)
        }
        periodic?.value.cancel()
        read?.value.setCancelHandler { if kq >= 0 { close(kq) } }
        read?.value.cancel()
        if read == nil, kq >= 0 { close(kq) }
    }

    /// The tracker's current view of a pid, for events that want names.
    func process(_ pid: pid_t) -> ProcessRef? {
        state.withLock { $0.known[pid] }
    }

    /// `meerkat` for processes the daemon spawned, for their direct
    /// children, and for the exit of a process it asked to end.
    func origin(of process: ProcessRef, exiting: Bool = false) -> EventOrigin {
        if ownProcesses.contains(process.identity) { return .meerkat }
        if exiting, ownProcesses.expectsExit(of: process.identity) { return .meerkat }
        guard let parent = state.withLock({ $0.known[process.parentPid] }) else { return .system }
        return ownProcesses.contains(parent.identity) ? .meerkat : .system
    }

    // MARK: - Queue-confined work

    private func drain() {
        let kq = state.withLock { $0.kqueue }
        guard kq >= 0 else { return }
        var buffer: [kevent] = Array(repeating: kevent(), count: 256)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        var forked = false
        while true {
            let count = kevent(kq, nil, 0, &buffer, Int32(buffer.count), &timeout)
            guard count > 0 else { break }
            for event in buffer.prefix(Int(count)) {
                let pid = pid_t(event.ident)
                if event.fflags & UInt32(NOTE_EXIT) != 0 {
                    handleExit(pid)
                } else {
                    if event.fflags & UInt32(NOTE_EXEC) != 0 { handleExec(pid) }
                    if event.fflags & UInt32(NOTE_FORK) != 0 { forked = true }
                }
            }
            if count < Int32(buffer.count) { break }
        }
        if forked { scheduleRescan() }
    }

    /// Coalesces fork storms (a build forking hundreds of compilers a second)
    /// into at most one table scan per `forkRescanDelay`.
    static let forkRescanDelay: DispatchTimeInterval = .milliseconds(50)

    private func scheduleRescan() {
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.rescanPending else { return false }
            state.rescanPending = true
            return true
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + Self.forkRescanDelay) { [weak self] in
            guard let self else { return }
            self.state.withLock { $0.rescanPending = false }
            self.rescan()
        }
    }

    private func handleExit(_ pid: pid_t) {
        guard let process = state.withLock({ $0.known.removeValue(forKey: pid) }) else { return }
        events.send(.exited(process))
        ownProcesses.remove(process.identity)
    }

    private func handleExec(_ pid: pid_t) {
        ProcessSampler.invalidateNames(of: pid)
        guard let record = ProcessTable.record(pid: pid) else { return }
        let updated = ProcessRef(record: record)
        let previous = state.withLock { state -> ProcessRef? in
            defer { state.known[pid] = updated }
            return state.known[pid]
        }
        events.send(.exec(updated, previousPath: previous?.path))
    }

    private func rescan() {
        // Without the table nothing can be compared: skip this scan rather
        // than report every known process as exited. The next fork rescans.
        guard let records = try? ProcessTable.all() else { return }
        register(records, reporting: true)
    }

    /// Compares `records`, a read of the whole table, with what is known.
    private func register(_ records: [ProcessRecord], reporting: Bool) {
        let (kq, known) = state.withLock { ($0.kqueue, $0.known) }
        guard kq >= 0 else { return }

        let current = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var reports: [ProcessLifecycleEvent] = []

        // Known processes that vanished without an exit note (or whose pid
        // now belongs to someone else) exited unobserved.
        for (pid, process) in known {
            if let record = current[pid], record.identity == process.identity { continue }
            state.withLock { _ = $0.known.removeValue(forKey: pid) }
            if reporting { reports.append(.exited(process)) }
        }

        for record in records {
            if let existing = known[record.pid], existing.identity == record.identity { continue }
            let process = ProcessRef(record: record)
            var change: kevent = kevent(
                ident: UInt(record.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_FORK) | UInt32(NOTE_EXEC), data: 0, udata: nil
            )
            let registered = kevent(kq, &change, 1, nil, 0, nil) == 0
            if registered {
                state.withLock { $0.known[record.pid] = process }
                if reporting { reports.append(.spawned(process)) }
            } else if reporting, errno == ESRCH {
                // Exited between the table read and registration.
                reports.append(.spawned(process))
                reports.append(.exited(process))
            }
        }

        for report in reports { events.send(report) }
    }
}

/// A process as reported in events.
public struct ProcessRef: Sendable, Equatable, Codable {
    public let pid: Int32
    /// Unix epoch milliseconds; with `pid` this identifies the process.
    public let startedAt: Double
    public let parentPid: Int32
    public let uid: UInt32
    public let name: String
    public let path: String?

    var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startedAt: startedAt)
    }

    init(record: ProcessRecord) {
        pid = record.pid
        startedAt = record.identity.startedAt
        parentPid = record.parentPid
        uid = record.uid
        name = ProcessSampler.name(of: record)
        path = ProcessSampler.path(of: record)
    }

    public init(pid: Int32, startedAt: Double, parentPid: Int32, uid: UInt32, name: String, path: String?) {
        self.pid = pid
        self.startedAt = startedAt
        self.parentPid = parentPid
        self.uid = uid
        self.name = name
        self.path = path
    }

    static let example = ProcessRef(
        pid: 4242, startedAt: 1_792_887_367_209.92, parentPid: 1, uid: 501,
        name: "node", path: "/opt/homebrew/bin/node")
}
