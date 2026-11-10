import MeerkatIPC
import MeerkatKit
import SwiftUI

/// meerkatd itself: the process, the rule runtime, and every event source
/// running right now, with its subscribers, throughput and drops.
struct HealthPage: View {
    let model: HealthModel
    let app: AppState

    var body: some View {
        content
            .navigationSubtitle(model.status.map { "meerkatd \($0.version) · pid \($0.pid)" } ?? "")
            // In the toolbar, so they stay reachable when the daemon does not
            // answer: a restart is most useful then.
            .toolbar { DaemonActions(agent: app.agent) }
            .task { await model.watch() }
    }

    @ViewBuilder
    private var content: some View {
        if let status = model.status {
            VStack(spacing: 0) {
                if case .failed(let fault) = model.loadState {
                    StaleBanner(subject: "status", fault: fault)
                    Divider()
                }
                HealthSummary(status: status, startedAt: model.startedAt, app: app)
                Divider()
                SourcesTable(model: model, app: app)
                if !model.dropped.isEmpty {
                    Divider()
                    DroppedList(model: model, app: app)
                }
            }
        } else {
            DaemonLoadGate(state: model.loadState, agent: app.agent) { await model.refresh() }
        }
    }
}

/// Restart and Reinstall, each confirmed first, as everywhere they are
/// offered (`AgentControl.Action.confirmation`). Its own toolbar content, so
/// an action's progress redraws the toolbar, not the page.
private struct DaemonActions: ToolbarContent {
    let agent: AgentControl
    @State private var pending: AgentControl.Action?
    /// The failure of an action started here. Kept apart from
    /// `agent.error`, which any surface's action sets: one that failed from
    /// a banner is reported there, not as an alert here later.
    @State private var failure: String?

    var body: some ToolbarContent {
        ToolbarItemGroup {
            if let action = agent.action {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(action.label).foregroundStyle(.secondary)
                }
            }
            // Distinct symbols: Rules uses a bare arrow.clockwise for Reload,
            // and two circular arrows side by side read as one action.
            // (The "restart" symbol reads as a Back button.)
            Button("Restart", systemImage: "arrow.clockwise.circle") { pending = .restarting }
                .help("Restart meerkatd through launchd")
                .disabled(!agent.canRestart)
            Button("Reinstall Agent", systemImage: "arrow.down.app") { pending = .reinstalling }
                .help("Register the agent from this copy of Meerkat.app again; nothing is rebuilt")
                .disabled(!agent.canReinstall)
                .confirmingAgentAction($pending, agent: agent) { failure = $0 }
                .alert(
                    "The meerkatd action failed",
                    isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
                ) {
                    Button("OK") { agent.dismissError() }
                } message: {
                    Text(failure ?? "")
                }
        }
    }
}

/// Process and rule runtime, side by side. Changes only when a poll brings
/// a different status.
private struct HealthSummary: View {
    let status: DaemonStatus
    let startedAt: Date?
    let app: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Section(title: "Daemon", symbol: "gearshape.2") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    LabeledGridRow(label: "Version") { Text(status.version) }
                    LabeledGridRow(label: "Process") { Text("pid \(status.pid)").monospacedDigit() }
                    LabeledGridRow(label: "Running for") {
                        if let startedAt {
                            Text(startedAt, style: .relative)
                        }
                    }
                    LabeledGridRow(label: "Executable") {
                        PathButton(path: status.executablePath) { Finder.reveal(status.executablePath) }
                    }
                }
            }
            Section(title: "Rules", symbol: "wand.and.rays") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    LabeledGridRow(label: "Runtime") {
                        StatusBadge(text: status.handlerHost.state.label, status: status.handlerHost.state.status)
                    }
                    LabeledGridRow(label: "Workers") {
                        Text(status.handlerHost.workers, format: .number).monospacedDigit()
                    }
                    LabeledGridRow(label: "Restarts") {
                        Text(status.handlerHost.restarts, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(status.handlerHost.restarts > 0 ? Status.warning.text : .primary)
                    }
                    LabeledGridRow(label: "Status") {
                        Button {
                            app.destination = .rules
                        } label: {
                            Text(RuleCounts(status.rules).summary)
                        }
                        .buttonStyle(.link)
                        .help("Open the Rules page")
                    }
                    LabeledGridRow(label: "Folder") {
                        PathButton(path: status.rulesDirectory) {
                            Finder.open(URL(fileURLWithPath: status.rulesDirectory))
                        }
                    }
                }
                if let lastExit = status.handlerHost.lastExit {
                    Text("Last exit: \(lastExit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(lastExit)
                }
            }
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Section<Content: View>: View {
        let title: String
        let symbol: String
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                content
            }
            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A long path as a link that keeps its distinctive end visible.
private struct PathButton: View {
    let path: String
    let action: () -> Void

    var body: some View {
        LinkButton(path, monospaced: false, action: action)
            .help(path)
    }
}

/// Every running source instance. The only view that reads per-poll
/// counters, so polls redraw the table and not the summary.
private struct SourcesTable: View {
    let model: HealthModel
    let app: AppState
    @State private var selection: SourceStatistics.ID?

    var body: some View {
        let sources = (model.status?.sources ?? []).sorted { ($0.kind, $0.instance) < ($1.kind, $1.instance) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Running sources", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Text("A source runs while something subscribes to it, including this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Table(sources, selection: $selection) {
                TableColumn("Event") { source in
                    LinkButton(source.kind) { app.showEvent(source.kind, parameters: source.parameters) }
                        .help("Open \(source.kind) in the Event Explorer with these parameters")
                }
                .width(min: 120, ideal: 170)
                TableColumn("Parameters") { source in
                    let text = source.parameters.canonicalString
                    Text(text == "{}" ? "none" : text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source.detail.map { "\(text)\n\n\($0)" } ?? text)
                }
                .width(min: 120, ideal: 240)
                TableColumn("Subscribers") { source in
                    Text(source.subscribers, format: .number)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Delivered") { source in
                    Text(source.delivered, format: .number)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("Rate") { source in
                    Group {
                        if let rate = model.rates[source.id], rate < 0.05 {
                            Text("0/s").foregroundStyle(.secondary)
                        } else if let rate = model.rates[source.id] {
                            Text("\(rate, format: .number.precision(.fractionLength(rate < 10 ? 1 : 0)))/s")
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 70, max: 100)
                TableColumn("Dropped") { source in
                    Text(source.dropped, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(source.dropped > 0 ? Status.warning.text : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 70, max: 100)
                // Payloads JSON can't carry (a NaN, say): the source's fault,
                // not a slow subscriber's, so not counted as dropped.
                TableColumn("Unencodable") { source in
                    Text(source.unencodable, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(source.unencodable > 0 ? Status.warning.text : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(source.lastUnencodable ?? "Every payload this source made could be sent.")
                }
                .width(min: 60, ideal: 90, max: 110)
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .contextMenu(forSelectionType: SourceStatistics.ID.self) { ids in
                if let source = sources.first(where: { ids.contains($0.id) }) {
                    Button("Open in Event Explorer", systemImage: "list.bullet.rectangle.portrait") {
                        app.showEvent(source.kind, parameters: source.parameters)
                    }
                }
            } primaryAction: { ids in
                if let source = sources.first(where: { ids.contains($0.id) }) {
                    app.showEvent(source.kind, parameters: source.parameters)
                }
            }
            .overlay {
                if sources.isEmpty {
                    ContentUnavailableView(
                        "No sources running",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Nothing is subscribed. Sources start when a rule or a client subscribes.")
                    )
                }
            }
        }
    }
}

/// Recent `meerkat.dropped` reports: subscribers that fell behind.
private struct DroppedList: View {
    let model: HealthModel
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Dropped events", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(Status.warning.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.dropped) { report in
                        HStack(spacing: 8) {
                            Text(report.date, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            LinkButton(report.kind) { app.showEvent(report.kind, parameters: report.parameters) }
                                .fixedSize()
                            Text("\(report.dropped, format: .number) dropped")
                                .monospacedDigit()
                            // Reports are per file, so two rows for one source
                            // differ only here. No file is the daemon's own
                            // subscriptions (its rules-folder watch) or a
                            // client's (`DroppedEventsPayload.file`).
                            Text(report.file.map { "by \($0)" } ?? "by the daemon or a client")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
