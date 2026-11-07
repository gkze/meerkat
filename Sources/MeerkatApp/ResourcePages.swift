import AppKit
import MeerkatKit
import SwiftUI

/// One resource's page: a header card with the live value, its stats and a
/// tall chart, then the breakdown beside a sortable table. Every page has
/// that one layout, so moving between them changes the data, not the
/// shape. Pages read only the fields the daemon reports.
struct ResourcePage: View {
    let model: MetricsModel
    let app: AppState
    let resource: Resource

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if let failure = model.feedFailure(resource, onPage: true) { FeedFailureNote(reason: failure) }
                switch resource {
                case .cpu: CPUPage(model: model, app: app)
                case .memory: MemoryPage(model: model, app: app)
                case .disk: DiskPage(model: model, app: app)
                case .network: NetworkPage(model: model)
                case .power: PowerPage(model: model, app: app)
                case .files: FilesPage(model: model)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 940, minHeight: 600)
        .navigationSubtitle(
            "Live · last \(resource == .files ? FilesPage.duration(model.rates) : SamplingRates.chartSpanText)"
        )
        .metricsFeed(model)
    }
}

// MARK: - Charts

/// A resource's chart. Its own view so it reads only its series, and is not
/// rebuilt by the headline beside it, which can update at 4 Hz (Live). Not
/// the Memory card's, which charts compressed memory.
struct ResourceChart: View {
    let resource: Resource
    let model: MetricsModel
    var height: CGFloat = 56

    var body: some View {
        switch resource {
        case .cpu:
            Sparkline(
                metric: "CPU use",
                series: model.ticks.map(\.cpuPercent),
                tint: resource.tint, height: height, format: { Format.percent($0) })
        case .memory:
            Sparkline(
                metric: "Memory in use",
                series: model.ticks.map(\.inUseMB),
                tint: resource.tint, height: height, format: { MemorySize.text(megabytes: $0) })
        case .disk:
            DualSparkline(
                metric: "Disk writes", secondary: "Disk reads", series: model.diskSeries, tint: resource.tint,
                height: height, format: { Format.megabytesPerSecond($0, digits: 0) })
        case .network:
            DualSparkline(
                metric: "Download", secondary: "Upload", series: model.networkSeries, tint: resource.tint,
                height: height, format: { RateUnit.text($0) })
        case .power:
            Sparkline(
                metric: "System power", series: model.powerSeries, tint: resource.tint, height: height,
                format: { Format.watts($0, digits: 0) })
        case .files:
            Sparkline(
                metric: "Changes per window", series: model.churnSeries, tint: resource.tint, height: height,
                format: { Format.number($0) }, span: FilesPage.span(model.rates))
        }
    }
}

// MARK: - Layout

/// The page's two rows. The breakdown column is fixed, the table takes the
/// rest, and nothing in either grows with the data.
private struct PageLayout<Header: View, Breakdown: View, Detail: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var breakdown: Breakdown
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) { breakdown }
                    .frame(width: 320)
                VStack(alignment: .leading, spacing: 14) { detail }
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The header card: what the number is, the number, its stats, and the
/// chart, full width.
private struct PageHeader<Badge: View, Chart: View>: View {
    let resource: Resource
    let reading: ResourceReading
    let stats: [StatRow.Item]
    @ViewBuilder var badge: Badge
    @ViewBuilder var chart: Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 28) {
                HStack(alignment: .top, spacing: 10) {
                    ResourceIcon(symbol: resource.symbol, tint: resource.tint, size: 28)
                    Readout(reading)
                }
                .fixedSize()
                badge
                StatRow(items: stats, divided: false)
            }
            chart
        }
        .padding(16)
        .modifier(CardSurface())
    }
}

/// A titled group in the breakdown column or around a table.
private struct Panel<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Label on the leading edge, value on the trailing one, one line.
private struct ValueRow: View {
    let label: String
    let value: String
    var tint: Color? = nil

    init(_ label: String, _ value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint.map { AnyShapeStyle(Theme.text($0)) } ?? AnyShapeStyle(.primary))
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Why a table is empty, in its place, at the table's height.
private struct TableNote: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: PageTable.height, alignment: .center)
    }
}

/// Tables are eight rows tall whatever they hold, so a page keeps its
/// height between samples. Rows with an app icon are 26 pt; the header and
/// the inset style's margins take 34.
private enum PageTable {
    static let rows = 8
    static let height: CGFloat = 34 + CGFloat(rows) * 26
}

/// A panel's table, or why it is empty, at the table's height. `note` is nil
/// once there are rows.
private struct TableSlot<Content: View>: View {
    let note: String?
    @ViewBuilder var table: Content

    var body: some View {
        if let note {
            TableNote(text: note)
        } else {
            table.frame(height: PageTable.height)
        }
    }
}

/// A panel with a sortable table of every process the page can measure,
/// largest first by the page's own measure, re-sortable by any column:
/// double-click a row, or choose Show Details, for its process card. The
/// panel owns the sort and the card.
private struct ProcessPanel<Columns: TableColumnContent>: View
where Columns.TableRowValue == ProcessRow, Columns.TableColumnSortComparator == KeyPathComparator<ProcessRow> {
    let title: String
    let note: String
    let empty: String
    let processes: [ProcessDelta]
    let model: MetricsModel
    let app: AppState
    private let columns: Columns
    @State private var order: [KeyPathComparator<ProcessRow>]
    @State private var card: ProcessTarget?

    init(
        title: String, note: String, empty: String, processes: [ProcessDelta],
        sortedBy order: KeyPathComparator<ProcessRow>,
        model: MetricsModel, app: AppState,
        @TableColumnBuilder<ProcessRow, KeyPathComparator<ProcessRow>> columns: () -> Columns
    ) {
        self.title = title
        self.note = note
        self.empty = empty
        self.processes = processes
        self.model = model
        self.app = app
        self.columns = columns()
        _order = State(initialValue: [order])
    }

    var body: some View {
        Panel(title: title, note: note) {
            let rows = processes.map(ProcessRow.init).sorted(using: order)
            TableSlot(note: rows.isEmpty ? empty : nil) {
                Table(rows, sortOrder: $order) { columns }
                    .opensProcessCards(rows, card: $card)
            }
        }
        .processCard($card, metrics: model, app: app)
    }
}

/// A segmented bar with its legend: parts of one whole.
private struct PartsBar: View {
    struct Part: Identifiable {
        let label: String
        let value: Double
        let text: String
        let color: Color
        /// Identity when labels repeat (placeholders); the label otherwise.
        var key: String? = nil
        var id: String { key ?? label }
    }

    let parts: [Part]
    /// The whole the parts are shares of; parts that do not fill it leave track.
    var total: Double? = nil

    private var whole: Double { max(total ?? 0, parts.reduce(0) { $0 + $1.value }, 0.0001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentTrack(
                segments: parts.map { .init(id: $0.id, share: $0.value / whole, color: $0.color) }, height: 10)
            // Fixed columns, so a legend entry's longer value never wraps
            // the legend onto another line.
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)])
            {
                ForEach(parts) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                        Text(part.label).foregroundStyle(.secondary)
                        Text(part.text).monospacedDigit()
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(parts.map { "\($0.label) \($0.text)" }.joined(separator: ", "))
    }
}

// MARK: - Process rows

/// A counter the daemon may be unable to read: other users' processes report
/// CPU only. Unknown shows as a dash, not a zero that was never measured, and
/// sorts below every reading, so a largest-first column ends with them.
struct ProcessCounter: Comparable {
    let value: Double?

    static func < (a: Self, b: Self) -> Bool {
        switch (a.value, b.value) {
        case (nil, .some): true
        case (let x?, let y?): x < y
        default: false
        }
    }

    func text(_ format: (Double) -> String) -> String { value.map(format) ?? "–" }
}

/// One process in a page's table, with comparable columns for sorting.
private struct ProcessRow: Identifiable {
    let id: Int32
    let name: String
    let cpu: Double
    let memoryMB: ProcessCounter
    let watts: ProcessCounter
    let writtenMBps: ProcessCounter
    let readMBps: ProcessCounter
    let user: String
    /// For the process card.
    let target: ProcessTarget

    @MainActor init(_ p: ProcessDelta) {
        id = p.pid
        target = ProcessTarget(p)
        name = DisplayName.process(p.name)
        cpu = p.cpuPct
        memoryMB = ProcessCounter(value: p.footprintMB)
        watts = ProcessCounter(value: p.energyWatts)
        writtenMBps = ProcessCounter(value: p.diskWriteMBps)
        readMBps = ProcessCounter(value: p.diskReadMBps)
        user = UserName.of(p.uid)
    }
}

/// The tables' source, `process.list`, arrives one ranking interval after
/// subscribing; a table is empty only until then.
private enum ProcessList {
    static let waiting = "Listing processes…"
}

extension View {
    /// Double-click a process row, or choose Show Details, for its card.
    fileprivate func opensProcessCards(_ rows: [ProcessRow], card: Binding<ProcessTarget?>) -> some View {
        contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
            if let target = rows.first(where: { ids.contains($0.id) })?.target {
                Button("Show Details") { card.wrappedValue = target }
                Button("Show in Finder") { ProcessControl.reveal(target) }
                    .disabled(target.path == nil)
            }
        } primaryAction: { ids in
            card.wrappedValue = rows.first { ids.contains($0.id) }?.target
        }
    }
}

/// Account names by uid, cached: the table asks every second.
@MainActor
private enum UserName {
    private static var cache: [UInt32: String] = [:]

    static func of(_ uid: UInt32) -> String {
        if let hit = cache[uid] { return hit }
        let name = getpwuid(uid).flatMap { String(validatingCString: $0.pointee.pw_name) } ?? "\(uid)"
        cache[uid] = name
        return name
    }
}

/// The process cell: the app's icon and its name.
private struct ProcessName: View {
    let pid: Int32
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            ProcessIcon(pid: pid, name: name)
            Text(name).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - CPU

private struct CPUPage: View {
    let model: MetricsModel
    let app: AppState

    var body: some View {
        PageLayout {
            PageHeader(
                resource: .cpu,
                reading: model.reading(.cpu, on: .page),
                stats: [
                    .init(
                        label: "Busy cores", value: Format.number(model.busyCores, digits: 1) + " of \(model.cpuCount)"),
                    .init(
                        label: "Load 1 / 5 / 15 m",
                        value: [model.load.0, model.load.1, model.load.2].map(Format.load).joined(separator: " · ")),
                    .init(label: "Ranked", value: "every " + SamplingStep.rate(model.rates.rank)),
                ]
            ) {
                ThermalBadge(state: model.thermal)
            } chart: {
                ResourceChart(resource: .cpu, model: model, height: 150)
            }
        } breakdown: {
            Panel(title: "Load average") {
                ValueRow("1 minute", Format.load(model.load.0))
                ValueRow("5 minutes", Format.load(model.load.1))
                ValueRow("15 minutes", Format.load(model.load.2))
            }
            Panel(title: "Thermal") {
                ValueRow("State", model.thermal.label)
                ValueRow("Low Power Mode", model.lowPowerMode ? "On" : "Off")
            }
        } detail: {
            ProcessPanel(
                title: "Processes", note: "% of one core · double-click for details", empty: ProcessList.waiting,
                processes: model.allProcesses, sortedBy: KeyPathComparator(\.cpu, order: .reverse), model: model,
                app: app
            ) {
                TableColumn("Process", value: \.name) { row in
                    ProcessName(pid: row.id, name: row.name)
                }
                TableColumn("% CPU", value: \.cpu) { Text(Format.number($0.cpu, digits: 1)).monospacedDigit() }
                    .width(70).alignment(.trailing)
                TableColumn("Memory", value: \.memoryMB) {
                    Text($0.memoryMB.text(MemorySize.text(megabytes:))).monospacedDigit()
                }
                .width(80).alignment(.trailing)
                TableColumn("Energy", value: \.watts) { Text($0.watts.text { Format.watts($0) }).monospacedDigit() }
                    .width(64).alignment(.trailing)
                TableColumn("User", value: \.user) { Text($0.user).lineLimit(1) }.width(90)
                TableColumn("PID", value: \.id) { Text(String($0.id)).monospacedDigit() }
                    .width(60).alignment(.trailing)
            }
        }
    }
}

// MARK: - Memory

private struct MemoryPage: View {
    let model: MetricsModel
    let app: AppState

    var body: some View {
        let m = model.memory
        PageLayout {
            PageHeader(
                resource: .memory,
                reading: model.reading(.memory, on: .page),
                stats: MemoryPart.inUse.map { part -> StatRow.Item in
                    StatRow.Item(
                        label: part.label,
                        value: m.map { MemorySize.text(megabytes: $0[keyPath: part.megabytes]) } ?? "–")
                } + [
                    .init(
                        label: "Swap",
                        value: m.map {
                            "\(MemorySize.text(megabytes: $0.swapUsedMB)) of \(MemorySize.text(megabytes: $0.swapTotalMB))"
                        } ?? "–")
                ]
            ) {
                PressureBadge(level: model.pressure)
            } chart: {
                ResourceChart(resource: .memory, model: model, height: 150)
            }
        } breakdown: {
            Panel(title: "Composition") {
                PartsBar(parts: composition, total: model.physicalMB)
            }
            Panel(title: "Pressure") {
                PressureTimeline(log: model.pressureLog, current: model.pressure)
            }
        } detail: {
            ProcessPanel(
                title: "Processes", note: "memory footprint · your processes", empty: ProcessList.waiting,
                processes: model.allProcesses.filter { $0.footprintMB != nil },
                sortedBy: KeyPathComparator(\.memoryMB, order: .reverse),
                model: model,
                app: app
            ) {
                TableColumn("Process", value: \.name) { row in
                    ProcessName(pid: row.id, name: row.name)
                }
                TableColumn("Memory", value: \.memoryMB) {
                    Text($0.memoryMB.text(MemorySize.text(megabytes:))).monospacedDigit()
                }
                .width(90).alignment(.trailing)
                TableColumn("% CPU", value: \.cpu) { Text(Format.number($0.cpu, digits: 1)).monospacedDigit() }
                    .width(70).alignment(.trailing)
                TableColumn("PID", value: \.id) { Text(String($0.id)).monospacedDigit() }
                    .width(60).alignment(.trailing)
            }
        }
    }
}

extension MemoryPage {
    /// What the in-use memory is made of, plus inactive pages; free memory
    /// is the bar's remaining track.
    fileprivate var composition: [PartsBar.Part] {
        let m = model.memory
        let inactive = MemoryPart(label: "Inactive", megabytes: \.inactiveMB, color: Theme.memory.opacity(0.14))
        return (MemoryPart.inUse + [inactive]).map { part in
            let mb = m?[keyPath: part.megabytes]
            return PartsBar.Part(
                label: part.label, value: mb ?? 0, text: mb.map(MemorySize.text(megabytes:)) ?? "–", color: part.color)
        }
    }
}

/// Memory pressure over the chart span: one band per level, colour and
/// label both, so it does not rely on colour alone.
private struct PressureTimeline: View {
    let log: [(at: Date, level: PressureLevel)]
    let current: PressureLevel

    var body: some View {
        // Redrawn every few seconds so the bands slide with time even when
        // the level does not change.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let now = context.date
            let start = now.addingTimeInterval(-SamplingRates.chartSpan)
            let bands = Self.bands(log: log, current: current, start: start, now: now)
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(bands, id: \.start) { band in
                            Rectangle()
                                .fill(Self.color(band.level))
                                .frame(width: geo.size.width * band.share)
                        }
                    }
                }
                .frame(height: 14)
                .clipShape(.rect(cornerRadius: 4))
                HStack {
                    Text("\(SamplingRates.chartSpanText) ago")
                    Spacer()
                    Text("now")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                Text(Self.summary(bands))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory pressure, last \(SamplingRates.chartSpanText)")
            .accessibilityValue(Self.summary(bands))
        }
    }

    struct Band {
        let start: Date
        let level: PressureLevel
        let share: Double
        let seconds: Double
    }

    static func bands(log: [(at: Date, level: PressureLevel)], current: PressureLevel, start: Date, now: Date)
        -> [Band]
    {
        let span = max(now.timeIntervalSince(start), 1)
        // Before the first reading the level is unknown; show it as the
        // current one rather than a gap.
        var changes = log.isEmpty ? [(at: start, level: current)] : log
        if changes[0].at > start { changes.insert((start, changes[0].level), at: 0) }
        var bands: [Band] = []
        for (index, change) in changes.enumerated() {
            let from = max(change.at, start)
            let to = index + 1 < changes.count ? changes[index + 1].at : now
            guard to > from else { continue }
            let seconds = to.timeIntervalSince(from)
            bands.append(Band(start: from, level: change.level, share: seconds / span, seconds: seconds))
        }
        return bands
    }

    static func color(_ level: PressureLevel) -> Color {
        switch level {
        case .normal: Theme.normal
        case .warning: Theme.warn
        case .critical: Theme.critical
        }
    }

    /// "Normal throughout", or "Elevated for 8 s, critical for 2 s".
    static func summary(_ bands: [Band]) -> String {
        let raised = Dictionary(grouping: bands.filter { $0.level != .normal }, by: \.level)
        guard !raised.isEmpty else { return "Normal throughout" }
        return [PressureLevel.warning, .critical].compactMap { level -> String? in
            guard let bands = raised[level] else { return nil }
            let seconds = Int(bands.reduce(0) { $0 + $1.seconds }.rounded())
            return "\(level == .warning ? "Elevated" : "Critical") for \(seconds) s"
        }.joined(separator: ", ")
    }
}

// MARK: - Disk

private struct DiskPage: View {
    let model: MetricsModel
    let app: AppState

    private var physical: [DiskRate] { (model.disk?.disks ?? []).filter { !$0.isVirtual } }

    var body: some View {
        let disks = physical
        let latency = disks.compactMap(\.writeLatencyMs).max()
        PageLayout {
            PageHeader(
                resource: .disk,
                reading: model.reading(.disk, on: .page),
                stats: [
                    .init(label: "Read", value: RateUnit.text(model.diskReadMBps)),
                    .init(
                        label: "Writes / s",
                        value: model.disk == nil
                            ? "–" : Format.number(disks.reduce(0) { $0 + $1.writesPerSecond })
                    ),
                    .init(
                        label: "Reads / s",
                        value: model.disk == nil
                            ? "–" : Format.number(disks.reduce(0) { $0 + $1.readsPerSecond })),
                    .init(label: "Write latency", value: latency.map(Format.milliseconds) ?? "–"),
                ]
            ) {
                EmptyView()
            } chart: {
                ResourceChart(resource: .disk, model: model, height: 150)
            }
        } breakdown: {
            Panel(title: model.scopeName("/")) {
                let volume = model.volume
                let used = volume.map { Double($0.total - $0.free) } ?? 0
                PartsBar(
                    parts: [
                        .init(
                            label: "Used", value: used,
                            text: volume.map { _ in
                                ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)
                            }
                                ?? "–", color: Theme.disk),
                        .init(
                            label: "Free", value: Double(volume?.free ?? 0),
                            text: volume.map { ByteCountFormatter.string(fromByteCount: $0.free, countStyle: .file) }
                                ?? "–",
                            color: .clear),
                    ], total: Double(volume?.total ?? 0))
            }
            Panel(title: "Disks") {
                if disks.isEmpty {
                    Text("Reading disks…").foregroundStyle(.tertiary)
                } else {
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Disk").gridColumnAlignment(.leading)
                            Text("Write")
                            Text("Read")
                            Text("Latency")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(disks, id: \.bsdName) { d in
                            GridRow {
                                Text(d.bsdName).font(.system(.callout, design: .monospaced))
                                Text(RateUnit.text(d.writeBytesPerSecond / 1e6))
                                Text(RateUnit.text(d.readBytesPerSecond / 1e6))
                                Text(d.writeLatencyMs.map(Format.milliseconds) ?? "–")
                            }
                            .monospacedDigit()
                            .lineLimit(1)
                        }
                    }
                }
            }
        } detail: {
            ProcessPanel(
                title: "Your processes", note: "per ranking window · others need root",
                empty: ProcessList.waiting, processes: model.allProcesses.filter { $0.diskReadMB != nil },
                sortedBy: KeyPathComparator(\.writtenMBps, order: .reverse), model: model, app: app
            ) {
                TableColumn("Process", value: \.name) { row in
                    ProcessName(pid: row.id, name: row.name)
                }
                TableColumn("Written", value: \.writtenMBps) {
                    Text($0.writtenMBps.text(RateUnit.text)).monospacedDigit()
                }
                .width(90).alignment(.trailing)
                TableColumn("Read", value: \.readMBps) { Text($0.readMBps.text(RateUnit.text)).monospacedDigit() }
                    .width(90).alignment(.trailing)
                TableColumn("PID", value: \.id) { Text(String($0.id)).monospacedDigit() }
                    .width(60).alignment(.trailing)
            }
        }
    }
}

// MARK: - Network

private struct InterfaceRow: Identifiable {
    let id: String
    let down: Double
    let up: Double
    let packets: Double
    let errors: Int

    init(_ i: InterfaceRate) {
        id = i.name
        down = i.receivedBytesPerSecond / 1e6
        up = i.sentBytesPerSecond / 1e6
        packets = i.receivedPacketsPerSecond + i.sentPacketsPerSecond
        errors = i.errors
    }
}

private struct NetworkPage: View {
    let model: MetricsModel
    @State private var order = [KeyPathComparator(\InterfaceRow.down, order: .reverse)]

    var body: some View {
        let interfaces = model.network?.interfaces ?? []
        PageLayout {
            PageHeader(
                resource: .network,
                reading: model.reading(.network, on: .page),
                stats: [
                    .init(label: "Upload", value: RateUnit.text(model.networkSentMBps)),
                    .init(
                        label: "Packets in / s",
                        value: model.network == nil
                            ? "–" : Format.number(interfaces.reduce(0) { $0 + $1.receivedPacketsPerSecond })),
                    .init(
                        label: "Packets out / s",
                        value: model.network == nil
                            ? "–" : Format.number(interfaces.reduce(0) { $0 + $1.sentPacketsPerSecond })),
                    .init(
                        label: "Errors",
                        value: model.network == nil ? "–" : "\(interfaces.reduce(0) { $0 + $1.errors })"),
                ]
            ) {
                EmptyView()
            } chart: {
                ResourceChart(resource: .network, model: model, height: 150)
            }
        } breakdown: {
            Panel(title: "Connection") {
                if let path = model.networkPath {
                    ValueRow(
                        "Status", Self.status(path.status),
                        tint: path.status == .satisfied ? Theme.normal : Theme.warn)
                    ValueRow("Via", Self.via(path))
                    ValueRow("Expensive", path.isExpensive ? "Yes" : "No")
                    ValueRow("Constrained", path.isConstrained ? "Yes" : "No")
                } else {
                    Text("Reading the network path…").foregroundStyle(.tertiary)
                }
            }
        } detail: {
            Panel(title: "Interfaces") {
                let rows = interfaces.map(InterfaceRow.init).sorted(using: order)
                TableSlot(note: rows.isEmpty ? "No traffic in this interval" : nil) {
                    Table(rows, sortOrder: $order) {
                        TableColumn("Interface", value: \.id) {
                            Text($0.id).font(.system(.body, design: .monospaced))
                        }
                        TableColumn("Down", value: \.down) { Text(RateUnit.text($0.down)).monospacedDigit() }
                            .width(90).alignment(.trailing)
                        TableColumn("Up", value: \.up) { Text(RateUnit.text($0.up)).monospacedDigit() }
                            .width(90).alignment(.trailing)
                        TableColumn("Packets / s", value: \.packets) {
                            Text(Format.number($0.packets)).monospacedDigit()
                        }
                        .width(90).alignment(.trailing)
                        TableColumn("Errors", value: \.errors) { Text("\($0.errors)").monospacedDigit() }
                            .width(60).alignment(.trailing)
                    }
                }
            }
        }
    }

    static func status(_ status: NetworkPathPayload.Status) -> String {
        switch status {
        case .satisfied: "Connected"
        case .unsatisfied: "Not connected"
        case .requiresConnection: "Connecting"
        }
    }

    /// "Wi-Fi · en0": the first interface the path uses.
    static func via(_ path: NetworkPathPayload) -> String {
        guard let first = path.interfaces.first else { return "–" }
        let kind =
            switch first.type {
            case .wifi: "Wi-Fi"
            case .wiredEthernet: "Ethernet"
            case .cellular: "Cellular"
            case .loopback: "Loopback"
            case .other: "Other"
            }
        return "\(kind) · \(first.name)"
    }
}

// MARK: - Power

private struct AssertionRow: Identifiable {
    let id: Int
    let pid: Int32
    let process: String
    let what: String
    let since: Double

    init(_ a: PowerAssertion) {
        id = a.id
        pid = a.pid
        process = a.process.map(DisplayName.process) ?? "pid \(a.pid)"
        what = AssertionText.describe(a)
        since = a.startedAt ?? 0
    }
}

/// Power assertion types in words, for the Power page and process cards.
enum AssertionText {
    /// "Prevents sleep · Time Machine": the type, and the name its holder gave.
    static func describe(_ assertion: PowerAssertion) -> String {
        [describe(assertion.type), assertion.name].compactMap { $0 }.joined(separator: " · ")
    }

    /// The common IOKit types in words; others as reported.
    static func describe(_ type: String) -> String {
        switch type {
        case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion": "Prevents sleep"
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": "Keeps the display on"
        case "BackgroundTask": "Background task"
        case "UserIsActive": "User activity"
        case "NetworkClientActive": "Network client"
        default: type
        }
    }
}

private struct PowerPage: View {
    let model: MetricsModel
    let app: AppState
    @State private var order = [KeyPathComparator(\AssertionRow.since)]

    var body: some View {
        // Without battery telemetry (a desktop Mac) only the battery's parts
        // go: energy, power assertions and Low Power Mode don't depend on
        // one, and there they are the page's whole content.
        PageLayout {
            if hasBattery {
                PageHeader(
                    resource: .power,
                    reading: model.reading(.power, on: .page),
                    stats: [
                        .init(label: "Battery", value: model.batteryText ?? "–", tint: model.batteryTint),
                        .init(
                            label: "Health", value: sample?.healthPercent.map { Format.percent($0) } ?? "–"),
                        .init(label: "Cycles", value: sample?.cycleCount.map(String.init) ?? "–"),
                        .init(label: "Time to full", value: timeToFull),
                    ]
                ) {
                    if model.lowPowerMode { StatusBadge(text: "Low Power Mode", tint: Theme.warn) }
                } chart: {
                    ResourceChart(resource: .power, model: model, height: 150)
                }
            }
        } breakdown: {
            if hasBattery {
                Panel(title: "Battery") {
                    let percent = model.batteryLevel?.currentCapacityPercent
                    PartsBar(
                        parts: [
                            .init(
                                label: "Charge", value: percent ?? 0,
                                text: percent.map { Format.percent($0) } ?? "–",
                                color: Theme.power)
                        ], total: 100)
                    ValueRow("Full charge", sample?.fullChargeCapacityMAh.map { "\($0.formatted()) mAh" } ?? "–")
                    ValueRow("Design", sample?.designCapacityMAh.map { "\($0.formatted()) mAh" } ?? "–")
                    ValueRow("Voltage", sample?.voltage.map { Format.number($0, digits: 1) + " V" } ?? "–")
                    ValueRow("Low Power Mode", model.lowPowerMode ? "On" : "Off")
                }
            } else {
                Panel(title: "Power") {
                    Text("This Mac reports no battery telemetry").foregroundStyle(.tertiary)
                        .help(noBatteryReason)
                    ValueRow("Low Power Mode", model.lowPowerMode ? "On" : "Off")
                }
            }
        } detail: {
            ProcessPanel(
                title: "Energy", note: "per ranking window · your processes", empty: ProcessList.waiting,
                processes: model.allProcesses.filter { $0.energyJoules != nil },
                sortedBy: KeyPathComparator(\.watts, order: .reverse), model: model, app: app
            ) {
                TableColumn("Process", value: \.name) { row in
                    ProcessName(pid: row.id, name: row.name)
                }
                TableColumn("Energy", value: \.watts) { Text($0.watts.text { Format.watts($0) }).monospacedDigit() }
                    .width(70).alignment(.trailing)
                TableColumn("% CPU", value: \.cpu) { Text(Format.number($0.cpu, digits: 1)).monospacedDigit() }
                    .width(70).alignment(.trailing)
                TableColumn("PID", value: \.id) { Text(String($0.id)).monospacedDigit() }
                    .width(60).alignment(.trailing)
            }
            Panel(title: "Keeping the Mac awake", note: "power assertions") {
                let rows = (model.assertions?.assertions ?? []).map(AssertionRow.init).sorted(using: order)
                let empty = model.assertions == nil ? "Reading assertions…" : "Nothing is keeping the Mac awake"
                TableSlot(note: rows.isEmpty ? empty : nil) {
                    Table(rows, sortOrder: $order) {
                        TableColumn("Process", value: \.process) { ProcessName(pid: $0.pid, name: $0.process) }
                        TableColumn("Assertion", value: \.what) { Text($0.what).lineLimit(1) }
                        TableColumn("Since", value: \.since) {
                            Text(Format.time($0.since == 0 ? nil : $0.since)).monospacedDigit()
                        }
                        .width(70).alignment(.trailing)
                    }
                }
            }
        }
    }

    /// False once the daemon refuses `battery.sample`; while waiting for the
    /// first sample the battery layout shows with dashes.
    private var hasBattery: Bool {
        if case .unavailable = model.battery { return false }
        return true
    }

    /// The daemon's refusal, for the curious.
    private var noBatteryReason: String {
        if case .unavailable(let reason) = model.battery { return reason }
        return ""
    }

    private var sample: BatterySamplePayload? {
        if case .reported(let sample) = model.battery { return sample }
        return nil
    }

    private var timeToFull: String {
        guard let battery = model.batteryLevel else { return "–" }
        if battery.isCharged == true { return "Charged" }
        guard battery.isCharging == true else { return "Not charging" }
        guard let minutes = battery.timeToFullMinutes else { return "–" }
        return Format.duration(minutes: minutes)
    }
}

// MARK: - Files

private struct FolderRow: Identifiable {
    let id: String
    let events: Int
}

private struct FilesPage: View {
    let model: MetricsModel
    @State private var order = [KeyPathComparator(\FolderRow.events, order: .reverse)]

    var body: some View {
        let c = model.churn
        PageLayout {
            PageHeader(
                resource: .files,
                reading: model.reading(.files, on: .page),
                stats: [
                    .init(label: "Modified", value: c.map { $0.modified.formatted() } ?? "–"),
                    .init(label: "Created", value: c.map { $0.created.formatted() } ?? "–"),
                    .init(label: "Removed", value: c.map { $0.removed.formatted() } ?? "–"),
                    .init(label: "Renamed", value: c.map { $0.renamed.formatted() } ?? "–"),
                ]
            ) {
                EmptyView()
            } chart: {
                ResourceChart(resource: .files, model: model, height: 150)
            }
        } breakdown: {
            Panel(title: "By kind") {
                // Four entries always (dashes until a reading, or "–" names
                // when fewer kinds changed), so the legend keeps its two lines.
                let kinds = Array((c?.categories ?? []).prefix(4))
                let shades = [1.0, 0.65, 0.4, 0.2]
                PartsBar(
                    parts: shades.indices.map { index in
                        let kind = index < kinds.count ? kinds[index] : nil
                        return .init(
                            label: kind.map { Self.kindName($0.path) } ?? "–",
                            value: Double(kind?.events ?? 0), text: kind.map { $0.events.formatted() } ?? "",
                            color: Theme.churn.opacity(shades[index]), key: "\(index)")
                    })
            }
            Panel(title: "Watching") {
                ValueRow("Folder", c.map { model.scopeName($0.root) } ?? "–")
                ValueRow(
                    "Excluding",
                    c.map { $0.excluded.isEmpty ? "Nothing" : $0.excluded.map(Self.short).joined(separator: " · ") }
                        ?? "–")
                ValueRow(
                    "Window",
                    "\(Int(SamplingRates.churnWindow)) s every \(SamplingStep.rate(model.rates.churnEvery))")
                ValueRow("Set in", "meerkat.json")
            }
        } detail: {
            Panel(title: "Busiest folders", note: "double-click to show in Finder") {
                let rows = (c?.buckets ?? []).map { FolderRow(id: $0.path, events: $0.events) }.sorted(using: order)
                TableSlot(note: rows.isEmpty ? "Watching for changes…" : nil) {
                    Table(rows, sortOrder: $order) {
                        TableColumn("Folder", value: \.id) {
                            Text($0.id).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                        TableColumn("Events", value: \.events) { Text($0.events.formatted()).monospacedDigit() }
                            .width(80).alignment(.trailing)
                    }
                    .contextMenu(forSelectionType: FolderRow.ID.self) { paths in
                        if !paths.isEmpty {
                            Button("Show in Finder", systemImage: "folder") { Self.reveal(paths) }
                        }
                    } primaryAction: { paths in
                        Self.reveal(paths)
                    }
                }
            }
        }
    }

    private static func reveal(_ paths: Set<FolderRow.ID>) {
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// "10 min": the churn series holds one point per window.
    static func duration(_ rates: SamplingRates) -> String {
        SamplingStep.span(rates.churnEvery * Double(MetricsModel.churnHistoryLimit))
    }

    static func span(_ rates: SamplingRates) -> String { "\(duration(rates)) ago" }

    static func kindName(_ category: String) -> String {
        category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func short(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
