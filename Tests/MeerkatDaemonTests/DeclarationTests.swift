import Foundation
import MeerkatIPC
import MeerkatKit
import Testing

@testable import MeerkatDaemon
@testable import MeerkatRules

/// The generated TypeScript: the checked-in copy is current, the examples
/// compile, and the types reject what the daemon would reject.
struct DeclarationTests {
    static func compiler() throws -> RuleCompiler {
        RuleCompiler(toolchain: try typeScriptToolchain())
    }

    @Test func checkedInDeclarationsAreCurrent() throws {
        let checkedIn = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/meerkat-rules/meerkat.d.ts"), encoding: .utf8)
        #expect(
            checkedIn == TypeScriptDeclarations.render(),
            "regenerate with: buck2 run //Sources/meerkat-rules:regenerate")
    }

    /// Sources/meerkat-rules/tsconfig.json is what editors and `bun run typecheck` use on the
    /// examples, so it must hold exactly the options the daemon compiles with.
    @Test func checkedInTsconfigMatchesCompilerOptions() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Sources/meerkat-rules/tsconfig.json"))
        let config = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(
            config["compilerOptions"] == .object(RuleCompiler.compilerOptions.merging(["noEmit": true]) { $1 }),
            "copy RuleCompiler.compilerOptions into Sources/meerkat-rules/tsconfig.json")
    }

    @Test func examplesTypeCheck() async throws {
        let output = try await Self.compiler().compile(
            rulesDirectory: repositoryRoot.appendingPathComponent("Sources/meerkat-rules/examples"),
            workDirectory: temporaryURL("meerkat-examples"),
            declarations: TypeScriptDeclarations.render(),
            runtimeDeclarations: DenoRuntime.handlerRuntime.declarations
        )
        #expect(output.diagnostics.isEmpty, "\(output.diagnostics)")
        #expect(output.entries == ["downloads", "heavy-writers", "low-battery", "microphone", "recorder"])
        #expect(output.modules.contains { $0.id == "lib/describe" })
    }

    /// `#` ends an entry file's name in its rules' ids (`RuleID`), so an
    /// entry file whose name holds one is not loaded, and says why; a module
    /// it is not, in a folder, is.
    @Test func anEntryFileNamedWithAHashIsNotLoaded() async throws {
        let directory = temporaryURL("meerkat-hash")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let code =
            "import { rule } from \"meerkat\";\nexport const r = rule({ name: \"r\", on: \"timer\", params: { every: 5 }, handle() {} });\n"
        for file in ["x.ts", "x.ts#y.ts", "lib/a#b.ts"] {
            try code.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let output = try await Self.compiler().compile(
            rulesDirectory: directory,
            workDirectory: directory.appendingPathComponent(".work"),
            declarations: TypeScriptDeclarations.render(),
            runtimeDeclarations: DenoRuntime.handlerRuntime.declarations
        )
        #expect(output.entries == ["x"])
        #expect(output.rejected["x.ts#y"] == RuleID.refusal(file: "x.ts#y.ts"))
        #expect(output.diagnostics.map(\.file) == ["x.ts#y.ts"], "\(output.diagnostics)")
        #expect(output.modules.contains { $0.id == "lib/a#b" })
    }

    /// Each line is a mistake the types must catch before the daemon runs it.
    @Test func typesRejectCommonMistakes() async throws {
        let directory = temporaryURL("meerkat-bad")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        import { rule } from "meerkat";
        rule({ name: "a", on: "fs.change", handle() {} });
        rule({ name: "b", on: "memory.pressure", match: { level: "critcal" }, handle() {} });
        rule({ name: "c", on: "memory.pressure", async handle(_e, ctx) { await ctx.notify({ title: "x" }); } });
        rule({ name: "d", on: "memory.presure", handle() {} });
        rule({ name: "e", on: "timer", params: { every: 5 }, handle(e) { e.cnt; } });
        rule({ name: "f", on: "cpu.sample", params: { intervall: 2 }, handle() {} });
        rule({ name: "g", on: "memory.pressure", capabilities: { process: { signal: true } }, async handle(_e, ctx) {
          await ctx.process.signal({ pid: 1 }, "kill");
        } });
        rule({ name: "h", on: "timer", params: { every: 5 }, capabilities: { state: true }, handle() {} });
        rule({ name: "i", on: "timer", params: { every: 5 }, capabilities: { process: { signl: true } }, handle() {} });
        rule({ name: "j", on: "timer", params: { every: 5 }, capabilities: { exec: { allowed: [] } }, handle() {} });
        rule({ name: "k", on: "window.focused", handle() {} });
        rule({ name: "m", on: "process.exited", capabilities: { notify: true }, handle() {} });
        rule({ name: "n", on: "fs.change", params: { paths: ["/tmp"] }, capabilities: { fs: { write: ["/tmp"] } }, handle() {} });
        rule({ name: "o", on: "timer", params: { every: 5 }, capabilities: { observe: { allow: ["cpu.sample"] } }, handle() {} });
        rule({ name: "p", on: "process.top", capabilities: { process: { observe: "some" } }, handle() {} });
        """.write(to: directory.appendingPathComponent("bad.ts"), atomically: true, encoding: .utf8)

        let output = try await Self.compiler().compile(
            rulesDirectory: directory,
            workDirectory: directory.appendingPathComponent(".work"),
            declarations: TypeScriptDeclarations.render(),
            runtimeDeclarations: DenoRuntime.handlerRuntime.declarations
        )
        let lines = Set(output.diagnostics.compactMap(\.line))
        #expect(lines == [2, 3, 4, 5, 6, 7, 9, 11, 12, 13, 14, 15, 16, 17, 18], "\(output.diagnostics)")
        #expect(output.entries.isEmpty)
        #expect(output.rejected["bad"] == "bad.ts has type errors")
    }

    /// The observation grants type-check where they are right: a named kind
    /// among others in `allow`, a level beside effect flags, a path list.
    @Test func typesAcceptObservationGrants() async throws {
        let directory = temporaryURL("meerkat-observing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        import { rule } from "meerkat";
        export const a = rule({ name: "a", on: "window.focused", capabilities: { observe: { allow: ["log.entry", "window.focused"] } }, handle() {} });
        export const b = rule({ name: "b", on: "process.top", capabilities: { process: { observe: "all", signal: true } }, async handle(event, ctx) {
          const row = event.cpu[0];
          if (row) await ctx.process.signal({ pid: row.pid, startedAt: row.startedAt }, "terminate");
        } });
        export const c = rule({ name: "c", on: "fs.churn", capabilities: { fs: { read: ["~"] } }, handle() {} });
        export const d = rule({ name: "d", on: "memory.pressure", handle() {} });
        """.write(to: directory.appendingPathComponent("ok.ts"), atomically: true, encoding: .utf8)

        let output = try await Self.compiler().compile(
            rulesDirectory: directory,
            workDirectory: directory.appendingPathComponent(".work"),
            declarations: TypeScriptDeclarations.render(),
            runtimeDeclarations: DenoRuntime.handlerRuntime.declarations
        )
        #expect(output.diagnostics.isEmpty, "\(output.diagnostics)")
        #expect(output.entries == ["ok"])
    }

    @Test func diagnosticsParseLocationsAndContinuations() {
        let text = """
            rules/a.ts(3,6): error TS2345: Argument is wrong.
              Property 'params' is missing.
            error TS5023: Unknown compiler option 'x'.
            """
        let diagnostics = RuleCompiler.parseDiagnostics(text, rulesDirectory: URL(fileURLWithPath: "/tmp/x"))
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].file == "rules/a.ts")
        #expect(diagnostics[0].line == 3 && diagnostics[0].column == 6 && diagnostics[0].code == "TS2345")
        #expect(diagnostics[0].message == "Argument is wrong.\nProperty 'params' is missing.")
        #expect(diagnostics[1].file == nil && diagnostics[1].code == "TS5023" && diagnostics[1].tool == .compiler)
    }
}
