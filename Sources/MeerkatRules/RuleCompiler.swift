import Foundation
import MeerkatIPC
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

        let declarationsFile = workDirectory.appendingPathComponent("meerkat.d.ts")
        try declarations.write(to: declarationsFile, atomically: true, encoding: .utf8)
        let runtimeFile = workDirectory.appendingPathComponent("deno.d.ts")
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
            if !id.contains("/"), let refusal = RuleID.refusal(file: source) {
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
            if !id.contains("/") { output.entries.append(id) }
        }
        return output
    }

    // MARK: - Files

    /// Declarations and an editor configuration in the rules directory, so
    /// an editor (and the linter's type-aware rules) checks rules against
    /// this catalog and runtime with the daemon's compiler options.
    /// `.meerkat/` is rewritten as needed; `tsconfig.json` is written only
    /// when absent: it is the author's file once it exists.
    ///
    /// - Parameter runtimeDeclarations: the runtime's globals; nil leaves
    ///   any copy already there.
    public static func writeEditorSupport(
        in rulesDirectory: URL, declarations: String, runtimeDeclarations: String?
    ) throws {
        let support = rulesDirectory.appendingPathComponent(".meerkat")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let base: JSONValue = .object([
            "compilerOptions": .object(compilerOptions.merging(["noEmit": true]) { $1 }),
            "include": .array([.string("../**/*.ts"), .string("./meerkat.d.ts"), .string("./deno.d.ts")]),
            "exclude": .array([.string("../**/node_modules")]),
        ])
        try writeIfChanged(declarations, to: support.appendingPathComponent("meerkat.d.ts"))
        if let runtimeDeclarations {
            try writeIfChanged(runtimeDeclarations, to: support.appendingPathComponent("deno.d.ts"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeIfChanged(
            String(decoding: try encoder.encode(base), as: UTF8.self) + "\n",
            to: support.appendingPathComponent("tsconfig.base.json"))
        let tsconfig = rulesDirectory.appendingPathComponent("tsconfig.json")
        if !FileManager.default.fileExists(atPath: tsconfig.path) {
            try writeIfChanged("{\n  \"extends\": \"./.meerkat/tsconfig.base.json\"\n}\n", to: tsconfig)
        }
    }

    /// Writes only when the contents differ, so the rules directory's
    /// watcher does not see a change that is not one.
    static func writeIfChanged(_ text: String, to url: URL) throws {
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

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
            guard path.hasSuffix(".ts"), !path.hasSuffix(".d.ts"), path.hasPrefix(base + "/"),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            sources.append(String(path.dropFirst(base.count + 1)))
        }
        return sources.sorted()
    }

    public static func moduleId(_ source: String) -> String {
        String(source.dropLast(3))
    }

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
    /// stopped after 60 seconds, with stdout and stderr combined.
    /// `environment` replaces the inherited one when given.
    static func runTool(
        _ executable: URL, arguments: [String], directory: URL, environment: [String: String]? = nil
    ) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // The exit is awaited through a continuation, which ignores task
        // cancellation: reading `terminationStatus` of a process that is
        // still running raises an Objective-C exception. Cancellation instead
        // terminates the tool, and the exit still arrives.
        let exited = ExitSignal()
        process.terminationHandler = { _ in exited.fire() }
        try process.run()
        // A blocking read belongs on a dispatch thread, not on the Swift
        // concurrency threads every actor in the daemon shares.
        let handle = pipe.fileHandleForReading
        let output = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
                }
            }
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            process.terminate()
            try await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        await withTaskCancellationHandler {
            await exited.wait()
        } onCancel: {
            process.terminate()
        }
        watchdog.cancel()
        let data = await output.value
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Toolchain location

/// The compiler, and the checked-in copy of the runtime's declarations
/// installed next to it.
public struct TypeScriptToolchain: Sendable, Equatable {
    /// Where Meerkat.app keeps tsrs, under `Contents/Resources`, which the
    /// bundler fills.
    public static let bundledDirectory = "typescript"

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
        executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) -> TypeScriptToolchain? {
        let fileManager = FileManager.default
        let resolved = executable.resolvingSymlinksInPath()
        let repository = repositoryJS(from: resolved)

        let installed = { (url: URL?) in url.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil } }

        if let override = environment["MEERKAT_TSRS"], fileManager.isExecutableFile(atPath: override) {
            let types =
                environment["MEERKAT_RUNTIME_TYPES"].map(URL.init(fileURLWithPath:))
                ?? repository?.appendingPathComponent("deno.d.ts")
            return TypeScriptToolchain(
                compiler: URL(fileURLWithPath: override), runtimeDeclarations: installed(types))
        }
        // Contents/MacOS/meerkatd -> Contents/Resources/typescript/
        let bundled = resolved.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(Self.bundledDirectory)
        let bundledCompiler = bundled.appendingPathComponent("tsrs")
        if fileManager.isExecutableFile(atPath: bundledCompiler.path) {
            return TypeScriptToolchain(
                compiler: bundledCompiler, runtimeDeclarations: installed(bundled.appendingPathComponent("deno.d.ts")))
        }
        guard let repository else { return nil }
        let compiler = repository.appendingPathComponent("node_modules/.bun/node_modules/@tsrs/darwin-arm64/tsrs")
            .resolvingSymlinksInPath()
        guard fileManager.isExecutableFile(atPath: compiler.path) else { return nil }
        return TypeScriptToolchain(
            compiler: compiler, runtimeDeclarations: installed(repository.appendingPathComponent("deno.d.ts")))
    }

    /// `.build/<config>/meerkatd` or a test bundle: the nearest enclosing
    /// directory's `Sources/meerkat-rules/` that has the checked-in declarations.
    private static func repositoryJS(from executable: URL) -> URL? {
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            let rules = directory.appendingPathComponent("Sources/meerkat-rules")
            if FileManager.default.fileExists(atPath: rules.appendingPathComponent("deno.d.ts").path) { return rules }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
