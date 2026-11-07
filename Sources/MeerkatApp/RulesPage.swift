import MeerkatIPC
import MeerkatKit
import SwiftUI

extension RuleEditorModel: Identifiable {}

/// The daemon's rules: what loaded, what failed and why, what each one has
/// done, with switches to turn rules off and on.
///
/// Files open in the user's editor or in the page's own (`RuleEditor`),
/// which is also where a new rule lands; either way the daemon recompiles
/// on its own when a file in the rules folder changes, and the page
/// reflects it.
struct RulesPage: View {
    @Bindable var model: RulesModel
    let app: AppState
    @State private var sortOrder = [KeyPathComparator(\RuleSummary.id)]
    @State private var query = ""
    @State private var showInspector = true
    /// The editor a new rule file is for, while its name sheet is up.
    @State private var naming: RuleEditorModel?

    var body: some View {
        content
            .navigationSubtitle(subtitle)
            // No details panel beside an empty or unavailable page.
            .trailingPanel(isPresented: showInspector && hasRules && !editing, width: 260...520, ideal: 300) {
                RuleInspector(model: model, app: app)
            }
            .focusedSceneValue(\.detailsPanel, hasRules && !editing ? $showInspector : nil)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        newRule()
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                    .keyboardShortcut("n")
                    .help("Make a new rule file")
                    Button {
                        toggleEditor()
                    } label: {
                        Label(
                            editing ? "Show Rules" : "Edit Rules",
                            systemImage: editing ? "tablecells" : "chevron.left.forwardslash.chevron.right")
                    }
                    .help(editing ? "Show the rules table" : "Edit the rule files here")
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("Reload Rules", systemImage: "arrow.clockwise")
                    }
                    .help("Recompile and reload the rules folder now")
                    .disabled(model.reloading)
                    Button {
                        Finder.open(URL(fileURLWithPath: model.rulesDirectory))
                    } label: {
                        Label("Open Rules Folder", systemImage: "folder")
                    }
                    .help("Open \(model.rulesDirectory)")
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help(showInspector ? "Hide rule details" : "Show rule details")
                    .disabled(!hasRules || editing)
                }
            }
            .task { await model.poll() }
            // The daemon moved the rules folder (`RulesDirectory`, then a
            // restart): the editor on screen follows it, and the old one
            // keeps its edits as a draft as it closes. `initial`: the folder
            // can move while another page shows (`RootView` refreshes the
            // rules on every `meerkat.rule` event), and the editor session
            // outlives the page, so it is checked again on every return.
            .onChange(of: model.rulesDirectory, initial: true) { if editing { _ = folderEditor() } }
            .sheet(item: $naming) { editor in
                FileNameSheet(naming: .new, existing: editor.names(in: "")) { name in
                    editor.create(name)
                    app.ruleEditor.isShown = true
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if editing, let editor {
            RuleEditor(model: editor, session: app.ruleEditor, rules: model, app: app)
                // A new model, for a moved folder, needs a view of its own:
                // its own run (language server, watcher) and a source
                // editor made with its text.
                .id(ObjectIdentifier(editor))
        } else if model.report == nil {
            DaemonLoadGate(state: model.loadState, agent: app.agent) { await model.refresh() }
        } else if model.rules.isEmpty && model.diagnostics.isEmpty && model.lintFindings.isEmpty {
            ContentUnavailableView {
                Label("No Rules Yet", systemImage: "wand.and.rays")
            } description: {
                Text(
                    "Rules are TypeScript files in the rules folder. Each top-level file that exports rules runs; the daemon picks up changes as you save."
                )
            } actions: {
                Button("New Rule…") { newRule() }
                    .buttonStyle(.borderedProminent)
                Button("Open Rules Folder") { Finder.open(URL(fileURLWithPath: model.rulesDirectory)) }
            }
        } else {
            VStack(spacing: 0) {
                if case .failed(let fault) = model.loadState {
                    StaleBanner(subject: "rules", reason: fault.description)
                    Divider()
                }
                RulesStatusBar(model: model)
                if !model.diagnostics.isEmpty {
                    Divider()
                    DiagnosticsList(model: model)
                }
                if !model.lintFindings.isEmpty {
                    Divider()
                    LintFindingsList(model: model)
                }
                Divider()
                RulesTable(model: model, app: app, sortOrder: $sortOrder, query: query)
            }
            // Here rather than on the page: it filters the table, so it
            // goes when the editor or an empty page replaces the table.
            .searchable(text: $query, placement: .toolbar, prompt: "Search rules")
        }
    }

    private var hasRules: Bool { !model.rules.isEmpty }

    /// The editor session lives in `AppState`, so it outlasts a visit to
    /// another page.
    private var editing: Bool { app.ruleEditor.isShown }
    private var editor: RuleEditorModel? { app.ruleEditor.model }

    /// The editor for the rules folder as the page knows it now.
    private func folderEditor() -> RuleEditorModel {
        app.ruleEditor.model(for: URL(fileURLWithPath: model.rulesDirectory))
    }

    /// Opens the editor on the selected rule's file, if any.
    private func toggleEditor() {
        if editing {
            app.ruleEditor.isShown = false
            return
        }
        let editor = folderEditor()
        if let file = model.selectedRule?.file, editor.file != file, !editor.isEdited {
            editor.open(file)
        }
        app.ruleEditor.isShown = true
    }

    /// Asks for a name, and on an answer shows the new file in the editor.
    /// The editor may not have run yet, so its list of files is read here,
    /// for the sheet to refuse a name that's taken.
    private func newRule() {
        let editor = folderEditor()
        editor.listFiles()
        naming = editor
    }

    private var subtitle: String {
        if editing, let editor, let file = editor.file {
            if editor.isEdited { return "\(file) · Edited" }
            return model.status(of: file)?.isFailure == true ? "\(file) · Saved with errors" : file
        }
        guard model.report != nil else { return "" }
        let failing = model.failingCount
        let running = model.rules.filter { $0.state == .loaded }.count
        return failing > 0 ? "\(running) running, \(failing) failed" : "\(running) running"
    }
}

/// Counts, last compile, and the result of the last action.
private struct RulesStatusBar: View {
    let model: RulesModel

    var body: some View {
        HStack(spacing: 14) {
            let rules = model.rules
            Count(value: rules.filter { $0.state == .loaded }.count, label: "running", tint: .green)
            Count(value: rules.filter { $0.state == .failed }.count, label: "failed", tint: .red)
            Count(value: rules.filter { $0.state == .disabled }.count, label: "off", tint: .secondary)
            Spacer(minLength: 8)
            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.text(Theme.critical))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(error)
            } else if model.reloading {
                ProgressView().controlSize(.small)
                Text("Reloading…").foregroundStyle(.secondary)
            } else if let compiledAt = model.report?.compiledAt {
                Text(
                    "Compiled \(Date(epochMilliseconds: compiledAt), format: .relative(presentation: .named))"
                )
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private struct Count: View {
        let value: Int
        let label: String
        let tint: Color

        var body: some View {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text("\(value) \(label)")
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Compiler and load errors, which stop a file from running.
private struct DiagnosticsList: View {
    let model: RulesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                model.diagnostics.count == 1 ? "1 problem" : "\(model.diagnostics.count) problems",
                systemImage: "exclamationmark.octagon"
            )
            .font(.headline)
            .foregroundStyle(Theme.text(Theme.critical))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.diagnostics) { listed in
                        DiagnosticRow(diagnostic: listed.diagnostic, url: listed.diagnostic.file.map(model.fileURL))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.06))
    }
}

/// Lint and format findings. Advice, not failures: collapsed by default and
/// styled quieter than compile errors, since every rule above still runs.
private struct LintFindingsList: View {
    let model: RulesModel
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.lintFindings) { listed in
                        DiagnosticRow(diagnostic: listed.diagnostic, url: listed.diagnostic.file.map(model.fileURL))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
        } label: {
            // The whole header toggles, not only the disclosure triangle.
            Button {
                isExpanded.toggle()
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the suggestions" : "Shows the suggestions")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.04))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label {
                Text(model.lintFindings.count == 1 ? "1 suggestion" : "\(model.lintFindings.count) suggestions")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.yellow)
            }
            .font(.headline)
            Text("Style and likely mistakes. Rules run either way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let lintedAt = model.lintedAt {
                Text("Linted \(lintedAt, format: .relative(presentation: .named))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }
}

private struct DiagnosticRow: View {
    let diagnostic: RuleDiagnostic
    let url: URL?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Without a file (a tool that did not run, a compiler error
            // without a location), the location names the tool.
            if let file = diagnostic.file {
                LinkButton(diagnostic.location) {
                    if let url { Finder.open(url) }
                }
                .help("Open \(file)")
            } else {
                Text(diagnostic.location)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let code = diagnostic.code {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(diagnostic.message)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

/// Only the table reads the rule rows, so polls redraw it and not the
/// status bar's neighbours.
private struct RulesTable: View {
    @Bindable var model: RulesModel
    let app: AppState
    @Binding var sortOrder: [KeyPathComparator<RuleSummary>]
    let query: String

    private var rows: [RuleSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matching =
            needle.isEmpty
            ? model.rules
            : model.rules.filter {
                $0.id.localizedStandardContains(needle) || ($0.event?.localizedStandardContains(needle) ?? false)
            }
        return matching.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("On") { rule in
                if !rule.isFileFailure {
                    // Labelled with the rule, hidden: VoiceOver names the
                    // rule each row's checkbox switches, which is in
                    // another column.
                    Toggle(
                        rule.name ?? rule.file,
                        isOn: Binding(
                            get: { rule.isEnabled },
                            set: { enabled in Task { await model.setEnabled(rule.id, enabled) } }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(rule.isEnabled ? "Turn this rule off" : "Turn this rule on")
                }
            }
            .width(30)

            TableColumn("Rule", value: \.id) { rule in
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.name ?? rule.file)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(rule.isFileFailure ? "whole file" : rule.file)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 120, ideal: 150)

            TableColumn("Event") { rule in
                if let event = rule.event {
                    LinkButton(event) { app.showEvent(event) }
                        .help("Open \(event) in the Event Explorer")
                }
            }
            .width(min: 90, ideal: 125)

            TableColumn("State") { rule in
                StatusBadge(text: rule.state.label, tint: rule.state.tint)
            }
            .width(min: 62, ideal: 68, max: 90)

            TableColumn("Runs", value: \.invocations) { rule in
                Text(rule.invocations, format: .number)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 48, max: 80)

            TableColumn("Failures", value: \.failures) { rule in
                Text(rule.failures, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(rule.failures > 0 ? Theme.text(Theme.critical) : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 56, max: 80)

            TableColumn("Last Run") { rule in
                if let date = rule.lastInvokedDate {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(date.formatted(date: .abbreviated, time: .standard))
                } else {
                    Text("never").foregroundStyle(.tertiary)
                }
            }
            .width(min: 58, ideal: 66)

            TableColumn("Problem") { rule in
                if let problem = rule.state == .failed ? rule.reason : rule.lastError {
                    Text(problem)
                        .foregroundStyle(Theme.text(Theme.critical))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(problem)
                }
            }
            .width(min: 90, ideal: 160)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: RuleSummary.ID.self) { ids in
            if let id = ids.first, let rule = model.rules.first(where: { $0.id == id }) {
                RuleActions(rule: rule, model: model, app: app)
            }
        } primaryAction: { ids in
            if let id = ids.first,
                let url = model.rules.first(where: { $0.id == id }).map({ model.fileURL($0.file) })
            {
                Finder.open(url)
            }
        }
        .overlay {
            if rows.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

/// A rule's context menu. The inspector repeats the two most used, Open
/// File and Turn On or Off, as buttons.
private struct RuleActions: View {
    let rule: RuleSummary
    let model: RulesModel
    let app: AppState

    var body: some View {
        let url = model.fileURL(rule.file)
        Button("Open \(rule.file)", systemImage: "doc.text") { Finder.open(url) }
        Button("Show in Finder", systemImage: "folder") { Finder.reveal(url.path) }
        if let event = rule.event {
            Button("Open \(event) in Event Explorer", systemImage: "list.bullet.rectangle.portrait") {
                app.showEvent(event)
            }
        }
        if !rule.isFileFailure {
            Divider()
            if rule.isEnabled {
                Button("Turn Off", systemImage: "pause.circle") { Task { await model.setEnabled(rule.id, false) } }
            } else {
                Button("Turn On", systemImage: "play.circle") { Task { await model.setEnabled(rule.id, true) } }
            }
        }
    }
}

// MARK: - Inspector

private struct RuleInspector: View {
    let model: RulesModel
    let app: AppState

    var body: some View {
        if let rule = model.selectedRule {
            RuleDetail(rule: rule, model: model, app: app)
                .task(id: rule.id) { await model.loadLogs(for: rule) }
        } else {
            ContentUnavailableView(
                "No rule selected",
                systemImage: "cursorarrow.rays",
                description: Text("Select a rule to see what it does and what it logged.")
            )
        }
    }
}

private struct RuleDetail: View {
    let rule: RuleSummary
    let model: RulesModel
    let app: AppState

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(rule.name ?? rule.file)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Spacer(minLength: 6)
                        StatusBadge(text: rule.state.label, tint: rule.state.tint)
                    }
                    Text(rule.file)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                if let reason = rule.reason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(rule.state == .failed ? Theme.text(Theme.critical) : .secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Activity") {
                if let event = rule.event {
                    LabeledContent("Event") {
                        LinkButton(event) { app.showEvent(event) }
                    }
                }
                LabeledContent("Runs") { Text(rule.invocations, format: .number).monospacedDigit() }
                LabeledContent("Failures") {
                    Text(rule.failures, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(rule.failures > 0 ? Theme.text(Theme.critical) : .primary)
                }
                LabeledContent("Last run") {
                    if let date = rule.lastInvokedDate {
                        Text(date, format: .dateTime.month().day().hour().minute().second())
                    } else {
                        Text("never").foregroundStyle(.secondary)
                    }
                }
                if let error = rule.lastError {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last error").foregroundStyle(.secondary)
                        Text(error)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Theme.text(Theme.critical))
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                HStack {
                    Button("Open File") { Finder.open(model.fileURL(rule.file)) }
                    if !rule.isFileFailure {
                        Button(rule.isEnabled ? "Turn Off" : "Turn On") {
                            Task { await model.setEnabled(rule.id, !rule.isEnabled) }
                        }
                    }
                }
            }

            let suggestions = model.lintFindings(in: rule.file)
            if !suggestions.isEmpty {
                Section("Suggestions for \(rule.file)") {
                    ForEach(suggestions) { listed in
                        SuggestionRow(diagnostic: listed.diagnostic)
                    }
                }
            }

            Section("Log") {
                if model.logsRule == rule.id, !model.logs.isEmpty {
                    ForEach(model.logs) { listed in
                        LogRow(listed: listed, ruleID: rule.id)
                    }
                } else if model.logsRule == rule.id, let error = model.logsError {
                    Label("Couldn't read the log: \(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(model.logsRule == rule.id ? "Nothing logged yet." : "Loading…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LogRow: View {
    let listed: ListedLogEntry
    let ruleID: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: listed.entry.level.symbol)
                .foregroundStyle(listed.entry.level.tint)
                .accessibilityLabel(listed.entry.level.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(listed.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                    // Lines about the file rather than this rule.
                    if let rule = listed.entry.rule, rule != ruleID {
                        Text(rule)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(listed.entry.message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One lint finding in the rule inspector, where the file is already known.
private struct SuggestionRow: View {
    let diagnostic: RuleDiagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let line = diagnostic.line {
                        Text(diagnostic.column.map { "\(line):\($0)" } ?? "\(line)")
                            .monospacedDigit()
                    }
                    if let code = diagnostic.code {
                        Text(code)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                Text(diagnostic.message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
