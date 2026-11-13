import Foundation
import Synchronization

// MARK: - Lifecycle payloads

public struct ProcessSpawnedPayload: RuleViewedPayload, Equatable {
    public let process: ProcessRef

    public func viewed(by view: RuleView) -> Self? { process.visible(to: view) ? self : nil }

    public static var schema: TypeSchema {
        .named("ProcessSpawned", ObjectSchema([.field("process", ProcessRef.self)]))
    }
    public static var examples: [Self] { [Self(process: .example)] }
}

public struct ProcessExitedPayload: RuleViewedPayload, Equatable {
    public let process: ProcessRef
    /// Seconds between start and the observed exit.
    public let lifetimeSeconds: Double

    public func viewed(by view: RuleView) -> Self? { process.visible(to: view) ? self : nil }

    public static var schema: TypeSchema {
        .named(
            "ProcessExited",
            ObjectSchema([
                .field("process", ProcessRef.self),
                .field("lifetimeSeconds", Double.self),
            ]))
    }
    public static var examples: [Self] { [Self(process: .example, lifetimeSeconds: 12.5)] }
}

public struct ProcessExecPayload: RuleViewedPayload, Equatable {
    /// The process after exec: same pid and start time, new image.
    public let process: ProcessRef
    public let previousPath: String?

    public func viewed(by view: RuleView) -> Self? { process.visible(to: view) ? self : nil }

    public static var schema: TypeSchema {
        .named(
            "ProcessExec",
            ObjectSchema([
                .field("process", ProcessRef.self),
                .optional("previousPath", String.self),
            ]))
    }
    public static var examples: [Self] {
        [Self(process: .example, previousPath: "/bin/zsh"), Self(process: .example, previousPath: nil)]
    }
}

extension ProcessRef {
    /// Whether a rule with `view` may see this process: every user's, or
    /// only the one it may observe.
    func visible(to view: RuleView) -> Bool { view.user.map { $0 == uid } ?? true }
}

extension ProcessDelta {
    func visible(to view: RuleView) -> Bool { view.user.map { $0 == uid } ?? true }
}

extension ProcessRef: SchemaDescribed {
    public static var schema: TypeSchema {
        .named(
            "ProcessRef",
            ObjectSchema([
                .field("pid", Int32.self),
                .field("startedAt", Double.self, doc: "Unix epoch milliseconds; with pid, identifies the process."),
                .field("parentPid", Int32.self),
                .field("uid", UInt32.self),
                .field("name", String.self),
                .optional("path", String.self, doc: "Executable path; absent when the kernel did not report one."),
            ]))
    }
}

/// Subscribes a lifecycle event kind to the shared tracker.
private func trackerSource<Payload: EventPayload>(
    _ environment: SourceEnvironment,
    emit: Emitter<Payload>,
    map: @escaping @Sendable (ProcessLifecycleEvent) -> (Payload, ProcessRef)?
) -> any EventSource {
    let token = Mutex<(tracker: ProcessTracker, token: UInt64)?>(nil)
    return ClosureSource(
        start: {
            let tracker = try environment.processTracker.acquire()
            let id = tracker.events.add { event in
                guard let (payload, process) = map(event) else { return }
                let exiting = if case .exited = event { true } else { false }
                emit(payload, origin: tracker.origin(of: process, exiting: exiting))
            }
            token.withLock { $0 = (tracker, id) }
        },
        stop: {
            guard
                let held = token.withLock({ current -> (tracker: ProcessTracker, token: UInt64)? in
                    defer { current = nil }
                    return current
                })
            else { return }
            held.tracker.events.remove(held.token)
            environment.processTracker.release()
        })
}

public enum ProcessSpawnedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "process.spawned",
        "A new process appeared, any user's. Found by rescanning the process table on every observed fork (at most every 50 ms) and every 2 s; a process that starts and exits between two scans is never reported.",
        mechanism: .push, semantics: .occurrence, loss: .lossy,
        observation: .processes,
        source: "kqueue EVFILT_PROC NOTE_FORK, sysctl KERN_PROC_ALL"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<ProcessSpawnedPayload>
    ) throws -> any EventSource {
        trackerSource(environment, emit: emit) { event in
            guard case .spawned(let process) = event else { return nil }
            return (ProcessSpawnedPayload(process: process), process)
        }
    }
}

public enum ProcessExitedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "process.exited",
        "A process exited. Every process known to the tracker reports its exit; the exit status is not available for processes this daemon did not start.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes,
        source: "kqueue EVFILT_PROC NOTE_EXIT"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<ProcessExitedPayload>
    ) throws -> any EventSource {
        trackerSource(environment, emit: emit) { event in
            guard case .exited(let process) = event else { return nil }
            let lifetime = max(nowMilliseconds() - process.startedAt, 0) / 1000
            return (ProcessExitedPayload(process: process, lifetimeSeconds: lifetime), process)
        }
    }
}

public enum ProcessExecEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "process.exec",
        "A process replaced its executable image (exec). Same pid and start time, new path and name.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes,
        source: "kqueue EVFILT_PROC NOTE_EXEC"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<ProcessExecPayload>
    ) throws -> any EventSource {
        trackerSource(environment, emit: emit) { event in
            guard case .exec(let process, let previousPath) = event else { return nil }
            return (ProcessExecPayload(process: process, previousPath: previousPath), process)
        }
    }
}

// MARK: - ProcessDelta as a payload part

extension ProcessDelta: SchemaDescribed {
    /// Bytes read plus written in the window, in decimal MB; 0 when unknown.
    public var diskMB: Double { (diskReadMB ?? 0) + (diskWriteMB ?? 0) }

    /// `windowSeconds`, never zero: what the window's totals are rates over.
    private var rateWindow: Double { max(windowSeconds, ProcessSnapshot.shortestWindow) }

    /// Each total over the window. Nil, like the total, when this user
    /// cannot read the counter.
    public var energyWatts: Double? { energyJoules.map { $0 / rateWindow } }
    public var diskWriteMBps: Double? { diskWriteMB.map { $0 / rateWindow } }
    public var diskReadMBps: Double? { diskReadMB.map { $0 / rateWindow } }
    public var diskMBps: Double { diskMB / rateWindow }
    /// Nil while the network filter is off or cannot account for this
    /// process in the window.
    public var networkInMBps: Double? { networkInMB.map { $0 / rateWindow } }
    public var networkOutMBps: Double? { networkOutMB.map { $0 / rateWindow } }
    public var networkMBps: Double? {
        guard let networkInMB, let networkOutMB else { return nil }
        return (networkInMB + networkOutMB) / rateWindow
    }

    /// Pid plus start time: the process instance; nil for a row from JSON
    /// whose start time no process can have.
    public var identity: ProcessIdentity? { ProcessIdentity(pid: pid, startedAt: startedAt) }

    public static var schema: TypeSchema {
        .named(
            "ProcessUsage",
            ObjectSchema([
                .field("pid", Int32.self),
                .field("name", String.self),
                .optional("path", String.self),
                .field("cpuPct", Double.self, doc: "Percent of one core over the window; sums across processes."),
                .field("cpuSeconds", Double.self),
                .field("windowSeconds", Double.self),
                .optional(
                    "footprintMB", Double.self,
                    doc: "Physical footprint at the end of the window; absent for other users' processes."),
                .optional("diskReadMB", Double.self, doc: "Read during the window; absent for other users' processes."),
                .optional(
                    "diskWriteMB", Double.self, doc: "Written during the window; absent for other users' processes."),
                .optional("energyJoules", Double.self, doc: "Absent for other users' processes."),
                .field("startedAt", Double.self, doc: "Unix epoch milliseconds."),
                .field("uid", UInt32.self),
                .optional(
                    "networkInMB", Double.self,
                    doc:
                        "Received over the network during the window, every user's processes included; absent while the network filter is off (Meerkat › Settings › Network)."
                ),
                .optional(
                    "networkOutMB", Double.self,
                    doc: "Sent over the network during the window; absent while the network filter is off."),
            ]))
    }

    static let example = ProcessDelta(
        pid: 812, name: "mds_stores",
        path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores",
        cpuPct: 63.2, cpuSeconds: 3.16, windowSeconds: 5, footprintMB: 210, diskReadMB: 120, diskWriteMB: 8,
        energyJoules: 1.9, startedAt: 1_792_870_301_000, uid: 0, networkInMB: 0.4, networkOutMB: 0.1
    )
}

// MARK: - process.hot

public struct ProcessHotParameters: NetworkFilterParameters {
    public enum Metric: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case cpuPercent, diskWriteMBps, diskReadMBps, footprintMB, energyWatts
        case networkInMBps, networkOutMBps, networkMBps

        /// nil when the counter is unknown for this process.
        func value(of row: ProcessDelta) -> Double? {
            switch self {
            case .cpuPercent: row.cpuPct
            case .diskWriteMBps: row.diskWriteMBps
            case .diskReadMBps: row.diskReadMBps
            case .footprintMB: row.footprintMB
            case .energyWatts: row.energyWatts
            case .networkInMBps: row.networkInMBps
            case .networkOutMBps: row.networkOutMBps
            case .networkMBps: row.networkMBps
            }
        }

        /// Whether the metric comes from the network filter, without which a
        /// subscription to it is refused rather than silently never firing.
        var needsNetworkFilter: Bool {
            switch self {
            case .networkInMBps, .networkOutMBps, .networkMBps: true
            case .cpuPercent, .diskWriteMBps, .diskReadMBps, .footprintMB, .energyWatts: false
            }
        }
    }

    public var metric: Metric
    public var above: Double
    public var sustainSeconds: Double
    public var interval: Double

    public var needsNetworkFilter: Bool { metric.needsNetworkFilter }

    public static let defaultSustainSeconds = 0.0
    public static let defaultInterval = 5.0

    public init(
        metric: Metric, above: Double, sustainSeconds: Double = defaultSustainSeconds,
        interval: Double = defaultInterval
    ) {
        self.metric = metric
        self.above = above
        self.sustainSeconds = sustainSeconds
        self.interval = interval
    }

    public static var objectSchema: ObjectSchema {
        ObjectSchema([
            .field(
                "metric", Metric.self,
                doc: "Which per-process value to watch. Rates are per second over the sample window."),
            ObjectSchema.Field(
                "above", .bounded(NumberBounds(minimum: 0)),
                doc: "Threshold; the episode starts when the value stays above it."),
            ObjectSchema.Field(
                "sustainSeconds", .bounded(NumberBounds(0...86_400)), default: .number(defaultSustainSeconds),
                doc: "How long the value must stay above `above`; 0 is one sample"),
            ObjectSchema.Field(
                "interval", .bounded(NumberBounds(1...3600)), default: .number(defaultInterval),
                doc: "Seconds between process-table samples"),
        ])
    }

    public static var examples: [Self] {
        [Self(metric: .cpuPercent, above: 80, sustainSeconds: 30), Self(metric: .diskWriteMBps, above: 50)]
    }
}

public struct ProcessHotPayload: RuleViewedPayload, Equatable {
    public enum Phase: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        /// The value stayed above the threshold for `sustainSeconds`.
        case started
        /// The value fell back to or below the threshold, or the process exited.
        case ended
    }

    public let phase: Phase
    public let metric: ProcessHotParameters.Metric
    public let value: Double
    public let threshold: Double
    /// Seconds the value has been above the threshold, as of this event.
    public let aboveForSeconds: Double
    public let process: ProcessDelta

    public func viewed(by view: RuleView) -> Self? { process.visible(to: view) ? self : nil }

    public static var schema: TypeSchema {
        .named(
            "ProcessHot",
            ObjectSchema([
                .field("phase", Phase.self),
                .field("metric", ProcessHotParameters.Metric.self),
                .field("value", Double.self, doc: "The metric's latest value."),
                .field("threshold", Double.self),
                .field("aboveForSeconds", Double.self),
                .init("process", ProcessDelta.schema),
            ]))
    }

    public static var examples: [Self] {
        [Self(phase: .started, metric: .cpuPercent, value: 92, threshold: 80, aboveForSeconds: 30, process: .example)]
    }
}

/// The episode state machine behind `process.hot`, free of I/O.
struct HotProcessDetector: Sendable {
    let parameters: ProcessHotParameters
    private var aboveSince: [ProcessIdentity: (since: Double, inEpisode: Bool, last: ProcessDelta, value: Double)] =
        [:]

    /// Feed one sample: every live process's usage over the latest window
    /// (idle processes included) at `now` seconds. Returns the episodes that
    /// started or ended.
    mutating func update(rows: [ProcessDelta], now: Double) -> [ProcessHotPayload] {
        var output: [ProcessHotPayload] = []
        var seen = Set<ProcessIdentity>()

        for row in rows {
            guard let identity = row.identity else { continue }
            seen.insert(identity)
            // An unknown value is not above the threshold.
            let value = parameters.metric.value(of: row)
            if let value, value > parameters.above {
                var entry = aboveSince[identity] ?? (since: now, inEpisode: false, last: row, value: value)
                entry.last = row
                entry.value = value
                if !entry.inEpisode, now - entry.since >= parameters.sustainSeconds {
                    entry.inEpisode = true
                    output.append(payload(.started, row: row, value: value, since: entry.since, now: now))
                }
                aboveSince[identity] = entry
            } else if let entry = aboveSince.removeValue(forKey: identity), entry.inEpisode {
                output.append(payload(.ended, row: row, value: value ?? entry.value, since: entry.since, now: now))
            }
        }

        // Exited processes end their episodes.
        for (identity, entry) in aboveSince where !seen.contains(identity) {
            aboveSince[identity] = nil
            if entry.inEpisode {
                output.append(
                    payload(
                        .ended, row: entry.last, value: entry.value,
                        since: entry.since, now: now))
            }
        }
        return output
    }

    private func payload(
        _ phase: ProcessHotPayload.Phase, row: ProcessDelta, value: Double,
        since: Double, now: Double
    ) -> ProcessHotPayload {
        ProcessHotPayload(
            phase: phase, metric: parameters.metric, value: value, threshold: parameters.above,
            aboveForSeconds: now - since, process: row)
    }
}

public enum ProcessHotEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "process.hot",
        "A process's CPU, disk, memory, energy or network use stayed above a threshold (phase \"started\"), or stopped doing so (\"ended\"). Processes owned by other users report CPU and network only. The network metrics need the network filter (Meerkat › Settings › Network); without it a subscription to one is refused.",
        mechanism: .derived, semantics: .occurrence, loss: .lossy,
        observation: .processes,
        source: "proc_pid_rusage, ps (other users' CPU time), the network filter (network metrics)"
    )

    public static func makeSource(
        _ parameters: ProcessHotParameters, environment: SourceEnvironment,
        emit: Emitter<ProcessHotPayload>
    ) throws -> any EventSource {
        if parameters.metric.needsNetworkFilter {
            do {
                _ = try environment.networkFilter.totals(wantsHosts: false)
            } catch {
                throw EventError.sourceUnavailable("process.hot on \(parameters.metric.rawValue): \(error)")
            }
        }
        let state = Mutex<(previous: ProcessSnapshot?, detector: HotProcessDetector)>(
            (nil, HotProcessDetector(parameters: parameters))
        )
        return PollingSource(label: "process-hot", interval: parameters.interval, failingThrough: emit) {
            // Up to half an interval old: shared with process.top's ranking.
            // An unreadable table skips the tick (an empty snapshot would end
            // every episode), as PollingSource does with any failure.
            let current = try environment.processSnapshots.current(
                maxAge: parameters.interval / 2, network: environment.networkFilter)
            let output = state.withLock { state -> [ProcessHotPayload] in
                defer { state.previous = current }
                guard let previous = state.previous else { return [] }
                let rows = ProcessSampler.deltas(previous: previous, current: current, top: .max, includeIdle: true)
                return state.detector.update(rows: rows, now: current.takenAt.timeIntervalSince1970)
            }
            for payload in output { emit(payload) }
        }
    }
}

// MARK: - process.top

public struct ProcessTopParameters: EventParameters {
    /// Seconds between refreshes of the ranked rows.
    public var interval: Double
    /// Seconds between full re-rankings of every process.
    public var rankInterval: Double
    public var count: Int
    public var ioCount: Int
    /// Rows ranked by memory footprint; 0 leaves `memory` empty.
    public var memoryCount: Int

    public static let defaultInterval = 1.0
    public static let defaultRankInterval = 5.0
    public static let defaultCount = 5
    public static let defaultIOCount = 3
    public static let defaultMemoryCount = 0
    /// Seconds between refreshes.
    static let intervalRange = 0.5...60.0
    static let intervalBounds = NumberBounds(intervalRange)
    /// Seconds between rankings, and the most a listing (`process.list`)
    /// may wait: a listing is one ranking's work.
    static let rankIntervalMaximum = 600.0

    public init(
        interval: Double = defaultInterval, rankInterval: Double = defaultRankInterval, count: Int = defaultCount,
        ioCount: Int = defaultIOCount, memoryCount: Int = defaultMemoryCount
    ) {
        self.interval = interval
        self.rankInterval = rankInterval
        self.count = count
        self.ioCount = ioCount
        self.memoryCount = memoryCount
    }

    public func validateRelations() throws {
        guard rankInterval >= interval else {
            throw EventError.invalidParameters(
                "rankInterval must be at least interval (\(NumberBounds.format(interval)))")
        }
    }

    public static var objectSchema: ObjectSchema {
        typealias Field = ObjectSchema.Field
        return ObjectSchema([
            Field(
                "interval", .bounded(intervalBounds), default: .number(defaultInterval),
                doc: "Seconds between refreshes of the ranked rows"),
            Field(
                "rankInterval",
                .bounded(NumberBounds(intervalRange.lowerBound...rankIntervalMaximum)),
                default: .number(defaultRankInterval), doc: "Seconds between full re-rankings, at least `interval`"),
            Field(
                "count", .bounded(.integer(1...100)), default: .number(Double(defaultCount)),
                doc: "Rows ranked by CPU"),
            Field(
                "ioCount", .bounded(.integer(0...100)), default: .number(Double(defaultIOCount)),
                doc: "Rows ranked by disk I/O"),
            Field(
                "memoryCount", .bounded(.integer(0...100)), default: .number(Double(defaultMemoryCount)),
                doc:
                    "Rows ranked by memory footprint. Only processes whose footprint this user can read (their own) rank."
            ),
        ])
    }

    public static var examples: [Self] { [Self()] }
}

public struct ProcessTopPayload: RuleViewedPayload, Equatable {
    /// Busiest by CPU at the last ranking, each re-read every `interval`
    /// until the next ranking or its exit.
    public let cpu: [ProcessDelta]
    /// Busiest by bytes read plus written over the last ranking window.
    public let io: [ProcessDelta]
    /// Largest memory footprints at the last ranking, idle processes
    /// included; empty unless `memoryCount` asks for rows.
    public let memory: [ProcessDelta]
    /// Machine-wide disk rates over the last ranking window, summed over the
    /// processes whose counters are readable.
    public let diskReadMBps: Double
    public let diskWriteMBps: Double
    public let rankWindowSeconds: Double
    /// Unix epoch milliseconds of the ranking `io` and the disk rates come
    /// from; it changes once per `rankInterval`, while `cpu` refreshes every
    /// `interval`.
    public let rankedAt: Double

    /// The rows of processes `view` may see. The disk rates stay: they sum
    /// only counters this user can read, which are its own processes'.
    public func viewed(by view: RuleView) -> Self? {
        guard view.user != nil else { return self }
        return Self(
            cpu: cpu.filter { $0.visible(to: view) }, io: io.filter { $0.visible(to: view) },
            memory: memory.filter { $0.visible(to: view) }, diskReadMBps: diskReadMBps,
            diskWriteMBps: diskWriteMBps, rankWindowSeconds: rankWindowSeconds, rankedAt: rankedAt)
    }

    public static var schema: TypeSchema {
        .named(
            "ProcessTop",
            ObjectSchema([
                .init("cpu", .array(ProcessDelta.schema)),
                .init("io", .array(ProcessDelta.schema)),
                .init(
                    "memory", .array(ProcessDelta.schema),
                    doc: "Largest footprints at the last ranking; empty unless memoryCount is set."),
                .field("diskReadMBps", Double.self),
                .field("diskWriteMBps", Double.self),
                .field("rankWindowSeconds", Double.self),
                .field(
                    "rankedAt", Double.self,
                    doc: "When `io` and the disk rates were ranked; changes once per rankInterval."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                cpu: [.example], io: [.example], memory: [.example], diskReadMBps: 24, diskWriteMBps: 1.6,
                rankWindowSeconds: 5,
                rankedAt: 1_792_887_400_000)
        ]
    }
}

/// Two clocks, as the dashboard has always sampled: a full enumeration every
/// `rankInterval` decides who is busy, and only those rows are re-read every
/// `interval`. Enumerating ~1000 processes at display speed is what made the
/// first dashboard cost a quarter of a core.
final class ProcessTopSource: EventSource {
    private let parameters: ProcessTopParameters
    private let emit: Emitter<ProcessTopPayload>
    /// Ranking and refresh run on this one queue, so a refresh never
    /// interleaves with a ranking that replaces the rows it read.
    private let queue = DispatchQueue(label: "com.gkze.meerkat.process-top", qos: .utility)
    private let state = Mutex<State>(State())
    /// The ranking timer, then the refresh timer.
    private let timers = Mutex<[PollingSource]>([])

    private struct State {
        var lastFull: ProcessSnapshot?
        var focusBaseline: ProcessSnapshot?
        var focus: [ProcessIdentity] = []
        var cpu: [ProcessDelta] = []
        var io: [ProcessDelta] = []
        var memory: [ProcessDelta] = []
        var rates = (read: 0.0, write: 0.0, window: 0.0)
        var rankedAt = 0.0
    }

    private let environment: SourceEnvironment

    init(parameters: ProcessTopParameters, environment: SourceEnvironment, emit: Emitter<ProcessTopPayload>) {
        self.parameters = parameters
        self.environment = environment
        self.emit = emit
    }

    func start() throws {
        let emit = self.emit
        let ranking = PollingSource(
            label: "process-top", interval: parameters.rankInterval, queue: queue, failingThrough: emit
        ) { [weak self] in try self?.rank() }
        let refresh = PollingSource(
            label: "process-top", interval: parameters.interval, fireImmediately: false, queue: queue,
            failingThrough: emit
        ) { [weak self] in try self?.refresh() }
        timers.withLock { $0 = [ranking, refresh] }
        try ranking.start()
        try refresh.start()
    }

    func stop() {
        let timers = self.timers.withLock { timers -> [PollingSource] in
            defer { timers = [] }
            return timers
        }
        for timer in timers { timer.stop() }
    }

    /// The ranking's failures, then the refresh's.
    var detail: String? {
        let details = timers.withLock { $0.compactMap(\.detail) }
        return details.isEmpty ? nil : details.joined(separator: "; ")
    }

    private func rank() throws {
        // Up to half a ranking interval old: shared with process.hot. An
        // unreadable table skips this ranking (the previous one stands), as
        // PollingSource does with any failure.
        let snapshot = try environment.processSnapshots.current(
            maxAge: parameters.rankInterval / 2, network: environment.networkFilter)
        let payload = state.withLock { state -> ProcessTopPayload? in
            defer { state.lastFull = snapshot }
            guard let previous = state.lastFull else { return nil }
            let deltas = ProcessSampler.deltas(previous: previous, current: snapshot, top: .max)
            let window = snapshot.window(since: previous)
            // Of the processes whose counters are known.
            state.rates = (
                deltas.reduce(0) { $0 + ($1.diskReadMB ?? 0) } / window,
                deltas.reduce(0) { $0 + ($1.diskWriteMB ?? 0) } / window,
                window
            )
            state.rankedAt = snapshot.takenAt.timeIntervalSince1970 * 1000
            state.cpu = Array(deltas.prefix(parameters.count))
            state.io = Array(
                deltas.filter { $0.diskMB > 0 }
                    .sorted { $0.diskMB > $1.diskMB }
                    .prefix(parameters.ioCount))
            if parameters.memoryCount > 0 {
                // Idle processes too: the largest footprints are often apps
                // that did nothing this window.
                state.memory = Array(
                    ProcessSampler.deltas(previous: previous, current: snapshot, top: .max, includeIdle: true)
                        .filter { $0.footprintMB != nil }
                        .sorted { ($0.footprintMB ?? 0) > ($1.footprintMB ?? 0) }
                        .prefix(parameters.memoryCount))
            }
            state.focus = state.cpu.compactMap(\.identity)
            let focus = Set(state.focus)
            state.focusBaseline = ProcessSnapshot(
                takenAt: snapshot.takenAt,
                counters: snapshot.counters.filter { focus.contains($0.key) })
            return makePayload(state)
        }
        if let payload { emit(payload) }
    }

    /// Re-reads the ranked rows, idle or not, so each stays until the next
    /// ranking unless it exits; other users' rows are read through `ps`, as
    /// the ranking reads them, whose 10 ms resolution would otherwise drop
    /// a lightly busy one from refresh to refresh. A refresh that cannot
    /// read a running row is skipped, so a row is never dropped for being
    /// unreadable, and the next one measures from the last good read.
    private func refresh() throws {
        let (baseline, focus) = state.withLock { ($0.focusBaseline, $0.focus) }
        guard let baseline, !focus.isEmpty else { return }
        let current = try ProcessSampler.snapshot(of: focus).snapshot
        let rows = ProcessSampler.deltas(previous: baseline, current: current, top: .max, includeIdle: true)
        let payload = state.withLock { state -> ProcessTopPayload in
            state.cpu = Array(rows.prefix(parameters.count))
            state.focusBaseline = current
            return makePayload(state)
        }
        emit(payload)
    }

    private func makePayload(_ state: State) -> ProcessTopPayload {
        ProcessTopPayload(
            cpu: state.cpu, io: state.io, memory: state.memory, diskReadMBps: state.rates.read,
            diskWriteMBps: state.rates.write, rankWindowSeconds: state.rates.window,
            rankedAt: state.rankedAt)
    }
}

public enum ProcessTopEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "process.top",
        "The busiest processes by CPU and by disk I/O, optionally the largest by memory, with machine-wide disk rates. The first event arrives after one ranking interval.",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .processes,
        source: "proc_pid_rusage, ps (other users' CPU time)"
    )

    public static func makeSource(
        _ parameters: ProcessTopParameters, environment: SourceEnvironment,
        emit: Emitter<ProcessTopPayload>
    ) throws -> any EventSource {
        ProcessTopSource(parameters: parameters, environment: environment, emit: emit)
    }
}

// MARK: - process.list

public struct ProcessListPayload: RuleViewedPayload, Equatable {
    /// Every process over the last interval, idle ones included, busiest CPU
    /// first.
    public let processes: [ProcessDelta]

    public func viewed(by view: RuleView) -> Self? {
        guard view.user != nil else { return self }
        return Self(processes: processes.filter { $0.visible(to: view) })
    }

    public static var schema: TypeSchema {
        .named(
            "ProcessList",
            ObjectSchema([
                .init(
                    "processes", .array(ProcessDelta.schema),
                    doc: "Every process over the last interval, idle ones included, busiest CPU first.")
            ]))
    }

    public static var examples: [Self] { [Self(processes: [.example])] }
}

/// The whole table, for listings that sort it themselves (the app's resource
/// pages). One enumeration per interval, never a refresh between: re-reading
/// every row at display speed is the cost `process.top`'s two clocks avoid.
/// Snapshots are shared with `process.top` and `process.hot` through the
/// environment's cache, so a matching interval adds no enumeration.
final class ProcessListSource: EventSource {
    private let parameters: IntervalParameters<ProcessListEvent>
    private let environment: SourceEnvironment
    private let emit: Emitter<ProcessListPayload>
    private let previous = Mutex<ProcessSnapshot?>(nil)
    private let timer = Mutex<PollingSource?>(nil)

    init(
        parameters: IntervalParameters<ProcessListEvent>, environment: SourceEnvironment,
        emit: Emitter<ProcessListPayload>
    ) {
        self.parameters = parameters
        self.environment = environment
        self.emit = emit
    }

    func start() throws {
        let timer = PollingSource(label: "process-list", interval: parameters.interval, failingThrough: emit) {
            [weak self] in try self?.list()
        }
        self.timer.withLock { $0 = timer }
        try timer.start()
    }

    func stop() {
        timer.withLock { timer -> PollingSource? in
            defer { timer = nil }
            return timer
        }?.stop()
    }

    var detail: String? { timer.withLock { $0 }?.detail }

    private func list() throws {
        let snapshot = try environment.processSnapshots.current(
            maxAge: parameters.interval / 2, network: environment.networkFilter)
        let previous = self.previous.withLock { previous -> ProcessSnapshot? in
            defer { previous = snapshot }
            return previous
        }
        guard let previous else { return }
        emit(
            ProcessListPayload(
                processes: ProcessSampler.deltas(previous: previous, current: snapshot, top: .max, includeIdle: true)))
    }
}

public enum ProcessListEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 5.0
    /// `process.top`'s ranking bounds: a listing is one ranking's work.
    public static let intervalRange =
        ProcessTopParameters.intervalRange.lowerBound...ProcessTopParameters.rankIntervalMaximum

    public static let descriptor = EventDescriptor(
        "process.list",
        "Every process, idle ones included, with its CPU, memory, disk and energy over the last interval, busiest CPU first. Processes owned by other users report CPU only. For the few busiest, `process.top` is cheaper. The first event arrives after one interval.",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .processes,
        source: "proc_pid_rusage, ps (other users' CPU time)"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<ProcessListEvent>, environment: SourceEnvironment,
        emit: Emitter<ProcessListPayload>
    ) throws -> any EventSource {
        ProcessListSource(parameters: parameters, environment: environment, emit: emit)
    }
}

// MARK: - process.sample

public struct ProcessSampleParameters: ProcessObservingParameters {
    public var pid: Int32
    /// The instance's start time, epoch milliseconds, as `ProcessDelta` and
    /// `ProcessRef` report it: a reused pid is another process, and is not
    /// followed.
    public var startedAt: Double
    /// Seconds between samples.
    public var interval: Double

    public static let defaultInterval = 1.0

    public init(pid: Int32, startedAt: Double, interval: Double = defaultInterval) {
        self.pid = pid
        self.startedAt = startedAt
        self.interval = interval
    }

    public var observedProcess: ProcessIdentity? { ProcessIdentity(pid: pid, startedAt: startedAt) }

    public static var objectSchema: ObjectSchema {
        ObjectSchema([
            ObjectSchema.Field("pid", .bounded(.integer(1...Int(Int32.max))), doc: "The process to follow."),
            ObjectSchema.Field(
                "startedAt", .bounded(NumberBounds(ProcessIdentity.startedAtRange)),
                doc: "Its start time, epoch milliseconds (ProcessUsage.startedAt), so a reused pid is not followed."
            ),
            ObjectSchema.Field(
                "interval", .bounded(NumberBounds(0.5...60)), default: .number(defaultInterval),
                doc: "Seconds between samples"),
        ])
    }

    public static var examples: [Self] { [Self(pid: 4242, startedAt: 1_792_887_367_209.92)] }
}

public struct ProcessSamplePayload: RuleViewedPayload, Equatable {
    /// The process over the last interval, idle or not; nil once it exited.
    public let process: ProcessDelta?
    public let running: Bool

    /// The exit report carries no process, so it stays: it says only that
    /// the process the rule named is gone.
    public func viewed(by view: RuleView) -> Self? { process.map { $0.visible(to: view) } ?? true ? self : nil }

    public static var schema: TypeSchema {
        .named(
            "ProcessSample",
            ObjectSchema([
                .optional("process", ProcessDelta.self, doc: "The last interval's usage; absent once it exited."),
                .field("running", Bool.self, doc: "False once, when the process exited; no events follow."),
            ]))
    }

    public static var examples: [Self] { [Self(process: .example, running: true), Self(process: nil, running: false)] }
}

/// Re-reads one process every `interval`, the way `process.top` refreshes
/// its rows, so following a process costs one `proc_pid_rusage` (or, for
/// another user's process, one `ps`) per sample rather than a full
/// enumeration. Reports the exit once, when the process table no longer
/// has the process, then stops; a sample that cannot read a running process
/// is skipped, under `PollingSource`'s failure policy.
final class ProcessSampleSource: EventSource {
    private let parameters: ProcessSampleParameters
    private let emit: Emitter<ProcessSamplePayload>
    private let identity: ProcessIdentity
    private let state = Mutex<(previous: ProcessSnapshot?, timer: PollingSource?)>((nil, nil))

    init(parameters: ProcessSampleParameters, identity: ProcessIdentity, emit: Emitter<ProcessSamplePayload>) {
        self.parameters = parameters
        self.emit = emit
        self.identity = identity
    }

    func start() throws {
        let timer = PollingSource(label: "process-sample", interval: parameters.interval, failingThrough: emit) {
            [weak self] in try self?.sample()
        }
        state.withLock { $0.timer = timer }
        try timer.start()
    }

    func stop() {
        let timer = state.withLock { state -> PollingSource? in
            defer { state.timer = nil }
            return state.timer
        }
        timer?.stop()
    }

    var detail: String? { state.withLock { $0.timer }?.detail }

    private func sample() throws {
        let (current, exited) = try ProcessSampler.snapshot(of: [identity])
        guard exited.isEmpty else {
            stop()
            emit(ProcessSamplePayload(process: nil, running: false))
            return
        }
        let previous = state.withLock { state -> ProcessSnapshot? in
            defer { state.previous = current }
            return state.previous
        }
        guard let previous,
            let row = ProcessSampler.deltas(previous: previous, current: current, top: .max, includeIdle: true).first
        else { return }
        emit(ProcessSamplePayload(process: row, running: true))
    }
}

public enum ProcessSampleEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "process.sample",
        "One process's CPU, memory, disk and energy every `interval`, idle or not, until it exits; then one event with `running: false`. The first sample arrives after one interval.",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .processes,
        source: "proc_pid_rusage, ps (other users' CPU time)"
    )

    public static func makeSource(
        _ parameters: ProcessSampleParameters, environment: SourceEnvironment,
        emit: Emitter<ProcessSamplePayload>
    ) throws -> any EventSource {
        // The schema bounds `startedAt`, so only parameters built in Swift
        // can name no process.
        guard let identity = parameters.observedProcess else {
            throw EventError.invalidParameters("startedAt: \(parameters.startedAt) is not a process start time")
        }
        return ProcessSampleSource(parameters: parameters, identity: identity, emit: emit)
    }
}
