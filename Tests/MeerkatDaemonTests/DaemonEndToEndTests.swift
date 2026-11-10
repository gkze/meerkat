import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatStore
import Testing
import notify

@testable import MeerkatDaemon
@testable import MeerkatRules

/// The daemon in-process with temporary directories, the real compiler
/// (tsrs: `MEERKAT_TSRS`, which `buck2 test` sets, else Sources/meerkat-rules/node_modules)
/// and the real embedded runtime: everything except XPC and launchd.
@Suite(.serialized)
struct DaemonEndToEndTests {
    struct Fixture {
        let root: URL
        let paths: DaemonPaths
        let daemon: Daemon

        /// - Parameters:
        ///   - lintToolchain: nil lints nothing, whatever the machine has
        ///     staged.
        ///   - linkedRules: the rules directory is a symlink to the folder,
        ///     whose real path is what FSEvents reports.
        init(lintToolchain: LintToolchain? = nil, linkedRules: Bool = false) throws {
            root = temporaryURL("meerkatd-e2e")
            paths = DaemonPaths(
                rulesDirectory: root.appendingPathComponent("rules"),
                cacheDirectory: root.appendingPathComponent("cache"),
                ruleDatabase: root.appendingPathComponent("rules.db"),
                sampleDatabase: root.appendingPathComponent("samples.db")
            )
            if linkedRules {
                let folder = root.appendingPathComponent("rules-folder")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: paths.rulesDirectory, withDestinationURL: folder)
            }
            try FileManager.default.createDirectory(at: paths.rulesDirectory, withIntermediateDirectories: true)
            let toolchain = try typeScriptToolchain()
            daemon = try Daemon(
                paths: paths, runtime: DenoRuntime.handlerRuntime, toolchain: toolchain, lintToolchain: lintToolchain)
        }

        func write(_ name: String, _ source: String) throws {
            try source.write(to: paths.rulesDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func store() throws -> RuleStore {
            try RuleStore(path: paths.ruleDatabase.path)
        }

        /// What the daemon knows, attached to failed expectations.
        func diagnosis() async -> Comment {
            let report = await daemon.engine.report()
            let logs = (try? store().logs(rule: nil, limit: 20)) ?? []
            return Comment(
                rawValue:
                    "rules: \(report.rules)\ndiagnostics: \(report.diagnostics)\nlogs: \(logs.map { "\($0.rule ?? "-") \($0.level) \($0.message)" })"
            )
        }

        func cleanup() async {
            await daemon.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Each reload lints the rules directory with the bundled tools. Lint
    /// findings are advice: the rule they are about still loads.
    @Test func reloadLintsWithoutRejecting() async throws {
        let fixture = try Fixture(lintToolchain: try LintTests.toolchain())
        try fixture.write(
            "compact.ts",
            """
            import { rule } from "meerkat";

            export const compact = rule({
              name: "compact",
              on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
              params: { names: ["com.gkze.meerkat.test.lint"] },
              handle(event, ctx) {
                if (event.name.length > 0) {
                  ctx.log(event.name);
                }
              },
            });

            """)

        try await fixture.daemon.start(listen: false)
        await fixture.daemon.engine.lintFinished()
        let report = await fixture.daemon.engine.report()
        #expect(report.rules.contains { $0.id == "compact.ts#compact" && $0.state == .loaded })
        let lint = try #require(report.lint, "no lint report")
        #expect(
            lint.diagnostics.contains { $0.file == "compact.ts" && $0.code == "meerkat(compact-control-statements)" },
            "\(lint.diagnostics)")
        for file in [".oxlintrc.json", ".oxfmtrc.json", ".meerkat/oxlintrc.json"] {
            #expect(
                FileManager.default.fileExists(atPath: fixture.paths.rulesDirectory.appendingPathComponent(file).path))
        }
        await fixture.cleanup()
    }

    @Test func typedRuleRunsAndBadRuleIsRejected() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "count.ts",
            """
            import { rule } from "meerkat";
            import { label } from "./lib/label";

            export const count = rule({
              name: "count",
              on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
              params: { names: ["\(name)"] },
              async handle(event, ctx) {
                const seen = (await ctx.state.get<number>("seen")) ?? 0;
                await ctx.state.set("nothing", null);
                await ctx.state.set("seen", seen + 1);
                ctx.log(label(event.name));
              },
            });
            """)
        try FileManager.default.createDirectory(
            at: fixture.paths.rulesDirectory.appendingPathComponent("lib"),
            withIntermediateDirectories: true)
        try fixture.write("lib/label.ts", "export const label = (text: string): string => `saw ${text}`;\n")
        try fixture.write(
            "broken.ts",
            """
            import { rule } from "meerkat";
            export const typo = rule({ name: "typo", on: "memory.pressure", handle(event) { const n: number = event.level; } });
            """)

        try await fixture.daemon.start(listen: false)
        let report = await fixture.daemon.engine.report()
        #expect(report.rules.contains { $0.id == "count.ts#count" && $0.state == .loaded })
        #expect(report.rules.contains { $0.file == "broken.ts" && $0.state == .failed })
        #expect(report.diagnostics.contains { $0.file == "broken.ts" && $0.code == "TS2322" })

        // Editor support was written next to the rules.
        let support = fixture.paths.rulesDirectory.appendingPathComponent(".meerkat/meerkat.d.ts")
        #expect(FileManager.default.fileExists(atPath: support.path))

        notify_post(name)
        let store = try fixture.store()
        let counted = try await eventually { try store.value(rule: "count.ts#count", key: "seen") == .number(1) }
        if !counted { Issue.record(await fixture.diagnosis()) }
        #expect(try store.value(rule: "count.ts#count", key: "nothing") == .null)
        // The handler logs only after its awaited state write has come back,
        // so the state can be visible before the log line has been sent.
        #expect(
            try await eventually {
                try store.logs(rule: "count.ts#count", limit: 10).contains { $0.message == "saw \(name)" }
            })

        // Hot reload: changing the file changes the behaviour without a restart.
        try fixture.write(
            "count.ts",
            """
            import { rule } from "meerkat";
            export const count = rule({
              name: "count",
              on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
              params: { names: ["\(name)"] },
              async handle(_event, ctx) { await ctx.state.set("seen", 100); },
            });
            """)
        #expect(
            try await eventually {
                notify_post(name)
                return try store.value(rule: "count.ts#count", key: "seen") == .number(100)
            })
        await fixture.cleanup()
    }

    /// An editor checks rules against the same globals the daemon compiles
    /// them with: the running runtime's.
    @Test func editorSupportDeclaresTheRuntimesGlobals() async throws {
        let fixture = try Fixture()
        try await fixture.daemon.start(listen: false)
        let support = fixture.paths.rulesDirectory.appendingPathComponent(".meerkat")
        let declarations = try String(contentsOf: support.appendingPathComponent("deno.d.ts"), encoding: .utf8)
        #expect(declarations == DenoRuntime.handlerRuntime.declarations)
        let config = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: support.appendingPathComponent("tsconfig.base.json")))
        #expect(config["include"] == .array(["../**/*.ts", "./meerkat.d.ts", "./deno.d.ts"]))
        await fixture.cleanup()
    }

    @Test func runawayHandlerIsKilledAndTheRuleKeepsWorking() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "spin.ts",
            """
            import { rule } from "meerkat";
            export const spin = rule({
              name: "spin",
              on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
              params: { names: ["\(name)"] },
              timeoutSeconds: 0.5,
              async handle(event, ctx) {
                if (event.state === 0) { for (;;) {} }
                await ctx.state.set("finished", event.state);
              },
            });
            """)
        try await fixture.daemon.start(listen: false)

        notify_post(name)
        let overran = try await eventually {
            await fixture.daemon.engine.report().rules.first { $0.id == "spin.ts#spin" }?.failures == 1
        }
        if !overran { Issue.record(await fixture.diagnosis()) }
        let failure = await fixture.daemon.engine.report().rules.first { $0.id == "spin.ts#spin" }
        #expect(failure?.lastError?.contains("did not finish within") == true)

        // The host restarts and reloads; a well-behaved event then completes.
        var token: Int32 = 0
        notify_register_check(name, &token)
        defer { notify_cancel(token) }
        notify_set_state(token, 7)
        let store = try fixture.store()
        #expect(
            try await eventually(20) {
                notify_post(name)
                return try store.value(rule: "spin.ts#spin", key: "finished") == .number(7)
            })
        await fixture.cleanup()
    }

    @Test func ungrantedEffectsAreRefused() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "sneaky.ts",
            """
            import { rule } from "meerkat";
            export const sneaky = rule({
              name: "sneaky",
              on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
              params: { names: ["\(name)"] },
              async handle(_event, ctx) {
                // Types forbid this without a grant; call through the untyped
                // context to prove the daemon enforces it as well.
                const untyped = ctx as unknown as { exec(r: { path: string }): Promise<unknown> };
                try {
                  await untyped.exec({ path: "/usr/bin/true" });
                  await ctx.state.set("result", "ran");
                } catch (error) {
                  await ctx.state.set("result", String(error));
                }
              },
            });
            """)
        try await fixture.daemon.start(listen: false)
        notify_post(name)
        let store = try fixture.store()
        #expect(try await eventually { try store.value(rule: "sneaky.ts#sneaky", key: "result") != nil })
        let result = try store.value(rule: "sneaky.ts#sneaky", key: "result")?.stringValue
        #expect(result?.contains("not granted") == true, "\(result ?? "nil")")
        await fixture.cleanup()
    }
}

/// Whether `condition` holds at every poll for `seconds`: for what must stay
/// true while something settles, where one passing poll could come before
/// the change under test.
func throughout(_ seconds: Double, _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard try await condition() else { return false }
        try await Task.sleep(for: .milliseconds(50))
    }
    return try await condition()
}

/// Polls until `condition` holds or `seconds` pass.
func eventually(_ seconds: Double = 15, _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return try await condition()
}
