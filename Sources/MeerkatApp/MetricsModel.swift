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
    private var sequence = 0

    var last: Value? { points.last?.value }

    init() {}

    private init(points: [Point], departed: [Point], sequence: Int) {
        self.points = points
        self.departed = departed
        self.sequence = sequence
    }

    mutating func append(_ value: Value, limit: Int) {
        sequence += 1
        points.append(Point(id: sequence, value: value))
        guard points.count > limit else { return }
        departed += points.prefix(points.count - limit)
        points.removeFirst(points.count - limit)
        if departed.count > StickyTop.memory { departed.removeFirst(departed.count - StickyTop.memory) }
    }

    /// Empties the series. Numbering goes on, so a mark never reuses an id.
    mutating func clear() {
        points = []
        departed = []
    }

    /// The same samples, numbered the same, each value transformed: one
    /// field of a sample that several charts share.
    func map<T>(_ transform: (Value) -> T) -> RollingSeries<T> {
        RollingSeries<T>(
            points: points.map { .init(id: $0.id, value: transform($0.value)) },
            departed: departed.map { .init(id: $0.id, value: transform($0.value)) }, sequence: sequence)
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
}

typealias PressureLevel = MemoryPressurePayload.Level

/// The dashboard's view of meerkatd.
///
/// Every number comes from the daemon's event sources, the same ones rules
/// subscribe to, so the machine samples once however many consumers there
/// are, as long as they ask for the same rates. The rates come from the
/// sampling settings (`SamplingRates`, Normal shown):
///
/// | event | parameters | drives |
/// |---|---|---|
/// | `cpu.sample` | 1 s (Live 0.25 s) | headline CPU number, load |
/// | `memory.sample` | 1 s | memory card, one chart point per sample |
/// | `disk.sample` | 1 s | disk rates and chart |
/// | `network.sample` | 1 s | network card |
/// | `battery.sample` | 5 s (fixed) | power card |
/// | `memory.pressure`, `thermal.state`, `power.lowPowerMode`, `power.source`, `network.path` | push | badges, detail panels |
/// | `power.assertions` | 5 s | Power page |
/// | `process.top` | rows 1 s, ranking 5 s | the cards' process rows |
/// | `process.list` | ranking 5 s | resource pages' process tables |
/// | `fs.churn` | 4 s of every 25 s | Files card and page; scope from meerkat.json |
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
    private(set) var rates = SamplingRates.stored
    private(set) var ticks = RollingSeries<LivePoint>()
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
    private(set) var diskSeries = RollingSeries<RatePair>()
    private(set) var disk: DiskSamplePayload?
    /// The startup volume's free and total bytes, refreshed with disk samples.
    private(set) var volume: (free: Int64, total: Int64)?
    private(set) var networkPath: NetworkPathPayload?
    private(set) var assertions: PowerAssertionsPayload?
    private(set) var network: NetworkSamplePayload?
    /// Physical interfaces only: area received, line sent.
    private(set) var networkSeries = RollingSeries<RatePair>()
    private(set) var battery: BatteryTelemetry = .waiting
    private(set) var powerSeries = RollingSeries<Double>()
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
    /// The pause before subscribing again after the daemon was lost.
    private let retryDelay: Duration
    private var streams: [Task<Void, Never>] = []
    private var retry: Task<Void, Never>?
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
    private(set) var churnSeries = RollingSeries<Double>()
    static let churnHistoryLimit = 24

    /// `client` is the app's one connection to the daemon, shared by every
    /// page. `isVisible` is whether the window can be seen.
    init(
        client: any DaemonConnection,
        isVisible: @escaping @MainActor () -> Bool = {
            MetricsModel.alwaysRun || NSApplication.shared.occlusionState.contains(.visible)
        },
        retryDelay: Duration = .seconds(5)
    ) {
        self.client = client
        self.isVisible = isVisible
        self.retryDelay = retryDelay
        Task { [weak self] in
            let host = await Task.detached { ProcessInfo.processInfo.hostName }.value
            self?.host = host
        }
    }

    /// The Mac's name, once read: `hostName` can wait on a name lookup, so
    /// it is read off the main actor (`init`).
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
        if newValue.churnEvery != rates.churnEvery { churnSeries.clear() }
        rates = newValue
        ticks.clear()
        diskSeries.clear()
        networkSeries.clear()
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

    /// Subscribes again now rather than at the next retry, for when the
    /// agent was just installed.
    func reconnect() {
        unsubscribe()
        updateForVisibility()
    }

    // MARK: - Subscriptions

    /// Subscribed exactly while a page shows the data and the window is
    /// visible: a retry or a reconnect after the last page left subscribes
    /// nothing.
    private func updateForVisibility() {
        if viewers > 0, isVisible() {
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
        streams = [
            consume(CPUSampleEvent.self, rates.cpuParameters) { model, sample in
                model.cpuNow = sample.usagePercent
                model.load = (sample.load1, sample.load5, sample.load15)
            },
            consume(MemorySampleEvent.self, rates.chartParameters) { model, sample in
                model.memory = sample
                model.ticks.append(
                    LivePoint(
                        cpuPercent: model.cpuNow, compressedMB: sample.compressedMB,
                        inUseMB: model.memoryInUseMB ?? 0),
                    limit: model.rates.historyLimit)
            },
            consume(MemoryPressureEvent.self, NoParameters()) { model, payload in
                model.pressure = payload.level
                model.logPressure(payload.level)
            },
            consume(DiskSampleEvent.self, rates.diskParameters) { model, sample in
                model.disk = sample
                model.diskSeries.append(
                    RatePair(area: sample.writeBytesPerSecond / 1e6, line: sample.readBytesPerSecond / 1e6),
                    limit: model.rates.historyLimit)
                model.refreshVolume()
                model.resolveScopeName("/")
            },
            consume(NetworkPathEvent.self, NoParameters()) { model, payload in
                model.networkPath = payload
            },
            consume(PowerAssertionsEvent.self, SamplingRates.assertionParameters) { model, payload in
                model.assertions = payload
            },
            consume(NetworkSampleEvent.self, rates.networkParameters) { model, sample in
                model.network = sample
                model.networkSeries.append(
                    RatePair(area: sample.receivedBytesPerSecond / 1e6, line: sample.sentBytesPerSecond / 1e6),
                    limit: model.rates.historyLimit)
            },
            // The daemon refuses `battery.sample` on a Mac without a battery.
            consume(
                BatterySampleEvent.self, SamplingRates.batteryParameters,
                refused: { model, reason in model.battery = .unavailable(reason) },
                apply: { model, sample in
                    model.battery = .reported(sample)
                    // A reading without the system-load key adds no point
                    // rather than a fake zero.
                    if let watts = sample.systemPowerWatts {
                        model.powerSeries.append(watts, limit: SamplingRates.powerHistoryLimit)
                    }
                }
            ),
            consume(PowerSourceEvent.self, NoParameters()) { model, payload in
                model.powerSource = payload
            },
            consume(ThermalStateEvent.self, NoParameters()) { model, payload in
                model.thermal = payload.state
            },
            consume(LowPowerModeEvent.self, NoParameters()) { model, payload in
                model.lowPowerMode = payload.enabled
            },
            consume(ProcessTopEvent.self, rates.processParameters()) { model, top in
                model.processes = top.cpu
                model.ioProcesses = top.io
                if model.noSample { model.unsubscribe() }
            },
            consume(ProcessListEvent.self, rates.listParameters) { model, list in
                model.allProcesses = list.processes
            },
            consume(FSChurnEvent.self, rates.churnParameters) { model, result in
                model.churn = result
                model.resolveScopeName(result.root)
                model.churnSeries.append(Double(result.totalEvents), limit: Self.churnHistoryLimit)
            },
        ]
    }

    private func unsubscribe() {
        for stream in streams { stream.cancel() }
        streams = []
    }

    /// One task per event kind, applying payloads on the main actor.
    ///
    /// Failures are told apart by who they are about:
    /// - The connection (`unreachable`, `differentBuild`, `resubscribeFailed`,
    ///   an unexpected reply): every feed is down, so the page shows why and
    ///   all of them reconnect (`lost`).
    /// - This one feed (`ClientError.daemon`, the daemon's own refusal or
    ///   end of it): the daemon answers, so the other feeds keep running.
    ///   The feed is marked failed with the daemon's reason and subscribes
    ///   again on its own backoff; its next payload clears the mark.
    ///   `refused`, when given, takes a refusal at subscribe instead, for a
    ///   source some Macs never have; that one is not retried.
    private func consume<Kind: EventKind>(
        _ kind: Kind.Type, _ parameters: Kind.Parameters,
        refused: (@MainActor (MetricsModel, String) -> Void)? = nil,
        apply: @escaping @MainActor (MetricsModel, Kind.Payload) -> Void
    ) -> Task<Void, Never> {
        let client = self.client
        let name = Kind.descriptor.name
        let firstDelay = retryDelay
        return Task { [weak self] in
            var delay = firstDelay
            while true {
                let reason: String
                do {
                    let events: AsyncThrowingStream<(Kind.Payload, EventEnvelope), any Error>
                    do {
                        events = try await client.events(kind, parameters: parameters)
                    } catch DaemonClient.ClientError.daemon(let message) where refused != nil {
                        guard let self else { return }
                        refused?(self, message)
                        return
                    }
                    for try await (payload, _) in events {
                        guard let self else { return }
                        if self.connection != .connected { self.connection = .connected }
                        if self.feedFailures[name] != nil { self.feedFailures[name] = nil }
                        delay = firstDelay
                        apply(self, payload)
                    }
                    // A cancelled task's stream ends without an error.
                    if Task.isCancelled { return }
                    // Otherwise only the daemon ends a feed; one ended
                    // without a reason is still not running.
                    reason = "meerkatd ended the \(name) feed"
                } catch is CancellationError {
                    return
                } catch DaemonClient.ClientError.daemon(let message) {
                    reason = message
                } catch {
                    self?.lost(error)
                    return
                }
                self?.feedFailures[name] = reason
                do { try await Task.sleep(for: delay) } catch { return }
                delay = min(delay * 2, Self.longestFeedRetry)
            }
        }
    }

    /// The longest a failed feed waits before subscribing again: a source
    /// that keeps failing is asked about once a minute, not every 5 s.
    private static let longestFeedRetry: Duration = .seconds(60)

    /// The daemon is unreachable, a different build, or lost every feed
    /// across a restart: show why, and try again while the window stays
    /// visible.
    private func lost(_ error: any Error) {
        guard !streams.isEmpty else { return }
        unsubscribe()
        connection = .unavailable(DaemonFault(error))
        retry?.cancel()
        retry = Task { [weak self, retryDelay] in
            do { try await Task.sleep(for: retryDelay) } catch { return }
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
