import AppKit
import Foundation
import LanguageServerProtocol
import MeerkatKit
import MeerkatRules
import Observation

/// One file of the rules directory open for editing, checked as it is typed
/// by tsrs's language server, and saved back for the daemon to reload.
///
/// The daemon watches the rules directory and recompiles on save, so saving
/// is the whole hand-off: what loaded shows on the Rules page as before.
/// Unsaved edits are kept as drafts (`RuleDrafts`) and come back when the
/// file opens again, after quitting included.
@MainActor
@Observable
final class RuleEditorModel {
    /// A problem tsrs reports in the open file. Positions are 0-based, in
    /// UTF-16 code units (LSP's default encoding, and NSString's).
    struct Problem: Identifiable, Equatable {
        enum Severity { case error, warning }

        let id: Int
        let severity: Severity
        let line: Int
        let character: Int
        let endLine: Int
        let endCharacter: Int
        let message: String
        let code: String?
    }

    enum ServerState: Equatable {
        case stopped
        case starting
        case running
        /// tsrs exited; another starts after `restartDelay(afterFailures:)`.
        case restarting(reason: String, attempt: Int)
        /// No tsrs to run, or it kept exiting: the editor still opens and
        /// saves, and `retry()` tries again.
        case unavailable(String)
    }

    /// Unsaved edits a draft brought back when the file opened.
    struct RestoredDraft: Equatable {
        /// The file changed on disk after the draft was made, so saving
        /// replaces that change.
        let changedOnDisk: Bool
    }

    /// How long typing must pause before the server is asked for
    /// diagnostics and the draft is written.
    nonisolated static let checkDelay: Duration = .milliseconds(250)
    /// How long FSEvents gathers the folder's changes, in seconds.
    nonisolated static let folderLatency = 0.25
    /// Restarts in a row before the editor stops and waits for `retry()`.
    nonisolated static let maxRestarts = 5
    /// A server that ran this long before exiting starts the count again.
    nonisolated static let stableRun: Duration = .seconds(60)
    /// Characters after which the editor asks for completions, besides
    /// letters and digits: tsrs's trigger characters without the ones that
    /// mostly start operators or tags (" ", "<", "@", "#", "*").
    nonisolated static let completionTriggers: Set<String> = [".", "\"", "'", "`", "/"]

    /// The pause before restart `failures` (1-based): 0.5, 1, 2, 4 and 8
    /// seconds, then nil (stop).
    nonisolated static func restartDelay(afterFailures failures: Int) -> Duration? {
        guard (1...maxRestarts).contains(failures) else { return nil }
        return .milliseconds(500 << (failures - 1))
    }

    let rulesDirectory: URL
    /// TypeScript files under the rules directory, relative to it.
    private(set) var files: [String] = []
    var file: String? { document?.file }
    var text: String { document?.text ?? "" }
    var savedText: String { document?.savedText ?? "" }
    /// Counts opens: each replaces `text`, which the view has to show.
    private(set) var opens = 0
    var problems: [Problem] { document?.problems ?? [] }
    /// What tsrs offers for the current text: none while a check of an edit
    /// is pending, as their positions are the previous text's.
    var fixes: [RuleFix] { offered.version == version ? offered.fixes : [] }
    private(set) var serverState = ServerState.stopped
    /// Why the last file operation failed; cleared by the next success.
    private(set) var fileError: String?
    /// Why unsaved edits couldn't be kept as a draft, or a draft couldn't be
    /// read; cleared when the next draft is written. Apart from `fileError`
    /// because drafts are written as you type, which says nothing about the
    /// last file operation.
    private(set) var draftError: String?
    /// The rules folder could not be watched while the editor runs, so
    /// files added or changed outside Meerkat don't show, and tsrs isn't
    /// told about changed declarations, until the editor opens again.
    private(set) var watchError: String?
    /// Set when the open file's edits came from a draft, until they are
    /// saved, reverted or acknowledged.
    var restoredDraft: RestoredDraft? {
        get { document?.restoredDraft }
        set { document?.restoredDraft = newValue }
    }
    /// When the open file was last saved, until the daemon's next compile
    /// (which the editor confirms) clears it.
    var savedAt: Date? {
        get { document?.savedAt }
        set { document?.savedAt = newValue }
    }
    /// A file asked for while the open one has unsaved edits, until the
    /// user says what happens to them.
    var pendingFile: String?
    /// The open file changed on disk under unsaved edits. Saving stops
    /// until the user chooses a version (`overwrite()`, `revert()`).
    var changedOnDisk: Bool { document?.changedOnDisk ?? false }

    var isEdited: Bool { document.map { $0.text != $0.savedText } ?? false }

    /// The open file and what holds only while it's open, as one value, so
    /// opening another file or closing this one replaces all of it.
    private struct Document {
        var file: String
        /// The text on disk, as last read or saved.
        var savedText: String
        var text: String
        /// A restored draft's base, which later drafts keep: they build on
        /// it, not on the newer text on disk.
        var draftBase: String?
        var restoredDraft: RestoredDraft?
        var changedOnDisk = false
        var savedAt: Date?
        var problems: [Problem] = []
    }

    private var document: Document?
    private var offered = (version: -1, fixes: [RuleFix]())
    private let drafts: RuleDrafts
    private let locateCompiler: () -> URL?
    private let serverLimits: RuleLanguageServer.Limits
    private let moveToTrash: (URL) throws -> Void
    private var server: RuleLanguageServer?
    private var version = 0
    /// The last version the server has, so a request can send newer text
    /// first.
    private var sentVersion = 0
    private var check: Task<Void, Never>?
    private var retryRequest: AsyncStream<Void>.Continuation?

    init(
        rulesDirectory: URL,
        drafts: RuleDrafts = .standard,
        locateCompiler: @escaping () -> URL? = { TypeScriptToolchain.locate()?.compiler },
        serverLimits: RuleLanguageServer.Limits = .standard,
        moveToTrash: @escaping (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        self.rulesDirectory = rulesDirectory
        self.drafts = drafts
        self.locateCompiler = locateCompiler
        self.serverLimits = serverLimits
        self.moveToTrash = moveToTrash
    }

    /// Runs the language server, restarting it when it exits, for as long
    /// as the calling task (the editor view's) lives, with the open file,
    /// if any, open in it.
    func run() async {
        listFiles()
        if file == nil, let first = files.first { open(first) }
        // The watcher only runs while the editor shows.
        reconcileWithDisk()
        // Quitting doesn't wait for the debounced draft write.
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeDraft() }
        }
        let watcher = FSEventStream(
            paths: [rulesDirectory.path], options: .init(latency: Self.folderLatency, markSelf: false)
        ) { [weak self] events in
            let paths = events.map(\.path)
            Task { @MainActor in self?.folderChanged(paths) }
        }
        do {
            try watcher.start()
            watchError = nil
        } catch {
            watchError =
                "Changes made outside Meerkat won't show until you reopen the editor: the rules folder could not be watched (\(error))."
        }
        await superviseServer()
        watcher.stop()
        NotificationCenter.default.removeObserver(observer)
        check?.cancel()
        writeDraft()
    }

    /// Starts the server again after it stopped restarting.
    func retry() { retryRequest?.yield() }

    /// Changes on disk, from the app or anything else: the file list
    /// follows them, and tsrs, which doesn't watch the folder, is told.
    func folderChanged(_ paths: [String]) {
        let before = Set(files)
        listFiles()
        let changes = Self.fileEvents(paths: paths, rulesDirectory: rulesDirectory, before: before, after: Set(files))
        guard !changes.isEmpty else { return }
        reconcileWithDisk()
        guard let server else { return }
        Task {
            try? await server.filesChanged(changes)
            await refreshProblems()
        }
    }

    /// Follows a change to the open file from outside: it shows the new
    /// text, or, under unsaved edits, flags the conflict.
    func reconcileWithDisk() {
        guard let file, let contents = diskText(file) else { return }
        if contents == savedText {
            document?.changedOnDisk = false
        } else if isEdited {
            document?.changedOnDisk = true
        } else {
            open(file)
        }
    }

    /// What `paths` mean to tsrs: rule files that appeared, changed or went
    /// away, from the file lists `before` and `after` the change, and
    /// declaration files, which the list leaves out but tsrs reads for
    /// types (the daemon rewrites `.meerkat/meerkat.d.ts`).
    static func fileEvents(paths: [String], rulesDirectory: URL, before: Set<String>, after: Set<String>)
        -> [FileEvent]
    {
        let base = rulesDirectory.standardizedFileURL.path + "/"
        return Set(paths).sorted().compactMap { path in
            guard path.hasPrefix(base) else { return nil }
            let file = String(path.dropFirst(base.count))
            let type: FileChangeType
            switch (before.contains(file), after.contains(file)) {
            case (false, true): type = .created
            case (true, true): type = .changed
            case (true, false): type = .deleted
            case (false, false):
                guard file.hasSuffix(".d.ts"), !file.contains("node_modules/") else { return nil }
                type = FileManager.default.fileExists(atPath: path) ? .changed : .deleted
            }
            return FileEvent(uri: URL(fileURLWithPath: path).absoluteString, type: type)
        }
    }

    /// The rule files, as the daemon's compiler finds them.
    func listFiles() {
        files = RuleCompiler.ruleSources(in: rulesDirectory).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// The names of the rule files in `folder`, relative to the rules
    /// directory ("" for the rules directory itself): what a new or renamed
    /// file there must not be called.
    func names(in folder: String) -> [String] {
        files.filter { ($0 as NSString).deletingLastPathComponent == folder }.map {
            ($0 as NSString).lastPathComponent
        }
    }

    /// Whether moving `file` to the Trash loses edits: the open file's, or
    /// a draft kept from before.
    func hasUnsavedChanges(_ file: String) -> Bool {
        file == self.file ? isEdited : drafts.exists(for: url(file))
    }

    /// Opens `file`, discarding unsaved edits to the current one and its
    /// draft (the view asks first). A draft of `file` itself comes back.
    func open(_ file: String) {
        let url = url(file)
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            fileError = "Couldn't open \(file): \(error.localizedDescription)"
            return
        }
        let previous = self.file
        if let previous, previous != file { drafts.remove(for: self.url(previous)) }
        // Whatever was said about drafts was about the file being left.
        draftError = nil
        var document = Document(file: file, savedText: contents, text: contents)
        if let draft = loadDraft(file), draft.text != contents {
            document.text = draft.text
            document.draftBase = draft.base
            document.restoredDraft = RestoredDraft(changedOnDisk: draft.base != contents)
        } else {
            drafts.remove(for: url)
        }
        self.document = document
        opens += 1
        fileError = nil
        reopen(file, closing: previous)
    }

    /// The editor's text changed.
    func edit(_ newText: String) {
        guard document != nil, newText != text else { return }
        document?.text = newText
        version += 1
        if !isEdited { document?.restoredDraft = nil }
        check?.cancel()
        // The draft first: it mustn't wait on tsrs, which may be slow to
        // answer or gone. Completions and hovers send the text themselves.
        check = Task {
            do { try await Task.sleep(for: Self.checkDelay) } catch { return }
            writeDraft()
            await sendChange()
            await refreshProblems()
        }
    }

    /// Saves, unless the file changed on disk since it was read: the watcher
    /// may not have said so yet, so this asks the disk itself.
    func save() {
        guard let file else { return }
        if changedOnDisk || diskText(file).map({ $0 != savedText }) == true {
            document?.changedOnDisk = true
            return
        }
        overwrite()
    }

    /// Writes the editor's text over whatever is on disk.
    func overwrite() {
        guard let file else { return }
        let url = url(file)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            fileError = "Couldn't save \(file): \(error.localizedDescription)"
            return
        }
        // Not `document?.savedText = text`: reading `text` while writing
        // `document` is an exclusivity violation, which traps.
        let saved = text
        document?.savedText = saved
        document?.draftBase = nil
        document?.restoredDraft = nil
        document?.changedOnDisk = false
        document?.savedAt = .now
        drafts.remove(for: url)
        fileError = nil
        Task { [server] in try? await server?.saved(uri(file)) }
    }

    /// Discards unsaved edits and their draft.
    func revert() {
        guard let file else { return }
        drafts.remove(for: url(file))
        open(file)
    }

    // MARK: - Files

    /// Opens `file`, or holds it in `pendingFile` when that would lose
    /// unsaved edits.
    func request(open file: String) {
        if isEdited, file != self.file { pendingFile = file } else { open(file) }
    }

    /// Creates `file` from the template and asks to open it.
    @discardableResult
    func create(_ file: String) -> Bool {
        let url = url(file)
        do {
            try RuleFileSource.create(url, text: RuleFileSource.template(for: file))
        } catch {
            fileError = "Couldn't create \(file): \(error.localizedDescription)"
            return false
        }
        fileError = nil
        listFiles()
        request(open: file)
        return true
    }

    /// Renames `file` to `name` in the same folder, keeping its draft and,
    /// when it is open, its unsaved edits. Only the name changes: a file in
    /// a subfolder stays a library file, and a top-level one stays a rule
    /// file.
    func rename(_ file: String, to name: String) {
        let folder = (file as NSString).deletingLastPathComponent
        let newFile = folder.isEmpty ? name : "\(folder)/\(name)"
        guard file != newFile else { return }
        let from = url(file)
        let to = url(newFile)
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            fileError = "Couldn't rename \(file): \(error.localizedDescription)"
            return
        }
        fileError = nil
        // Saved under the new name before the old one goes, so a failure
        // leaves the draft where it was.
        if let draft = loadDraft(file) {
            do {
                try drafts.save(draft, for: to)
                drafts.remove(for: from)
            } catch {
                draftError =
                    "Renamed \(file), but its unsaved changes stay under the old name: \(error.localizedDescription)"
            }
        }
        listFiles()
        guard self.file == file else { return }
        document?.file = newFile
        reopen(newFile, closing: file)
    }

    /// Moves `file` to the Trash with its draft; if it was open, the first
    /// remaining file opens.
    func trash(_ file: String) {
        let url = url(file)
        do {
            try moveToTrash(url)
        } catch {
            fileError = "Couldn't move \(file) to the Trash: \(error.localizedDescription)"
            return
        }
        fileError = nil
        drafts.remove(for: url)
        listFiles()
        guard self.file == file else { return }
        document = nil
        Task { [server] in try? await server?.close(uri(file)) }
        if let next = files.first { open(next) }
    }

    // MARK: - Completions and hovers

    /// Completions at a position of the open file, after sending the
    /// server the latest text.
    func completions(line: Int, character: Int, trigger: String?) async -> [CompletionItem] {
        guard let server, let file else { return [] }
        await sendChange()
        let position = Position(line: line, character: character)
        return (try? await server.completions(uri(file), at: position, trigger: trigger)) ?? []
    }

    func resolve(_ item: CompletionItem) async -> CompletionItem? {
        try? await server?.resolve(item)
    }

    func hover(line: Int, character: Int) async -> Hover? {
        guard let server, let file else { return nil }
        await sendChange()
        return try? await server.hover(uri(file), at: Position(line: line, character: character))
    }

    // MARK: - Private

    private func url(_ file: String) -> URL { rulesDirectory.appendingPathComponent(file) }

    private func uri(_ file: String) -> DocumentUri { url(file).absoluteString }

    private func diskText(_ file: String) -> String? { try? String(contentsOf: url(file), encoding: .utf8) }

    /// Keeps the open file's unsaved edits on disk, or removes the draft
    /// when there are none.
    private func writeDraft() {
        guard let document else { return }
        let file = document.file
        guard isEdited else { return drafts.remove(for: url(file)) }
        do {
            try drafts.save(
                RuleDrafts.Draft(base: document.draftBase ?? document.savedText, text: document.text), for: url(file))
            draftError = nil
        } catch {
            draftError =
                "Couldn't keep your unsaved changes to \(file); save them or they're lost when Meerkat quits: "
                + error.localizedDescription
        }
    }

    /// `file`'s draft. One that can't be read is set aside, not removed,
    /// and said where, so the edits in it can still be recovered by hand.
    private func loadDraft(_ file: String) -> RuleDrafts.Draft? {
        do {
            return try drafts.load(for: url(file))
        } catch {
            let aside = try? drafts.setAside(for: url(file))
            draftError =
                "The unsaved changes kept for \(file) can't be read (\(error.localizedDescription))"
                + (aside.map { "; they were moved to \($0.path)." } ?? ".")
            return nil
        }
    }

    /// Hands the server `file` as a new version, with `previous` closed first,
    /// for a file it hasn't got under that name.
    private func reopen(_ file: String, closing previous: String?) {
        version += 1
        sentVersion = version
        Task { [server, version, text] in
            if let previous { try? await server?.close(uri(previous)) }
            try? await server?.open(uri(file), text: text, version: version)
            await refreshProblems()
        }
    }

    private func sendChange() async {
        guard let server, let file, sentVersion < version else { return }
        sentVersion = version
        try? await server.change(uri(file), text: text, version: version)
    }

    private enum RunOutcome {
        case cancelled
        case missing
        case exited(String)
    }

    private func superviseServer() async {
        var failures = 0
        while !Task.isCancelled {
            let started = ContinuousClock.now
            switch await runServer() {
            case .cancelled:
                return
            case .missing:
                serverState = .unavailable("tsrs not found")
                guard await nextRetry() else { return }
                failures = 0
            case .exited(let reason):
                if started.duration(to: .now) >= Self.stableRun { failures = 0 }
                failures += 1
                if let delay = Self.restartDelay(afterFailures: failures) {
                    serverState = .restarting(reason: reason, attempt: failures)
                    do { try await Task.sleep(for: delay) } catch { return }
                } else {
                    serverState = .unavailable(reason)
                    guard await nextRetry() else { return }
                    failures = 0
                }
            }
        }
        serverState = .stopped
    }

    /// Waits for `retry()`; false when the editor closes first.
    private func nextRetry() async -> Bool {
        let (requests, continuation) = AsyncStream<Void>.makeStream()
        retryRequest = continuation
        defer { retryRequest = nil }
        for await _ in requests { return true }
        return false
    }

    /// One server's life: start it, open the file in it, and wait for it to
    /// exit or for the editor to close.
    private func runServer() async -> RunOutcome {
        guard let compiler = locateCompiler() else { return .missing }
        serverState = .starting
        let (exits, exited) = AsyncStream<String>.makeStream()
        let server: RuleLanguageServer
        do {
            server = try RuleLanguageServer(compiler: compiler, rulesDirectory: rulesDirectory, limits: serverLimits) {
                failure in exited.yield(failure.description)
            }
        } catch {
            return .exited(error.localizedDescription)
        }
        do {
            try await server.start()
        } catch {
            await server.stop()
            if Task.isCancelled { return .cancelled }
            // The exit status, which may follow the closed session by a
            // moment, says more than the session's error.
            let status = await withTaskGroup(of: String?.self) { group in
                group.addTask { await exits.first { _ in true } }
                group.addTask {
                    try? await Task.sleep(for: .seconds(1))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            return .exited(status ?? "tsrs's language server didn't start (\(error))")
        }
        self.server = server
        serverState = .running
        if let file {
            version += 1
            sentVersion = version
            try? await server.open(uri(file), text: text, version: version)
            await refreshProblems()
        }
        var outcome = RunOutcome.cancelled
        for await reason in exits {
            outcome = .exited(reason)
            break
        }
        self.server = nil
        document?.problems = []
        if case .cancelled = outcome { serverState = .stopped }
        await server.stop()
        return outcome
    }

    private func refreshProblems() async {
        guard let server, let file else { return }
        let requested = file
        let checked = version
        let text = text
        guard let diagnostics = try? await server.diagnostics(uri(file)), self.file == requested else { return }
        let found = diagnostics.enumerated().compactMap { Self.problem($1, id: $0) }
        if found != problems { document?.problems = found }
        let whole = LSPRange(
            start: Position(line: 0, character: 0),
            end: (text as NSString).lspPosition(of: (text as NSString).length))
        let actions = (try? await server.codeActions(uri(file), in: whole, for: diagnostics)) ?? []
        offered = (
            checked,
            RuleFix.offered(actions, for: diagnostics, shown: Set(found.map(\.id)), in: uri(file), text: text)
        )
    }

    /// Errors and warnings; hints (unused names, deprecations) are not
    /// problems.
    private static func problem(_ diagnostic: Diagnostic, id: Int) -> Problem? {
        let severity: Problem.Severity
        switch diagnostic.severity ?? .error {
        case .error: severity = .error
        case .warning: severity = .warning
        case .information, .hint: return nil
        }
        let code: String? =
            switch diagnostic.code {
            case .optionA(let number)?: "TS\(number)"
            case .optionB(let text)?: text
            case nil: nil
            }
        let range = diagnostic.range
        return Problem(
            id: id, severity: severity, line: range.start.line, character: range.start.character,
            endLine: range.end.line, endCharacter: range.end.character, message: diagnostic.message, code: code)
    }
}
