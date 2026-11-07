import Foundation
import LanguageServerProtocol
import Testing

@testable import MeerkatApp

/// The rule editor's logic apart from its views and tsrs: names and
/// templates for new files, drafts of unsaved edits, file operations, the
/// language server's restart policy, and how hovers and completions read
/// text.
@MainActor
struct RuleEditorTests {
    /// A rules folder with one file, and a drafts folder beside it, both
    /// removed when the test ends.
    @MainActor
    final class Folder {
        let root: URL
        var rules: URL { root.appendingPathComponent("rules") }
        var drafts: RuleDrafts { RuleDrafts(directory: root.appendingPathComponent("drafts")) }

        init(files: [String: String] = ["recorder.ts": "export const a = 1;\n"]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RuleEditorTests-\(UUID())")
            try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
            for (name, text) in files {
                let url = rules.appendingPathComponent(name)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func read(_ file: String) throws -> String {
            try String(contentsOf: rules.appendingPathComponent(file), encoding: .utf8)
        }

        func model(
            locate: @escaping () -> URL? = { nil }, limits: RuleLanguageServer.Limits = .standard,
            trash: @escaping (URL) throws -> Void = { _ in }
        ) -> RuleEditorModel {
            RuleEditorModel(
                rulesDirectory: rules, drafts: drafts, locateCompiler: locate, serverLimits: limits,
                moveToTrash: trash)
        }

        func draft(_ file: String) throws -> RuleDrafts.Draft? {
            try drafts.load(for: rules.appendingPathComponent(file))
        }

        /// An executable script standing in for tsrs.
        func script(_ text: String) throws -> URL {
            let url = root.appendingPathComponent("tsrs")
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
    }

    // MARK: - The folder

    /// Rule files by the lists either side of the change; declarations,
    /// which tsrs reads for types, by the disk.
    @Test func fileEventsNameWhatHappened() throws {
        let folder = try Folder(files: [".meerkat/meerkat.d.ts": "declare const a: 1;\n"])
        let base = folder.rules.standardizedFileURL.path
        let events = RuleEditorModel.fileEvents(
            paths: [
                "\(base)/recorder.ts", "\(base)/recorder.ts", "\(base)/added.ts", "\(base)/gone.ts",
                "\(base)/notes.md", "\(base)/node_modules/x.d.ts", "/elsewhere/other.ts",
                "\(base)/.meerkat/meerkat.d.ts", "\(base)/old.d.ts",
            ],
            rulesDirectory: folder.rules, before: ["recorder.ts", "gone.ts"], after: ["recorder.ts", "added.ts"])
        #expect(events.map(\.type) == [.changed, .created, .deleted, .deleted, .changed])
        #expect(
            events.map { URL(string: $0.uri)?.lastPathComponent }
                == ["meerkat.d.ts", "added.ts", "gone.ts", "old.d.ts", "recorder.ts"])
    }

    /// The list is the daemon's compiler's: regular .ts files, subfolders
    /// included, without declarations, hidden folders or node_modules.
    @Test func theListIsWhatTheDaemonCompiles() throws {
        let folder = try Folder(files: [
            "recorder.ts": "", "lib/util.ts": "", "types.d.ts": "", ".hidden/a.ts": "",
            "node_modules/pkg/index.ts": "", "folder.ts/inner.ts": "",
        ])
        let model = folder.model()
        model.listFiles()
        #expect(model.files == ["folder.ts/inner.ts", "lib/util.ts", "recorder.ts"])
        #expect(model.names(in: "") == ["recorder.ts"])
        #expect(model.names(in: "lib") == ["util.ts"])
    }

    /// A file added by anything but the editor reaches the list.
    @Test func filesAddedElsewhereJoinTheList() throws {
        let folder = try Folder()
        let model = folder.model()
        model.listFiles()
        let added = folder.rules.appendingPathComponent("added.ts")
        try "export {};\n".write(to: added, atomically: true, encoding: .utf8)
        #expect(model.files == ["recorder.ts"])
        model.folderChanged([added.standardizedFileURL.path])
        #expect(model.files == ["added.ts", "recorder.ts"])
    }

    // MARK: - Names

    @Test func namesGetTheExtensionAndAreChecked() {
        #expect(RuleEditorModel.fileName("battery", existing: []) == .success("battery.ts"))
        #expect(RuleEditorModel.fileName("  low power.ts ", existing: []) == .success("low power.ts"))
        #expect(RuleEditorModel.fileName("", existing: []) == .failure(.empty))
        #expect(RuleEditorModel.fileName(".hidden", existing: []) == .failure(.notAFileName))
        #expect(RuleEditorModel.fileName("a/b", existing: []) == .failure(.notAFileName))
        #expect(RuleEditorModel.fileName(".ts", existing: []) == .failure(.notAFileName))
        #expect(RuleEditorModel.fileName("types.d.ts", existing: []) == .failure(.declarationFile))
        #expect(RuleEditorModel.fileName("Recorder", existing: ["recorder.ts"]) == .failure(.exists("recorder.ts")))
    }

    /// The export is a valid identifier and the rule's name a slug, whatever
    /// the file is called.
    @Test(arguments: [
        ("low power.ts", "lowPower", "low-power"),
        ("2fa.ts", "rule2fa", "2fa"),
        ("delete.ts", "ruleDelete", "delete"),
        ("Battery_Watch.ts", "batteryWatch", "battery-watch"),
        ("h²o.ts", "hO", "h-o"),
    ])
    func templatesNameTheirRule(file: String, identifier: String, name: String) {
        let template = RuleEditorModel.template(for: file)
        #expect(template.contains("export const \(identifier) = rule({"))
        #expect(template.contains("name: \"\(name)\""))
        #expect(template.hasPrefix("// \(file): "))
    }

    /// The confirmation's timer restarts when `Reload` changes, so a second
    /// save with the same result must still be a new confirmation.
    @Test func eachSaveIsItsOwnConfirmation() {
        let status = FileStatus(text: "2 rules loaded", state: .running)
        let first = RuleEditor.Reload(file: "a.ts", status: status, savedAt: Date(timeIntervalSince1970: 1))
        let second = RuleEditor.Reload(file: "a.ts", status: status, savedAt: Date(timeIntervalSince1970: 2))
        #expect(first != second)
    }

    // MARK: - Drafts

    @Test func draftsRoundTripPerFile() throws {
        let folder = try Folder()
        let drafts = folder.drafts
        let file = folder.rules.appendingPathComponent("recorder.ts")
        #expect(try drafts.load(for: file) == nil)
        try drafts.save(.init(base: "a", text: "b"), for: file)
        #expect(try drafts.load(for: file) == .init(base: "a", text: "b"))
        #expect(try drafts.load(for: folder.rules.appendingPathComponent("other.ts")) == nil)
        drafts.remove(for: file)
        #expect(try drafts.load(for: file) == nil)
    }

    /// A draft that can't be read isn't taken for none: it's set aside, not
    /// deleted, the editor says where, and the file opens as saved.
    @Test func anUnreadableDraftIsSetAsideAndSaid() throws {
        let folder = try Folder()
        try folder.drafts.save(.init(base: "", text: "edited"), for: folder.rules.appendingPathComponent("recorder.ts"))
        for url in try FileManager.default.contentsOfDirectory(
            at: folder.drafts.directory, includingPropertiesForKeys: nil)
        {
            try Data("{".utf8).write(to: url)
        }
        #expect(throws: (any Error).self) { try folder.draft("recorder.ts") }

        let model = folder.model()
        model.open("recorder.ts")
        #expect(model.text == "export const a = 1;\n")
        #expect(model.draftError?.contains("can't be read") == true)
        #expect(try folder.draft("recorder.ts") == nil)
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.drafts.directory.path)
        #expect(kept.count == 1)
        #expect(kept.first?.contains("unreadable") == true)
    }

    /// Edits that can't be kept as a draft are said, as the editor otherwise
    /// promises they survive quitting.
    @Test func aDraftThatCantBeWrittenIsSaid() async throws {
        let folder = try Folder()
        // A file where the drafts folder goes.
        try Data().write(to: folder.drafts.directory)
        let model = folder.model()
        model.open("recorder.ts")
        model.edit("edited")
        try await waitUntil { model.draftError?.contains("Couldn't keep your unsaved changes") == true }
    }

    /// Opening a file with a draft brings its edits back, marked restored,
    /// and notes a change on disk since.
    @Test func openingRestoresADraft() throws {
        let folder = try Folder()
        let file = folder.rules.appendingPathComponent("recorder.ts")
        try folder.drafts.save(.init(base: "export const a = 1;\n", text: "edited"), for: file)
        let model = folder.model()
        model.open("recorder.ts")
        #expect(model.text == "edited")
        #expect(model.isEdited)
        #expect(model.restoredDraft == .init(changedOnDisk: false))

        try folder.drafts.save(.init(base: "older", text: "edited"), for: file)
        model.open("recorder.ts")
        #expect(model.restoredDraft == .init(changedOnDisk: true))
    }

    /// Saving and reverting end the draft; a draft equal to the file is
    /// dropped on open.
    @Test func savingAndRevertingRemoveTheDraft() throws {
        let folder = try Folder()
        let file = folder.rules.appendingPathComponent("recorder.ts")
        try folder.drafts.save(.init(base: "", text: "saved text"), for: file)
        let model = folder.model()
        model.open("recorder.ts")
        model.save()
        #expect(try folder.read("recorder.ts") == "saved text")
        #expect(try folder.drafts.load(for: file) == nil)
        #expect(model.restoredDraft == nil)

        try folder.drafts.save(.init(base: "", text: "other"), for: file)
        model.open("recorder.ts")
        model.revert()
        #expect(model.text == "saved text")
        #expect(try folder.drafts.load(for: file) == nil)

        try folder.drafts.save(.init(base: "", text: "saved text"), for: file)
        model.open("recorder.ts")
        #expect(model.restoredDraft == nil)
        #expect(try folder.drafts.load(for: file) == nil)
    }

    /// The view replaces the editor's text when `opens` changes, so every
    /// way of loading text has to count, and an edit must not.
    @Test func everyLoadCountsAsAnOpen() throws {
        let folder = try Folder(files: ["a.ts": "a", "b.ts": "b"])
        let model = folder.model()
        model.open("a.ts")
        #expect(model.opens == 1)
        model.edit("edited")
        #expect(model.opens == 1)
        model.revert()
        #expect(model.opens == 2)
        #expect(model.text == "a")
        model.open("b.ts")
        #expect(model.opens == 3)
        #expect(model.text == "b")
    }

    // MARK: - Files

    @Test func creatingWritesTheTemplateWithoutOverwriting() throws {
        let folder = try Folder()
        let model = folder.model()
        #expect(model.create("battery.ts"))
        #expect(try folder.read("battery.ts") == RuleEditorModel.template(for: "battery.ts"))
        #expect(model.files == ["battery.ts", "recorder.ts"])
        #expect(model.file == "battery.ts")
        #expect(!model.create("recorder.ts"))
        #expect(model.fileError != nil)
        #expect(model.file == "battery.ts")
        #expect(try folder.read("recorder.ts") == "export const a = 1;\n")
    }

    /// Changed elsewhere with nothing unsaved: the editor shows the new text,
    /// so a later save can't write the old one back.
    @Test func anExternalChangeReachesACleanEditor() throws {
        let folder = try Folder()
        let model = folder.model()
        model.open("recorder.ts")
        try Data("export const b = 2;\n".utf8).write(to: folder.rules.appendingPathComponent("recorder.ts"))
        model.reconcileWithDisk()
        #expect(model.text == "export const b = 2;\n")
        #expect(!model.isEdited)
        #expect(!model.changedOnDisk)
    }

    /// Changed elsewhere under unsaved edits: saving stops until the user
    /// picks a version, even before the watcher reports the change.
    @Test func saveKeepsAnExternalChangeUntilToldOtherwise() throws {
        let folder = try Folder()
        let model = folder.model()
        model.open("recorder.ts")
        model.edit("mine")
        let theirs = "export const b = 2;\n"
        try Data(theirs.utf8).write(to: folder.rules.appendingPathComponent("recorder.ts"))
        model.save()
        #expect(try folder.read("recorder.ts") == theirs)
        #expect(model.changedOnDisk)
        #expect(model.text == "mine")

        model.overwrite()
        #expect(try folder.read("recorder.ts") == "mine")
        #expect(!model.changedOnDisk)
    }

    @Test func revertTakesTheVersionOnDisk() throws {
        let folder = try Folder()
        let model = folder.model()
        model.open("recorder.ts")
        model.edit("mine")
        let theirs = "export const b = 2;\n"
        try Data(theirs.utf8).write(to: folder.rules.appendingPathComponent("recorder.ts"))
        model.reconcileWithDisk()
        #expect(model.changedOnDisk)
        model.revert()
        #expect(model.text == theirs)
        #expect(!model.changedOnDisk)
    }

    /// A draft keeps the text it began from, so a file that moved on keeps
    /// reading as changed however much more is typed.
    @Test func aRestoredDraftKeepsItsBase() async throws {
        let folder = try Folder()
        let url = folder.rules.appendingPathComponent("recorder.ts")
        try folder.drafts.save(RuleDrafts.Draft(base: "older", text: "edited"), for: url)
        let model = folder.model()
        model.open("recorder.ts")
        #expect(model.restoredDraft?.changedOnDisk == true)
        model.edit("edited more")
        try await Task.sleep(for: RuleEditorModel.checkDelay * 3)
        #expect(try folder.drafts.load(for: url)?.base == "older")
    }

    /// The daemon makes the rules folder when it starts, and it may not have.
    @Test func creatingMakesTheRulesFolder() throws {
        let folder = try Folder()
        try FileManager.default.removeItem(at: folder.rules)
        let model = folder.model()
        #expect(model.create("battery.ts"))
        #expect(model.file == "battery.ts")
    }

    /// A new file waits behind unsaved edits rather than replacing them.
    @Test func creatingLeavesUnsavedEditsToTheUser() throws {
        let folder = try Folder()
        let model = folder.model()
        model.open("recorder.ts")
        model.edit("edited")
        #expect(model.create("battery.ts"))
        #expect(model.file == "recorder.ts")
        #expect(model.text == "edited")
        #expect(model.pendingFile == "battery.ts")
        #expect(model.files.contains("battery.ts"))
    }

    /// Renaming the open file keeps its unsaved edits and moves its draft.
    @Test func renamingKeepsEditsAndDraft() throws {
        let folder = try Folder()
        let draft = RuleDrafts.Draft(base: "export const a = 1;\n", text: "edited")
        try folder.drafts.save(draft, for: folder.rules.appendingPathComponent("recorder.ts"))
        let model = folder.model()
        model.open("recorder.ts")
        model.rename("recorder.ts", to: "sampler.ts")
        #expect(model.file == "sampler.ts")
        #expect(model.files == ["sampler.ts"])
        #expect(model.text == "edited")
        #expect(try folder.draft("sampler.ts")?.text == "edited")
        #expect(try folder.draft("recorder.ts") == nil)
    }

    /// Renaming changes the name only: a file in a subfolder stays there,
    /// as a library file, rather than moving up where it would run.
    @Test func renamingANestedFileKeepsItsFolder() throws {
        let folder = try Folder(files: ["recorder.ts": "", "lib/util.ts": "export const u = 1;\n"])
        let model = folder.model()
        model.listFiles()
        model.open("lib/util.ts")
        #expect(FileNaming.rename("lib/util.ts").folder == "lib")
        model.rename("lib/util.ts", to: "helpers.ts")
        #expect(model.files == ["lib/helpers.ts", "recorder.ts"])
        #expect(model.file == "lib/helpers.ts")
        #expect(try folder.read("lib/helpers.ts") == "export const u = 1;\n")
    }

    /// The draft is saved under the new name before the old one goes, so a
    /// failure leaves it where it was, and says so.
    @Test func aDraftThatCantMoveStaysAndIsSaid() throws {
        let folder = try Folder()
        try folder.drafts.save(.init(base: "", text: "edited"), for: folder.rules.appendingPathComponent("recorder.ts"))
        let locked = folder.drafts.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let model = folder.model()
        model.rename("recorder.ts", to: "sampler.ts")
        #expect(model.files == ["sampler.ts"])
        #expect(model.draftError?.contains("stay under the old name") == true)
        #expect(try folder.draft("recorder.ts")?.text == "edited")
    }

    /// Trashing warns about edits the file would lose: the open file's, or a
    /// draft from before.
    @Test func unsavedChangesIncludeDrafts() throws {
        let folder = try Folder(files: ["a.ts": "a", "b.ts": "b"])
        let model = folder.model()
        model.open("a.ts")
        try folder.drafts.save(.init(base: "b", text: "edited"), for: folder.rules.appendingPathComponent("b.ts"))
        #expect(!model.hasUnsavedChanges("a.ts"))
        #expect(model.hasUnsavedChanges("b.ts"))
        model.edit("edited")
        #expect(model.hasUnsavedChanges("a.ts"))
    }

    /// Trashing goes through the Trash (never a delete), takes the draft
    /// with it, and opens the next file.
    @Test func trashingOpensTheNextFile() throws {
        let folder = try Folder(files: ["a.ts": "a", "b.ts": "b"])
        var trashed: [String] = []
        let model = folder.model(trash: { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        })
        model.open("a.ts")
        try folder.drafts.save(.init(base: "a", text: "edited"), for: folder.rules.appendingPathComponent("a.ts"))
        model.trash("a.ts")
        #expect(trashed == ["a.ts"])
        #expect(model.file == "b.ts")
        #expect(model.text == "b")
        #expect(try folder.draft("a.ts") == nil)
    }

    /// The session outlives the page: the same folder gets the same editor,
    /// with its open file; another folder gets a new one. (No edits: the
    /// session's editor keeps drafts in the real drafts folder.)
    @Test func theSessionKeepsItsEditor() throws {
        let folder = try Folder()
        let session = RuleEditorSession()
        let editor = session.model(for: folder.rules)
        editor.open("recorder.ts")
        #expect(session.model(for: folder.rules) === editor)
        #expect(session.model(for: folder.rules).file == "recorder.ts")
        #expect(session.model(for: folder.root) !== editor)
    }

    // MARK: - Language server

    @Test func restartsBackOffThenStop() {
        let delays = (1...6).map(RuleEditorModel.restartDelay(afterFailures:))
        #expect(delays == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), nil])
        #expect(RuleEditorModel.restartDelay(afterFailures: 0) == nil)
    }

    /// No tsrs: the editor says so and waits for Try Again, which looks
    /// again.
    @Test func missingServerWaitsForRetry() async throws {
        let folder = try Folder()
        var looks = 0
        let model = folder.model(locate: {
            looks += 1
            return nil
        })
        let run = Task { await model.run() }
        try await waitUntil { model.serverState == .unavailable("tsrs not found") && looks == 1 }
        model.retry()
        try await waitUntil { looks == 2 }
        #expect(model.serverState == .unavailable("tsrs not found"))
        run.cancel()
        await run.value
        #expect(model.file == "recorder.ts")
    }

    /// A server that exits is restarted after a pause, with the reason
    /// shown meanwhile.
    @Test func exitedServerRestarts() async throws {
        let folder = try Folder()
        let script = try folder.script("#!/bin/sh\nexit 3\n")
        let model = folder.model(locate: { script })
        let run = Task { await model.run() }
        try await waitUntil {
            if case .restarting(let reason, attempt: 1) = model.serverState { return reason.contains("status 3") }
            return false
        }
        try await waitUntil {
            if case .restarting(_, attempt: 2) = model.serverState { return true }
            return false
        }
        run.cancel()
        await run.value
    }

    /// A crash is an exit too: a signal, not only a status, restarts it.
    @Test func killedServerRestarts() async throws {
        let folder = try Folder()
        let script = try folder.script("#!/bin/sh\nkill -KILL $$\n")
        let model = folder.model(locate: { script })
        let run = Task { await model.run() }
        try await waitUntil {
            if case .restarting(let reason, attempt: 1) = model.serverState { return reason.contains("signal 9") }
            return false
        }
        run.cancel()
        await run.value
    }

    /// Unsaved edits are written as a draft when the editor closes.
    @Test func closingWritesTheDraft() async throws {
        let folder = try Folder()
        let model = folder.model()
        let run = Task { await model.run() }
        try await waitUntil { model.file == "recorder.ts" }
        model.edit("edited")
        run.cancel()
        await run.value
        #expect(try folder.draft("recorder.ts")?.text == "edited")
    }

    /// A tsrs that runs but never answers counts as exited, so it restarts;
    /// closing the editor still returns, and ends every tsrs it started,
    /// even one that ignores SIGTERM.
    @Test func aSilentServerRestartsAndIsEnded() async throws {
        let folder = try Folder()
        let pids = folder.root.appendingPathComponent("pids")
        // Alive with its pipes open, answering nothing; output closed
        // instead would read as an exit, not silence.
        let script = try folder.script("#!/bin/sh\necho $$ >> '\(pids.path)'\ntrap '' TERM\nexec sleep 600\n")
        let limits = RuleLanguageServer.Limits(
            start: .milliseconds(200), request: .milliseconds(200), shutdown: .milliseconds(100),
            termination: .milliseconds(200))
        let model = folder.model(locate: { script }, limits: limits)
        let run = Task { await model.run() }
        try await waitUntil {
            if case .restarting(let reason, attempt: 1) = model.serverState {
                return reason.contains("didn't answer initialize")
            }
            return false
        }
        run.cancel()
        await run.value
        let started = try String(contentsOf: pids, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        #expect(!started.isEmpty)
        for pid in started {
            try await waitUntil { kill(pid, 0) != 0 }
        }
    }

    /// Drafts don't wait for tsrs: one that never answers still has the
    /// edits written.
    @Test func draftsDontWaitForTheServer() async throws {
        let folder = try Folder()
        let script = try folder.script("#!/bin/sh\nexec sleep 600\n")
        let model = folder.model(locate: { script })
        let run = Task { await model.run() }
        try await waitUntil { model.file == "recorder.ts" }
        model.edit("edited")
        try await waitUntil { (try? folder.draft("recorder.ts"))??.text == "edited" }
        run.cancel()
        await run.value
    }

    // MARK: - Fixes

    private static let document = "file:///rules/zz.ts"

    /// One of tsrs's code actions as JSON, for `document` unless `uri` says
    /// otherwise; `edits` are start line, start character, end line, end
    /// character and new text.
    private func action(
        _ title: String, edits: [(Int, Int, Int, Int, String)], uri: String = document, extra: String = ""
    ) throws -> String {
        let encoded = try edits.map { edit in
            let text = String(decoding: try JSONEncoder().encode(edit.4), as: UTF8.self)
            return """
                {"range": {"start": {"line": \(edit.0), "character": \(edit.1)},
                "end": {"line": \(edit.2), "character": \(edit.3)}}, "newText": \(text)}
                """
        }
        return """
            {"title": "\(title)", "kind": "quickfix", \(extra)
            "edit": {"changes": {"\(uri)": [\(encoded.joined(separator: ","))]}}}
            """
    }

    private func fixes(
        _ actions: [String], text: String, findings: String = "[]", shown: Set<Int> = []
    ) throws -> [RuleFix] {
        let decoder = JSONDecoder()
        return RuleFix.offered(
            try decoder.decode([RuleFix.Action].self, from: Data("[\(actions.joined(separator: ","))]".utf8)),
            for: try decoder.decode([RuleFix.Finding].self, from: Data(findings.utf8)),
            shown: shown, in: Self.document, text: text)
    }

    /// Inserts at one position appear in the order tsrs gave them, as in its
    /// "Implement interface".
    @Test func editsAtOnePositionKeepTheirOrder() throws {
        let text = "class Box implements Shape {}\n"
        let edits = [(0, 28, 0, 28, "\n    area() {}"), (0, 28, 0, 28, "\n    name;"), (0, 28, 0, 28, "\n")]
        let offer = try fixes([action("Implement interface", edits: edits)], text: text)
        #expect(offer.first?.applied(to: text) == "class Box implements Shape {\n    area() {}\n    name;\n}\n")
    }

    /// Edits in any order apply against the original text, as tsrs's
    /// Organize Imports replacing a line and deleting the next.
    @Test func editsApplyAgainstTheOriginalText() throws {
        let text = "import a;\nimport b;\nrest\n"
        let edits = [(1, 0, 2, 0, ""), (0, 0, 1, 0, "import c;\n")]
        let offer = try fixes([action("Organize Imports", edits: edits)], text: text)
        #expect(offer.first?.applied(to: text) == "import c;\nrest\n")
    }

    /// Positions count UTF-16 units, as `NSString` does.
    @Test func editsCountUTF16() throws {
        let text = "\"😀\"; x\n"
        let offer = try fixes([action("Rename", edits: [(0, 6, 0, 7, "y")])], text: text)
        #expect(offer.first?.applied(to: text) == "\"😀\"; y\n")
    }

    /// Nothing is offered that the editor couldn't apply whole, or that
    /// wouldn't change the text.
    @Test func onlyApplicableFixesAreOffered() throws {
        let edit = [(0, 0, 0, 3, "ONE")]
        let offer = try fixes(
            [
                action("Other file", edits: edit, uri: "file:///rules/other.ts"),
                action("No change", edits: [(0, 0, 0, 3, "one")]),
                action("Outside", edits: [(9, 0, 9, 1, "x")]),
                action("Backwards", edits: [(1, 0, 0, 0, "x")]),
                action("Overlapping", edits: [(0, 0, 0, 2, "x"), (0, 1, 0, 3, "y")]),
                action("Command", edits: edit, extra: #""command": {"title": "t", "command": "c"},"#),
                action("Good", edits: edit),
            ],
            text: "one\ntwo\n")
        #expect(offer.map(\.title) == ["Good"])
        #expect(offer.map(\.id) == [0])
    }

    /// An action names its diagnostics; one with none, or only ones the
    /// editor doesn't list, applies to the file.
    @Test func fixesBelongToTheirProblems() throws {
        let range = #""range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}}"#
        let hint = #"{\#(range), "severity": 4, "code": 6133, "source": "ts", "message": "Unused"}"#
        let error = #"{\#(range), "severity": 1, "code": 2304, "source": "ts", "message": "Cannot find name"}"#
        let edit = [(0, 0, 0, 3, "ONE")]
        let offer = try fixes(
            [
                action("For the hint", edits: edit, extra: #""diagnostics": [\#(hint)],"#),
                action("For the error", edits: edit, extra: #""diagnostics": [\#(error)],"#),
                action("Whole file", edits: edit),
            ],
            text: "one\n", findings: "[\(hint), \(error)]", shown: [1])
        #expect(offer.map(\.title) == ["For the hint", "For the error", "Whole file"])
        #expect(offer.map(\.problems) == [[], [1], []])
    }

    // MARK: - Text

    @Test func wordsEndAtTheCursor() {
        let text = "ctx.store.rec" as NSString
        #expect(RuleCompletions.wordStart(before: text.length, in: text) == 10)
        #expect(RuleCompletions.wordStart(before: 10, in: text) == 10)
        #expect(RuleCompletions.wordStart(before: 3, in: text) == 0)
    }

    /// tsrs's hovers are a fenced signature followed by documentation.
    @Test func hoversSplitSignatureFromDocumentation() {
        let hover = HoverContent(
            markdown: "```typescript\n(method) record(request: RecordRequest): Promise<void>\n```\nMeasure the system.")
        #expect(hover.code == ["(method) record(request: RecordRequest): Promise<void>"])
        #expect(hover.prose == ["Measure the system."])
        #expect(HoverContent(markdown: "\n\n").isEmpty)
    }
}
