import MeerkatIPC
import MeerkatKit
import SwiftUI

/// Every event kind the daemon offers, and a live view of any one of them.
///
/// The catalog drives the whole page: the list, the metadata and the
/// parameter hint come from `CatalogEntry`, and payloads are rendered from
/// their JSON. A kind added to the daemon shows up here as it is.
struct EventExplorer: View {
    @Bindable var model: ExplorerModel
    let app: AppState
    @State private var query = ""
    /// Page-wide, so hiding the inspector stays hidden across kinds.
    @State private var showInspector = true

    var body: some View {
        HStack(spacing: 0) {
            CatalogList(model: model, agent: app.agent, query: query)
                .frame(width: 300)
            Divider()
            Group {
                if let entry = model.selectedEntry {
                    KindDetail(entry: entry, model: model, app: app, showInspector: $showInspector)
                        // Fresh parameter text and selection per kind.
                        .id(entry.descriptor.name)
                } else {
                    ContentUnavailableView(
                        "Select an Event",
                        systemImage: "list.bullet.rectangle.portrait",
                        description: Text("Pick any event the daemon offers to see what it delivers.")
                    )
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search events")
        .task { await model.loadCatalog() }
        .onChange(of: model.selectedKind) { model.reset() }
        // A subscription runs only while the page is on screen.
        .onDisappear { model.stop() }
    }
}

// MARK: - Catalog

private struct CatalogList: View {
    @Bindable var model: ExplorerModel
    let agent: AgentControl
    let query: String

    var body: some View {
        switch model.catalogState {
        case .loading, .failed:
            // The catalog comes from the daemon, so its failure is the
            // daemon's, with the same explanation and fix as other pages.
            DaemonLoadGate(state: model.catalogState, agent: agent) { await model.loadCatalog() }
        case .loaded:
            let families = model.families(matching: query)
            if families.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selectedKind) {
                        ForEach(families) { family in
                            Section(family.name) {
                                ForEach(family.entries, id: \.descriptor.name) { entry in
                                    CatalogRow(descriptor: entry.descriptor)
                                }
                            }
                        }
                    }
                    // A link from another page selects a kind that may be
                    // far down the list; bring it into view.
                    .onChange(of: model.selectedKind, initial: true) {
                        if let kind = model.selectedKind { proxy.scrollTo(kind, anchor: .center) }
                    }
                }
            }
        }
    }
}

private struct CatalogRow: View {
    let descriptor: EventDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(descriptor.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let need = descriptor.permission {
                    Image(systemName: need.without == .refused ? "lock" : "lock.open")
                        .foregroundStyle(.secondary)
                        .help(need.sentence)
                        .accessibilityLabel(need.sentence)
                }
            }
            Text(descriptor.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One kind

private struct KindDetail: View {
    let entry: CatalogEntry
    let model: ExplorerModel
    let app: AppState
    @Binding var showInspector: Bool
    @State private var selection: ReceivedEvent.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KindHeader(entry: entry)
            UsedByRules(kind: entry.descriptor.name, rules: app.rules, app: app)
            Divider()
            SubscriptionBar(entry: entry, model: model)
            Divider()
            EventTable(model: model, selection: $selection)
        }
        .trailingPanel(isPresented: showInspector, width: 260...520, ideal: 340) {
            EventInspector(model: model, selection: selection)
        }
        .focusedSceneValue(\.detailsPanel, $showInspector)
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "Hide payload inspector" : "Show payload inspector")
            }
        }
    }
}

/// What the catalog says about the kind. Static for a given entry, so it
/// does not redraw as events arrive.
private struct KindHeader: View {
    let entry: CatalogEntry

    private var descriptor: EventDescriptor { entry.descriptor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(descriptor.name)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
            // No vertical fixedSize: the window's minimum height comes from
            // content, and a summary laid out at the pane's minimum width
            // would demand most of a screen.
            Text(descriptor.summary)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .help(descriptor.summary)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                MetadataRow(label: "Delivery", value: descriptor.mechanism.explanation)
                MetadataRow(label: "Meaning", value: descriptor.semantics.explanation)
                MetadataRow(label: "Loss", value: descriptor.loss.explanation)
                MetadataRow(label: "Interface", value: descriptor.stability.explanation)
                MetadataRow(label: "Source", value: descriptor.source)
            }
            .font(.callout)

            if let need = descriptor.permission {
                Label {
                    Text(
                        "\(need.sentence) (\(need.permission.settingsPane)). Subscribing can make macOS ask for it."
                    )
                } icon: {
                    Image(systemName: need.without == .refused ? "lock" : "lock.open")
                }
                .font(.callout)
                .foregroundStyle(need.status.text)
            }

            DisclosureGroup("Payload type") {
                Text(entry.payloadType)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.callout)
        }
        .padding()
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledGridRow(label: label) {
            Text(value)
                .textSelection(.enabled)
        }
    }
}

/// Parameters and the start/stop control. Reads only the stream state.
private struct SubscriptionBar: View {
    let entry: CatalogEntry
    let model: ExplorerModel
    @State private var parametersText = "{}"
    @State private var parameterError: String?

    private var isRunning: Bool {
        model.streamState == .live || model.streamState == .starting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Parameters")
                    .font(.headline)
                Text(entry.parametersType)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                StreamStatusLabel(state: model.streamState)
                if isRunning {
                    Button("Stop", systemImage: "stop.fill") { model.stop() }
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button("Subscribe", systemImage: "play.fill", action: subscribe)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                Button("Clear", systemImage: "trash") { model.clear() }
                    .labelStyle(.iconOnly)
                    .help("Clear captured events")
            }
            TextField("Parameters as JSON", text: $parametersText, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(subscribe)
                .onChange(of: parametersText) { parameterError = nil }
            if let parameterError {
                Text(parameterError)
                    .font(.caption)
                    .foregroundStyle(Status.critical.text)
            } else if case .failed(let fault) = model.streamState {
                Text(fault.description)
                    .font(.caption)
                    .foregroundStyle(Status.critical.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding()
        // One-time seed: parameters another page linked here with. Later
        // edits are the user's.
        .onAppear {
            if let text = model.takePendingParameters(for: entry.descriptor.name) {
                parametersText = text
            }
        }
    }

    private func subscribe() {
        let text = parametersText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parameters: JSONValue
        if text.isEmpty {
            parameters = .object([:])
        } else {
            do {
                parameters = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            } catch {
                parameterError = "Parameters aren't valid JSON. Use {} for none."
                return
            }
        }
        model.start(entry.descriptor.name, parameters: parameters)
    }
}

private struct StreamStatusLabel: View {
    let state: ExplorerModel.StreamState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .starting:
            Label("Subscribing…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .live:
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(Status.normal.text)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Status.critical.text)
        }
    }
}

// MARK: - Events

/// The only view that reads `events`, so arrivals redraw the table and the
/// inspector, not the header or the parameter field.
private struct EventTable: View {
    let model: ExplorerModel
    @Binding var selection: ReceivedEvent.ID?

    var body: some View {
        Table(model.events, selection: $selection) {
            TableColumn("Time") { event in
                Text(event.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                    .monospacedDigit()
            }
            .width(min: 115, ideal: 125, max: 160)
            TableColumn("Payload") { event in
                Text(event.summary)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            TableColumn("Origin") { event in
                Text(
                    event.envelope.replayed
                        ? "\(event.envelope.origin.rawValue), replayed" : event.envelope.origin.rawValue
                )
                .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 110, max: 160)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .overlay {
            if model.events.isEmpty {
                EmptyCapture(state: model.streamState)
            }
        }
    }
}

private struct EmptyCapture: View {
    let state: ExplorerModel.StreamState

    var body: some View {
        switch state {
        case .failed(let fault):
            // The reason is shown under the parameters, next to the fix.
            ContentUnavailableView(
                fault.title(.subscription), systemImage: "exclamationmark.triangle",
                description: Text(fault.explanation(.subscription)))
        case .live, .starting:
            ContentUnavailableView(
                "Waiting for events", systemImage: "dot.radiowaves.left.and.right",
                description: Text("Events appear here as the daemon delivers them."))
        case .idle:
            ContentUnavailableView(
                "No events captured", systemImage: "play.circle",
                description: Text("Subscribe to stream this event live. The last \(ExplorerModel.eventLimit) are kept.")
            )
        }
    }
}

private struct EventInspector: View {
    let model: ExplorerModel
    let selection: ReceivedEvent.ID?

    var body: some View {
        if let event = selection.flatMap({ id in model.events.first { $0.id == id } }) {
            List {
                Section("Envelope") {
                    LabeledContent("Kind", value: event.envelope.kind)
                    LabeledContent("Sequence", value: String(event.envelope.sequence))
                    LabeledContent("Time") {
                        Text(
                            event.date,
                            format: .dateTime.year().month().day().hour().minute().second().secondFraction(
                                .fractional(3)))
                    }
                    LabeledContent("Origin", value: event.envelope.origin.rawValue)
                    LabeledContent("Replayed", value: event.envelope.replayed ? "yes" : "no")
                }
                Section("Payload") {
                    OutlineGroup(JSONNode.roots(of: event.envelope.payload), children: \.children) { node in
                        JSONRow(node: node)
                    }
                }
                Section("JSON") {
                    Text(event.envelope.payload.prettyPrinted)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            // A different event is a different tree; don't carry expansion
            // state across by matching paths.
            .id(event.id)
        } else {
            ContentUnavailableView(
                "No event selected", systemImage: "cursorarrow.rays",
                description: Text("Select a row to see its full payload."))
        }
    }
}

private struct JSONRow: View {
    let node: JSONNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(node.key)
                .font(.system(.callout, design: .monospaced))
            if let hint = node.hint {
                // Paths are long; their ends are what tell them apart.
                Text(hint)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hint)
            }
            Spacer(minLength: 8)
            Text(node.value.inlineText)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(node.value.isContainer ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Descriptor text

extension EventDescriptor.PermissionNeed {
    /// Kit's `note`, standing alone.
    var sentence: String { note.prefix(1).uppercased() + note.dropFirst() }

    /// Only a permission the kind can't run without is a warning.
    var status: Status { without == .refused ? .warning : .neutral }
}

extension EventDescriptor.Mechanism {
    var explanation: String {
        switch self {
        case .push: return "pushed by macOS"
        case .poll: return "sampled at an interval"
        case .derived: return "derived from other observations"
        }
    }
}

extension EventDescriptor.Semantics {
    var explanation: String {
        switch self {
        case .occurrence: return "something happened"
        case .state: return "current state, replayed to each new subscriber"
        }
    }
}

extension EventDescriptor.Loss {
    var explanation: String {
        switch self {
        case .none: return "every change is delivered"
        case .coalesced: return "one event can stand for several changes"
        case .lossy: return "changes between observations are missed"
        }
    }
}

extension EventDescriptor.Stability {
    var explanation: String {
        switch self {
        case .documented: return "documented Apple interface"
        case .undocumented: return "undocumented, stable in practice"
        }
    }
}

/// The rules that subscribe to this kind, each a link to the Rules page.
/// Reads only the rules model, so a rule change redraws this row alone.
private struct UsedByRules: View {
    let kind: String
    let rules: RulesModel
    let app: AppState

    var body: some View {
        let users = rules.rules(handling: kind)
        if !users.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(users.count == 1 ? "Used by" : "Used by \(users.count) rules")
                    .foregroundStyle(.secondary)
                ForEach(users) { rule in
                    LinkButton(rule.name ?? rule.id, monospaced: false) { app.showRule(rule.id) }
                        .help("Open \(rule.id) on the Rules page")
                }
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }
}
