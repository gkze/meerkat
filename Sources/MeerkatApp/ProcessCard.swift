import AppKit
import Charts
import MeerkatIPC
import MeerkatKit
import Observation
import SwiftUI

/// The process a card is about: one instance, so a reused pid is not it.
struct ProcessTarget: Hashable, Identifiable {
    let pid: Int32
    let startedAt: Double
    let name: String
    let path: String?
    let uid: UInt32

    var id: Self { self }

    init(_ p: ProcessDelta) {
        pid = p.pid
        startedAt = p.startedAt
        name = DisplayName.process(p.name)
        path = p.path
        uid = p.uid
    }
}

// MARK: - Model

/// Follows one process with `process.sample` while its card is open: the
/// tiles' numbers and their last minute, and the helpers it runs.
@MainActor
@Observable
final class ProcessCardModel {
    let target: ProcessTarget
    private(set) var latest: ProcessDelta?
    private(set) var running = true
    private(set) var cpu = RollingSeries<Double>()
    private(set) var memory = RollingSeries<Double>()
    private(set) var energy = RollingSeries<Double>()
    private(set) var disk = RollingSeries<Double>()
    /// Direct children now: what "helpers" means here.
    private(set) var helpers: [String] = []
    private(set) var problem: String?

    private let client: any DaemonConnection
    private let retryDelay: Duration
    /// Whether the process still runs, checked before following it again.
    private let isRunning: @Sendable (ProcessIdentity) -> Bool
    private var task: Task<Void, Never>?
    private var samples = 0
    private static let history = 60
    /// The longest the card waits before following the process again, as
    /// for the Overview's feeds (`MetricsModel`).
    private static let longestRetry: Duration = .seconds(60)

    init(
        target: ProcessTarget, client: any DaemonConnection, retryDelay: Duration = .seconds(5),
        isRunning: @escaping @Sendable (ProcessIdentity) -> Bool = { identity in
            ProcessTable.record(pid: identity.pid)?.identity == identity
        }
    ) {
        self.target = target
        self.client = client
        self.retryDelay = retryDelay
        self.isRunning = isRunning
    }

    /// Follows the process until it exits. A feed the daemon refuses or
    /// ends, a lost connection, or a feed that ends with no word while the
    /// process runs is the card's `problem`, and the card follows it again,
    /// waiting 5 s and doubling to a minute; the next sample clears it. A
    /// process that has exited meanwhile is not followed again.
    func start() {
        guard task == nil else { return }
        refreshHelpers()
        let client = client
        let parameters = ProcessSampleParameters(pid: target.pid, startedAt: target.startedAt)
        let identity = ProcessIdentity(pid: target.pid, startedAt: target.startedAt)
        let (firstDelay, isRunning) = (retryDelay, self.isRunning)
        task = Task { [weak self] in
            var delay = firstDelay
            while true {
                let reason: String
                do {
                    for try await (payload, _) in try await client.events(
                        ProcessSampleEvent.self, parameters: parameters)
                    {
                        guard let self else { return }
                        if self.problem != nil { self.problem = nil }
                        delay = firstDelay
                        self.apply(payload)
                        if !payload.running { return }
                    }
                    if Task.isCancelled { return }
                    reason = "meerkatd stopped following this process"
                } catch is CancellationError {
                    return
                } catch DaemonClient.ClientError.daemon(let message) {
                    reason = message
                } catch {
                    reason = "\(error)"
                }
                guard let self else { return }
                guard isRunning(identity) else {
                    self.running = false
                    self.problem = nil
                    return
                }
                self.problem = reason
                do { try await Task.sleep(for: delay) } catch { return }
                delay = min(delay * 2, Self.longestRetry)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ payload: ProcessSamplePayload) {
        running = payload.running
        guard let p = payload.process else { return }
        latest = p
        samples += 1
        cpu.append(p.cpuPct, limit: Self.history)
        // Another user's process reports CPU only: a counter this user
        // can't read adds no point, so its tile shows "–" over an empty
        // chart rather than a line at a zero nobody measured.
        if let footprint = p.footprintMB { memory.append(footprint, limit: Self.history) }
        if let watts = p.energyWatts { energy.append(watts, limit: Self.history) }
        if let written = p.diskWriteMBps { disk.append(written, limit: Self.history) }
        if samples % 5 == 1 { refreshHelpers() }
    }

    private func refreshHelpers() {
        let pid = target.pid
        // An unreadable table keeps the last list rather than showing none.
        guard let table = try? ProcessTable.all() else { return }
        helpers = table.filter { $0.parentPid == pid }.map(\.command).sorted()
    }
}

// MARK: - Card

/// Activity Monitor's process window, as a popover, plus what only Meerkat
/// knows: what the process keeps awake, the helpers it runs, the rules on
/// process events, and a rule made from it.
struct ProcessCard: View {
    let target: ProcessTarget
    let metrics: MetricsModel
    let app: AppState
    @State private var model: ProcessCardModel
    @State private var confirmingForceQuit = false
    /// Quit for a process that isn't an app, until confirmed.
    @State private var confirmingQuit = false
    /// Why the last Quit or Force Quit did nothing, until the next one.
    @State private var quitProblem: String?
    @Environment(\.dismiss) private var dismiss

    init(target: ProcessTarget, metrics: MetricsModel, app: AppState) {
        self.target = target
        self.metrics = metrics
        self.app = app
        // One-time seed: the card is recreated for another process.
        _model = State(initialValue: ProcessCardModel(target: target, client: app.client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProcessCardHeader(target: target)
            ProcessTiles(model: model)
            if let problem = model.problem {
                // Why the sample feed stopped, in the daemon's words where
                // it gave some; the model follows the process again, and the
                // tiles keep their last values meanwhile.
                Label("Not updating: \(problem). Trying again.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(problem)
            }
            Text("What Meerkat sees")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ProcessFacts(model: model, metrics: metrics, rules: app.rules)
            Divider()
            actions
            if let quitProblem {
                Label(quitProblem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 380)
        .task { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog(
            "Force quit \(target.name)?", isPresented: $confirmingForceQuit, titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) { quit(force: true) }
        } message: {
            Text("Unsaved changes in it are lost.")
        }
        .confirmationDialog("Quit \(target.name)?", isPresented: $confirmingQuit, titleVisibility: .visible) {
            Button("Quit") { quit(force: false) }
        } message: {
            Text("It isn't an app, so it can't ask to save anything first.")
        }
    }

    /// An app is asked to quit at once, as the Dock asks it, and can ask to
    /// save; anything else is confirmed first, as Activity Monitor does.
    private func requestQuit() {
        if ProcessControl.isApp(target) { quit(force: false) } else { confirmingQuit = true }
    }

    private func quit(force: Bool) {
        quitProblem = ProcessControl.quit(target, force: force).problem(name: target.name)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Make a Rule…") {
                // The card closes and the window shows the sheet.
                dismiss()
                app.newRuleFor = target
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            Button("Show in Finder") { ProcessControl.reveal(target) }
                .disabled(target.path == nil)
                .frame(maxWidth: .infinity)
            Menu("Quit") {
                Button("Force Quit…") { confirmingForceQuit = true }
            } primaryAction: {
                requestQuit()
            }
            // Signalling another user's process is refused (EPERM).
            .disabled(!model.running || !isOwn)
            .help(isOwn ? "Ask \(target.name) to quit" : "\(target.name) belongs to another user")
            .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
    }

    private var isOwn: Bool { target.uid == getuid() }
}

private struct ProcessCardHeader: View {
    let target: ProcessTarget

    var body: some View {
        HStack(spacing: 12) {
            ProcessIcon(pid: target.pid, name: target.name)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let path = target.path {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "pid 4123 · example · started 09:12, 6 hours ago"
    private var subtitle: String {
        let started = Date(epochMilliseconds: target.startedAt)
        let ago = started.formatted(.relative(presentation: .named))
        let user = getpwuid(target.uid).flatMap { String(validatingCString: $0.pointee.pw_name) }
        return ["pid \(target.pid)", user, "started \(started.formatted(date: .omitted, time: .shortened)), \(ago)"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Four live numbers with their last minute. Its own view, so a sample
/// redraws the tiles and not the facts below.
private struct ProcessTiles: View {
    let model: ProcessCardModel

    var body: some View {
        let p = model.latest
        let disk = p?.diskWriteMBps.map(RateUnit.scaled)
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            let footprint = p?.footprintMB.map(MemorySize.parts(megabytes:))
            GridRow {
                ProcessTile(
                    label: "CPU", value: p.map { Format.number($0.cpuPct) }, unit: "% of a core",
                    series: model.cpu, tint: Theme.cpu)
                ProcessTile(
                    label: "Memory", value: footprint?.value, unit: footprint?.unit ?? "GB",
                    series: model.memory, tint: Theme.memory)
            }
            GridRow {
                ProcessTile(
                    label: "Energy", value: p?.energyWatts.map { Format.number($0, digits: 1) }, unit: "W",
                    series: model.energy, tint: Theme.power)
                ProcessTile(
                    label: "Disk", value: disk.map { Format.number($0.value, digits: 1) },
                    unit: disk.map { $0.unit + " written" } ?? "written",
                    series: model.disk, tint: Theme.disk)
            }
        }
    }
}

private struct ProcessTile: View {
    let label: String
    /// Nil until the first sample, or when this user cannot read the counter.
    let value: String?
    let unit: String
    let series: RollingSeries<Double>
    let tint: Color

    private var values: ClosedRange<Double> { StickyTop.range(of: series, headroom: 1.15) { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                let number = RollingNumber(text: value ?? "–", style: .title3)
                number
                    .alignmentGuide(.firstTextBaseline) { _ in number.baseline }
                    .accessibilityRepresentation { Text(value ?? "–") }
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            SlidingPlot(step: series.points.last?.id ?? 0, capacity: series.capacity, values: values) {
                Chart(series.drawn) { point in
                    AreaMark(x: .value("Time", point.id), y: .value(label, point.value))
                        .foregroundStyle(tint.opacity(0.16))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.id), y: .value(label, point.value))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartXScale(domain: windowDomain(series))
                .chartYScale(domain: values)
            }
            .frame(height: 22)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Facts from what the daemon reports now. History (when it ran hot, what
/// it started earlier) needs an event history the app does not keep yet.
private struct ProcessFacts: View {
    let model: ProcessCardModel
    let metrics: MetricsModel
    let rules: RulesModel

    var body: some View {
        let pid = model.target.pid
        let held = (metrics.assertions?.assertions ?? []).filter { $0.pid == pid || $0.onBehalfOfPid == pid }
        let processRules = rules.rules.filter { $0.event?.hasPrefix("process.") == true }
        VStack(alignment: .leading, spacing: 10) {
            if !model.running {
                ProcessFact(
                    symbol: "xmark.circle", tint: .secondary, title: "Exited", detail: "It is no longer running.")
            }
            if let first = held.first {
                ProcessFact(
                    symbol: "bolt.fill", tint: Theme.power, title: "Keeping the Mac awake",
                    detail: held.map(AssertionText.describe).joined(separator: "; "),
                    when: first.startedAt.map {
                        "since " + Date(epochMilliseconds: $0).formatted(date: .omitted, time: .shortened)
                    })
            }
            if !model.helpers.isEmpty {
                ProcessFact(
                    symbol: "arrow.triangle.branch", tint: .secondary,
                    title: model.helpers.count == 1 ? "Running 1 helper" : "Running \(model.helpers.count) helpers",
                    detail: model.helpers.prefix(4).joined(separator: ", ") + (model.helpers.count > 4 ? ", …" : ""))
            }
            if processRules.isEmpty {
                ProcessFact(
                    symbol: "wand.and.rays", tint: .secondary, title: "No rule listens to process events",
                    detail: "Make one to get told, throttle it or record it")
            } else {
                ProcessFact(
                    symbol: "wand.and.rays", tint: .secondary,
                    title: processRules.count == 1
                        ? "1 rule listens to process events" : "\(processRules.count) rules listen to process events",
                    detail: processRules.map(\.file).joined(separator: ", "))
            }
        }
    }
}

private struct ProcessFact: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var when: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            if let when {
                Text(when).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Actions

enum ProcessControl {
    /// The app bundle for an app's executable, the file otherwise.
    static func reveal(_ target: ProcessTarget) {
        guard let path = target.path else { return }
        var url = URL(fileURLWithPath: path)
        if let range = path.range(of: ".app/Contents/MacOS/") {
            url = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    enum QuitOutcome: Equatable {
        /// The app was asked, or the signal sent; whether it quits is up to it.
        case sent
        /// No process with the target's pid and start time: it has exited,
        /// and the pid may be another process's now.
        case exited
        /// The app didn't take the request.
        case declined
        /// `kill` failed with `errno`.
        case failed(errno: Int32)

        /// What to tell the person, nil when there's nothing to say.
        func problem(name: String) -> String? {
            switch self {
            case .sent: nil
            case .exited: "\(name) has already exited."
            case .declined: "\(name) didn't accept the request to quit."
            case .failed(errno: EPERM): "Couldn't quit \(name): it isn't your process."
            case .failed(let code): "Couldn't quit \(name): \(String(cString: strerror(code)))."
            }
        }
    }

    static func isApp(_ target: ProcessTarget) -> Bool {
        NSRunningApplication(processIdentifier: target.pid) != nil
    }

    /// Asks an app to quit the way the Dock does, or sends SIGTERM to
    /// anything else; `force` is SIGKILL. The pid is checked against the
    /// start time first, so a reused pid is never signalled.
    static func quit(_ target: ProcessTarget, force: Bool) -> QuitOutcome {
        guard
            ProcessTable.record(pid: target.pid)?.identity
                == ProcessIdentity(pid: target.pid, startedAt: target.startedAt)
        else { return .exited }
        if let app = NSRunningApplication(processIdentifier: target.pid) {
            return (force ? app.forceTerminate() : app.terminate()) ? .sent : .declined
        }
        return kill(target.pid, force ? SIGKILL : SIGTERM) == 0 ? .sent : .failed(errno: errno)
    }
}
