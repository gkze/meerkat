import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import MeerkatIPC
import MeerkatKit
import SwiftUI

/// The Rules page's editor:
/// one rule file in a source editor, the rules directory's files on the
/// trailing side, and the open file's problems underneath. Problems come
/// from tsrs's language server as you type, or, when it cannot run, from
/// the daemon's compile of the saved file. Saving writes the file; the
/// daemon reloads on its own, and the editor confirms the reload.
/// Completions and hovers come from the same server
/// (`RuleCompletions`, `RuleHovers`); files are created, renamed and moved
/// to the Trash from the file list.
struct RuleEditor: View {
    @Bindable var model: RuleEditorModel
    /// What outlives the view: the Try It panel and the place in the file.
    @Bindable var session: RuleEditorSession
    let rules: RulesModel
    let app: AppState
    @State private var annotations = ProblemAnnotations()
    @State private var completions = RuleCompletions()
    @State private var hovers = RuleHovers()
    /// The name sheet, for a new file or a rename.
    @State private var naming: FileNaming?
    /// A file to move to the Trash, once confirmed.
    @State private var trashing: String?
    /// The toolbar's Revert, until confirmed.
    @State private var confirmingRevert = false
    /// The daemon's verdict on the last save, shown for a few seconds.
    @State private var reloaded: Reload?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RuleEditorTheme.defaultsKey) private var theme: RuleEditorTheme = .system

    /// Spaces per indent, as oxfmt formats rule files, so typing and
    /// `meerkat rules fmt` agree: the policy's `tabWidth`
    /// (Sources/meerkat-lint/policy/oxfmtrc.json), which RuleEditorIndentTests
    /// compares it with.
    static let indentWidth = 2

    /// How long the "Saved and reloaded" confirmation stays.
    static let confirmationDuration: Duration = .seconds(4)

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Not StaleBanner: these are the disk's failures, not the
                // daemon's.
                ForEach([model.fileError, model.draftError, model.watchError].compactMap(\.self), id: \.self) {
                    error in
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Status.warning.text)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Status.warning.color.opacity(0.08))
                    Divider()
                }
                editor
                    .overlay(alignment: .bottom) { notices }
                Divider()
                ProblemsBar(
                    problems: problems, file: model.file ?? "", source: problemSource,
                    fixes: usesDaemonProblems ? [] : model.fixes, apply: annotations.apply(_:)
                ) { problem in
                    annotations.moveCursor(to: CursorPosition(line: problem.line + 1, column: problem.character + 1))
                }
                Divider()
                EditorStatusLine(model: model, cursor: session.editorState.cursorPositions?.first)
            }
            Divider()
            if session.isTryingIt {
                RuleTryIt(model: app.dryRun, editor: model, app: app)
                    .frame(width: 340)
            } else {
                RuleFileList(
                    model: model, rules: rules, open: model.request(open:), create: { naming = .new },
                    rename: { naming = .rename($0) }, trash: { trashing = $0 }
                )
                .frame(width: 220)
            }
        }
        .background(WindowEditedMarker(isEdited: model.isEdited))
        .onChange(of: problems, initial: true) { _, problems in annotations.problems = problems }
        .onChange(of: model.opens) { annotations.show(model.text) }
        .onChange(of: rules.report?.compiledAt) { _, compiledAt in confirmReload(compiledAt) }
        .task(id: reloaded) {
            guard reloaded != nil else { return }
            // Cancelled when a newer confirmation replaces this one, which
            // must stay.
            do { try await Task.sleep(for: Self.confirmationDuration) } catch { return }
            withAnimation { reloaded = nil }
        }
        .task {
            completions.model = model
            hovers.model = model
            await model.run()
        }
        .toolbar { toolbar }
        .sheet(item: $naming) { naming in
            FileNameSheet(naming: naming, existing: model.names(in: naming.folder)) { name in
                switch naming {
                case .new: model.create(name)
                case .rename(let file): model.rename(file, to: name)
                }
            }
        }
        .confirmationDialog(
            "Move “\(trashing ?? "")” to the Trash?", item: $trashing
        ) { file in
            Button("Move to Trash", role: .destructive) { model.trash(file) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(trashMessage)
        }
        .confirmationDialog(
            "Save changes to \(model.file ?? "")?", item: $model.pendingFile
        ) { file in
            Button("Save") {
                model.save()
                if !model.isEdited { model.open(file) }
            }
            Button("Don't Save", role: .destructive) { model.open(file) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your changes are lost if you don't save them.")
        }
        // Asked, unlike the notices' buttons, which name their choice:
        // reverting replaces the text view's storage, which clears its undo
        // history, and removes the draft, so nothing brings the edits back.
        .confirmationDialog("Revert to the saved version of \(model.file ?? "")?", isPresented: $confirmingRevert) {
            Button("Revert", role: .destructive) { model.revert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes are lost.")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if model.file != nil {
            SourceEditor(
                Binding(get: { model.text }, set: { model.edit($0) }),
                language: .typescript,
                configuration: configuration,
                state: $session.editorState,
                coordinators: [annotations, hovers],
                completionDelegate: completions
            )
        } else {
            ContentUnavailableView {
                Label("No Rule Files", systemImage: "doc.text")
            } description: {
                Text("Make a rule file, or add a .ts file to the rules folder, to edit it here.")
            } actions: {
                Button("New Rule…") { naming = .new }
            }
        }
    }

    /// The reload confirmation, restored edits, or why problems wait for a
    /// save.
    @ViewBuilder
    private var notices: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let reloaded {
                Notice(
                    symbol: reloaded.status.isFailure ? "exclamationmark.circle" : "checkmark.circle",
                    tint: reloaded.status.state.status.color,
                    title: reloaded.status.isFailure ? "Saved with errors" : "Saved and reloaded",
                    detail: "meerkatd compiled \(reloaded.file) · \(reloaded.status.text)")
            }
            if let restored = model.restoredDraft, let file = model.file {
                Notice(
                    symbol: "clock.arrow.circlepath", tint: .accentColor, title: "Restored unsaved changes",
                    detail: "Your edits to \(file) weren't saved when the editor last closed."
                        + (restored.changedOnDisk
                            ? " The file has changed on disk since; saving replaces that version." : ""),
                    wide: true
                ) {
                    Button("Discard Changes") { model.revert() }
                    Button("Keep") { model.restoredDraft = nil }
                }
            }
            if model.changedOnDisk, let file = model.file {
                Notice(
                    symbol: "exclamationmark.triangle", tint: Status.warning.color, title: "Changed on disk",
                    detail: "Something else changed \(file) while you were editing it.",
                    wide: true
                ) {
                    Button("Use Version on Disk") { model.revert() }
                    Button("Keep My Changes") { model.overwrite() }
                }
            }
            if case .unavailable(let reason) = model.serverState {
                Notice(
                    symbol: "info.circle", tint: Status.warning.color, title: "TypeScript language server unavailable",
                    detail:
                        "Meerkat.app's tsrs is missing or didn't start (\(reason)). Problems appear when you save, from meerkatd's compile.",
                    wide: true
                ) {
                    Button("Try Again") { model.retry() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.opacity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                confirmingRevert = true
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
            .help("Discard changes since the last save")
            .disabled(!model.isEdited)
            Button {
                model.save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s")
            .help("Save the file; meerkatd reloads it")
            .disabled(!model.isEdited)
            Toggle(isOn: $session.isTryingIt) {
                Label("Try It", systemImage: "play.circle")
            }
            .help("Run the unsaved text on events; nothing is sent or changed")
            .disabled(model.file == nil)
            Button {
                if let file = model.file { Finder.open(model.rulesDirectory.appendingPathComponent(file)) }
            } label: {
                Label("Open in Your Editor", systemImage: "arrow.up.forward.square")
            }
            .help("Open the file in the app that opens .ts files")
            .disabled(model.file == nil)
        }
        // A toolbar shows a switch without its label, so the label is text
        // beside it.
        ToolbarItem {
            HStack(spacing: 6) {
                Text("Enabled")
                Toggle("Enabled", isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 6)
            .help("Turn the open file's rules on or off")
            .disabled(fileRules.isEmpty)
        }
    }

    // MARK: - Derived state

    /// The language server's problems while it runs; otherwise the
    /// daemon's compile errors for the saved file.
    private var problems: [RuleEditorModel.Problem] {
        if usesDaemonProblems, let file = model.file {
            return rules.loadFailures(in: file).enumerated().map { RuleEditorModel.Problem($1.diagnostic, id: $0) }
        }
        return model.problems
    }

    /// The system's monospaced font and the chosen theme's colors
    /// (`RuleEditorTheme`).
    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme.palette(colorScheme).editorTheme,
                font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                wrapLines: false,
                tabWidth: Self.indentWidth),
            behavior: .init(indentOption: .spaces(count: Self.indentWidth)),
            peripherals: .init(
                showMinimap: false, showFoldingRibbon: false,
                codeSuggestionTriggerCharacters: RuleEditorModel.completionTriggers))
    }

    private var usesDaemonProblems: Bool {
        switch model.serverState {
        case .unavailable, .restarting: true
        case .stopped, .starting, .running: false
        }
    }

    private var problemSource: String {
        usesDaemonProblems ? "meerkatd · on save (tsrs)" : "TypeScript language server · as you type"
    }

    private var trashMessage: String {
        let edited =
            trashing.map(model.hasUnsavedChanges) == true ? " Your unsaved changes to it are discarded." : ""
        return "meerkatd stops its rules. You can put it back from the Trash." + edited
    }

    /// The open file's rules at the daemon's last compile.
    private var fileRules: [RuleSummary] {
        rules.rules.filter { $0.file == model.file && !$0.isFileFailure }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { fileRules.contains(where: \.isEnabled) },
            set: { isOn in
                let ids = fileRules.map(\.id)
                Task { for id in ids { await rules.setEnabled(id, isOn) } }
            })
    }

    /// A compile that finishes after the last save is that save's reload.
    private func confirmReload(_ compiledAt: Double?) {
        guard let savedAt = model.savedAt, let compiledAt, let file = model.file,
            Date(epochMilliseconds: compiledAt) >= savedAt
        else { return }
        model.savedAt = nil
        withAnimation {
            reloaded = Reload(
                file: file, status: rules.status(of: file) ?? .noRules,
                savedAt: savedAt)
        }
    }

    /// A save's reload, with its file: the editor may show another by the
    /// time the confirmation goes.
    struct Reload: Equatable {
        let file: String
        let status: FileStatus
        /// Which save this confirms. Two saves with the same result are
        /// still two confirmations, so the second restarts the timer.
        let savedAt: Date
    }
}

/// The editor's session apart from the view, kept by `AppState` as it keeps
/// the page models: leaving the Rules page, for a link to the Event Explorer
/// say, and coming back finds the editor as it was, with its file, unsaved
/// edits, place and Try It panel.
@MainActor
@Observable
final class RuleEditorSession {
    /// Made on first use, for the rules folder meerkatd reports.
    private(set) var model: RuleEditorModel?
    /// The Rules page shows the editor rather than the rules table.
    var isShown = false
    /// The Try It inspector is open, in place of the file list.
    var isTryingIt = false
    /// The cursor and scroll position in the open file.
    var editorState = SourceEditorState()

    /// The editor for `directory`; a new one if the folder moved.
    func model(for directory: URL) -> RuleEditorModel {
        if let model, model.rulesDirectory == directory { return model }
        let created = RuleEditorModel(rulesDirectory: directory)
        model = created
        return created
    }
}

extension RuleEditorModel.Problem.Severity {
    var status: Status { self == .error ? .critical : .warning }
}

extension RuleEditorModel.Problem {
    /// A daemon diagnostic (1-based line and column, no range) as a problem
    /// one character wide.
    init(_ diagnostic: RuleDiagnostic, id: Int) {
        let line = max((diagnostic.line ?? 1) - 1, 0)
        let character = max((diagnostic.column ?? 1) - 1, 0)
        self.init(
            id: id, severity: diagnostic.severity == .error ? .error : .warning, line: line,
            character: character, endLine: line, endCharacter: character + 1, message: diagnostic.message,
            code: diagnostic.code)
    }
}

/// A floating confirmation or explanation over the bottom of the editor,
/// with buttons for what can be done about it.
private struct Notice<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var wide = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .accessibilityElement(children: .combine)
            if wide { Spacer(minLength: 0) }
            HStack(spacing: 8) { actions }
                .controlSize(.small)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
        .background(fill, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(wide ? 0.35 : 0.15)))
        .shadow(color: .black.opacity(wide ? 0 : 0.12), radius: 8, y: 2)
    }

    /// A banner tints its background; a confirmation floats on material.
    private var fill: AnyShapeStyle { wide ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(.regularMaterial) }
}

extension Notice where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String, wide: Bool = false) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, wide: wide) { EmptyView() }
    }
}

// MARK: - Problems

/// The open file's errors and warnings and where they come from; selecting
/// one moves the cursor to it.
private struct ProblemsBar: View {
    let problems: [RuleEditorModel.Problem]
    let file: String
    let source: String
    let fixes: [RuleFix]
    let apply: (RuleFix) -> Void
    let reveal: (RuleEditorModel.Problem) -> Void

    private var fileFixes: [RuleFix] { fixes.filter(\.problems.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Problems").font(.headline)
                if !problems.isEmpty {
                    // A tinted capsule with status text, as `StatusBadge`:
                    // white on the system orange or red is under 4:1.
                    let worst: RuleEditorModel.Problem.Severity =
                        problems.contains(where: { $0.severity == .error }) ? .error : .warning
                    let status = worst.status
                    Text(problems.count, format: .number)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(status.text)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(status.color.opacity(0.14), in: .capsule)
                        .accessibilityLabel(problems.count == 1 ? "1 problem" : "\(problems.count) problems")
                }
                Spacer(minLength: 8)
                if !fileFixes.isEmpty {
                    FixMenu(title: "File Actions", fixes: fileFixes, apply: apply)
                }
                Text(source)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if problems.isEmpty {
                Label {
                    Text("No problems").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(Status.normal.color)
                }
                .font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(problems) { problem in
                            ProblemRow(
                                problem: problem, file: file, fixes: fixes.filter { $0.problems.contains(problem.id) },
                                apply: apply
                            ) { reveal(problem) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 96)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct ProblemRow: View {
    let problem: RuleEditorModel.Problem
    let file: String
    let fixes: [RuleFix]
    let apply: (RuleFix) -> Void
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            row
            if let fix = fixes.first, fixes.count == 1 {
                Button("Fix") { apply(fix) }
                    .controlSize(.small)
                    .help(fix.title)
                    .accessibilityLabel(fix.title)
            } else if !fixes.isEmpty {
                FixMenu(title: "Fix", fixes: fixes, apply: apply)
            }
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: problem.severity == .error ? "xmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(problem.severity.status.color)
                    .accessibilityLabel(problem.severity == .error ? "Error" : "Warning")
                Text("\(file):\(problem.line + 1):\(problem.character + 1)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(problem.message)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let code = problem.code {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Go to \(problem.line + 1):\(problem.character + 1)")
    }
}

/// A choice of fixes, for a problem with several or for the whole file.
private struct FixMenu: View {
    let title: String
    let fixes: [RuleFix]
    let apply: (RuleFix) -> Void

    var body: some View {
        Menu(title) {
            ForEach(fixes) { fix in
                Button(fix.title) { apply(fix) }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}

/// Cursor position and indentation on the leading side, the language
/// server's state on the trailing side.
private struct EditorStatusLine: View {
    let model: RuleEditorModel
    let cursor: CursorPosition?

    var body: some View {
        HStack(spacing: 6) {
            if let cursor, cursor.start.line > 0 {
                Text("Ln \(cursor.start.line), Col \(cursor.start.column) · Spaces: \(RuleEditor.indentWidth) · UTF-8")
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Circle()
                .fill(serverStatus.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(serverLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 5)
    }

    private var serverLabel: String {
        switch model.serverState {
        case .stopped: "tsrs · stopped"
        case .starting: "tsrs · starting…"
        case .running: "tsrs · ready"
        case .restarting(_, let attempt): "tsrs · restarting (\(attempt) of \(RuleEditorModel.maxRestarts))"
        case .unavailable: "No language server"
        }
    }

    private var serverStatus: Status {
        switch model.serverState {
        case .running: .normal
        case .starting, .stopped: .neutral
        case .restarting, .unavailable: .warning
        }
    }
}

// MARK: - Files

/// The rules directory's TypeScript files, each with what the daemon made
/// of it at its last compile; a file's context menu renames it or moves it
/// to the Trash, and the add button below makes a new one.
private struct RuleFileList: View {
    let model: RuleEditorModel
    let rules: RulesModel
    let open: (String) -> Void
    let create: () -> Void
    let rename: (String) -> Void
    let trash: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((model.rulesDirectory.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            List(
                selection: Binding(
                    get: { model.file },
                    set: { file in if let file, file != model.file { open(file) } })
            ) {
                ForEach(model.files, id: \.self) { file in
                    HStack(spacing: 6) {
                        Label(file, systemImage: "doc.text")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let status = rules.status(of: file) {
                            Text(status.text)
                                .font(.caption)
                                .foregroundStyle(status.state.status.text)
                        }
                    }
                    .tag(file as String?)
                    .contextMenu {
                        Button("Rename…") { rename(file) }
                        Button("Move to Trash") { trash(file) }
                        Divider()
                        Button("Show in Finder") {
                            Finder.reveal(model.rulesDirectory.appendingPathComponent(file).path)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 8) {
                Button(action: create) {
                    Label("New Rule File", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Make a new rule file")
                Spacer(minLength: 4)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onAppear { model.listFiles() }
    }

    private var summary: String {
        let count = rules.rules.filter { !$0.isFileFailure }.count
        return count == 1 ? "1 rule" : "\(count) rules"
    }
}

/// Puts the unsaved-changes dot in the window's close button while the
/// open file is edited (its edits are kept as a draft either way).
private struct WindowEditedMarker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let isEdited = isEdited
        // The view has no window during its first update.
        DispatchQueue.main.async { view.window?.isDocumentEdited = isEdited }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        view.window?.isDocumentEdited = false
    }
}
