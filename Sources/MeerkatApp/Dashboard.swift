import MeerkatAgent
import MeerkatKit
import SwiftUI

/// The Overview page. It reads only the connection state and which feeds
/// failed, both rare changes; every card is its own view taking the model, so Observation invalidates each one only
/// for the properties it reads. The CPU feed, the fastest, then redraws the
/// CPU card and its sidebar row, not the charts in the other cards. Each
/// card opens its resource's page.
struct Dashboard: View {
    /// Owned by `AppState`, so chart history outlives a visit to another page.
    let model: MetricsModel
    /// For the agent banner and the process cards the lists open.
    let app: AppState
    let open: (Resource) -> Void

    /// The process card each list has open. Here rather than in the cards,
    /// so the cards' buttons can offer them to VoiceOver as actions.
    @State private var cpuCard: ProcessTarget?
    @State private var diskCard: ProcessTarget?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if case .unavailable(let fault) = model.connection {
                    ConnectionBanner(fault: fault, agent: app.agent) { model.reconnect() }
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    opening(.cpu) {
                        CPUCard(model: model, app: app, card: $cpuCard)
                    } actions: {
                        ProcessDetailActions(model: model, processes: \.processes, card: $cpuCard)
                    }
                    opening(.memory) { MemoryCard(model: model) }
                    opening(.disk) {
                        DiskCard(model: model, app: app, card: $diskCard)
                    } actions: {
                        ProcessDetailActions(model: model, processes: \.ioProcesses, card: $diskCard)
                    }
                    opening(.network) { NetworkCard(model: model) }
                    opening(.power) { PowerCard(model: model) }
                    opening(.files) { ChurnCard(model: model) }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 940, minHeight: 600)
        .navigationSubtitle(
            ([model.host, model.machine, "\(model.cpuCount) cores"] as [String?]).compactMap(\.self).joined(
                separator: " · ")
        )
        .metricsFeed(model)
    }

    /// `actions` are the card's other targets for VoiceOver, which reads
    /// the card's button as one element and so cannot reach buttons in it.
    private func opening(
        _ resource: Resource, @ViewBuilder card: () -> some View,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        Button {
            open(resource)
        } label: {
            card()
        }
        .buttonStyle(CardButtonStyle())
        .environment(\.cardOpensPage, true)
        .environment(\.feedFailure, model.feedFailure(resource))
        .accessibilityHint("Opens the \(resource.title) page")
        .accessibilityActions(actions)
    }
}

extension View {
    /// Keeps `model`'s subscriptions running while this page is on screen,
    /// at the rates the Sampling settings choose. Pages count as viewers, so
    /// moving between two of them never stops the feed.
    func metricsFeed(_ model: MetricsModel) -> some View {
        modifier(MetricsFeed(model: model))
    }
}

private struct MetricsFeed: ViewModifier {
    let model: MetricsModel
    @AppStorage(SamplingPreset.defaultsKey) private var preset: SamplingPreset = .normal
    @AppStorage(SamplingRates.customKey) private var customRates = ""

    private var rates: SamplingRates { preset.rates(custom: SamplingRates(json: customRates)) }

    func body(content: Content) -> some View {
        content
            // `initial`: the rates may have changed in Settings while another
            // page was showing.
            .onChange(of: rates, initial: true) { model.setRates(rates) }
            // `onAppear`, not `task`: a task starts after the update that
            // removed the previous page, whose `stop` would already have
            // run (`MetricsModel.stop`).
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

// MARK: - Resources

/// The six things the Overview measures, in card and sidebar order.
enum Resource: String, CaseIterable, Identifiable, Hashable {
    case cpu, memory, disk, network, power, files

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .power: "Power"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu.fill"
        case .memory: "memorychip.fill"
        case .disk: "internaldrive.fill"
        case .network: "network"
        case .power: "bolt.fill"
        case .files: "folder.fill"
        }
    }

    /// The event kinds its card and page show, so a failed feed is reported
    /// where its numbers stop.
    var feeds: [String] {
        switch self {
        case .cpu: [CPUSampleEvent.descriptor.name, ThermalStateEvent.descriptor.name, ProcessTopEvent.descriptor.name]
        case .memory:
            [MemorySampleEvent.descriptor.name, MemoryPressureEvent.descriptor.name, ProcessTopEvent.descriptor.name]
        case .disk: [DiskSampleEvent.descriptor.name, ProcessTopEvent.descriptor.name]
        case .network: [NetworkSampleEvent.descriptor.name, NetworkPathEvent.descriptor.name]
        case .power:
            [
                BatterySampleEvent.descriptor.name, PowerSourceEvent.descriptor.name,
                LowPowerModeEvent.descriptor.name, PowerAssertionsEvent.descriptor.name,
            ]
        case .files: [FSChurnEvent.descriptor.name]
        }
    }

    /// `feeds`, plus what only its page shows: the CPU, Memory, Disk and
    /// Power pages' process tables read `process.list`, which no card does.
    var pageFeeds: [String] {
        switch self {
        case .cpu, .memory, .disk, .power: feeds + [ProcessListEvent.descriptor.name]
        case .network, .files: feeds
        }
    }

    var tint: Color {
        switch self {
        case .cpu: Theme.cpu
        case .memory: Theme.memory
        case .disk: Theme.disk
        case .network: Theme.network
        case .power: Theme.power
        case .files: Theme.churn
        }
    }
}

extension MetricsModel {
    /// Why some of `resource`'s numbers have stopped, in the daemon's words;
    /// nil while all its feeds run. `onPage` adds the feeds only its page
    /// shows (`Resource.pageFeeds`).
    func feedFailure(_ resource: Resource, onPage: Bool = false) -> String? {
        let reasons = (onPage ? resource.pageFeeds : resource.feeds).compactMap { feedFailures[$0] }
        return reasons.isEmpty ? nil : reasons.joined(separator: " · ")
    }

    /// Active, wired and compressed pages: memory apps and the system hold.
    /// Decimal megabytes, like `MemorySample`.
    var memoryInUseMB: Double? {
        memory.map { $0.activeMB + $0.wiredMB + $0.compressedMB }
    }

    /// "In use of 16 GB".
    private var memoryContext: String { "In use of " + MemorySize.text(bytes: physicalMemoryBytes) }

    /// The live value each resource shows in the sidebar and leads its card with.
    func headline(_ resource: Resource) -> String? {
        switch resource {
        case .cpu: return Format.percent(cpuNow)
        case .memory: return memoryInUseMB.map(MemorySize.text(megabytes:))
        case .disk: return Format.megabytesPerSecond(diskWriteMBps)
        case .network: return RateUnit.text(networkReceivedMBps)
        case .power:
            guard case .reported(let sample) = battery, let watts = sample.systemPowerWatts else { return nil }
            return Format.watts(watts)
        case .files: return churn.map { "\($0.totalEvents)" }
        }
    }
}

/// A resource's headline: what the number is, the number and its unit.
struct ResourceReading {
    let context: String
    let value: String
    let unit: String
}

extension Readout {
    init(_ reading: ResourceReading) {
        self.init(context: reading.context, value: reading.value, unit: reading.unit)
    }
}

extension MetricsModel {
    /// Where a reading shows. An Overview card is narrower than a resource
    /// page, and shows less exact figures.
    enum ReadingPlace { case card, page }

    func reading(_ resource: Resource, on place: ReadingPlace) -> ResourceReading {
        switch resource {
        case .cpu:
            return ResourceReading(
                context: "Now · \(Format.number(busyCores, digits: 1)) of \(cpuCount) cores busy",
                value: Format.number(cpuNow), unit: "%")
        case .memory:
            let inUse = memoryInUseMB.map(MemorySize.parts(megabytes:))
            var context = memoryContext
            if place == .card, let swap = memory?.swapUsedMB, swap >= 100 {
                context += " · " + MemorySize.text(megabytes: swap) + " in swap"
            }
            return ResourceReading(context: context, value: inUse?.value ?? "–", unit: inUse?.unit ?? "GB")
        case .disk:
            let read = place == .card ? Format.megabytesPerSecond(diskReadMBps) : RateUnit.text(diskReadMBps)
            return ResourceReading(
                context: "Writing · reading " + read, value: Format.number(diskWriteMBps, digits: 1), unit: "MB/s")
        case .network:
            let received = RateUnit.scaled(networkReceivedMBps)
            return ResourceReading(
                context: "Downloading · uploading " + RateUnit.text(networkSentMBps),
                value: RateUnit.number(received.value), unit: received.unit)
        case .power:
            var sample: BatterySamplePayload?
            if case .reported(let reported) = battery { sample = reported }
            return ResourceReading(
                context: sample?.caption ?? "System draw",
                value: sample.map { Format.number($0.systemPowerWatts ?? 0, digits: 1) } ?? "–", unit: "W")
        case .files:
            let total = churn.map { place == .card ? "\($0.totalEvents)" : $0.totalEvents.formatted() }
            return ResourceReading(
                context: churn.map { "Changes on \(scopeName($0.root)) · last \(Format.number($0.windowSeconds)) s" }
                    ?? "Changes under the paths meerkat.json watches",
                value: total ?? "0", unit: "events")
        }
    }

    /// The battery the system reports a charge for.
    var batteryLevel: PowerSourceBattery? {
        powerSource?.batteries.first { $0.currentCapacityPercent != nil }
    }

    /// "100%", "82% · 3 h 12 min", "60% · charging".
    var batteryText: String? {
        guard let battery = batteryLevel, let percent = battery.currentCapacityPercent else { return nil }
        let charge = Format.percent(percent)
        if battery.isCharging == true, battery.isCharged != true { return charge + " · charging" }
        if battery.powerSourceState == .battery, let minutes = battery.timeToEmptyMinutes {
            return charge + " · " + Format.duration(minutes: minutes)
        }
        return charge
    }

    /// The system's own low-battery warning levels.
    var batteryTint: Color? {
        switch powerSource?.warningLevel {
        case .early?: Theme.warn
        case .final?: Theme.critical
        default: nil
        }
    }
}

extension BatterySamplePayload {
    /// Where power comes from, and the battery's flow when it has one:
    /// "System draw · 90 W adapter", "System draw · 12.4 W from battery".
    var caption: String {
        var parts = ["System draw"]
        if let watts = adapterWatts {
            parts.append("\(watts) W adapter")
        } else if externalConnected == false {
            parts.append("on battery")
        }
        if let volts = voltage, let amps = amperage, abs(volts * amps) >= 0.1 {
            let watts = volts * amps
            parts.append(
                watts > 0 ? "charging " + Format.watts(watts) : Format.watts(-watts) + " from battery")
        }
        return parts.joined(separator: " · ")
    }
}

/// One of the parts of memory in use, as the Memory card and page show it.
struct MemoryPart {
    let label: String
    let megabytes: KeyPath<MemorySample, Double>
    let color: Color

    @MainActor static let inUse = [
        MemoryPart(label: "Active", megabytes: \.activeMB, color: Theme.memory),
        MemoryPart(label: "Wired", megabytes: \.wiredMB, color: Theme.memory.opacity(0.6)),
        MemoryPart(label: "Compressed", megabytes: \.compressedMB, color: Theme.memory.opacity(0.32)),
    ]
}

// MARK: - Shared

/// Diagnostic: MEERKAT_PLAIN=1 swaps charts for blank space so the
/// same binary can attribute its own rendering cost.
private let plainCharts = ProcessInfo.processInfo.environment["MEERKAT_PLAIN"] != nil

private struct ChartSlot<Content: View>: View {
    var height: CGFloat = 76
    @ViewBuilder var content: Content

    var body: some View {
        if plainCharts { Color.clear.frame(height: height) } else { content }
    }
}

/// How a churn root reads in a sentence: the volume's name for a volume's
/// root ("Macintosh HD"), otherwise the path with `~`. `of` reads file-system
/// metadata, which can block, so views take the name from
/// `MetricsModel.scopeName`, which resolves it off the main actor.
enum FileScopeName {
    static func of(_ root: String) -> String {
        let url = URL(fileURLWithPath: root)
        if let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey]),
            values.volume?.standardizedFileURL == url.standardizedFileURL, let name = values.volumeName
        {
            return name
        }
        return path(root)
    }

    static func path(_ root: String) -> String {
        (root as NSString).abbreviatingWithTildeInPath
    }
}

enum DisplayName {
    static func process(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// "~/Library/Application Support/Example" -> "Application Support/Example"
    static func cluster(_ path: String) -> String {
        var s = path
        if s.hasPrefix("~/Library/") { s = String(s.dropFirst("~/Library/".count)) }
        return s.count > 34 ? "…" + s.suffix(32) : s
    }
}

/// Memory sizes as macOS shows them: binary multiples labelled GB and MB,
/// through the system's memory byte-count style, so a 16 GiB Mac reads
/// "16 GB" as it does in Activity Monitor and About This Mac. Payloads carry
/// decimal megabytes (`MemorySample`, `ProcessDelta.footprintMB`); this is the
/// one place that turns them into text.
enum MemorySize {
    private static let style = ByteCountFormatStyle(style: .memory)

    /// Clamped rather than converted: readings come from the daemon, and a
    /// value `Int64` cannot hold would trap the app.
    static func bytes(megabytes: Double) -> Int64 {
        let bytes = (megabytes * 1_000_000).rounded()
        if bytes.isNaN { return 0 }
        if bytes >= 0x1p63 { return .max }
        if bytes < -0x1p63 { return .min }
        return Int64(bytes)
    }

    static func text(bytes: Int64) -> String { bytes.formatted(style) }

    /// "12.35 GB", "512 MB".
    static func text(megabytes: Double) -> String { text(bytes: bytes(megabytes: megabytes)) }

    /// The number and its unit apart, for readouts that set them in
    /// different sizes; taken from the formatter's own fields, so the
    /// locale's number format and unit name survive.
    static func parts(megabytes: Double) -> (value: String, unit: String) {
        let attributed = bytes(megabytes: megabytes).formatted(style.attributed)
        var value = ""
        var unit = ""
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            switch run.byteCount {
            case .unit?: unit += text
            case .value?, .spelledOutValue?: value += text
            default: break
            }
        }
        return (value, unit)
    }
}

/// Figures as text, through the locale's number format (its decimal
/// separator and digits), as `MemorySize` does for sizes: the one place the
/// app turns a measurement into text. `String(format:)` always writes a
/// POSIX ".", so a figure beside a memory size would disagree with it.
enum Format {
    /// "3.5", "1,204": `digits` decimals.
    static func number(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// "42%", or the locale's own form; `percent` is out of 100.
    static func percent(_ percent: Double) -> String {
        (percent / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// A load average: two decimals, as `uptime` shows it.
    static func load(_ value: Double) -> String { number(value, digits: 2) }

    static func watts(_ watts: Double, digits: Int = 1) -> String { number(watts, digits: digits) + " W" }

    static func megabytesPerSecond(_ mbps: Double, digits: Int = 1) -> String {
        number(mbps, digits: digits) + " MB/s"
    }

    /// One decimal below 10 ms, whole above.
    static func milliseconds(_ ms: Double) -> String { number(ms, digits: ms < 10 ? 1 : 0) + " ms" }

    /// "3 h 12 min", "45 min".
    static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func time(_ epochMs: Double?) -> String {
        guard let epochMs else { return "–" }
        return Date(epochMilliseconds: epochMs).formatted(date: .omitted, time: .shortened)
    }
}

/// Network rates span bytes to gigabits, so they pick a unit per reading:
/// KB/s below one decimal megabyte per second, MB/s from there.
enum RateUnit {
    static func scaled(_ mbps: Double) -> (value: Double, unit: String) {
        mbps < 1 ? (mbps * 1000, "KB/s") : (mbps, "MB/s")
    }

    static func text(_ mbps: Double) -> String {
        let (value, unit) = scaled(mbps)
        return number(value) + " " + unit
    }

    /// A scaled value: one decimal below 10, whole above.
    static func number(_ value: Double) -> String { Format.number(value, digits: value < 10 ? 1 : 0) }
}

// MARK: - CPU

private struct CPUCard: View {
    let model: MetricsModel
    let app: AppState
    @Binding var card: ProcessTarget?

    var body: some View {
        ProbeCard(resource: .cpu) {
            ThermalBadge(state: model.thermal)
        } content: {
            Readout(model.reading(.cpu, on: .card))
            ChartSlot { ResourceChart(resource: .cpu, model: model) }
            StatRow(items: [
                .init(label: "Load 1 m", value: Format.load(model.load.0)),
                .init(label: "5 m", value: Format.load(model.load.1)),
                .init(label: "15 m", value: Format.load(model.load.2)),
            ])
            let peak = max(model.processes.prefix(3).map(\.cpuPct).max() ?? 1, 1)
            RankedList(
                title: "Busiest processes · % of one core", items: model.processes, id: \.pid, lanes: 3,
                empty: "Ranking processes…"
            ) { p in
                ProcessBarRow(process: p, card: $card, metrics: model, app: app) {
                    BarRow(
                        label: DisplayName.process(p.name), value: Format.percent(p.cpuPct),
                        fraction: p.cpuPct / peak, tint: Theme.cpu, pid: p.pid)
                }
            }
            .processCard($card, metrics: model, app: app)
        }
    }
}

/// `ProcessInfo.thermalState`, shown only above nominal. Fair is Apple's
/// "slightly elevated, no action needed", so it stays secondary.
struct ThermalBadge: View {
    let state: ThermalStatePayload.State

    var body: some View {
        switch state {
        case .nominal: EmptyView()
        case .fair: StatusBadge(text: state.label, tint: .secondary)
        case .serious: StatusBadge(text: state.label, tint: Theme.warn)
        case .critical: StatusBadge(text: state.label, tint: Theme.critical)
        }
    }
}

extension ThermalStatePayload.State {
    /// The app's word for each state, on the badge and the CPU page alike.
    var label: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Overheating"
        }
    }
}

// MARK: - Memory

private struct MemoryCard: View {
    let model: MetricsModel

    var body: some View {
        ProbeCard(resource: .memory) {
            PressureBadge(level: model.pressure)
        } content: {
            Readout(model.reading(.memory, on: .card))
            // Laid out before the first sample too (an empty bar, dashes), so
            // the card keeps its height when the reading arrives.
            let m = model.memory
            MemoryCompositionBar(
                segments: MemoryPart.inUse.map { ($0.label, m?[keyPath: $0.megabytes] ?? 0, $0.color) },
                totalMB: model.physicalMB, totalBytes: model.physicalMemoryBytes)
            StatRow(
                items: MemoryPart.inUse.map { part in
                    .init(
                        label: part.label,
                        value: m.map { MemorySize.text(megabytes: $0[keyPath: part.megabytes]) } ?? "–",
                        key: part.color)
                })
            ChartSlot {
                Sparkline(
                    metric: "Compressed memory",
                    series: model.ticks.map(\.compressedMB),
                    tint: Theme.memory, format: { MemorySize.text(megabytes: $0) }, banded: true)
            }
        }
    }
}

/// The kernel's memory pressure, which is what slows a Mac down; free
/// memory and swap alone are not.
struct PressureBadge: View {
    let level: PressureLevel

    var body: some View {
        switch level {
        case .normal: StatusBadge(text: "Pressure normal", tint: Theme.normal)
        case .warning: StatusBadge(text: "Pressure elevated", tint: Theme.warn)
        case .critical: StatusBadge(text: "Pressure critical", tint: Theme.critical)
        }
    }
}

// MARK: - Disk

private struct DiskCard: View {
    let model: MetricsModel
    let app: AppState
    @Binding var card: ProcessTarget?

    var body: some View {
        ProbeCard(resource: .disk) {
            Readout(model.reading(.disk, on: .card))
            ChartSlot { ResourceChart(resource: .disk, model: model) }
            // The rate is every physical disk's; rows are only the processes
            // whose counters this user can read, so I/O from root daemons
            // moves the rate with no rows.
            let writers = model.ioProcesses
            let peak = max(writers.prefix(3).map(\.diskMB).max() ?? 1, 0.001)
            RankedList(
                title: "Your processes", items: writers, id: \.pid, lanes: 3,
                empty: "No I/O from your processes in this window"
            ) { p in
                ProcessBarRow(process: p, card: $card, metrics: model, app: app) {
                    BarRow(
                        label: DisplayName.process(p.name),
                        value: Format.megabytesPerSecond(p.diskMBps),
                        fraction: p.diskMB / peak, tint: Theme.disk, pid: p.pid)
                }
            }
            .processCard($card, metrics: model, app: app)
        }
    }
}

// MARK: - Network

private struct NetworkCard: View {
    let model: MetricsModel

    var body: some View {
        ProbeCard(resource: .network) {
            Readout(model.reading(.network, on: .card))
            ChartSlot { ResourceChart(resource: .network, model: model) }
            // Per interface, so loopback and tunnels show here even though the
            // totals above leave them out. Names are unique within one sample.
            let interfaces = (model.network?.interfaces ?? [])
                .sorted { $0.totalBytesPerSecond > $1.totalBytesPerSecond }
            let peak = max(interfaces.prefix(3).map(\.totalBytesPerSecond).max() ?? 1, 1)
            RankedList(
                title: "Interfaces", items: interfaces, id: \.name, lanes: 3, empty: "No traffic in this interval"
            ) { interface in
                BarRow(
                    label: interface.name, value: RateUnit.text(interface.totalBytesPerSecond / 1e6),
                    fraction: interface.totalBytesPerSecond / peak, tint: Theme.network, monospaced: true)
            }
        }
    }
}

extension InterfaceRate {
    fileprivate var totalBytesPerSecond: Double { receivedBytesPerSecond + sentBytesPerSecond }
}

// MARK: - Power

private struct PowerCard: View {
    let model: MetricsModel

    var body: some View {
        ProbeCard(resource: .power) {
            if model.lowPowerMode { StatusBadge(text: "Low Power Mode", tint: Theme.warn) }
        } content: {
            switch model.battery {
            case .unavailable(let reason):
                // Permanent for this Mac, so the card settles on this layout.
                QuietLine("This Mac reports no battery telemetry")
                    .help(reason)
            case .waiting:
                // The reported layout with dashes, so the first battery
                // reading (up to 5 s in) does not grow the card.
                readings(nil)
            case .reported(let sample):
                readings(sample)
            }
        }
    }

    @ViewBuilder private func readings(_ sample: BatterySamplePayload?) -> some View {
        Readout(model.reading(.power, on: .card))
        ChartSlot { ResourceChart(resource: .power, model: model) }
        StatRow(items: [
            .init(label: "Battery", value: model.batteryText ?? "–", tint: model.batteryTint),
            .init(
                label: "Health", value: sample?.healthPercent.map { Format.percent($0) } ?? "–",
                tint: (sample?.healthPercent ?? 100) < 80 ? Theme.warn : nil),
            .init(label: "Cycles", value: sample?.cycleCount.map(String.init) ?? "–"),
        ])
    }
}

// MARK: - Files

private struct ChurnCard: View {
    let model: MetricsModel

    var body: some View {
        ProbeCard(resource: .files) {
            // The same rows before the first reading, with dashes, so the
            // card does not grow when it arrives.
            let c = model.churn
            Readout(model.reading(.files, on: .card))
            StatRow(items: [
                .init(label: "Modified", value: c.map { "\($0.modified)" } ?? "–"),
                .init(label: "Created", value: c.map { "\($0.created)" } ?? "–"),
                .init(label: "Removed", value: c.map { "\($0.removed)" } ?? "–"),
            ])
            // Keyed by path so a re-ranked folder moves rows instead of one
            // row's bar taking another folder's count. Paths are unique per
            // result.
            let buckets = c?.buckets ?? []
            let peak = max(buckets.prefix(4).map(\.events).max() ?? 1, 1)
            RankedList(
                title: "Busiest folders", items: buckets, id: \.path, lanes: 4, empty: "Watching for changes…"
            ) { b in
                BarRow(
                    label: DisplayName.cluster(b.path), value: "\(b.events)",
                    fraction: Double(b.events) / Double(peak), tint: Theme.churn, monospaced: true)
            }
        }
    }
}

// MARK: - Process rows

/// "Show details for …" for each process a card lists, as the card button's
/// accessibility actions. Its own view, so a new ranking redraws these
/// actions and not the Overview.
private struct ProcessDetailActions: View {
    let model: MetricsModel
    let processes: KeyPath<MetricsModel, [ProcessDelta]>
    @Binding var card: ProcessTarget?

    var body: some View {
        // The lanes the card shows; `RankedList` lists three.
        ForEach(model[keyPath: processes].prefix(3).map(ProcessTarget.init)) { target in
            Button("Show details for \(target.name)") { card = target }
        }
    }
}

/// A process in an Overview card's list. A click opens the process card,
/// as a double-click does in the page tables, rather than the resource
/// page. A gesture, not a button: a button here would also reach VoiceOver
/// as a second, bare-named action beside the card's "Show details for …"
/// (`ProcessDetailActions`).
private struct ProcessBarRow<Row: View>: View {
    let process: ProcessDelta
    @Binding var card: ProcessTarget?
    let metrics: MetricsModel
    let app: AppState
    @ViewBuilder let row: () -> Row

    var body: some View {
        let target = ProcessTarget(process)
        row()
            .contentShape(.rect)
            .onTapGesture { card = target }
            .accessibilityAddTraits(.isButton)
            .help("Show details for \(target.name)")
            .contextMenu {
                Button("Show Details") { card = target }
                Button("Show in Finder") { ProcessControl.reveal(target) }
                    .disabled(target.path == nil)
            }
    }
}

// MARK: - Connection

/// Shown while the daemon does not answer, with the one action that fixes
/// the most likely cause. The Overview keeps its cards beneath, so this is a
/// banner rather than `DaemonUnavailableView`; both say the same things.
private struct ConnectionBanner: View {
    let fault: DaemonFault
    let agent: AgentControl
    let fixed: () -> Void

    var body: some View {
        let problem = DaemonProblem(fault: fault, agent: agent.status)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Theme.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title).font(.headline)
                Text(agent.error ?? detail(problem))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            AgentFixButton(problem: problem, agent: agent, fixed: fixed)
        }
        .padding(14)
        .background(Theme.warn.opacity(0.10), in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.warn.opacity(0.35), lineWidth: 0.5)
        }
        .task { agent.refresh() }
    }

    /// The explanation, or the raw reason when there is nothing to explain.
    private func detail(_ problem: DaemonProblem) -> String {
        switch agent.status {
        case .notRegistered, .requiresApproval: return problem.explanation
        case .enabled, .notInBundle: return fault.isDifferentBuild ? problem.explanation : fault.description
        }
    }
}
