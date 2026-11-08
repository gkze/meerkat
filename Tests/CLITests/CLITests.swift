import ArgumentParser
import Foundation
import MeerkatKit
import MeerkatRules
import Testing

@testable import MeerkatIPC
@testable import MeerkatStore
@testable import meerkat

/// Parsing contracts for the command-line tool. These exercise the parsers
/// only; sampling itself is covered by MeerkatKitTests.
struct MeerkatCLITests {
    /// A bare `meerkat` names no operation, so it shows help instead of
    /// starting a measurement.
    @Test func samplingIsAnExplicitSubcommand() throws {
        let sample = try #require(try Meerkat.parseAsRoot(["sample", "--window", "20", "--quiet"]) as? Sample)
        #expect(sample.window == 20)
        #expect(sample.quiet)
        #expect(throws: (any Error).self) { try Meerkat.parseAsRoot(["--window", "20"]) }
    }

    @Test func defaultsMatchDocumentedValues() throws {
        let sample = try Sample.parse([])
        #expect(sample.window == 10)
        #expect(sample.top == 10)
        #expect(sample.churnDepth == 5)
        #expect(sample.repeatCount == 1)
        #expect(sample.label == "unlabelled")
        #expect(sample.retain == nil)
    }

    @Test func renamedFlagsKeepTheirSpelling() throws {
        let sample = try Sample.parse([
            "--repeat", "3", "--churn", "~/Library",
            "--churn-depth", "6", "--db", "x.db", "-q",
        ])
        #expect(sample.repeatCount == 3)
        #expect(sample.churnPath == "~/Library")
        #expect(sample.churnDepth == 6)
        #expect(sample.quiet)
    }

    /// The hand-rolled parser silently fell back to defaults on these, and a
    /// typo in `--retain` disabled retention altogether.
    @Test(arguments: [
        ["--window", "abc"],
        ["--top", "x"],
        ["--retain", "10k"],
        ["--repeat", "two"],
        ["--window", "0"],
        ["--retain", "0"],
        ["--repeat", "0"],
        ["--no-such-flag"],
        // Churn shares the window: a second one would pair two intervals.
        ["--churn", "~/Library", "--churn-window", "4"],
        ["--json", "--table"],
    ])
    func invalidSampleArgumentsAreRejected(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try Sample.parse(arguments) }
    }

    @Test func subcommandsTakeTheirDatabaseArgument() throws {
        let compare = try #require(try Meerkat.parseAsRoot(["compare", "~/db"]) as? Compare)
        #expect(compare.db == "~/db")
        let analyze = try #require(try Meerkat.parseAsRoot(["analyze", "~/db"]) as? Analyze)
        #expect(analyze.db == "~/db")
    }

    @Test func subcommandsRejectMissingOrExtraArguments() {
        #expect(throws: (any Error).self) { try Meerkat.parseAsRoot(["compare"]) }
        #expect(throws: (any Error).self) { try Meerkat.parseAsRoot(["analyze", "a", "b"]) }
    }

    @Test func daemonCommandsParse() throws {
        #expect(try Meerkat.parseAsRoot(["status", "--json"]) is Status)
        #expect(try Meerkat.parseAsRoot(["rules"]) is Rules.List)
        #expect(try Meerkat.parseAsRoot(["rules", "reload"]) is Rules.Reload)
        let logs = try #require(try Meerkat.parseAsRoot(["rules", "logs", "a.ts#b", "--limit", "5"]) as? Rules.Logs)
        #expect(logs.rule == "a.ts#b" && logs.limit == 5)
        #expect(try Meerkat.parseAsRoot(["agent"]) is Agent.Status)
        #expect(try Meerkat.parseAsRoot(["events"]) is Events.List)
    }

    @Test func dryRunTakesPayloadsOrASampleNotBoth() throws {
        let command = try Rules.DryRun.parseAsRoot(["draft.ts", "--as", "a.ts", "--payload", "{}", "--payload", "[]"])
        #expect((command as? Rules.DryRun)?.payload.count == 2)
        #expect((command as? Rules.DryRun)?.name == "a.ts")
        #expect(throws: (any Error).self) {
            try Rules.DryRun.parseAsRoot(["a.ts", "--payload", "{}", "--sample", "5"])
        }
    }

    @Test func watchParametersMergeJSONAndKeyValues() throws {
        let watch = try #require(
            try Meerkat.parseAsRoot([
                "events", "watch", "fs.change", "--params", #"{"paths":["~/x"]}"#, "--param", "latency=0.5", "--param",
                "label=raw",
            ]) as? Events.Watch)
        #expect(try watch.parameters() == .object(["paths": ["~/x"], "latency": 0.5, "label": "raw"]))
    }

    /// Every insert applies the budget, so writing with the wrong one
    /// deletes samples the user chose to keep.
    @Test func recordingAppliesTheConfiguredBudget() throws {
        let rules = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-\(UUID())")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rules) }
        #expect(try Sample.recordingLimits(in: rules).maxAge == SampleStore.Limits.standard.maxAge)

        let file = rules.appendingPathComponent("meerkat.json")
        try Data(#"{ "samples": { "maxAgeDays": 90 } }"#.utf8).write(to: file)
        #expect(try Sample.recordingLimits(in: rules).maxAge == 90 * 86_400)

        try Data("{".utf8).write(to: file)
        #expect(throws: (any Error).self) { try Sample.recordingLimits(in: rules) }
    }

    /// A mistyped folder must not read as rules that all pass.
    @Test func rulesCommandsNeedAFolderThatExists() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-\(UUID())")
        #expect(throws: (any Error).self) { try Rules.existingDirectory(missing.path) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let folder = FileManager.default.temporaryDirectory
        #expect(try Rules.existingDirectory(folder.path).path == folder.path)
    }

    /// A check runs on a copy with Meerkat's configuration added, so the
    /// folder it checks is left as it was; fixing works in place.
    @Test func checkingWritesNothingIntoTheFolder() throws {
        let rules = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: rules) }
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try "export const x = 1;\n".write(to: rules.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)

        let (copy, cleanup) = try Rules.folder(for: rules, writing: false)
        #expect(copy != rules)
        try RuleCompiler.writeEditorSupport(
            in: copy, declarations: TypeScriptDeclarations.render(), runtimeDeclarations: nil)
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("a.ts").path))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("tsconfig.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rules.path) == ["a.ts"])
        cleanup()
        #expect(!FileManager.default.fileExists(atPath: copy.path))

        #expect(try Rules.folder(for: rules, writing: true).folder == rules)
    }

    /// Dotfile managers link the rules folder. The check must copy the
    /// folder, not the link, or it writes into the real one; and a relative
    /// link inside must still reach its file from the copy.
    @Test func checkingALinkedFolderWritesNothingIntoIt() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("CLITests-\(UUID())")
        defer { try? fileManager.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        let shared = base.appendingPathComponent("shared")
        try fileManager.createDirectory(at: real, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        try "export const a = 1;\n".write(to: real.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        try "export const b = 2;\n".write(to: shared.appendingPathComponent("b.ts"), atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            atPath: real.appendingPathComponent("b.ts").path, withDestinationPath: "../shared/b.ts")
        let linked = base.appendingPathComponent("linked")
        try fileManager.createSymbolicLink(atPath: linked.path, withDestinationPath: "real")

        let (copy, cleanup) = try Rules.folder(for: linked, writing: false)
        defer { cleanup() }
        try RuleCompiler.writeEditorSupport(
            in: copy, declarations: TypeScriptDeclarations.render(), runtimeDeclarations: nil)
        #expect(try fileManager.contentsOfDirectory(atPath: real.path).sorted() == ["a.ts", "b.ts"])
        #expect(fileManager.fileExists(atPath: copy.appendingPathComponent("tsconfig.json").path))
        #expect(
            try String(contentsOf: copy.appendingPathComponent("b.ts"), encoding: .utf8) == "export const b = 2;\n")
    }

    /// An agent acts on what a skill says, so every command in one must parse.
    @Test func skillsNameRealCommands() throws {
        for skill in AgentSkill.all {
            let commands = skill.instructions.matches(of: /`meerkat ([^`]+)`/).map {
                $0.1.split(separator: " ").map(String.init)
            }
            #expect(!commands.isEmpty)
            for command in commands {
                #expect(throws: Never.self, "\(skill.name): \(command)") { try Meerkat.parseAsRoot(command) }
            }
        }
    }

    @Test func skillsAreValidSkillFiles() {
        for skill in AgentSkill.all {
            #expect(skill.name.wholeMatch(of: /[a-z0-9-]{1,64}/) != nil)
            #expect((1...1024).contains(skill.summary.count))
            #expect(!skill.summary.contains("\n") && !skill.summary.contains(": "))
            #expect(skill.document.hasPrefix("---\nname: \(skill.name)\ndescription: "))
        }
    }

    @Test func installingWritesEachSkillAndKeepsOtherText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try Skills.install(AgentSkill.all, into: folder, force: false)
        #expect(files.count == AgentSkill.all.count)
        #expect(try String(contentsOf: files[0], encoding: .utf8) == AgentSkill.all[0].document)
        // The same text again is a no-op, not a conflict.
        _ = try Skills.install(AgentSkill.all, into: folder, force: false)

        try "edited".write(to: files[1], atomically: true, encoding: .utf8)
        #expect(throws: Skills.Conflict.self) { try Skills.install(AgentSkill.all, into: folder, force: false) }
        #expect(try String(contentsOf: files[1], encoding: .utf8) == "edited")
        _ = try Skills.install(AgentSkill.all, into: folder, force: true)
        #expect(try String(contentsOf: files[1], encoding: .utf8) == AgentSkill.all[1].document)
    }

    /// A file that can't be compared as text is still the user's: it is a
    /// conflict, not an absent file.
    @Test func aSkillFileThatIsNotUTF8IsAConflict() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try Skills.install(AgentSkill.all, into: folder, force: false)
        let bytes = Data([0x66, 0xFF, 0xFE, 0x0A])
        try bytes.write(to: files[0])
        #expect(throws: Skills.Conflict.self) { try Skills.install(AgentSkill.all, into: folder, force: false) }
        #expect(try Data(contentsOf: files[0]) == bytes)
    }

    /// The diagnose skill names where rules' samples are kept; it must be
    /// the default the daemon uses.
    @Test func theDiagnoseSkillNamesTheDefaultSampleStore() {
        let store = DaemonPaths.standard(environment: [:], preferences: { _ in nil }).sampleDatabase.path
        let home = NSHomeDirectory()
        #expect(store.hasPrefix(home + "/"))
        let named = "~" + store.dropFirst(home.count)
        #expect(AgentSkill.named("meerkat-diagnose")?.instructions.contains("`\(named)`") == true)
    }

    /// Text other programs chose can't start a line or drive the terminal.
    @Test func controlCharactersAreEscapedForTheTerminal() {
        #expect(terminalSafe("ok\n2026-11-03 error other.ts#guard") == #"ok\n2026-11-03 error other.ts#guard"#)
        #expect(terminalSafe("\u{1B}]0;title\u{07}\u{9B}2J\u{7F}") == #"\u{1B}]0;title\u{7}\u{9B}2J\u{7F}"#)
        #expect(terminalSafe("a\tb\rc") == #"a\tb\rc"#)
        #expect(terminalSafe("plain — ünïcode ✓") == "plain — ünïcode ✓")
    }

    /// Rule code chooses rule names and the messages diagnostics carry, so
    /// the rules and dry-run output must not let one forge a line or drive
    /// the terminal, in any field.
    @Test func ruleOutputEscapesWhatRulesChose() {
        let forged = "ok\n2026-11-04 12:00:00 error other.ts#guard  disabled"
        let name = "x\u{1B}]0;title\u{07}"
        let diagnostic = RuleDiagnostic(tool: .loader, file: "a\u{9B}.ts", message: "rule \"\(name)\": \(forged)")
        let rule = RuleSummary(
            id: "a.ts#\(name)", file: "a.ts", event: "timer", state: .failed, reason: forged, invocations: 0,
            failures: 0, lastInvokedAt: nil, lastError: nil)
        let rules = Rules.output(
            RulesReport(
                rules: [rule], diagnostics: [diagnostic], compiledAt: nil,
                lint: LintReport(diagnostics: [diagnostic], lintedAt: 0)))
        let dryRun = Rules.DryRun.output(
            DryRunReport(outcome: .chooseRule, diagnostics: [diagnostic], rules: [name, "\(name)2"]))
        for line in rules.lines + dryRun.lines {
            #expect(!line.unicodeScalars.contains { $0.properties.generalCategory == .control }, "\(line)")
        }
        #expect(rules.lines.count == 10)
        #expect(dryRun.lines.count == 2)
    }

    @Test(arguments: [
        ["events", "watch", "no.such.event"],
        ["events", "watch", "fs.change", "--params", "[1]"],
        ["events", "watch", "fs.change", "--param", "=1"],
        ["events", "watch", "timer", "--count", "0"],
        ["rules", "logs", "--limit", "0"],
        ["rules", "enable"],
    ])
    func invalidDaemonCommandsAreRejected(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try Meerkat.parseAsRoot(arguments) }
    }

    /// `meerkat effects --json` lists as observation grants exactly those
    /// some event kind needs, not every grant no effect uses: `fs.write` is
    /// Deno's, and observes nothing.
    @Test func effectsListTheGrantsKindsNeed() throws {
        let listing = Effects.listing()
        #expect(
            Set(listing.observing.map(\.grant))
                == ["capabilities.fs.read", "capabilities.process.observe", "capabilities.observe"])
        let json = try JSONValue(encoding: listing)
        #expect(json["observing"]?.arrayValue?.count == 3)
        #expect(json["effects"]?.arrayValue?.count == EffectCatalog.standard.effects.count)
    }
}

/// The contract agents rely on (docs/cli.md, "Agent skills"): `--json` wherever
/// there's data, and exit statuses that mean what they say.
struct OutputContractTests {
    /// Commands whose output isn't data, and why. Every other command
    /// prints JSON, always or with `--json`.
    static let notData: [String: String] = [
        "types": "prints TypeScript",
        "mcp": "speaks MCP on stdout",
        "skills show": "prints a SKILL.md",
        "agent install": "an action; `agent status --json` reports the result",
        "agent uninstall": "an action; `agent status --json` reports the result",
        "agent restart": "an action; `agent status --json` reports the result",
    ]

    /// Commands that print JSON without being asked to.
    static let alwaysJSON: Set = ["events watch", "config show", "config schema"]

    /// Every command that can run, by its path from `meerkat`.
    static func leaves(_ command: any ParsableCommand.Type, path: [String] = []) -> [(String, any ParsableCommand.Type)]
    {
        let subcommands = command.configuration.subcommands
        guard !subcommands.isEmpty else { return [(path.joined(separator: " "), command)] }
        return subcommands.flatMap { leaves($0, path: path + [$0._commandName]) }
    }

    /// A new command gets JSON output, or a reason here not to.
    @Test func everyCommandThatPrintsDataHasJSON() {
        let leaves = Self.leaves(Meerkat.self)
        #expect(leaves.count > 20)
        for (path, command) in leaves {
            if let reason = Self.notData[path] {
                #expect(!(command is any JSONOutput.Type), "\(path) has JSON, but is listed as \(reason)")
                continue
            }
            #expect(command is any JSONOutput.Type, "\(path) prints data but has no --json")
            if !Self.alwaysJSON.contains(path) {
                #expect(command.helpMessage().contains("--json"), "\(path) has no --json flag")
            }
        }
        #expect(Set(Self.notData.keys).union(Self.alwaysJSON).isSubset(of: leaves.map(\.0)))
    }

    /// `main` writes what `outcome` says. A check's findings are its output,
    /// so its bare `ExitCode` adds nothing; anything else says what failed.
    @Test func failuresKeepTheirStatusAndMessage() {
        let failure = Meerkat.outcome(of: CommandFailure("no daemon", status: ExitStatus.unavailable))
        #expect(failure.status == 69 && failure.message == "no daemon")
        let check = Meerkat.outcome(of: ExitCode.failure)
        #expect(check.status == 1 && check.message == nil)
        let usage = Meerkat.outcome(of: ValidationError("--top must be greater than 0"))
        #expect(usage.status == ExitCode.validationFailure.rawValue)
        #expect(usage.message?.contains("--top must be greater than 0") == true)
    }

    /// The line `--json` writes is one object on one line, whatever the
    /// message holds.
    @Test func aJSONFailureIsOneObject() throws {
        let line = Meerkat.failureLine("no rules directory at /x\nnote", status: 66)
        #expect(!line.contains("\n"))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        #expect(json == .object(["error": .object(["status": 66, "message": "no rules directory at /x\nnote"])]))
    }

    /// A usage error is found before there is a command to ask, so the
    /// arguments and the command's type decide whether it is JSON.
    @Test func aUsageErrorIsJSONWhenTheCommandWouldBe() {
        let watch = Meerkat.commandType(named: ["events", "watch", "no.such"])
        #expect(ObjectIdentifier(watch) == ObjectIdentifier(Events.Watch.self))
        let rules = Meerkat.commandType(named: ["rules", "--limit", "0"])
        #expect(ObjectIdentifier(rules) == ObjectIdentifier(Rules.self))
        #expect(Meerkat.wantsJSON(["events", "watch", "no.such"]))
        #expect(Meerkat.wantsJSON(["rules", "logs", "--limit", "0", "--json"]))
        #expect(!Meerkat.wantsJSON(["sample", "--window", "0"]))
        // After `--`, `--json` is an argument, not the flag.
        #expect(!Meerkat.wantsJSON(["rules", "check", "--", "--json"]))
    }

    /// `alwaysJSON` is what the types say, so a usage error of each is JSON.
    @Test func alwaysJSONCommandsSayItByType() {
        let typed = Self.leaves(Meerkat.self).filter { $0.1 is any AlwaysJSONOutput.Type }.map(\.0)
        #expect(Set(typed) == Self.alwaysJSON)
    }

    /// A configuration that doesn't apply says why on a line of its own,
    /// not after an escaped newline.
    @Test func statusShowsTheConfigurationProblemOnItsOwnLine() throws {
        let configuration = ConfigurationStatus(
            file: "/r/meerkat.json", source: .lastGood, effective: .init(), problem: "$.mcp: bad", appliedAt: 0)
        let status = DaemonStatus(
            version: "test", pid: 1, startedAt: 0, executablePath: "/x", rulesDirectory: "/r",
            handlerHost: HandlerHostStatus(state: .idle, workers: 0, restarts: 0, lastExit: nil), sources: [],
            rules: [], configuration: configuration)
        let lines = Status.output(status).lines
        let config = try #require(lines.firstIndex { $0.hasPrefix("config ") })
        #expect(lines[config].contains("last good version"))
        #expect(lines[config + 1] == padField("", 12) + "not applied: $.mcp: bad")
        #expect(!lines.contains { $0.contains("\\n") })
    }

    /// A store or file that isn't there is 66, like a missing rules folder,
    /// and nothing is created in its place.
    @Test func aMissingInputIsNoInput() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-\(UUID())").path
        let store = #expect(throws: CommandFailure.self) { try openExistingStore(missing) }
        #expect(store?.status == ExitStatus.noInput)
        let check = try #require(try Meerkat.parseAsRoot(["config", "check", missing, "--json"]) as? Config.Check)
        let failure = #expect(throws: CommandFailure.self) { try check.run() }
        #expect(failure?.status == ExitStatus.noInput)
        #expect(!FileManager.default.fileExists(atPath: missing))
    }
}

/// What `meerkat sample` does when a sample can't be taken.
struct SampleRunTests {
    /// The samples written before stay written, retention still runs, and
    /// the failure is reported with any problem before it.
    @Test func aFailedSampleEndsTheRunButKeepsWhatCameBefore() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-\(UUID()).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SampleStore(path: path)
        for _ in 0..<3 { try store.insert(label: "run", sample: .test) }

        let command = try Sample.parse(["--repeat", "5", "--label", "run", "--retain", "2"])
        var taken = 0
        var shown: [Int] = []
        let (samples, problems) = command.record(
            into: store,
            sampling: {
                taken += 1
                guard taken < 3 else { throw CommandFailure("sampling failed: no process table") }
                return .test
            },
            show: { index, _ in shown.append(index) })
        #expect(samples.count == 2)
        #expect(shown == [0, 1])
        #expect(problems == ["sampling failed: no process table"])
        #expect(taken == 3)
        // Five were written; retention kept the newest two.
        #expect(try store.labelMetrics().first { $0.label == "run" }?.count == 2)
    }
}

extension SystemSample {
    static let test = SystemSample(
        timestamp: "2026-11-06T12:00:00Z", host: "test-host", cpuCount: 10, windowSeconds: 5, cpuUsagePercent: 20,
        load1: 1, load5: 1, load15: 1,
        memory: MemorySample(
            pageSize: 16_384, freeMB: 100, activeMB: 200, inactiveMB: 50, wiredMB: 25, compressedMB: 10,
            swapUsedMB: 0, swapTotalMB: 1_024),
        processes: [], churn: nil)
}

/// The built `meerkat`, run as an agent runs it: what each failure that
/// needs no daemon exits with, and what it writes where. `buck2 test` sets
/// `MEERKAT_CLI` to the binary.
struct CommandLineContractTests {
    struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ arguments: [String]) throws -> Run {
        let executable = try #require(
            ProcessInfo.processInfo.environment["MEERKAT_CLI"], "buck2 test sets MEERKAT_CLI to the built meerkat")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Files, not pipes: nothing waits on a full pipe.
        let out = folder.appendingPathComponent("stdout")
        let err = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, stdout: try String(contentsOf: out, encoding: .utf8),
            stderr: try String(contentsOf: err, encoding: .utf8))
    }

    static let missing = FileManager.default.temporaryDirectory.appendingPathComponent("CLITests-missing-\(UUID())")
        .path

    /// Each fails with `--json` (asked for, or always the command's) as one
    /// JSON object on stderr carrying its status, and nothing on stdout.
    @Test(
        arguments: [
            (["events", "watch", "no.such.kind"], 64),
            (["rules", "logs", "--limit", "0", "--json"], 64),
            (["sample", "--window", "0", "--json"], 64),
            (["rules", "dry-run", "a.ts", "--payload", "{}", "--sample", "5", "--json"], 64),
            (["rules", "dry-run", "a.ts", "--payload", "notjson", "--json"], 64),
            (["status", "--no-such-flag", "--json"], 64),
            (["skills", "install", "--to", missing, "--json", "no-such-skill"], 64),
            (["rules", "dry-run", missing + ".ts", "--json"], 66),
            (["config", "check", missing, "--json"], 66),
            (["compare", missing, "--json"], 66),
            (["analyze", missing, "--json"], 66),
            (["rules", "check", missing, "--json"], 66),
        ] as [([String], Int32)])
    func aJSONFailureIsOneObjectOnStderr(arguments: [String], status: Int32) throws {
        let run = try Self.run(arguments)
        #expect(run.status == status, "\(arguments): \(run.stderr)")
        #expect(run.stdout.isEmpty, "\(arguments)")
        let lines = run.stderr.split(separator: "\n")
        #expect(lines.count == 1, "\(arguments): \(run.stderr)")
        let report = try JSONDecoder().decode(JSONValue.self, from: Data((lines.last ?? "").utf8))
        #expect(report["error"]?["status"] == .number(Double(status)), "\(arguments)")
        #expect(report["error"]?["message"]?.stringValue?.isEmpty == false, "\(arguments)")
    }

    /// Without `--json` the same failures are text, with their status.
    @Test(
        arguments: [
            (["sample", "--window", "0"], 64),
            (["rules", "dry-run", missing + ".ts"], 66),
            (["rules", "check", missing], 66),
        ] as [([String], Int32)])
    func aTextFailureIsText(arguments: [String], status: Int32) throws {
        let run = try Self.run(arguments)
        #expect(run.status == status, "\(arguments): \(run.stderr)")
        #expect(!run.stderr.isEmpty && !run.stderr.hasPrefix("{"), "\(arguments): \(run.stderr)")
    }

    /// A command that names no operation shows its help where help goes,
    /// on stdout, and succeeds.
    @Test(arguments: [[], ["config"]] as [[String]])
    func noOperationShowsHelpOnStdout(arguments: [String]) throws {
        let run = try Self.run(arguments)
        #expect(run.status == 0)
        #expect(run.stdout.contains("USAGE:"), "\(arguments)")
        #expect(run.stderr.isEmpty, "\(arguments): \(run.stderr)")
    }

    /// Data goes to stdout as JSON, and nothing to stderr.
    @Test func dataIsJSONOnStdout() throws {
        let run = try Self.run(["skills", "list", "--json"])
        #expect(run.status == 0)
        #expect(run.stderr.isEmpty)
        let skills = try JSONDecoder().decode(JSONValue.self, from: Data(run.stdout.utf8))
        #expect(skills.arrayValue?.count == AgentSkill.all.count)
    }
}

/// `compare` and MCP's `samples_compare` share `SampleComparison`.
struct SampleComparisonTests {
    static func samples(_ cpu: [Double], swap: Double = 0) -> [[String: Double]] {
        cpu.map { ["cpu_usage_pct": $0, "swap_mb": swap] }
    }

    @Test func twoLabelsHaveADeltaAndItsWarnings() throws {
        let comparison = SampleComparison([
            ("before", Self.samples([10, 12, 11])),
            ("after", Self.samples([30, 31, 29])),
        ])
        #expect(comparison.labels.map(\.label) == ["before", "after"])
        #expect(comparison.labels[0].metrics["cpu_usage_pct"] == Spread([10, 11, 12]))
        let change = try #require(comparison.delta?["cpu_usage_pct"])
        #expect(change.change == 19)
        #expect(change.percent.map { abs($0 - 172.727) < 0.01 } == true)
        // Separate ranges, and swap didn't move on either side.
        #expect(comparison.overlapping.isEmpty)
        #expect(comparison.noisy.isEmpty)
        // A zero median has a change but no percentage.
        #expect(comparison.delta?["swap_mb"] == SampleComparison.Change(change: 0, percent: nil))
    }

    @Test func overlapAndNoiseAreFlagged() {
        let comparison = SampleComparison([("a", Self.samples([10, 40])), ("b", Self.samples([20, 30]))])
        #expect(comparison.overlapping == ["cpu_usage_pct"])
        #expect(comparison.noisy == ["cpu_usage_pct"])
    }

    /// Records group by label in the order labels first appear; with other
    /// than two there is no delta.
    @Test func recordsGroupByLabel() {
        let records = [
            StoredMetrics(label: "b", metrics: ["cpu_usage_pct": 1]),
            StoredMetrics(label: "a", metrics: ["cpu_usage_pct": 2]),
            StoredMetrics(label: "b", metrics: ["cpu_usage_pct": 3]),
            StoredMetrics(label: "c", metrics: [:]),
        ]
        let comparison = SampleComparison(records)
        #expect(comparison.labels.map(\.label) == ["b", "a", "c"])
        #expect(comparison.labels.map(\.count) == [2, 1, 1])
        #expect(comparison.labels[2].metrics.isEmpty)
        #expect(comparison.delta == nil && comparison.overlapping.isEmpty)
    }

    /// One process under a short name and a full path is one process.
    @Test func analysisGroupsProcessesByName() {
        let analysis = Analyze.analysis(
            labels: [],
            usage: [
                .init(sampleID: 1, name: "/usr/libexec/mds", cpuPct: 10),
                .init(sampleID: 2, name: "mds", cpuPct: 30),
                .init(sampleID: 2, name: "zsh", cpuPct: 20),
                .init(sampleID: 1, name: "bash", cpuPct: 20),
            ])
        #expect(analysis.processes.map(\.name) == ["bash", "mds", "zsh"])
        #expect(analysis.processes[1].seen == 2 && analysis.processes[1].peakCPUPct == 30)
    }
}

/// The daemon client's side of surviving a daemon restart.
struct DaemonClientTests {
    /// A subscription a restarted daemon could not take back is the daemon
    /// being unavailable (69), not a failed request (1), and `watch` must
    /// reach that mapping while it reads its stream.
    @Test func aWatchWhoseSubscriptionIsLostExitsUnavailable() async throws {
        let watch = try #require(try Meerkat.parseAsRoot(["events", "watch", "cpu.sample"]) as? Events.Watch)
        let failure = await #expect(throws: CommandFailure.self) { try await watch.run(on: LosingDaemon()) }
        #expect(failure?.status == ExitStatus.unavailable)
    }

    /// A daemon that takes a request and never answers is not answering,
    /// which a bounded ping reports in time.
    @Test func aSilentDaemonDoesNotAnswerAPing() async {
        let started = ContinuousClock.now
        await #expect(throws: DaemonDidNotAnswer.self) {
            try await SilentDaemon().daemonIdentity(within: .milliseconds(100))
        }
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func anAnsweringDaemonGivesItsIdentityInTime() async throws {
        let identity = try await AnsweringDaemon().daemonIdentity(within: .seconds(5))
        #expect(identity == DaemonIdentity(pid: 42, startedAt: 1_000))
    }

    @Test func theCallersCancellationEndsABoundedRequest() async {
        let waiting = Task { try await SilentDaemon().send(.status, within: .seconds(3600)) }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    /// Each subscription is checked against the daemon that accepted it: a
    /// new subscription that reached the new daemon first must not make the
    /// old daemon's subscription look current.
    @Test func onlySubscriptionsAnotherDaemonAcceptedAreRecreated() {
        let old = DaemonIdentity(pid: 100, startedAt: 1_000)
        let new = DaemonIdentity(pid: 200, startedAt: 2_000)
        let accepted: [UInt64: DaemonIdentity?] = [1: old, 2: new, 3: nil]
        #expect(DaemonClient.stale(accepted, current: new) == [1])
        #expect(DaemonClient.stale(accepted, current: old) == [2])
        // The same pid with a later start is a different daemon.
        #expect(DaemonClient.stale([1: old], current: DaemonIdentity(pid: 100, startedAt: 3_000)) == [1])
    }
}

/// Subscribes, then loses the subscription the way a restart can.
private struct LosingDaemon: DaemonConnection {
    func send(_ request: DaemonRequest) async throws -> DaemonReply { .done }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        AsyncThrowingStream {
            $0.finish(throwing: DaemonClient.ClientError.resubscribeFailed(kind: kind, reason: "gone"))
        }
    }
}

/// Takes requests and never answers them, ignoring cancellation, like an
/// XPC reply that never comes.
private struct SilentDaemon: DaemonConnection {
    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        throw CancellationError()
    }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        AsyncThrowingStream { _ in }
    }
}

private struct AnsweringDaemon: DaemonConnection {
    func send(_ request: DaemonRequest) async throws -> DaemonReply { .pong(pid: 42, startedAt: 1_000) }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        AsyncThrowingStream { _ in }
    }
}
