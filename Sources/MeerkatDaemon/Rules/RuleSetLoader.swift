import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRules
import MeerkatRuntimeBindings

/// What the engine and the dry run must agree on when they load rules, so a
/// draft loads, or fails, exactly as the saved file will: the tools rules
/// need, the declarations they compile against, how long a file's
/// top-level code may run, how a file's load result becomes rules and
/// failures, and what a file's code may touch through Deno's APIs. Built
/// once by the engine (`RuleEngine.loader`) and handed to the dry run.
struct RuleSetLoader: Sendable {
    let runtime: HandlerRuntime?
    let toolchain: TypeScriptToolchain?
    let catalog: EventCatalog
    let observation: ObservationScope
    let protected: RuleEngine.ProtectedPaths
    /// The `meerkat` module's declarations: the catalog never changes under
    /// a running daemon, so they are rendered once.
    let declarations: String

    /// Deadline for one entry file's top-level code.
    static let entryDeadline: Duration = .seconds(5)

    init(
        runtime: HandlerRuntime?, toolchain: TypeScriptToolchain?, catalog: EventCatalog,
        observation: ObservationScope, protected: RuleEngine.ProtectedPaths
    ) {
        self.runtime = runtime
        self.toolchain = toolchain
        self.catalog = catalog
        self.observation = observation
        self.protected = protected
        declarations = TypeScriptDeclarations.render(catalog)
    }

    /// Why rules cannot load at all: a tool is missing.
    struct Unavailable: Error, CustomStringConvertible {
        /// Which tool's absence it is, for the diagnostic.
        let tool: RuleDiagnostic.Tool
        let description: String

        var diagnostic: RuleDiagnostic { .toolFailure(tool, message: "\(description); rules cannot load") }
    }

    struct Tools: Sendable {
        let runtime: HandlerRuntime
        let toolchain: TypeScriptToolchain
    }

    /// The runtime and the compiler, or why rules cannot load.
    func tools() throws(Unavailable) -> Tools {
        guard let runtime else { throw Unavailable(tool: .loader, description: "no rule runtime is available") }
        guard let toolchain else {
            throw Unavailable(tool: .compiler, description: "the TypeScript compiler was not found")
        }
        return Tools(runtime: runtime, toolchain: toolchain)
    }

    func compile(_ rulesDirectory: URL, in workDirectory: URL, with tools: Tools) async throws -> RuleCompiler.Output {
        try await RuleCompiler(toolchain: tools.toolchain).compile(
            rulesDirectory: rulesDirectory, workDirectory: workDirectory, declarations: declarations,
            runtimeDeclarations: tools.runtime.declarations)
    }

    /// Loads `entries` (module ids) of `compiled` into `host`, with
    /// `rejected` the modules they may not import, and decodes each file's
    /// result.
    func load(
        _ compiled: RuleCompiler.Output, entries: [String], rejected: [String: String], into host: HandlerHost,
        fileScope: FileScopeCheck
    ) async throws -> [LoadedFile] {
        try await host.load(
            modules: compiled.modules, entries: entries, rejected: rejected, entryDeadline: Self.entryDeadline
        ).map { decode($0, fileScope: fileScope) }
    }

    /// Gives each file's code its rules' file grants, before any handler
    /// runs; until then it has none. Without `writes`, nothing to write
    /// (a dry run).
    func permit(_ definitions: [RuleDefinition], in host: HandlerHost, writes: Bool) async {
        for (entry, permissions) in Self.permissions(for: definitions, protected: protected, writes: writes) {
            await host.permit(entry: entry, permissions: permissions)
        }
    }

    /// The file is the unit Deno's permissions apply to (one worker per
    /// file), so a file's code may do what any of its rules was granted.
    static func permissions(
        for definitions: [RuleDefinition], protected: RuleEngine.ProtectedPaths, writes: Bool = true
    ) -> [String: FilePermissions] {
        var permissions: [String: FilePermissions] = [:]
        for definition in definitions {
            let entry = RuleCompiler.moduleId(definition.file)
            var file = permissions[entry] ?? FilePermissions(denyRead: protected.read, denyWrite: protected.write)
            for path in definition.grants.fsRead where !file.read.contains(path) { file.read.append(path) }
            if writes {
                for path in definition.grants.fsWrite where !file.write.contains(path) { file.write.append(path) }
            }
            permissions[entry] = file
        }
        return permissions
    }

    /// When a rule's `fs.read` grant is held against `meerkat.json`'s file
    /// scope, which can change under a loaded rule.
    enum FileScopeCheck {
        /// Where it subscribes, and again when the scope changes: the engine,
        /// whose rules outlive a scope.
        case atSubscribe
        /// As the file loads: a dry run, which subscribes once and at once.
        case atLoad
    }

    /// One entry file as it loaded.
    struct LoadedFile {
        let file: String
        var definitions: [RuleDefinition] = []
        /// Rules of the file that did not decode, or fall outside the file
        /// scope (`FileScopeCheck.atLoad`); the others still load.
        var failures: [HandlerHost.LoadedEntry.RuleFailure] = []
        /// The file's code failed or overran: none of its rules loaded.
        var error: HandlerError?

        /// What kept the file, or some of its rules, from loading.
        var diagnostics: [RuleDiagnostic] {
            if let error { return [RuleDiagnostic(tool: .loader, file: file, message: error.report, fixable: false)] }
            return failures.map(\.diagnostic)
        }
    }

    /// A file's load result as rules and failures; what the host reports is
    /// untrusted, since the host runs user code.
    private func decode(_ result: HandlerHost.LoadedEntry, fileScope: FileScopeCheck) -> LoadedFile {
        var loaded = LoadedFile(file: result.file)
        if let error = result.error {
            loaded.error = error
            return loaded
        }
        (loaded.definitions, loaded.failures) = result.definitions(catalog: catalog, observation: observation)
        guard fileScope == .atLoad else { return loaded }
        loaded.definitions.removeAll { definition in
            do {
                try observation.requireFileScope(of: definition, in: catalog)
                return false
            } catch {
                loaded.failures.append(
                    .init(file: result.file, name: definition.name, event: definition.event, reason: "\(error)"))
                return true
            }
        }
        return loaded
    }
}

extension HandlerHost.InvocationResult {
    /// The handler's own failure, in the words the rule's log and a dry run
    /// give it; nil when it finished, or the host ended for a reason that is
    /// not the rule's.
    func failure(timeout: Duration) -> String? {
        switch self {
        case .completed(nil), .interrupted, .superseded, .undeliverable: nil
        case .completed(let error?): error.report
        case .timedOut, .overran: "did not finish within \(timeout.formatted())"
        }
    }
}
