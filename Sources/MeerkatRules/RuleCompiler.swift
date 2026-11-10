import Foundation
import MeerkatKit

/// Type-checks and compiles the rules directory with tsrs, the Rust port of
/// TypeScript 7's compiler, to the ES modules the runtime loads.
///
/// One compile covers the whole directory, so imports between rule files are
/// checked together, against the `meerkat` module's declarations and the
/// runtime's globals (Deno's). A file with any diagnostic is rejected: it is
/// not run, and importing it from another file fails with that reason.
public struct RuleCompiler: Sendable {
    public let toolchain: TypeScriptToolchain

    public init(toolchain: TypeScriptToolchain) {
        self.toolchain = toolchain
    }

    /// One emitted ES module, by its path relative to the rules directory
    /// without the extension (`util`, `lib/paths`).
    public struct Module: Sendable, Equatable {
        public let id: String
        public let code: String
    }

    public struct Output: Sendable, Equatable {
        public var modules: [Module] = []
        /// Accepted top-level files, by module id, in path order.
        public var entries: [String] = []
        /// Module id to the reason it may not load.
        public var rejected: [String: String] = [:]
        public var diagnostics: [RuleDiagnostic] = []
    }

    /// Compiler options shared by the daemon's compile and the editor config
    /// written into the rules directory, so an editor reports exactly what
    /// the daemon will. Sources/meerkat-rules/tsconfig.json carries the same options.
    ///
    /// Any diagnostic rejects its file, so these are the type-safety checks
    /// only. Unused locals and parameters are left to the linter: as compiler
    /// errors they would stop a rule from loading over an unused import.
    static let compilerOptions: [String: JSONValue] = [
        "target": "es2024",
        // The runtime's declarations add Deno's globals on top.
        "lib": ["esnext"],
        "module": "esnext",
        // Extensionless relative imports, as the runtime's loader resolves
        // them.
        "moduleResolution": "bundler",
        "moduleDetection": "force",
        "strict": true,
        "exactOptionalPropertyTypes": true,
        "noUncheckedIndexedAccess": true,
        "noPropertyAccessFromIndexSignature": true,
        "noImplicitOverride": true,
        "noImplicitReturns": true,
        "noFallthroughCasesInSwitch": true,
        "noUncheckedSideEffectImports": true,
        "allowUnreachableCode": false,
        "allowUnusedLabels": false,
        "erasableSyntaxOnly": true,
        "isolatedModules": true,
        "forceConsistentCasingInFileNames": true,
        "types": [],
        "newLine": "lf",
    ]

    /// - Parameters:
    ///   - declarations: the `meerkat` module's (`TypeScriptDeclarations`).
    ///   - runtimeDeclarations: the runtime's globals (`HandlerRuntime`).
    public func compile(
        rulesDirectory: URL, workDirectory: URL, declarations: String, runtimeDeclarations: String
    ) async throws -> Output {
        let sources = Self.ruleSources(in: rulesDirectory)
        guard !sources.isEmpty else { return Output() }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let declarationsFile = workDirectory.appendingPathComponent(EditorSupport.declarationsFile)
        try declarations.write(to: declarationsFile, atomically: true, encoding: .utf8)
        let runtimeFile = workDirectory.appendingPathComponent(TypeScriptToolchain.runtimeDeclarationsFile)
        try runtimeDeclarations.write(to: runtimeFile, atomically: true, encoding: .utf8)
        let outDirectory = workDirectory.appendingPathComponent("out")

        var options = Self.compilerOptions
        options["rootDir"] = .string(rulesDirectory.path)
        options["outDir"] = .string(outDirectory.path)
        options["noEmitOnError"] = false
        options["pretty"] = false
        // The program is the files listed below and nothing an import or a
        // `/// <reference>` names besides: the runtime loads only rule
        // modules, and `rules_check` compiles text from an MCP client, whose
        // diagnostics would otherwise describe any file the daemon can read.
        options["noResolve"] = true
        let config: JSONValue = .object([
            "compilerOptions": .object(options),
            "files": .array(
                [.string(runtimeFile.path), .string(declarationsFile.path)]
                    + sources.map { .string(rulesDirectory.appendingPathComponent($0).path) }),
        ])
        let configFile = workDirectory.appendingPathComponent("tsconfig.json")
        try config.canonicalString.write(to: configFile, atomically: true, encoding: .utf8)

        let result = try await Self.runTool(
            toolchain.compiler, arguments: ["-p", configFile.path], directory: rulesDirectory)
        var output = Output()
        output.diagnostics = Self.parseDiagnostics(result.output, rulesDirectory: rulesDirectory)
        if result.status != 0, output.diagnostics.isEmpty {
            // tsrs exits non-zero with diagnostics (1 or 2, depending on
            // whether it emitted); non-zero without any means it did not run.
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            output.diagnostics.append(
                .toolFailure(
                    .compiler,
                    message: "tsrs exited with status \(result.status)" + (detail.isEmpty ? "" : ": \(detail)")))
        }

        let failedFiles = Set(output.diagnostics.compactMap(\.file))
        // A diagnostic outside every rule file (configuration, the generated
        // declarations) or about no file invalidates the whole compile.
        let global = output.diagnostics.contains { $0.file.map { !sources.contains($0) } ?? true }

        for source in sources {
            let id = Self.moduleId(source)
            // An entry file's name is the first part of its rules' ids.
            if Self.isEntry(id), let refusal = RuleID.refusal(file: source) {
                output.rejected[id] = refusal
                output.diagnostics.append(RuleDiagnostic(tool: .loader, file: source, message: refusal, fixable: false))
                continue
            }
            if global || failedFiles.contains(source) {
                output.rejected[id] = global ? "the rules could not be compiled" : "\(source) has type errors"
                continue
            }
            let compiled = outDirectory.appendingPathComponent(id + ".js")
            guard let code = try? String(contentsOf: compiled, encoding: .utf8) else {
                output.rejected[id] = "tsrs produced no output for \(source)"
                output.diagnostics.append(.toolFailure(.compiler, file: source, message: "tsrs produced no output"))
                continue
            }
            output.modules.append(Module(id: id, code: code))
            if Self.isEntry(id) { output.entries.append(id) }
        }
        return output
    }

    // MARK: - Files

    /// `*.ts` files relative to the rules directory, excluding declarations,
    /// hidden directories (including `.meerkat`) and `node_modules`.
    public static func ruleSources(in directory: URL) -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }
        let base = directory.standardizedFileURL.path
        var sources: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/"), isRuleSource(String(path.dropFirst(base.count + 1))),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            sources.append(String(path.dropFirst(base.count + 1)))
        }
        return sources.sorted()
    }

    /// Whether `path`, relative to the rules directory, is one `ruleSources`
    /// finds: a `.ts` file, not a declaration file, with no hidden part
    /// (`.meerkat` included) and not under `node_modules`.
    public static func isRuleSource(_ path: String) -> Bool {
        guard path.hasSuffix(".ts"), !path.hasSuffix(".d.ts") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && $0 != "node_modules"
        }
    }

    public static func moduleId(_ source: String) -> String {
        String(source.dropLast(3))
    }

    /// Whether a module is an entry file, one whose rules run: a file at the
    /// top of the rules directory. Files in folders are helpers its entries
    /// import.
    public static func isEntry(_ moduleId: String) -> Bool { !moduleId.contains("/") }

    /// The source file of an entry module, as rule ids and logs name it.
    public static func entryFile(_ moduleId: String) -> String { moduleId + ".ts" }

    // MARK: - Diagnostics

    /// Parses `tsrs --pretty false` output: `file(line,col): error TSn: text`,
    /// with indented continuation lines, or `error TSn: text` without a
    /// location. This is TypeScript's documented non-pretty format, which
    /// tsrs keeps, a line-oriented text contract, so a line parser is the
    /// right tool.
    static func parseDiagnostics(_ text: String, rulesDirectory: URL) -> [RuleDiagnostic] {
        let located = /^(.+)\((\d+),(\d+)\): error (TS\d+): (.*)$/
        let unlocated = /^error (TS\d+): (.*)$/
        var diagnostics: [RuleDiagnostic] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if let match = line.wholeMatch(of: located) {
                diagnostics.append(
                    RuleDiagnostic(
                        tool: .compiler, file: relative(String(match.1), to: rulesDirectory), line: Int(match.2),
                        column: Int(match.3), code: String(match.4), message: String(match.5), fixable: false))
            } else if let match = line.wholeMatch(of: unlocated) {
                diagnostics.append(
                    RuleDiagnostic(
                        tool: .compiler, file: nil, code: String(match.1), message: String(match.2), fixable: false))
            } else if line.hasPrefix(" "), let last = diagnostics.popLast() {
                diagnostics.append(
                    RuleDiagnostic(
                        tool: last.tool, kind: last.kind, severity: last.severity, file: last.file, line: last.line,
                        column: last.column, code: last.code,
                        message: last.message + "\n" + line.trimmingCharacters(in: .whitespaces),
                        fixable: last.fixable))
            }
        }
        return diagnostics
    }

    /// tsrs prints paths relative to its working directory (the rules
    /// directory); anything outside it, such as the generated declarations,
    /// keeps its absolute form.
    private static func relative(_ path: String, to directory: URL) -> String {
        let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        let base = directory.standardizedFileURL.path + "/"
        let full = absolute.standardizedFileURL.path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
    }

    // MARK: - Process

    /// Runs a bundled tool (tsrs, or one of `RuleLinter`'s) to completion,
    /// bounded as the `exec` effect is (`ChildProcess`): its process group
    /// is ended after 60 seconds or when the calling task is cancelled, and
    /// each output is cut at 8 MiB. Its stdout, then its stderr. `environment`
    /// replaces the inherited one when given.
    static func runTool(
        _ executable: URL, arguments: [String], directory: URL, environment: [String: String]? = nil
    ) async throws -> (status: Int32, output: String) {
        let result = try await ChildProcess.run(
            path: executable.path, arguments: arguments,
            environment: environment ?? ProcessInfo.processInfo.environment, directory: directory.path, stdin: nil,
            timeout: 60, outputLimit: 8 << 20)
        // A tool a signal ended has no status; the signal stands in for it
        // in the failure callers report.
        return (result.status ?? result.signal ?? -1, result.stdout + result.stderr)
    }
}

// MARK: - Toolchain location

/// The compiler, and the checked-in copy of the runtime's declarations
/// installed next to it.
public struct TypeScriptToolchain: Sendable, Equatable {
    /// Where Meerkat.app keeps tsrs, under `AppBundle.resources`, which the
    /// bundler fills.
    public static let bundledDirectory = "typescript"
    /// The runtime's declarations, by this name beside tsrs in the bundle,
    /// in the repository, in the compile's work directory and in the rules
    /// directory's editor support.
    public static let runtimeDeclarationsFile = "deno.d.ts"

    /// tsrs, next to the `lib.*.d.ts` it resolves beside itself.
    public let compiler: URL
    /// Sources/meerkat-rules/deno.d.ts, the copy of the declarations the runtime exports, for
    /// compiling where the runtime is not linked (`meerkat rules check`);
    /// the daemon takes them from the runtime. Nil when not installed.
    public let runtimeDeclarations: URL?

    public init(compiler: URL, runtimeDeclarations: URL?) {
        self.compiler = compiler
        self.runtimeDeclarations = runtimeDeclarations
    }

    /// In order: `MEERKAT_TSRS` (with `MEERKAT_RUNTIME_TYPES`, or the
    /// repository's Sources/meerkat-rules/deno.d.ts), the compiler bundled in Meerkat.app
    /// (`Contents/Resources/typescript/`, next to its `lib.*.d.ts`), then
    /// the repository's `Sources/meerkat-rules/` for development builds.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL = .currentExecutable
    ) -> TypeScriptToolchain? {
        let fileManager = FileManager.default
        let resolved = executable.resolvingSymlinksInPath()
        let repository = repositoryJS(from: resolved)

        let installed = { (url: URL?) in url.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil } }

        if let override = environment["MEERKAT_TSRS"], fileManager.isExecutableFile(atPath: override) {
            let types =
                environment["MEERKAT_RUNTIME_TYPES"].map(URL.init(fileURLWithPath:))
                ?? repository?.appendingPathComponent(runtimeDeclarationsFile)
            return TypeScriptToolchain(
                compiler: URL(fileURLWithPath: override), runtimeDeclarations: installed(types))
        }
        let bundled = AppBundle.resource(Self.bundledDirectory, besideExecutable: resolved)
        let bundledCompiler = bundled.appendingPathComponent("tsrs")
        if fileManager.isExecutableFile(atPath: bundledCompiler.path) {
            return TypeScriptToolchain(
                compiler: bundledCompiler,
                runtimeDeclarations: installed(bundled.appendingPathComponent(runtimeDeclarationsFile)))
        }
        guard let repository else { return nil }
        let compiler = repository.appendingPathComponent("node_modules/.bun/node_modules/@tsrs/darwin-arm64/tsrs")
            .resolvingSymlinksInPath()
        guard fileManager.isExecutableFile(atPath: compiler.path) else { return nil }
        return TypeScriptToolchain(
            compiler: compiler,
            runtimeDeclarations: installed(repository.appendingPathComponent(runtimeDeclarationsFile)))
    }

    /// `.build/<config>/meerkatd` or a test bundle: the nearest enclosing
    /// directory's `Sources/meerkat-rules/` that has the checked-in declarations.
    private static func repositoryJS(from executable: URL) -> URL? {
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            let rules = directory.appendingPathComponent("Sources/meerkat-rules")
            let declarations = rules.appendingPathComponent(runtimeDeclarationsFile)
            if FileManager.default.fileExists(atPath: declarations.path) { return rules }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
