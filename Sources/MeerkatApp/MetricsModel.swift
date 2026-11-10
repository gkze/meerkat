import AppKit
import Foundation
import MeerkatIPC
import MeerkatKit
import Observation

/// A series' recent samples, each numbered in its own sequence. The number
/// gives a chart a stable mark identity, so a new sample scrolls the series
/// instead of re-valuing every slot in place, and it is what `SlidingPlot`
/// counts: the series must number its samples one by one to glide.
struct RollingSeries<Value> {
    struct Point: Identifiable {
        let id: Int
        let value: Value
    }

    private(set) var points: [Point] = []
    /// The last `StickyTop.memory` samples that scrolled out of `points`,
    /// oldest first: a chart's scale still remembers them for a while.
    private(set) var departed: [Point] = []
    /// How many samples the series keeps: the window a chart draws, full or
    /// not.
    private(set) var capacity: Int
    /// Seconds between samples.
    private(set) var spacing: Double
    private var sequence = 0

    var last: Value? { points.last?.value }

    /// The time the window covers, which a chart's axis names.
    var span: Double { Double(capacity) * spacing }

    /// What a chart draws: `points` after the newest departed samples
    /// `SlidingPlotView.spare` counts, which cover the left edge while a
    /// glide is cut short.
    var drawn: [Point] { departed.suffix(SlidingPlotView.spare) + points }

    init(capacity: Int, spacing: Double) {
        self.capacity = capacity
        self.spacing = spacing
    }

    private init(points: [Point], departed: [Point], capacity: Int, spacing: Double, sequence: Int) {
        self.points = points
        self.departed = departed
        self.capacity = capacity
        self.spacing = spacing
        self.sequence = sequence
    }

    mutating func append(_ value: Value) {
        sequence += 1
        points.append(Point(id: sequence, value: value))
        guard points.count > capacity else { return }
        departed += points.prefix(points.count - capacity)
        points.removeFirst(points.count - capacity)
        if departed.count > StickyTop.memory { departed.removeFirst(departed.count - StickyTop.memory) }
    }

    /// Empties the series. Numbering goes on, so a mark never reuses an id.
    mutating func clear() {
        points = []
        departed = []
    }

    /// Empties the series for samples `spacing` apart, `capacity` of them:
    /// two spacings never share a chart.
    mutating func restart(capacity: Int, spacing: Double) {
        clear()
        self.capacity = capacity
        self.spacing = spacing
    }

    /// The same samples, numbered the same, each value transformed: one
    /// field of a sample that several charts share.
    func map<T>(_ transform: (Value) -> T) -> RollingSeries<T> {
        RollingSeries<T>(
            points: points.map { .init(id: $0.id, value: transform($0.value)) },
            departed: departed.map { .init(id: $0.id, value: transform($0.value)) }, capacity: capacity,
            spacing: spacing, sequence: sequence)
    }
}

/// One live sample for the charts that share the memory sample's cadence.
struct LivePoint {
    let cpuPercent: Double
    let compressedMB: Double
    /// Active, wired and compressed: what the Memory page charts.
    let inUseMB: Double
}

/// One sample of a pair of rates (disk write and read, network received
/// and sent), in decimal MB/s.
struct RatePair {
    /// Drawn as the filled area: the rate the card leads with.
    let area: Double
    /// Drawn as the dashed line.
    let line: Double
}

typealias RatePoint = RollingSeries<RatePair>.Point

/// Whether the Mac reports battery telemetry, decided by the daemon's answer
/// to the `battery.sample` subscription.
enum BatteryTelemetry: Equatable {
    case waiting
    case reported(BatterySamplePayload)
    /// The daemon refused the subscription when it was made; on a Mac
    /// without a battery it always does. A feed that ends later is a failed
    /// feed (`MetricsModel.feedFailures`), not this: the battery was there.
    case unavailable(String)

    var sample: BatterySamplePayload? {
        if case .reported(let sample) = self { sample } else { nil }
    }

    /// Why there is no battery telemetry; nil while there may be some.
    var absence: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }
}

typealias PressureLevel = MemoryPressurePayload.Level

/// The dashboard's view of meerkatd.
///
/// Every number comes from the daemon's event sources, the same ones rules
/// subscribe to, so the machine samples once however many consumers there
/// are, as long as they ask for the same rates. `feeds` lists each
/// subscription: its parameters at the sampling settings' rates
/// (`SamplingRates`), what it updates, and the cards and pages it drives.
///
/// Subscriptions exist only while the window is visible and some page that
/// shows them (the Overview, a resource page) is on screen: occlusion
/// cancels them and the daemon stops the sources nobody else uses.
@MainActor
@Observable
final class MetricsModel {
    enum Connection: Equatable {
        case connecting
        case connected
        /// The daemon did not answer, answered as another build, or lost a
        /// subscription across a restart: every feed is down. One feed the
        /// daemon refuses or ends is in `feedFailures` instead.
        case unavailable(DaemonFault)
    }

    /// Set from the Settings pane through `setRates`; read at launch so the
    /// first subscription already uses the stored rates.
    private(set) var rates: SamplingRates
    private(set) var ticks: RollingSeries<LivePoint>
    private(set) var cpuNow: Double = 0
    private(set) var processes: [ProcessDelta] = []
    /// Busiest by disk I/O over the ranking window, among the processes
    /// whose counters this user can read. Root daemons are not among them,
    /// so the machine's disk rate can be high with no rows.
    private(set) var ioProcesses: [ProcessDelta] = []
    /// Every process at the last listing, idle ones included, for the
    /// resource pages, which each sort it by their own measure. Only this
    /// user's processes carry footprint, disk and energy.
    private(set) var allProcesses: [ProcessDelta] = []
    private(set) var memory: MemorySample?
    /// Pressure changes over the chart span, oldest first, for the Memory
    /// page's timeline. The first entry is the level at the span's start.
    private(set) var pressureLog: [(at: Date, level: PressureLevel)] = []
    private(set) var churn: ChurnResult?
    private(set) var load: (Double, Double, Double) = (0, 0, 0)
    private(set) var pressure: PressureLevel = .normal
    /// Physical disks only (`DiskSamplePayload` totals): area write, line read.
    private(set) var diskSeries: RollingSeries<RatePair>
    private(set) var disk: DiskSamplePayload?
    /// The startup volume's free and total bytes, refreshed with disk samples.
    private(set) var volume: (free: Int64, total: Int64)?
    private(set) var networkPath: NetworkPathPayload?
    private(set) var assertions: PowerAssertionsPayload?
    private(set) var network: NetworkSamplePayload?
    /// Physical interfaces only: area received, line sent.
    private(set) var networkSeries: RollingSeries<RatePair>
    private(set) var battery: BatteryTelemetry = .waiting
    private(set) var powerSeries = RollingSeries<Double>(
        capacity: SamplingRates.powerHistoryLimit, spacing: SamplingRates.batteryInterval)
    private(set) var powerSource: PowerSourcePayload?
    private(set) var thermal: ThermalStatePayload.State = .nominal
    private(set) var lowPowerMode = false
    private(set) var connection: Connection = .connecting
    /// Feeds the daemon refused or ended while it still answers, by event
    /// kind, with its reason: a source that failed (a polling tick that
    /// threw, `fs.churn` losing its folder). Only that feed is down, and it
    /// tries again on its own; the others keep running.
    private(set) var feedFailures: [String: String] = [:]

    private let client: any DaemonConnection
    private let isVisible: @MainActor () -> Bool
    /// How a feed subscribes again (`follow`).
    private let feedRetry: FeedRetry
    private let back: DaemonReturn
    private var streams: [Task<Void, Never>] = []
    /// `back.count` when they were made, so a return while they fail
    /// wakes the reconnect.
    private var subscribedSince: UInt64 = 0
    private var retry: Task<Void, Never>?
    /// The wait before subscribing every feed again after the connection
    /// was lost: it grows while the daemon stays away, and starts over once
    /// any feed delivers, or meerkatd is back (`DaemonReturn`).
    private var reconnectRetry: FeedRetry
    private var occlusionObserver: (any NSObjectProtocol)?
    /// Pages showing this model's data. Counted rather than flagged, so one
    /// page appearing before another disappears never stops the feed.
    private var viewers = 0
    private var volumeCheckedAt = Date.distantPast
    /// How each churn root, and "/", reads in a sentence (`FileScopeName`),
    /// resolved once per root, off the main actor: the root comes from
    /// `meerkat.json` and may be on a volume that is slow to answer.
    private var scopeNames: [String: String] = [:]
    /// One point per `fs.churn` window (events per window), for the Files
    /// page; windows are 25 s apart at Normal, so it spans longer.
    private(set) var churnSeries: RollingSeries<Double>
    static let churnHistoryLimit = 24

    /// `client` is the app's one connection to the daemon, shared by every
    /// page. `hostName` reads the Mac's name, off the main actor: it can
    /// wait on a name lookup. `isVisible` is whether the window can be seen.
    init(
        client: any DaemonConnection,
        hostName: @escaping @Sendable () -> String = { ProcessInfo.processInfo.hostName },
        isVisible: @escaping @MainActor () -> Bool = {
            MetricsModel.alwaysRun || NSApplication.shared.occlusionState.contains(.visible)
        },
        retry: FeedRetry = FeedRetry(), back: DaemonReturn = DaemonReturn()
    ) {
        let rates = SamplingRates.stored
        self.rates = rates
        ticks = RollingSeries(capacity: rates.historyLimit, spacing: rates.chart)
        diskSeries = RollingSeries(capacity: rates.historyLimit, spacing: rates.chart)
        networkSeries = RollingSeries(capacity: rates.historyLimit, spacing: rates.chart)
        churnSeries = RollingSeries(capacity: MetricsModel.churnHistoryLimit, spacing: rates.churnEvery)
        self.client = client
        self.isVisible = isVisible
        feedRetry = retry
        self.back = back
        reconnectRetry = retry
        Task { [weak self] in
            let host = await Task.detached { hostName() }.value
            self?.host = host
        }
    }

    private(set) var host: String?
    let physicalMemoryBytes = Int64(ProcessInfo.processInfo.physicalMemory)
    /// Decimal MB, the same unit as `MemorySample`, for proportions of it.
    let physicalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000
    let cpuCount = ProcessInfo.processInfo.processorCount
    let machine = MetricsModel.machineModel()
    let noSample = ProcessInfo.processInfo.environment["MEERKAT_NO_SAMPLE"] != nil
    static let alwaysRun = ProcessInfo.processInfo.environment["MEERKAT_ALWAYS"] != nil

    var busyCores: Double { cpuNow / 100 * Double(cpuCount) }
    var diskWriteMBps: Double { diskSeries.last?.area ?? 0 }
    var diskReadMBps: Double { diskSeries.last?.line ?? 0 }
    var networkReceivedMBps: Double { networkSeries.last?.area ?? 0 }
    var networkSentMBps: Double { networkSeries.last?.line ?? 0 }

    func start() {
        viewers += 1
        guard occlusionObserver == nil else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateForVisibility() }
        }
        updateForVisibility()
    }

    /// New rates restart the subscriptions. The history is cleared rather
    /// than mixing two sample spacings on one chart.
    func setRates(_ newValue: SamplingRates) {
        guard newValue != rates else { return }
        // The churn chart keeps one point per window, so only its own
        // period changes its spacing.
        if newValue.churnEvery != rates.churnEvery {
            churnSeries.restart(capacity: Self.churnHistoryLimit, spacing: newValue.churnEvery)
        }
        rates = newValue
        ticks.restart(capacity: newValue.historyLimit, spacing: newValue.chart)
        diskSeries.restart(capacity: newValue.historyLimit, spacing: newValue.chart)
        networkSeries.restart(capacity: newValue.historyLimit, spacing: newValue.chart)
        guard !streams.isEmpty else { return }
        unsubscribe()
        updateForVisibility()
    }

    func stop() {
        viewers = max(viewers - 1, 0)
        guard viewers == 0 else { return }
        // On the next turn, not now: changing pages may remove the old page
        // before the new one appears, in the same update, and the feed
        // carries over rather than all its subscriptions being remade.
        Task { [weak self] in self?.stopIfUnwatched() }
    }

    private func stopIfUnwatched() {
        guard viewers == 0 else { return }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        retry?.cancel()
        retry = nil
        unsubscribe()
    }

    // MARK: - Subscriptions

    /// Subscribed exactly while a page shows the data and the window is
    /// visible: a retry after the last page left subscribes nothing. With
    /// `MEERKAT_NO_SAMPLE`, also only until the first ranking.
    private func updateForVisibility() {
        if viewers > 0, isVisible(), !(noSample && !processes.isEmpty) {
            if streams.isEmpty { subscribe() }
        } else {
            unsubscribe()
        }
    }

    private func subscribe() {
        retry?.cancel()
        retry = nil
        connection = .connecting
        feedFailures = [:]
        subscribedSince = back.count
        streams = Self.feeds.map { $0.subscribe(self) }
    }

    private func unsubscribe() {
        for stream in streams { stream.cancel() }
        streams = []
    }

    /// One task per event kind, applying payloads on the main actor.
    ///
    /// Failures are told apart by who they are about (`DaemonFault`):
    /// - The connection (`unreachable`, `differentBuild`): every feed is
    ///   down, so the page shows why and all of them reconnect (`lost`).
    /// - This one feed (`refused`, the daemon's own refusal or end of it):
    ///   the daemon answers, so the other feeds keep running. The feed is
    ///   marked failed with the daemon's reason and subscribes again on its
    ///   own (`follow`); its next payload clears the mark. `refused`, when
    ///   given, takes a refusal at subscribe instead, for a source some
    ///   Macs never have; that one is not retried.
    fileprivate func consume<Kind: EventKind>(
        _ kind: Kind.Type, _ parameters: Kind.Parameters,
        refused: (@MainActor (MetricsModel, String) -> Void)?,
        apply: @escaping @MainActor (MetricsModel, Kind.Payload) -> Void
    ) -> Task<Void, Never> {
        let (client, retry, back) = (self.client, feedRetry, self.back)
        let name = Kind.descriptor.name
        return Task { [weak self] in
            await follow(
                retry: retry, back: back,
                subscribe: { try await client.events(kind, parameters: parameters) },
                event: { event in
                    guard let self else { return false }
                    if self.connection != .connected {
                        self.connection = .connected
                        self.reconnectRetry.reset()
                    }
                    if self.feedFailures[name] != nil { self.feedFailures[name] = nil }
                    apply(self, event.0)
                    if self.noSample { self.updateForVisibility() }
                    return true
                },
                stopped: { end in
                    guard let self else { return false }
                    let reason: String
                    switch end {
                    case .notSubscribed(.refused(let message)) where refused != nil:
                        refused?(self, message)
                        return false
                    case .notSubscribed(.refused(let message)), .ended(.refused(let message)):
                        reason = message
                    case .ended(nil):
                        // Only the daemon ends a feed; one ended without a
                        // reason is still not running.
                        reason = "meerkatd ended the \(name) feed"
                    case .notSubscribed(let fault), .ended(let fault?):
                        self.lost(fault)
                        return false
                    }
                    self.feedFailures[name] = reason
                    return true
                })
        }
    }

    /// The daemon is unreachable, a different build, or lost every feed
    /// across a restart: show why, and try again while the window stays
    /// visible.
    private func lost(_ fault: DaemonFault) {
        guard !streams.isEmpty else { return }
        unsubscribe()
        connection = .unavailable(fault)
        retry?.cancel()
        let (delay, back, seen, clock) = (reconnectRetry.next(), back, subscribedSince, reconnectRetry.clock)
        retry = Task { [weak self] in
            switch await back.sleep(for: delay, since: seen, on: clock) {
            case .cancelled: return
            case .woken: self?.reconnectRetry.reset()
            case .elapsed: break
            }
            self?.updateForVisibility()
        }
    }

    // MARK: - Series

    private func logPressure(_ level: PressureLevel) {
        let now = Date()
        if pressureLog.last?.level != level { pressureLog.append((now, level)) }
        // Keep the newest change from before the span: it is the level the
        // timeline starts with.
        let start = now.addingTimeInterval(-SamplingRates.chartSpan)
        while pressureLog.count > 1, pressureLog[1].at <= start { pressureLog.removeFirst() }
    }

    /// Free space changes slowly; reading it every 30 s is plenty. Off the
    /// main actor: "important usage" capacity has the system work out
    /// purgeable space, which can take far longer than a `statfs`.
    private func refreshVolume() {
        guard Date().timeIntervalSince(volumeCheckedAt) >= 30 else { return }
        volumeCheckedAt = Date()
        Task {
            let read = Task.detached { () -> (free: Int64, total: Int64)? in
                let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
                guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
                    let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity
                else { return nil }
                return (free, Int64(total))
            }
            if let volume = await read.value { self.volume = volume }
        }
    }

    /// `root` as a sentence names it: its volume's name once resolved, the
    /// path with `~` until then.
    func scopeName(_ root: String) -> String {
        scopeNames[root] ?? FileScopeName.path(root)
    }

    private func resolveScopeName(_ root: String) {
        guard scopeNames[root] == nil else { return }
        // Claimed now, so later readings don't start another lookup.
        scopeNames[root] = FileScopeName.path(root)
        Task {
            let name = await Task.detached { FileScopeName.of(root) }.value
            self.scopeNames[root] = name
        }
    }

    // MARK: - Helpers

    private static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - Feeds

extension MetricsModel {
    /// One subscription the model keeps: its event kind, the parameters the
    /// sampling rates choose, what its payloads update, and the cards and
    /// pages whose numbers it drives, where its failure is reported.
    struct Feed: Sendable {
        let kind: String
        /// The Custom rates its parameters follow; none for a fixed rate or
        /// a pushed kind.
        let rates: Set<SamplingField>
        let cards: Set<Resource>
        let pages: Set<Resource>
        /// Throws what the daemon would answer to subscribing at `rates`.
        let validate: @Sendable (SamplingRates) throws -> Void
        /// The parameters it subscribes with at `rates`, encoded. They must
        /// follow only the fields in `rates`, which alone the Sampling
        /// pane checks against `validate`.
        let encodedParameters: @Sendable (SamplingRates) -> JSONValue?
        fileprivate let subscribe: @MainActor @Sendable (MetricsModel) -> Task<Void, Never>

        init<Kind: EventKind>(
            _: Kind.Type, rates: Set<SamplingField> = [], cards: Set<Resource> = [], pages: Set<Resource>,
            parameters: @escaping @Sendable (SamplingRates) -> Kind.Parameters,
            refused: (@MainActor @Sendable (MetricsModel, String) -> Void)? = nil,
            apply: @escaping @MainActor @Sendable (MetricsModel, Kind.Payload) -> Void
        ) {
            kind = Kind.descriptor.name
            self.rates = rates
            self.cards = cards
            self.pages = pages
            validate = { try parameters($0).validate() }
            encodedParameters = { try? JSONValue(encoding: parameters($0)) }
            subscribe = { model in
                model.consume(Kind.self, parameters(model.rates), refused: refused, apply: apply)
            }
        }

        /// A pushed kind, which takes no parameters.
        init<Kind: EventKind>(
            _ kind: Kind.Type, cards: Set<Resource> = [], pages: Set<Resource>,
            apply: @escaping @MainActor @Sendable (MetricsModel, Kind.Payload) -> Void
        ) where Kind.Parameters == NoParameters {
            self.init(kind, cards: cards, pages: pages, parameters: { _ in NoParameters() }, apply: apply)
        }

        func shows(_ resource: Resource, on place: ReadingPlace) -> Bool {
            (place == .card ? cards : pages).contains(resource)
        }
    }

    /// Everything the Overview, the resource pages and the sidebar show, in
    /// one table: subscribing, the Sampling pane's checks of each rate, the
    /// failure notes and the sample data all follow it.
    nonisolated static let feeds: [Feed] = [
        // The CPU chart takes its points from `memory.sample`, at the
        // charts' rate; this drives the headline and load, at their own.
        Feed(
            CPUSampleEvent.self, rates: [.cpu], cards: [.cpu], pages: [.cpu],
            parameters: { .init(interval: $0.cpu) },
            apply: { model, sample in
                model.cpuNow = sample.usagePercent
                model.load = (sample.load1, sample.load5, sample.load15)
            }),
        Feed(
            MemorySampleEvent.self, rates: [.chart], cards: [.cpu, .memory], pages: [.cpu, .memory],
            parameters: { .init(interval: $0.chart) },
            apply: { model, sample in
                model.memory = sample
                model.ticks.append(
                    LivePoint(
                        cpuPercent: model.cpuNow, compressedMB: sample.compressedMB, inUseMB: model.memoryInUseMB ?? 0))
            }),
        Feed(
            MemoryPressureEvent.self, cards: [.memory], pages: [.memory],
            apply: { model, payload in
                model.pressure = payload.level
                model.logPressure(payload.level)
            }),
        Feed(
            DiskSampleEvent.self, rates: [.chart], cards: [.disk], pages: [.disk],
            parameters: { .init(interval: $0.chart) },
            apply: { model, sample in
                model.disk = sample
                model.diskSeries.append(
                    RatePair(area: sample.writeBytesPerSecond / 1e6, line: sample.readBytesPerSecond / 1e6))
                model.refreshVolume()
                model.resolveScopeName("/")
            }),
        Feed(
            NetworkPathEvent.self, pages: [.network],
            apply: { model, payload in
                model.networkPath = payload
            }),
        // Also what a process card says the process keeps awake.
        Feed(
            PowerAssertionsEvent.self, pages: [.power],
            parameters: { _ in .init(interval: SamplingRates.assertionInterval) },
            apply: { model, payload in
                model.assertions = payload
            }),
        Feed(
            NetworkSampleEvent.self, rates: [.chart], cards: [.network], pages: [.network],
            parameters: { .init(interval: $0.chart) },
            apply: { model, sample in
                model.network = sample
                model.networkSeries.append(
                    RatePair(area: sample.receivedBytesPerSecond / 1e6, line: sample.sentBytesPerSecond / 1e6))
            }),
        // The daemon refuses `battery.sample` on a Mac without a battery.
        Feed(
            BatterySampleEvent.self, cards: [.power], pages: [.power],
            parameters: { _ in .init(interval: SamplingRates.batteryInterval) },
            refused: { model, reason in model.battery = .unavailable(reason) },
            apply: { model, sample in
                model.battery = .reported(sample)
                // A reading without the system-load key adds no point rather
                // than a fake zero.
                if let watts = sample.systemPowerWatts { model.powerSeries.append(watts) }
            }),
        Feed(
            PowerSourceEvent.self, cards: [.power], pages: [.power],
            apply: { model, payload in
                model.powerSource = payload
            }),
        Feed(
            ThermalStateEvent.self, cards: [.cpu], pages: [.cpu],
            apply: { model, payload in
                model.thermal = payload.state
            }),
        Feed(
            LowPowerModeEvent.self, cards: [.power], pages: [.cpu, .power],
            apply: { model, payload in
                model.lowPowerMode = payload.enabled
            }),
        // The cards' three rows, by CPU and by disk I/O. Each row's start
        // time identifies its process; a row whose can't opens no card
        // (`ProcessTarget`).
        Feed(
            ProcessTopEvent.self, rates: [.rows, .rank], cards: [.cpu, .disk], pages: [],
            parameters: { .init(interval: $0.rows, rankInterval: $0.rank, count: 3, ioCount: 3) },
            apply: { model, top in
                model.processes = top.cpu
                model.ioProcesses = top.io
            }),
        // Every process, once per ranking, for the pages' tables to sort.
        Feed(
            ProcessListEvent.self, rates: [.rank], pages: [.cpu, .memory, .disk, .power],
            parameters: { .init(interval: $0.rank) },
            apply: { model, list in
                model.allProcesses = list.processes
            }),
        // No root: the daemon measures its file scope (meerkat.json
        // `files`, by default the whole startup volume).
        Feed(
            FSChurnEvent.self, rates: [.churn], cards: [.files], pages: [.files],
            parameters: { .init(window: SamplingRates.churnWindow, every: $0.churnEvery, depth: 5) },
            apply: { model, result in
                model.churn = result
                model.resolveScopeName(result.root)
                model.churnSeries.append(Double(result.totalEvents))
            }),
    ]

    /// Why some of `resource`'s numbers at `place` have stopped, in the
    /// daemon's words; nil while every feed they come from runs.
    func feedFailure(_ resource: Resource, on place: ReadingPlace) -> String? {
        let reasons = Self.feeds.filter { $0.shows(resource, on: place) }.compactMap { feedFailures[$0.kind] }
        return reasons.isEmpty ? nil : reasons.joined(separator: " · ")
    }
}
