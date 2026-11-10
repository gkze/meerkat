import Foundation
import MeerkatKit

/// Lints and formats a rules directory with the tools Meerkat.app ships:
/// Oxlint (type-aware rules on tsrslint), meerkat-lint (the `meerkat/*`
/// rules, which the standalone Oxlint cannot load as a JS plugin) and
/// Oxfmt. Type errors are the compiler's (`RuleCompiler`).
///
/// Every finding is advice. The compile alone decides whether a rule loads,
/// so linting runs beside it and never changes what is running.
public struct RuleLinter: Sendable {
    public let toolchain: LintToolchain

    public init(toolchain: LintToolchain) {
        self.toolchain = toolchain
    }

    // MARK: - Configuration

    /// What the rules directory's own `.oxlintrc.json` says, written only
    /// when absent: like `tsconfig.json`, it is the author's file once it
    /// exists. The policy it extends is Meerkat's and is rewritten on every
    /// reload. Oxlint does not inherit `ignorePatterns`, so they are here.
    static let rootOxlintConfiguration = """
        {
          // Written once by meerkatd, then yours. It extends Meerkat's rule
          // policy, which meerkatd rewrites into \(RulesDirectoryLayout.supportDirectory)/ on every reload.
          "extends": ["./\(RulesDirectoryLayout.supportDirectory)/\(supportPolicy)"],
          "ignorePatterns": ["\(supportPattern)", "**/node_modules/**"]
        }

        """

    /// Writes `.meerkat/oxlintrc.json` (the policy, kept current) and, when
    /// absent, the directory's `.oxlintrc.json` and `.oxfmtrc.json`. Oxfmt
    /// has no `extends`, so its root file is the policy itself plus the
    /// ignores; delete it to take a newer policy. A root file it creates is
    /// put through Oxfmt, so the format check does not flag Meerkat's own
    /// output.
    public func writeConfiguration(in rulesDirectory: URL) async throws {
        let fileManager = FileManager.default
        let support = rulesDirectory.appendingPathComponent(RulesDirectoryLayout.supportDirectory)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try EditorSupport.writeIfChanged(
            try String(contentsOf: toolchain.oxlintPolicy, encoding: .utf8),
            to: support.appendingPathComponent(Self.supportPolicy))

        var created: [String] = []
        let oxlintrc = rulesDirectory.appendingPathComponent(".oxlintrc.json")
        if !fileManager.fileExists(atPath: oxlintrc.path) {
            try EditorSupport.writeIfChanged(Self.rootOxlintConfiguration, to: oxlintrc)
            created.append(oxlintrc.lastPathComponent)
        }
        let oxfmtrc = rulesDirectory.appendingPathComponent(".oxfmtrc.json")
        if !fileManager.fileExists(atPath: oxfmtrc.path) {
            try EditorSupport.writeIfChanged(try rootOxfmtConfiguration(), to: oxfmtrc)
            created.append(oxfmtrc.lastPathComponent)
        }
        if !created.isEmpty {
            _ = try await RuleCompiler.runTool(
                toolchain.oxfmt, arguments: created, directory: rulesDirectory, environment: environment)
        }
    }

    func rootOxfmtConfiguration() throws -> String {
        let policy = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: toolchain.oxfmtPolicy))
        guard case .object(var options) = policy else {
            throw LintError.badPolicy(toolchain.oxfmtPolicy.path)
        }
        options["ignorePatterns"] = .array([.string(Self.supportPattern)])
        return JSONValue.object(options).canonicalString + "\n"
    }

    // MARK: - Checking and fixing

    /// Lints and format-checks `rulesDirectory`.
    public func check(_ rulesDirectory: URL) async -> LintReport {
        let started = Date().timeIntervalSince1970 * 1000
        var diagnostics = await unix(.oxlint, toolchain.oxlint, Self.oxlintArguments, in: rulesDirectory)
        diagnostics += await unix(.meerkatLint, toolchain.meerkatLint, ["."], in: rulesDirectory)
        diagnostics += await formatCheck(rulesDirectory)
        return LintReport(diagnostics: diagnostics, lintedAt: started)
    }

    /// Fix passes before `fix` reports what is left.
    static let maximumFixPasses = 5

    /// Applies every fix and formats, until a pass changes nothing that is
    /// reported, then returns what is left (findings without a fix).
    /// Oxlint, meerkat-lint and Oxfmt each fix in one pass what the others
    /// may then rewrite, so one pass is not enough. A tool that fails shows
    /// in the next check.
    public func fix(_ rulesDirectory: URL) async -> LintReport {
        var report = await check(rulesDirectory)
        for _ in 0..<Self.maximumFixPasses where !report.diagnostics.isEmpty {
            _ = await unix(.oxlint, toolchain.oxlint, ["--fix"] + Self.oxlintArguments, in: rulesDirectory)
            _ = await unix(.meerkatLint, toolchain.meerkatLint, ["--fix", "."], in: rulesDirectory)
            _ = await format(rulesDirectory)
            let next = await check(rulesDirectory)
            if next.diagnostics == report.diagnostics { return next }
            report = next
        }
        return report
    }

    /// Formats `rulesDirectory` in place.
    public func format(_ rulesDirectory: URL) async -> [RuleDiagnostic] {
        do {
            let result = try await RuleCompiler.runTool(
                toolchain.oxfmt, arguments: ["--no-error-on-unmatched-pattern", "."], directory: rulesDirectory,
                environment: environment)
            return result.status == 0 ? [] : [Self.failure(.oxfmt, status: result.status, output: result.output)]
        } catch {
            return [Self.failure(.oxfmt, error: error)]
        }
    }

    // MARK: - Tools

    /// A rules directory with no sources yet is clean, not an error: Oxlint
    /// otherwise exits 1 with "No files found to lint".
    private static let oxlintArguments = [
        "--format=unix", "--no-error-on-unmatched-pattern", "--ignore-pattern", supportPattern, ".",
    ]

    private static let supportPattern = RulesDirectoryLayout.supportDirectory + "/**"
    /// The policy's copy in the support directory, which the root file extends.
    private static let supportPolicy = "oxlintrc.json"

    /// No inherited environment: the type-aware backend is the bundled
    /// tsrslint whatever the user's shell points `OXLINT_TSGOLINT_PATH` at.
    private var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "OXLINT_TSGOLINT_PATH": toolchain.tsrslint.path]
    }

    /// Runs a tool that prints Oxlint's `unix` format and exits 1 on
    /// findings: Oxlint itself, and meerkat-lint.
    private func unix(_ tool: RuleDiagnostic.Tool, _ executable: URL, _ arguments: [String], in directory: URL)
        async -> [RuleDiagnostic]
    {
        do {
            let result = try await RuleCompiler.runTool(
                executable, arguments: arguments, directory: directory, environment: environment)
            let findings = Self.parseUnix(result.output, tool: tool)
            if result.status == 0 || (result.status == 1 && !findings.isEmpty) { return findings }
            return findings + [Self.failure(tool, status: result.status, output: result.output)]
        } catch {
            return [Self.failure(tool, error: error)]
        }
    }

    /// Files Oxfmt would change, one diagnostic each.
    public func formatCheck(_ directory: URL) async -> [RuleDiagnostic] {
        do {
            let result = try await RuleCompiler.runTool(
                toolchain.oxfmt, arguments: ["--list-different", "--no-error-on-unmatched-pattern", "."],
                directory: directory, environment: environment)
            let files = result.output.split(separator: "\n").map {
                String($0.trimmingCharacters(in: .whitespaces).trimmingPrefix("./"))
            }.filter { !$0.isEmpty }
            switch result.status {
            case 0: return []
            case 1:
                return files.map {
                    RuleDiagnostic(
                        tool: .oxfmt, severity: .warning, file: $0,
                        message: "not formatted; `meerkat rules fmt` formats it", fixable: true)
                }
            default: return [Self.failure(.oxfmt, status: result.status, output: result.output)]
            }
        } catch {
            return [Self.failure(.oxfmt, error: error)]
        }
    }

    // MARK: - Output

    /// `path:line:column: message [Error/plugin(rule)]`, as Oxlint's `unix`
    /// format and meerkat-lint print it. A finding without a rule (an
    /// unused disable directive) has `[Error]`. The format does not say
    /// whether `--fix` fixes a finding, so `fixable` is unknown.
    static func parseUnix(_ text: String, tool: RuleDiagnostic.Tool) -> [RuleDiagnostic] {
        let finding = /^(.+?):(\d+):(\d+): (.*) \[(Error|Warning)(?:\/(.+))?\]$/
        return text.split(separator: "\n").compactMap { line in
            guard let match = String(line).wholeMatch(of: finding) else { return nil }
            return RuleDiagnostic(
                tool: tool, severity: match.5 == "Warning" ? .warning : .error,
                file: String(match.1.trimmingPrefix("./")), line: Int(match.2), column: Int(match.3),
                code: match.6.map(String.init), message: String(match.4))
        }
    }

    private static func failure(_ tool: RuleDiagnostic.Tool, status: Int32, output: String) -> RuleDiagnostic {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .toolFailure(
            tool, message: "\(tool.rawValue) exited with status \(status)" + (detail.isEmpty ? "" : ": \(detail)"))
    }

    private static func failure(_ tool: RuleDiagnostic.Tool, error: any Error) -> RuleDiagnostic {
        .toolFailure(tool, message: "\(tool.rawValue) did not run: \(error)")
    }
}

enum LintError: Error, CustomStringConvertible {
    case badPolicy(String)

    var description: String {
        switch self {
        case .badPolicy(let path): "\(path) is not a JSON object"
        }
    }
}

// MARK: - Toolchain location

/// The lint tools and the policy, in the layout //Tools/Bundler:lint-toolchain
/// builds and the bundler copies to `Contents/Resources/lint/`:
/// `bin/` (oxlint, oxfmt, tsrslint, meerkat-lint) and `policy/`
/// (oxlintrc.json, oxfmtrc.json).
public struct LintToolchain: Sendable, Equatable {
    /// Where Meerkat.app keeps these tools, under `AppBundle.resources`,
    /// which the bundler fills.
    public static let bundledDirectory = "lint"

    public let directory: URL

    public var oxlint: URL { bin("oxlint") }
    public var oxfmt: URL { bin("oxfmt") }
    public var tsrslint: URL { bin("tsrslint") }
    public var meerkatLint: URL { bin("meerkat-lint") }
    var oxlintPolicy: URL { directory.appendingPathComponent("policy/oxlintrc.json") }
    var oxfmtPolicy: URL { directory.appendingPathComponent("policy/oxfmtrc.json") }

    private func bin(_ name: String) -> URL { directory.appendingPathComponent("bin/\(name)") }

    /// A toolchain at `directory`, if every tool and policy file is there.
    public init?(directory: URL) {
        self.directory = directory
        let fileManager = FileManager.default
        let executables = [oxlint, oxfmt, tsrslint, meerkatLint]
        guard executables.allSatisfy({ fileManager.isExecutableFile(atPath: $0.path) }),
            [oxlintPolicy, oxfmtPolicy].allSatisfy({ fileManager.fileExists(atPath: $0.path) })
        else { return nil }
    }

    /// In order: `MEERKAT_LINT_TOOLCHAIN`, the toolchain bundled in
    /// Meerkat.app (`Contents/Resources/lint/`), then the repository's
    /// `.build/lint-toolchain/` for development builds
    /// (`buck2 build //Tools/Bundler:lint-toolchain --out .build/lint-toolchain`).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL = .currentExecutable
    ) -> LintToolchain? {
        if let override = environment["MEERKAT_LINT_TOOLCHAIN"] {
            return LintToolchain(directory: URL(fileURLWithPath: override))
        }
        let resolved = executable.resolvingSymlinksInPath()
        let bundled = AppBundle.resource(Self.bundledDirectory, besideExecutable: resolved)
        if let toolchain = LintToolchain(directory: bundled) { return toolchain }
        var directory = resolved.deletingLastPathComponent()
        for _ in 0..<8 {
            let manifest = directory.appendingPathComponent("Sources/meerkat-lint/BUCK")
            if FileManager.default.fileExists(atPath: manifest.path) {
                return LintToolchain(directory: directory.appendingPathComponent(".build/lint-toolchain"))
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
