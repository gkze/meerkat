import Foundation
import MeerkatIPC
import MeerkatKit
import Testing

@testable import MeerkatDaemon
@testable import MeerkatRules

/// Rules folders get the lint and format policy this repository is checked
/// with, run by the bundled tools.
struct LintTests {
    /// `MEERKAT_LINT_TOOLCHAIN` (which `buck2 test` sets to
    /// //Tools/Bundler:lint-toolchain), else the development fallback.
    static func toolchain() throws -> LintToolchain {
        try #require(
            LintToolchain.locate(executable: repositoryRoot.appendingPathComponent(".build/x")),
            "build the lint toolchain: buck2 build //Tools/Bundler:lint-toolchain, and set MEERKAT_LINT_TOOLCHAIN")
    }

    static func temporaryRules() throws -> URL {
        let directory = temporaryURL("meerkat-lint")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The Oxlint configuration `directory` resolves to, as Oxlint reports
    /// it: extends applied, the repository's own config included.
    static func resolvedConfiguration(in directory: URL, toolchain: LintToolchain) async throws -> [String: JSONValue] {
        let result = try await RuleCompiler.runTool(
            toolchain.oxlint, arguments: ["--print-config"], directory: directory,
            environment: ["PATH": "/usr/bin:/bin"])
        try #require(result.status == 0, "\(result.output)")
        guard case .object(let configuration) = try JSONDecoder().decode(JSONValue.self, from: Data(result.output.utf8))
        else { throw LintError.badPolicy("oxlint --print-config") }
        return configuration
    }

    /// Everything but where the files are and what to skip: the policy.
    static let policyKeys = ["categories", "env", "globals", "options", "plugins", "rules", "settings"]

    @Test func rulesFoldersResolveToTheRepositoryPolicy() async throws {
        let toolchain = try Self.toolchain()
        let rules = try Self.temporaryRules()
        defer { try? FileManager.default.removeItem(at: rules) }
        try await RuleLinter(toolchain: toolchain).writeConfiguration(in: rules)

        let repository = try await Self.resolvedConfiguration(in: repositoryRoot, toolchain: toolchain)
        let folder = try await Self.resolvedConfiguration(in: rules, toolchain: toolchain)
        for key in Self.policyKeys {
            #expect(repository[key] == folder[key], "\(key) differs between the repository and a rules folder")
        }
        #expect(repository["rules"] != nil)
    }

    /// Oxfmt has no `extends`: the repository's .oxfmtrc.json and the one a
    /// rules folder gets must each hold the policy, plus their own ignores.
    @Test func formatConfigurationsHoldThePolicy() async throws {
        let decode = { (url: URL) throws -> JSONValue in
            guard case .object(var options) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            else {
                throw LintError.badPolicy(url.path)
            }
            options["$schema"] = nil
            options["ignorePatterns"] = nil
            return .object(options)
        }
        let policy = try decode(repositoryRoot.appendingPathComponent("Sources/meerkat-lint/policy/oxfmtrc.json"))
        #expect(try decode(repositoryRoot.appendingPathComponent(".oxfmtrc.json")) == policy)

        let rules = try Self.temporaryRules()
        defer { try? FileManager.default.removeItem(at: rules) }
        try await RuleLinter(toolchain: try Self.toolchain()).writeConfiguration(in: rules)
        #expect(try decode(rules.appendingPathComponent(".oxfmtrc.json")) == policy)
    }

    @Test func parsesOxlintUnixOutput() {
        let output = """
            planted.ts:3:1: Convert function to const arrow. [Error/meerkat(const-arrow-functions)]
            ./lib/a.ts:10:5: Unexpected console statement. [Warning/eslint(no-console)]
            a.ts:2:1: Unused oxlint-disable directive (no problems were reported). [Error]

            3 problems
            """
        #expect(
            RuleLinter.parseUnix(output, tool: .oxlint) == [
                RuleDiagnostic(
                    tool: .oxlint, file: "planted.ts", line: 3, column: 1, code: "meerkat(const-arrow-functions)",
                    message: "Convert function to const arrow."),
                RuleDiagnostic(
                    tool: .oxlint, severity: .warning, file: "lib/a.ts", line: 10, column: 5,
                    code: "eslint(no-console)", message: "Unexpected console statement."),
                RuleDiagnostic(
                    tool: .oxlint, file: "a.ts", line: 2, column: 1,
                    message: "Unused oxlint-disable directive (no problems were reported)."),
            ])
    }

    /// Every field survives XPC's coding, a diagnostic without a file
    /// included.
    @Test func diagnosticsRoundTrip() throws {
        let report = RulesReport(
            rules: [],
            diagnostics: [
                RuleDiagnostic(tool: .compiler, file: nil, code: "TS5023", message: "Unknown option.", fixable: false),
                .toolFailure(.loader, message: "no rule runtime is available; rules cannot load"),
            ],
            compiledAt: 1,
            lint: LintReport(
                diagnostics: [
                    RuleDiagnostic(tool: .oxfmt, severity: .warning, file: "a.ts", message: "x", fixable: true)
                ], lintedAt: 2))
        let decoded = try JSONDecoder().decode(RulesReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }

    /// Compiler and loader diagnostics stop a file from loading, and
    /// nothing else does, whatever its severity.
    @Test func onlyCompilerAndLoaderBlockLoading() {
        let blocking = RuleDiagnostic.Tool.allCases.filter {
            RuleDiagnostic(tool: $0, file: "a.ts", message: "x").blocksLoading
        }
        #expect(blocking == [.compiler, .loader])
    }

    /// A new rules directory, with only what the daemon writes into it, is
    /// clean: no tool reports an empty directory as a failure.
    @Test func emptyRulesDirectoryIsClean() async throws {
        let rules = try Self.temporaryRules()
        defer { try? FileManager.default.removeItem(at: rules) }
        try RuleCompiler.writeEditorSupport(
            in: rules, declarations: TypeScriptDeclarations.render(), runtimeDeclarations: nil)
        let linter = RuleLinter(toolchain: try Self.toolchain())
        try await linter.writeConfiguration(in: rules)
        #expect(await linter.check(rules).diagnostics == [])
        #expect(await linter.fix(rules).diagnostics == [])
    }

    /// Lint finds each kind of problem, and fixing leaves only what has no
    /// fix, in formatted files.
    @Test func lintsAndFixesARulesDirectory() async throws {
        let toolchain = try Self.toolchain()
        let rules = try Self.temporaryRules()
        defer { try? FileManager.default.removeItem(at: rules) }
        try RuleCompiler.writeEditorSupport(
            in: rules, declarations: TypeScriptDeclarations.render(), runtimeDeclarations: nil)
        let linter = RuleLinter(toolchain: toolchain)
        try await linter.writeConfiguration(in: rules)
        try """
        import { rule } from "meerkat";

        const LIMIT = 1;

        function isOver(value: number): boolean {
          if (value > LIMIT) {
            return true;
          }
          return false;
        }

        rule({ name: "discarded", on: "system.power", handle: () => { return isOver(LIMIT) ? undefined : undefined; } });

        """.write(to: rules.appendingPathComponent("planted.ts"), atomically: true, encoding: .utf8)

        let found = await linter.check(rules).diagnostics
        #expect(
            Set(found.compactMap(\.code)).isSuperset(of: [
                "meerkat(const-arrow-functions)", "meerkat(compact-control-statements)", "meerkat(rule-exported)",
            ]))
        #expect(found.contains { $0.tool == .oxfmt && $0.file == "planted.ts" && $0.fixable == true })
        #expect(found.allSatisfy { !$0.blocksLoading && $0.kind == .finding }, "\(found)")

        let fixed = await linter.fix(rules)
        #expect(fixed.diagnostics.map(\.code) == ["meerkat(rule-exported)"])
        let source = try String(contentsOf: rules.appendingPathComponent("planted.ts"), encoding: .utf8)
        #expect(source.contains("const isOver = (value: number): boolean => {"))
        #expect(source.contains("if (value > LIMIT) return true;"))
        #expect(await linter.formatCheck(rules).isEmpty)
    }
}
