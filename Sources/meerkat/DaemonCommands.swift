import ArgumentParser
import Foundation
import MeerkatAgent
import MeerkatIPC
import MeerkatKit
import MeerkatRules

// Commands that talk to meerkatd, or work with the same catalog and rule
// compiler it uses.

/// Writes `value` as JSON and a newline.
func printJSON<T: Encodable>(_ value: T, pretty: Bool = false) throws {
    FileHandle.standardOutput.write(try JSONEncoder.meerkat(pretty: pretty).encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// `text` with every control character escaped (`\n`, `\u{1B}`), for
/// printing text that other programs chose: rule log lines, rule errors,
/// process names, paths. Printed raw, a newline would start a line that
/// reads as another rule's, and an escape sequence would drive the
/// terminal. What is stored and `--json` keep the text as it was.
func terminalSafe(_ text: String) -> String {
    var escaped = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\n": escaped += "\\n"
        case "\r": escaped += "\\r"
        case "\t": escaped += "\\t"
        case "\u{00}"..."\u{1F}", "\u{7F}"..."\u{9F}":
            escaped += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
        default: escaped.unicodeScalars.append(scalar)
        }
    }
    return escaped
}

/// Human-readable output, escaped line by line as it is built. Its lines
/// carry text that rules and other programs chose in many fields (rule
/// names, diagnostics, log messages, request values, source details), so
/// each whole line goes through `terminalSafe`, and a field added later is
/// escaped without anyone remembering to. The only line breaks are the
/// ones between lines.
struct TerminalOutput {
    private(set) var lines: [String] = []

    mutating func add(_ line: String = "") { lines.append(terminalSafe(line)) }

    func print() {
        for line in lines { Swift.print(line) }
    }
}

/// Runs a daemon request; what a failure says about the daemon
/// (`DaemonFailure`) decides its exit status. `connection` is for tests.
func withDaemon<T>(
    _ connection: any DaemonConnection = DaemonClient(), _ body: (any DaemonConnection) async throws -> T
) async throws -> T {
    do {
        return try await body(connection)
    } catch {
        throw daemonFailure(error)
    }
}

/// `error` as the command's failure, by what it says about the daemon
/// (`DaemonFailure`): unavailable, including a watch that lost its
/// subscription to a restart, is `ExitStatus.unavailable`; a refusal or a
/// different build is `failure`. An error that is not the daemon's stays as
/// it is.
func daemonFailure(_ error: any Error) -> any Error {
    switch DaemonFailure(classifying: error) {
    case .unavailable?:
        // The daemon only accepts clients signed by its own team, which a
        // development build (buck-out/) is not: it shows as unreachable.
        let unreachable = if case .unreachable? = error as? DaemonClient.ClientError { true } else { false }
        let note =
            unreachable && AgentRegistration.appBundle == nil
            ? "\nnote: this meerkat is not the one inside Meerkat.app; meerkatd accepts only clients signed with the app."
            : ""
        return CommandFailure("\(error)" + note, status: .unavailable)
    case .refused?, .differentBuild?: return CommandFailure("\(error)")
    case nil: return error
    }
}

/// `directory`, or the rules directory the daemon uses.
func rulesDirectory(_ directory: String?) -> String {
    directory.map { ($0 as NSString).expandingTildeInPath } ?? DaemonPaths.standard().rulesDirectory.path
}

/// Writes generated text to `output`, or to stdout.
func writeOutput(_ text: String, to output: String?) throws {
    if let output {
        try text.write(toFile: (output as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
    } else {
        print(text, terminator: "")
    }
}

func formatTime(_ milliseconds: Double?) -> String {
    guard let milliseconds else { return "-" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = .current
    return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
}

// MARK: - status

struct Status: AsyncParsableCommand, JSONOutput {
    static let configuration = CommandConfiguration(abstract: "Show the daemon, its handler host, sources and rules.")

    @Flag(help: "Print JSON.")
    var json = false

    func run() async throws {
        let status = try await withDaemon { try await $0.status() }
        if json { return try printJSON(status, pretty: true) }
        Self.output(status).print()
    }

    static func output(_ status: DaemonStatus) -> TerminalOutput {
        var output = TerminalOutput()
        output.add("meerkatd \(status.version)  pid \(status.pid)  since \(formatTime(status.startedAt))")
        output.add("executable  \(status.executablePath)")
        output.add("rules       \(status.rulesDirectory)")
        for (index, line) in describe(status.configuration).enumerated() {
            output.add((index == 0 ? "config      " : padField("", 12)) + line)
        }
        let host = status.handlerHost
        output.add(
            "host        \(host.state.rawValue)  workers \(host.workers)  restarts \(host.restarts)"
                + (host.lastExit.map { "  last exit: \($0)" } ?? ""))
        output.add()
        output.add("sources (\(status.sources.count))")
        for source in status.sources {
            output.add(
                "  \(padField(source.kind, 24)) subscribers \(source.subscribers)  delivered \(source.delivered)  dropped \(source.dropped)  \(source.parameters.canonicalString)"
            )
            if let detail = source.detail { output.add("  \(padField("", 24)) \(detail)") }
            // Payloads JSON can't carry, which the source left out.
            if source.unencodable > 0 {
                output.add(
                    "  \(padField("", 24)) unencodable \(source.unencodable)"
                        + (source.lastUnencodable.map { ", last: \($0)" } ?? ""))
            }
        }
        addRules(status.rules, to: &output)
        return output
    }
}

func addRules(_ rules: [RuleSummary], to output: inout TerminalOutput) {
    output.add()
    output.add("rules (\(rules.count))")
    for rule in rules {
        var line = "  \(padField(rule.state.rawValue, 9)) \(padField(rule.id, 40)) \(rule.event ?? "")"
        if rule.invocations > 0 { line += "  runs \(rule.invocations)  failures \(rule.failures)" }
        output.add(line)
        if let reason = rule.reason { output.add("            \(reason)") }
        if let error = rule.lastError { output.add("            last error: \(error)") }
    }
}

// MARK: - effects

struct Effects: ParsableCommand, JSONOutput {
    static let configuration = CommandConfiguration(
        abstract:
            "List what rules can do: every effect, its place on ctx, and the grant it needs; then the grants for observing.",
        discussion:
            "The list is the daemon's effect catalog; docs/design/effects.md explains it. `meerkat events list` says which kinds need which observation grant."
    )

    @Flag(help: "Print JSON, including each effect's request type.")
    var json = false

    struct Entry: Encodable {
        let kind: String
        let method: String
        let grant: String?
        let permission: EventDescriptor.Permission?
        let summary: String
        let request: String
    }

    func run() throws {
        let listing = Self.listing()
        if json { return try printJSON(listing, pretty: true) }
        for entry in listing.effects {
            let need = entry.permission.map { EventDescriptor.PermissionNeed.required($0).note }
            let tags = [entry.grant ?? "no grant"] + (need.map { [$0] } ?? [])
            print("\(padField(entry.method, 30)) \(tags.joined(separator: ", "))")
            print("    \(entry.summary)")
        }
        print()
        print("observing (see meerkat events list for which kinds need which)")
        for grant in listing.observing {
            print("\(padField(grant.grant, 30))")
            print("    \(grant.summary)")
        }
    }

    struct ObservationGrant: Encodable {
        let grant: String
        let summary: String
    }

    /// The effect catalog, and the grants observing needs as the event
    /// catalog names them: a grant is an observation grant because some
    /// kind needs it to be observed, in the effect catalog's order.
    static func listing() -> Listing {
        let catalog = EffectCatalog.standard
        let entries = catalog.effects.map { effect in
            Entry(
                kind: effect.kind, method: "ctx." + effect.method.joined(separator: "."),
                grant: effect.grant.grantKey.map { "capabilities.\($0)" }, permission: effect.permission,
                summary: effect.summary, request: TypeScriptDeclarations.inlineType(effect.requestType))
        }
        let observed = Set(EventCatalog.standard.kinds.compactMap { $0.descriptor.observationGrant?.key })
        let observing = catalog.grants.filter { observed.contains($0.key) }.map {
            ObservationGrant(grant: "capabilities.\($0.key)", summary: $0.doc)
        }
        return Listing(effects: entries, observing: observing)
    }

    struct Listing: Encodable {
        let effects: [Entry]
        let observing: [ObservationGrant]
    }
}

// MARK: - events

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List event kinds, or stream one from the daemon.",
        subcommands: [List.self, Watch.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(abstract: "Every event kind with its delivery guarantees.")

        @Flag(help: "Print JSON, including payload and parameter types.")
        var json = false

        func run() throws {
            let entries = CatalogEntry.entries()
            if json { return try printJSON(entries, pretty: true) }
            for entry in entries {
                let d = entry.descriptor
                let tags =
                    [d.mechanism.rawValue, d.semantics.rawValue, "loss: \(d.loss.rawValue)"]
                    + (d.stability == .undocumented ? ["undocumented"] : [])
                    + (d.permission.map { [$0.note] } ?? [])
                    + (d.observationGrant.map { ["rules need capabilities.\($0.key)"] } ?? [])
                print("\(padField(d.name, 26)) \(tags.joined(separator: ", "))")
                print("    \(d.summary)")
                if entry.parametersType != "{}" {
                    print("    params: \(entry.parametersType)")
                }
            }
        }
    }

    /// Its output is JSON lines, so its failures are JSON too.
    struct Watch: AsyncParsableCommand, AlwaysJSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Stream one event kind from the daemon as JSON lines.",
            discussion: "Example: meerkat events watch fs.change --params '{\"paths\":[\"~/Documents\"]}'"
        )

        @Argument(help: "Event kind, e.g. memory.pressure.")
        var kind: String

        @Option(help: "Parameters as a JSON object.")
        var params: String?

        @Option(
            name: .customLong("param"),
            help: "One parameter as key=value; the value is parsed as JSON when it can be. Repeatable.")
        var param: [String] = []

        @Option(help: "Stop after this many events.")
        var count: Int?

        func validate() throws {
            guard EventCatalog.standard.kind(named: kind) != nil else {
                throw ValidationError("unknown event \"\(kind)\"; see `meerkat events list`")
            }
            if let count, count <= 0 { throw ValidationError("--count must be greater than 0") }
            _ = try parameters()
        }

        func parameters() throws -> JSONValue {
            var fields: [String: JSONValue] = [:]
            if let params {
                guard let object = try? JSONDecoder().decode(JSONValue.self, from: Data(params.utf8)).objectValue else {
                    throw ValidationError("--params must be a JSON object")
                }
                fields = object
            }
            for item in param {
                guard let equals = item.firstIndex(of: "="), equals != item.startIndex else {
                    throw ValidationError("--param expects key=value, got \"\(item)\"")
                }
                let key = String(item[..<equals])
                let raw = String(item[item.index(after: equals)...])
                fields[key] = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .string(raw)
            }
            return .object(fields)
        }

        func run() async throws {
            try await run(on: DaemonClient())
        }

        func run(on connection: any DaemonConnection) async throws {
            // The whole watch runs inside `withDaemon`: a subscription lost to
            // a daemon restart ends the stream with `resubscribeFailed`,
            // which must exit 69 like any other unavailable daemon.
            try await withDaemon(connection) { client in
                var seen = 0
                for try await envelope in try await client.subscribe(kind, parameters: try parameters()) {
                    try printJSON(envelope)
                    seen += 1
                    if let count, seen >= count { return }
                }
            }
        }
    }
}

// MARK: - rules

struct Rules: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and control the daemon's rules.",
        subcommands: [
            List.self, Reload.self, Check.self, Lint.self, Fmt.self, Logs.self, Enable.self, Disable.self, DryRun.self,
        ],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(abstract: "Loaded and failed rules, with compiler diagnostics.")
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            try show(try await withDaemon { try await $0.rules() }, json: json)
        }
    }

    struct Reload: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(abstract: "Recompile and reload the rules directory now.")
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let report = try await withDaemon { try await $0.reloadRules() }
            try show(report, json: json)
            if !report.diagnostics.isEmpty { throw ExitCode.failure }
        }
    }

    struct Check: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Type-check a rules directory with the daemon's compiler, without the daemon.",
            discussion: """
                Exits \(ExitStatus.failure.code) when any file has a diagnostic, with or without --json, \(ExitStatus.noInput.code) when the directory \
                doesn't exist, and \(ExitStatus.unavailable.code) when the compiler isn't installed. Defaults to ~/.config/meerkat/rules.
                """
        )

        @Argument(help: "Rules directory.")
        var directory: String?

        @Flag(help: "Print JSON.") var json = false

        /// What `--json` prints: how many rule files compiled, and every
        /// diagnostic.
        struct Report: Encodable {
            let files: Int
            let diagnostics: [RuleDiagnostic]
        }

        func run() async throws {
            let rules = try Rules.existingDirectory(directory)
            // The CLI does not link the runtime, so it reads the copy of its
            // declarations installed with the compiler.
            guard let toolchain = TypeScriptToolchain.locate(), let runtimeDeclarations = toolchain.runtimeDeclarations
            else {
                throw CommandFailure(
                    "the TypeScript compiler or the runtime's declarations were not found (run from Meerkat.app, or `bun install` in Sources/meerkat-rules/)",
                    status: ExitStatus.unavailable)
            }
            let output = try await RuleCompiler(toolchain: toolchain).compile(
                rulesDirectory: rules,
                workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "meerkat-check-\(UUID().uuidString)"),
                declarations: TypeScriptDeclarations.render(),
                runtimeDeclarations: try String(contentsOf: runtimeDeclarations, encoding: .utf8)
            )
            if json {
                try printJSON(Report(files: output.entries.count, diagnostics: output.diagnostics), pretty: true)
                if !output.diagnostics.isEmpty { throw ExitCode.failure }
                return
            }
            var lines = TerminalOutput()
            for diagnostic in output.diagnostics { lines.add("\(diagnostic)") }
            lines.add(
                "\(output.entries.count) rule file\(output.entries.count == 1 ? "" : "s") ok, \(output.diagnostics.count) diagnostic\(output.diagnostics.count == 1 ? "" : "s")"
            )
            lines.print()
            if !output.diagnostics.isEmpty { throw ExitCode.failure }
        }
    }

    struct Lint: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Lint a rules directory with the tools Meerkat.app ships, without the daemon.",
            discussion: """
                Runs Oxlint (type-aware rules on tsrslint), meerkat-lint and an Oxfmt check; \
                `meerkat rules check` reports type errors. --fix applies every fix and formats until \
                nothing more changes. Findings are advice: the daemon loads a rule whatever they say. \
                Exits \(ExitStatus.failure.code) when any remain, with or without --json, and \(ExitStatus.noInput.code) when the directory doesn't exist. \
                Defaults to ~/.config/meerkat/rules. Without --fix it writes nothing: it checks a copy of \
                the directory with Meerkat's configuration added. --fix, like the daemon, first writes \
                editor support into the directory: \(RulesDirectoryLayout.supportDirectory)/, and \
                tsconfig.json, .oxlintrc.json and .oxfmtrc.json where they are missing.
                """
        )

        @Argument(help: "Rules directory.") var directory: String?
        @Flag(help: "Apply fixes and format, then report what is left.") var fix = false
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let (linter, rules, cleanup) = try await Rules.prepare(directory, writing: fix)
            defer { cleanup() }
            let report = fix ? await linter.fix(rules) : await linter.check(rules)
            if json {
                try printJSON(report, pretty: true)
            } else {
                var output = TerminalOutput()
                for diagnostic in report.diagnostics { output.add("\(diagnostic)") }
                output.add("\(report.diagnostics.count) finding\(report.diagnostics.count == 1 ? "" : "s")")
                output.print()
            }
            if !report.diagnostics.isEmpty { throw ExitCode.failure }
        }
    }

    struct Fmt: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Format a rules directory with Oxfmt.",
            discussion: """
                --check lists unformatted files and exits 1 if there are any, and writes nothing. \
                Defaults to ~/.config/meerkat/rules. Formatting, like `rules lint --fix`, first writes \
                editor support into the directory.
                """
        )

        @Argument(help: "Rules directory.") var directory: String?
        @Flag(help: "Only list files that are not formatted.") var check = false
        @Flag(help: "Print JSON.") var json = false

        /// What `--json` prints: the files left unformatted, or what
        /// formatting couldn't do.
        struct Report: Encodable {
            let diagnostics: [RuleDiagnostic]
        }

        func run() async throws {
            let (linter, rules, cleanup) = try await Rules.prepare(directory, writing: !check)
            defer { cleanup() }
            let diagnostics = check ? await linter.formatCheck(rules) : await linter.format(rules)
            if json {
                try printJSON(Report(diagnostics: diagnostics), pretty: true)
                if !diagnostics.isEmpty { throw ExitCode.failure }
                return
            }
            var output = TerminalOutput()
            for diagnostic in diagnostics { output.add("\(diagnostic)") }
            output.print()
            if !diagnostics.isEmpty { throw ExitCode.failure }
        }
    }

    /// `directory`, or the daemon's rules directory, which must exist: a
    /// mistyped path is not an empty set of rules that all pass, and nothing
    /// here should create one. Exit status 66 is EX_NOINPUT.
    static func existingDirectory(_ directory: String?) throws -> URL {
        let path = rulesDirectory(directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CommandFailure("no rules directory at \(path)", status: ExitStatus.noInput)
        }
        return URL(fileURLWithPath: path)
    }

    /// The linter, and a folder holding the rules with the editor support
    /// the daemon writes on reload: declarations and compiler options, which
    /// the type-aware lint rules read, and the lint configuration. When
    /// `writing`, that is the rules directory itself. Otherwise it is a
    /// scratch copy, so a check leaves the folder it checks as it was;
    /// findings name files relative to the folder, so they name the
    /// originals. `cleanup` removes the copy.
    static func prepare(_ directory: String?, writing: Bool) async throws -> (
        linter: RuleLinter, folder: URL, cleanup: @Sendable () -> Void
    ) {
        guard let toolchain = LintToolchain.locate() else {
            throw CommandFailure(
                "the lint tools were not found (run from Meerkat.app, or in the repository `buck2 build //Tools/Bundler:lint-toolchain --out .build/lint-toolchain`)",
                status: ExitStatus.unavailable)
        }
        let linter = RuleLinter(toolchain: toolchain)
        let (rules, cleanup) = try folder(for: try existingDirectory(directory), writing: writing)
        do {
            try await editorSupport(linter: linter).write(in: rules)
        } catch {
            cleanup()
            throw error
        }
        return (linter, rules, cleanup)
    }

    /// What the daemon writes into a rules directory (`EditorSupport`). The
    /// CLI does not link the runtime: its declarations come from the copy
    /// installed with the compiler, when there is one.
    static func editorSupport(linter: RuleLinter?) -> EditorSupport {
        EditorSupport(
            declarations: TypeScriptDeclarations.render(),
            runtimeDeclarations: TypeScriptToolchain.locate()?.runtimeDeclarations.flatMap {
                try? String(contentsOf: $0, encoding: .utf8)
            },
            configurationSchema: (MeerkatConfiguration.schemaPath, MeerkatConfiguration.jsonSchema()),
            linter: linter)
    }

    /// `rules` itself when `writing`, or a scratch copy of it and what
    /// removes the copy.
    ///
    /// The copy is of the folder a link names: copying the link (dotfile
    /// managers link the rules folder) would copy only the link, and what
    /// is then written "in the copy" would land in the real folder. Links
    /// inside keep pointing where they did: a relative one is made absolute,
    /// since the copy is somewhere else. Nothing writes through them, as
    /// the editor support is written only where a file is missing.
    static func folder(for rules: URL, writing: Bool) throws -> (folder: URL, cleanup: @Sendable () -> Void) {
        guard !writing else { return (rules, {}) }
        let fileManager = FileManager.default
        let original = rules.resolvingSymlinksInPath()
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("meerkat-lint-\(UUID().uuidString)")
        let cleanup: @Sendable () -> Void = { try? FileManager.default.removeItem(at: scratch) }
        do {
            try fileManager.copyItem(at: original, to: scratch)
            // Paths relative to the copy; linked directories are not entered.
            var links: [String] = []
            let entries = fileManager.enumerator(atPath: scratch.path)
            while let relative = entries?.nextObject() as? String {
                if entries?.fileAttributes?[.type] as? FileAttributeType == .typeSymbolicLink { links.append(relative) }
            }
            for relative in links {
                let link = scratch.appendingPathComponent(relative)
                let target = try fileManager.destinationOfSymbolicLink(atPath: link.path)
                guard !target.hasPrefix("/") else { continue }
                let absolute = original.appendingPathComponent(relative).deletingLastPathComponent()
                    .appendingPathComponent(target).standardizedFileURL
                try fileManager.removeItem(at: link)
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: absolute.path)
            }
            // Written again for this build, as the daemon would.
            try? fileManager.removeItem(at: scratch.appendingPathComponent(RulesDirectoryLayout.supportDirectory))
        } catch {
            cleanup()
            throw error
        }
        return (scratch, cleanup)
    }

    struct Logs: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(abstract: "What rules logged, newest first.")

        @Argument(help: "Rule id (`file.ts#name`) or file; all rules when omitted.")
        var rule: String?

        @Option(help: "Lines to show.")
        var limit = 50

        @Flag(help: "Print JSON.") var json = false

        func validate() throws {
            let limits = RuleLogEntry.readLimits
            guard limits.contains(limit) else {
                throw ValidationError("--limit must be \(limits.lowerBound)–\(limits.upperBound)")
            }
        }

        func run() async throws {
            let entries = try await withDaemon { try await $0.logs(rule: rule, limit: limit) }
            if json { return try printJSON(entries, pretty: true) }
            var output = TerminalOutput()
            for entry in entries {
                output.add(
                    "\(formatTime(entry.time)) \(padField(entry.level.rawValue, 5)) \(entry.rule ?? "-")  \(entry.message)"
                )
            }
            output.print()
        }
    }

    struct DryRun: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            commandName: "dry-run",
            abstract: "Run a rule from a file on events, with its effects captured, not performed.",
            discussion: """
                The file need not be in the rules directory: it compiles beside the directory's other files \
                under its own name (or --as), in place of a saved file of that name. Nothing is sent, written \
                or run, and the rules directory is not touched: state.get reads the rule's stored state, and \
                every other effect gets a placeholder result. Events come from --payload, from --sample, or by \
                default from the event kind's examples. Rate limits are not applied. \
                Exits \(ExitStatus.failure.code) when the file does not load or a handler fails, and \(ExitStatus.noInput.code) when there is no file.
                """
        )

        @Argument(help: "TypeScript file with the rule.") var file: String
        @Option(name: .customLong("as"), help: "The file's name in the rules directory.") var name: String?
        @Option(help: "Rule name; needed when the file has several.") var rule: String?
        @Option(help: "An event payload as JSON. Repeatable.") var payload: [String] = []
        @Option(help: "Sample live events from the rule's source for this many seconds.") var sample: Double?
        @Option(help: "Most events a sample takes.") var maxEvents = 16
        @Flag(help: "Print JSON.") var json = false

        func validate() throws {
            guard payload.isEmpty || sample == nil else { throw ValidationError("use --payload or --sample, not both") }
            _ = try payloads()
        }

        /// The events `--payload` gives, each of which must be JSON.
        func payloads() throws -> [DryRunEvent] {
            try payload.map {
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) else {
                    throw ValidationError("--payload is not JSON: \($0)")
                }
                return DryRunEvent(payload: value)
            }
        }

        func run() async throws {
            let path = (file as NSString).expandingTildeInPath
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch CocoaError.fileReadNoSuchFile {
                throw CommandFailure("no file at \(path)", status: ExitStatus.noInput)
            } catch {
                throw CommandFailure("cannot read \(path): \(error.localizedDescription)")
            }
            let events: DryRunRequest.Events
            if let sample {
                events = .sampled(seconds: sample, maxEvents: maxEvents)
            } else if payload.isEmpty {
                events = .examples
            } else {
                events = .given(try payloads())
            }
            let request = DryRunRequest(
                file: name ?? (path as NSString).lastPathComponent, text: text, rule: rule, events: events)
            let report = try await withDaemon { try await $0.dryRun(request) }
            if json {
                try printJSON(report, pretty: true)
            } else {
                Self.output(report).print()
            }
            if Self.failed(report) { throw ExitCode.failure }
        }

        static func failed(_ report: DryRunReport) -> Bool {
            report.outcome != .ran
                || report.runs.contains {
                    switch $0.result {
                    case .completed, .skipped: false
                    case .failed, .timedOut, .interrupted: true
                    }
                }
        }

        static func output(_ report: DryRunReport) -> TerminalOutput {
            var output = TerminalOutput()
            for diagnostic in report.diagnostics { output.add("\(diagnostic)") }
            switch report.outcome {
            case .ran: output.add("\(report.rule ?? "?") on \(report.event ?? "?"): \(report.runs.count) events")
            case .rejected: output.add("did not load")
            case .chooseRule: output.add("choose a rule with --rule: \(report.rules.joined(separator: ", "))")
            }
            for log in report.fileLogs { output.add("  \(padField(log.level.rawValue, 5)) \(log.message)") }
            for run in report.runs {
                let time = String(format: "%.1f ms", run.milliseconds)
                output.add("#\(run.event.sequence) \(Self.text(run.result)) \(time)")
                for effect in run.effects { output.add("  \(Self.text(effect))") }
                for log in run.logs { output.add("  \(padField(log.level.rawValue, 5)) \(log.message)") }
            }
            if report.outOfTime { output.add("ran out of time before the last events") }
            return output
        }

        private static func text(_ result: DryRunInvocation.Result) -> String {
            switch result {
            case .completed: "completed"
            case .failed(let message): "failed: \(message)"
            case .timedOut(let seconds): "timed out after \(seconds) s"
            case .interrupted(let reason): "interrupted: \(reason)"
            case .skipped(let reason): "skipped: \(reason)"
            }
        }

        private static func text(_ effect: DryRunEffect) -> String {
            let request = effect.truncated ? "(left out)" : effect.request.canonicalString
            switch effect.outcome {
            case .simulated: return "would \(effect.kind) \(request)"
            case .read(let result): return "read \(effect.kind) \(request) = \(result.canonicalString)"
            case .refused(let message): return "refused \(effect.kind) \(request): \(message)"
            }
        }
    }

    struct Enable: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Turn a disabled rule back on.",
            discussion: "Enabling a rule that is on does nothing, and succeeds.")
        @Argument(help: "Rule id, `file.ts#name`.") var rule: String
        @Flag(help: "Print the rule as JSON.") var json = false

        func run() async throws { try await setEnabled(rule, true, json: json) }
    }

    struct Disable: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Turn a rule off until enabled or its file changes.",
            discussion: "Disabling a rule that is off does nothing, and succeeds.")
        @Argument(help: "Rule id, `file.ts#name`.") var rule: String
        @Flag(help: "Print the rule as JSON.") var json = false

        func run() async throws { try await setEnabled(rule, false, json: json) }
    }

    /// Prints the rule as it is now: its `RuleSummary`, as JSON or text.
    static func setEnabled(_ rule: String, _ enabled: Bool, json: Bool) async throws {
        let report = try await withDaemon { try await $0.setRule(rule, enabled: enabled) }
        guard let summary = report.rules.first(where: { $0.id == rule }) else {
            throw CommandFailure("no rule \(rule)")
        }
        if json { return try printJSON(summary, pretty: true) }
        var output = TerminalOutput()
        addRules([summary], to: &output)
        output.print()
    }

    static func show(_ report: RulesReport, json: Bool) throws {
        if json { return try printJSON(report, pretty: true) }
        output(report).print()
    }

    static func output(_ report: RulesReport) -> TerminalOutput {
        var output = TerminalOutput()
        addRules(report.rules, to: &output)
        if !report.diagnostics.isEmpty {
            output.add()
            output.add("diagnostics (\(report.diagnostics.count))")
            for diagnostic in report.diagnostics { output.add("  \(diagnostic)") }
        }
        if let lint = report.lint, !lint.diagnostics.isEmpty {
            output.add()
            output.add("lint (\(lint.diagnostics.count), advice; `meerkat rules lint --fix` fixes what it can)")
            for diagnostic in lint.diagnostics { output.add("  \(diagnostic)") }
        }
        return output
    }
}

// MARK: - types

struct Types: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the TypeScript declarations for rules (the `meerkat` module)."
    )

    @Option(help: "Write to this file instead of stdout.")
    var output: String?

    func run() throws {
        try writeOutput(TypeScriptDeclarations.render(), to: output)
    }
}

// MARK: - config

/// Where the configuration comes from, then its problem if any: one line
/// each, so a caller that escapes each line keeps them apart.
func describe(_ status: ConfigurationStatus) -> [String] {
    let source =
        switch status.source {
        case .defaults: "defaults (no \(MeerkatConfiguration.fileName))"
        case .file: "\(status.file)  applied \(formatTime(status.appliedAt))"
        case .lastGood: "\(status.file)  last good version, applied \(formatTime(status.appliedAt))"
        }
    return [source] + (status.problem.map { ["not applied: \($0)"] } ?? [])
}

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The daemon's live configuration, meerkat.json in the rules directory.",
        discussion: """
            meerkat.json sets the MCP policy (which event kinds clients may sample, and the limits on \
            events_sample), the sample store's budget, and the files fs.churn watches (`files`: a root \
            and its exclusions). Saving it applies it within a second; a file \
            that does not validate changes nothing, and its problem shows in `meerkat status` and \
            `meerkat rules`.
            """,
        subcommands: [Show.self, Check.self, Schema.self]
    )

    /// Its output is JSON, so its failures are JSON too.
    struct Show: AsyncParsableCommand, AlwaysJSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Print the configuration the daemon applies now, with every default filled in.",
            discussion: "The JSON goes to stdout; where it comes from, and any problem with the file, to stderr.")

        func run() async throws {
            let configuration = try await withDaemon { try await $0.status() }.configuration
            for line in describe(configuration) { stderrLine(line) }
            try printJSON(configuration.effective, pretty: true)
        }
    }

    struct Check: ParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Validate a meerkat.json without the daemon.",
            discussion:
                "Exits \(ExitStatus.failure.code) when it is not valid, with or without --json, and \(ExitStatus.noInput.code) when there is no file."
        )

        @Argument(help: "The file to check (default: meerkat.json in the rules directory).")
        var file: String?

        @Flag(help: "Print JSON.") var json = false

        /// What `--json` prints.
        struct Report: Encodable {
            let file: String
            let valid: Bool
            let problems: [String]
        }

        func run() throws {
            let path =
                file.map { ($0 as NSString).expandingTildeInPath } ?? DaemonPaths.standard().configurationFile.path
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch CocoaError.fileReadNoSuchFile {
                throw CommandFailure("no file at \(path)", status: ExitStatus.noInput)
            } catch {
                throw CommandFailure("cannot read \(path): \(error.localizedDescription)")
            }
            var problems: [String] = []
            do {
                _ = try MeerkatConfiguration.decode(data)
            } catch let invalid as MeerkatConfiguration.Invalid {
                problems = invalid.problems.map { "\($0)" }
            }
            if json {
                try printJSON(Report(file: path, valid: problems.isEmpty, problems: problems), pretty: true)
            } else if problems.isEmpty {
                print("\(path): valid")
            } else {
                var output = TerminalOutput()
                for problem in problems { output.add("\(path): \(problem)") }
                output.print()
            }
            if !problems.isEmpty { throw ExitCode.failure }
        }
    }

    /// Its output is JSON, so its failures are JSON too.
    struct Schema: ParsableCommand, AlwaysJSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Print the JSON Schema for meerkat.json.",
            discussion: "The daemon also writes it to \(MeerkatConfiguration.schemaPath) in the rules directory.")

        @Option(help: "Write to this file instead of stdout.")
        var output: String?

        func run() throws {
            try writeOutput(MeerkatConfiguration.jsonSchema(), to: output)
        }
    }
}

// MARK: - agent

struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install, remove or inspect the meerkatd LaunchAgent.",
        discussion: "Uses SMAppService, the same mechanism as the app's Install button, so either can undo the other.",
        subcommands: [Install.self, Uninstall.self, Restart.self, Status.self],
        defaultSubcommand: Status.self
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Register the agent (again, if it is registered) so the daemon runs this build and its plist.",
            discussion: """
                Succeeds once a daemon started from this build answers. Exits \(ExitStatus.registeredButSilent.code) \
                when the agent registered but none answered within \(AgentRegistration.startLimit.formatted()), \
                which trying again can fix.
                """
        )

        func run() async throws {
            let wasEnabled = AgentRegistration.status == .enabled
            let started: AgentRegistration.Started
            do {
                started = try await AgentRegistration.installAndAwait(client: DaemonClient())
            } catch {
                throw Self.failure(error)
            }
            switch started {
            case .answering(let daemon):
                print(
                    wasEnabled
                        ? "agent re-registered; meerkatd restarted from this build, pid \(daemon.pid)"
                        : "agent installed; meerkatd started, pid \(daemon.pid)")
            case .requiresApproval:
                print(
                    "agent installed but switched off: enable Meerkat in System Settings > General > Login Items & Extensions"
                )
                AgentRegistration.openLoginItemsSettings()
            }
        }

        /// Registered but silent exits `registeredButSilent`, which trying
        /// again can fix; every other failure is an ordinary one.
        static func failure(_ error: any Error) -> any Error {
            guard case .silent? = error as? AgentRegistration.RegistrationError else { return error }
            return CommandFailure("\(error)", status: .registeredButSilent)
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unregister the agent; launchd stops meerkatd.")

        func run() throws {
            try AgentRegistration.uninstall()
            print("agent uninstalled")
        }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restart meerkatd through launchd, keeping its registration and plist.",
            discussion: "Works when the daemon no longer answers. To pick up a new build or plist, use install."
        )

        func run() throws {
            try AgentRegistration.restart()
            print("meerkatd restarting")
        }
    }

    struct Status: AsyncParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Registration state and whether the daemon answers.",
            discussion:
                "Exits \(ExitStatus.failure.code) when the agent is registered and the daemon doesn't answer, with or without --json."
        )

        @Flag(help: "Print JSON.") var json = false

        /// What `--json` prints. `daemon` is nil when it doesn't answer.
        struct Report: Encodable {
            let registration: String
            let bundle: String?
            let daemon: DaemonIdentity?
        }

        func run() async throws {
            let registration = AgentRegistration.status
            // Bounded: a daemon that takes the request and never replies is
            // not answering, which is what this reports.
            let daemon = try? await DaemonClient().daemonIdentity()
            if json {
                try printJSON(
                    Report(
                        registration: registration.rawValue, bundle: AgentRegistration.appBundle?.path, daemon: daemon),
                    pretty: true)
            } else {
                print("registration  \(registration.rawValue)")
                if let bundle = AgentRegistration.appBundle { print("bundle        \(bundle.path)") }
                if let daemon {
                    print("daemon        running, pid \(daemon.pid), since \(formatTime(daemon.startedAt))")
                } else {
                    print("daemon        not reachable")
                }
            }
            if daemon == nil, registration == .enabled { throw ExitCode.failure }
        }
    }
}
