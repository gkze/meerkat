import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRules
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization
import Testing
import notify

@testable import MeerkatDaemon

/// `DaemonRequest.dryRun`: unsaved text, real compiler and runtime, nothing
/// performed. The first test is the feature's invariant.
struct DryRunTests {
    final class CountingNotifier: Notifier {
        let posted = Atomic<Int>(0)
        func post(_ plan: NotificationPlan) async throws { posted.add(1, ordering: .relaxed) }
        func withdraw(identifier: String) async throws {}
    }

    /// A daemon's parts without the XPC server: the engine has an executor,
    /// as in meerkatd, and the runner does not.
    struct Harness {
        let root: URL
        let rules: URL
        let cache: URL
        let hub = EventHub()
        let store: RuleStore
        let notifier = CountingNotifier()
        let engine: RuleEngine
        let runner: RuleDryRunner

        init(permissionStatus: @escaping EventDescriptor.Permission.StatusReader = { $0.status }) throws {
            root = temporaryURL("meerkat-dry")
            rules = root.appendingPathComponent("rules")
            cache = root.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            store = try RuleStore(path: root.appendingPathComponent("rules.db").path)
            let toolchain = try typeScriptToolchain()
            let configuration = RuleEngine.Configuration(
                rulesDirectory: rules, cacheDirectory: cache, toolchain: toolchain,
                runtime: DenoRuntime.handlerRuntime, reloadDebounce: .milliseconds(50))
            let executor = EffectExecutor(
                store: store, ownProcesses: hub.environment.ownProcesses, notifier: notifier,
                sampleDatabasePath: root.appendingPathComponent("samples.db").path)
            engine = RuleEngine(configuration: configuration, hub: hub, store: store, executor: executor)
            runner = RuleDryRunner(
                configuration: configuration, hub: hub, store: store, permissionStatus: permissionStatus)
        }

        func marker(_ name: String) -> String { root.appendingPathComponent(name).path }

        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: marker(name)) }

        func write(_ name: String, _ source: String) throws {
            try source.write(to: rules.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func cleanup() async {
            await engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let emptyNotification: JSONValue = ["name": "test.dry", "state": 0]

    /// A rule that does what the invariant names, and tries the ways around
    /// `ctx` too. Running it live is the control: everything the dry run must
    /// not do does happen, so these checks can fail.
    private func actingRule(_ harness: Harness, name: String) -> String {
        """
        import { rule } from "meerkat";
        export const act = rule({
          name: "act",
          on: "darwin.notification",
          params: { names: ["\(name)"] },
          capabilities: {
            observe: { allow: ["darwin.notification"] },
            notify: true,
            exec: { allow: ["/usr/bin/touch"] },
            fs: { write: ["\(harness.root.path)"] },
          },
          async handle(_event, ctx) {
            await ctx.notify({ title: "hello" });
            await ctx.state.set("ran", "yes");
            await ctx.exec({ path: "/usr/bin/touch", args: ["\(harness.marker("by-exec"))"] });
            try {
              await Deno.writeTextFile("\(harness.marker("by-deno"))", "x");
            } catch (error) {
              ctx.log(String(error));
            }
            try {
              new Deno.Command("/usr/bin/touch", { args: ["\(harness.marker("by-command"))"] }).outputSync();
            } catch (error) {
              ctx.log(String(error));
            }
          },
        });
        """
    }

    @Test func noEffectExecutes() async throws {
        let harness = try Harness()
        let name = uniqueName()
        let source = actingRule(harness, name: name)

        let report = try await harness.runner.run(
            DryRunRequest(
                file: "act.ts", text: source,
                events: .given([DryRunEvent(payload: ["name": .string(name), "state": 0])])))

        #expect(report.outcome == .ran, "\(report.diagnostics)")
        #expect(report.rule == "act.ts#act")
        let run = try #require(report.runs.first)
        #expect(run.result == .completed, "\(run)")
        #expect(run.effects.map(\.kind) == ["notify", "state.set", "exec"])
        #expect(run.effects[0].request == ["title": "hello"])
        #expect(run.effects[1].outcome == .simulated(result: .null))
        // The handler goes on with a placeholder of `ExecResult`.
        guard case .simulated(let result) = run.effects[2].outcome else {
            Issue.record("exec was \(run.effects[2].outcome)")
            return
        }
        #expect(result["stdout"] == "")
        #expect(run.logs.count == 2, "\(run.logs)")
        #expect(run.milliseconds > 0)

        // Nothing happened, by any route.
        #expect(harness.notifier.posted.load(ordering: .relaxed) == 0)
        #expect(try harness.store.value(rule: "act.ts#act", key: "ran") == nil)
        #expect(!harness.exists("by-exec"))
        #expect(!harness.exists("by-deno"))
        #expect(!harness.exists("by-command"))
        // The draft left nothing behind, and no rule loaded or logged.
        #expect(RuleCompiler.ruleSources(in: harness.rules).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.cache.path).isEmpty)
        #expect(await harness.engine.report().rules.isEmpty)
        #expect(try harness.store.logs(rule: nil, limit: 10).isEmpty)

        // The control: saved, the same text does all of it, except what
        // Deno's permissions forbid a live rule as well.
        try harness.write("act.ts", source)
        await harness.engine.start()
        notify_post(name)
        #expect(try await eventually { try harness.store.value(rule: "act.ts#act", key: "ran") != nil })
        #expect(try await eventually { harness.exists("by-deno") })
        #expect(harness.notifier.posted.load(ordering: .relaxed) == 1)
        #expect(harness.exists("by-exec"))
        await harness.cleanup()
    }

    @Test func stateReadsTheStoreUnderSimulatedWrites() async throws {
        let harness = try Harness()
        try harness.store.setValue(1, rule: "count.ts#count", key: "n")
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "count.ts",
                text: """
                    import { rule } from "meerkat";
                    export const count = rule({
                      name: "count",
                      on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
                      params: { names: ["test.dry"] },
                      async handle(_event, ctx) {
                        const n = (await ctx.state.get<number>("n")) ?? 0;
                        await ctx.state.set("n", n + 1);
                      },
                    });
                    """,
                events: .given([
                    DryRunEvent(payload: Self.emptyNotification), DryRunEvent(payload: Self.emptyNotification),
                ])
            ))
        #expect(report.runs.count == 2, "\(report)")
        let reads = report.runs.map { $0.effects.first?.outcome }
        #expect(reads[0] == .read(result: ["found": true, "value": 1]))
        // The second event sees the first's write, as a live rule would.
        #expect(reads[1] == .read(result: ["found": true, "value": 2]))
        #expect(try harness.store.value(rule: "count.ts#count", key: "n") == 1)
        await harness.cleanup()
    }

    /// What MCP gets: text is type-checked and none of it runs, not even
    /// top-level code.
    @Test func checkingCompilesAndRunsNothing() async throws {
        let harness = try Harness()
        let marker = harness.marker("ran")
        let text = """
            import { rule } from "meerkat";
            Deno.writeTextFileSync(\(JSONValue.string(marker).canonicalString), "ran");
            export const quiet = rule({ name: "quiet", on: "timer", params: { every: 300 }, handle() {} });
            """
        let good = try await harness.runner.check(file: "quiet.ts", text: text)
        #expect(good.compiles, "\(good.diagnostics)")
        #expect(good.diagnostics.isEmpty)
        #expect(!harness.exists("ran"))

        let bad = try await harness.runner.check(file: "quiet.ts", text: text + "\nconst n: number = \"no\";\n")
        #expect(!bad.compiles)
        #expect(bad.diagnostics.contains { $0.file == "quiet.ts" })
        #expect(RuleCompiler.ruleSources(in: harness.rules).isEmpty)
        await harness.cleanup()
    }

    /// What MCP gets to run: a saved rule, with no way to see stored state.
    @Test func aSavedRuleRunsWithItsStoredStateLeftOut() async throws {
        let harness = try Harness()
        try harness.store.setValue("secret", rule: "keep.ts#keep", key: "token")
        try harness.write(
            "keep.ts",
            """
            import { rule } from "meerkat";
            export const keep = rule({
              name: "keep",
              on: "memory.pressure",
              async handle(_event, ctx) {
                await ctx.state.get<string>("token");
              },
            });
            """)
        let report = try await harness.runner.runSaved(file: "keep.ts", rule: nil)
        #expect(report.outcome == .ran, "\(report.diagnostics)")
        let effect = try #require(report.runs.first?.effects.first, "\(report)")
        #expect(effect.outcome == .read(result: .null))
        #expect(try harness.store.value(rule: "keep.ts#keep", key: "token") == "secret")
        await harness.cleanup()
    }

    @Test(arguments: ["missing.ts", "../keep.ts", "lib/keep.ts"])
    func onlyAFileInTheFolderRuns(file: String) async throws {
        let harness = try Harness()
        await #expect(throws: RuleDryRunner.Failure.self) { try await harness.runner.runSaved(file: file, rule: nil) }
        await harness.cleanup()
    }

    @Test func aMissingGrantFailsAsItWouldLive() async throws {
        let harness = try Harness()
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "sneaky.ts",
                text: """
                    import { rule } from "meerkat";
                    export const sneaky = rule({
                      name: "sneaky",
                      on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
                      params: { names: ["test.dry"] },
                      async handle(_event, ctx) {
                        const untyped = ctx as unknown as { exec(r: { path: string }): Promise<unknown> };
                        await untyped.exec({ path: "/usr/bin/true" });
                      },
                    });
                    """,
                events: .given([DryRunEvent(payload: Self.emptyNotification)])))
        let run = try #require(report.runs.first, "\(report)")
        guard case .failed(let message) = run.result, case .refused(let refusal) = run.effects.first?.outcome else {
            Issue.record("\(run)")
            return
        }
        #expect(message.contains("not granted"))
        #expect(refusal.contains("not granted"))
        await harness.cleanup()
    }

    @Test func aTypeErrorStopsTheRunAndNamesTheFile() async throws {
        let harness = try Harness()
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "bad.ts", text: "const bad: number = \"x\";\nexport { bad };\n",
                events: .given([])))
        #expect(report.outcome == .rejected)
        #expect(report.diagnostics.first?.file == "bad.ts", "\(report.diagnostics)")
        #expect(report.diagnostics.first?.code == "TS2322")
        await harness.cleanup()
    }

    /// The draft replaces the saved file for this compile: other files import
    /// the unsaved version, and the saved one is left alone.
    @Test func theDraftCompilesWithTheDirectoryInPlaceOfItsFile() async throws {
        let harness = try Harness()
        try FileManager.default.createDirectory(
            at: harness.rules.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try harness.write("lib/greeting.ts", "export const greeting = \"from lib\";\n")
        let saved = "export const old = 1;\n"
        try harness.write("draft.ts", saved)
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "draft.ts",
                text: """
                    import { rule } from "meerkat";
                    import { greeting } from "./lib/greeting";
                    console.log("top level");
                    export const draft = rule({
                      name: "draft",
                      on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
                      params: { names: ["test.dry"] },
                      handle(_event, ctx) {
                        ctx.log(greeting);
                      },
                    });
                    """,
                events: .given([DryRunEvent(payload: Self.emptyNotification)])))
        #expect(report.fileLogs.map(\.message) == ["top level"], "\(report)")
        #expect(report.runs.first?.logs == [DryRunLog(level: .info, message: "from lib")])
        let onDisk = try String(contentsOf: harness.rules.appendingPathComponent("draft.ts"), encoding: .utf8)
        #expect(onDisk == saved)
        await harness.cleanup()
    }

    @Test func matchSkipsAndBadEventsAreRefused() async throws {
        let harness = try Harness()
        let text = """
            import { rule } from "meerkat";
            export const picky = rule({
              name: "picky",
              on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
              params: { names: ["a", "b"] },
              match: { name: "a" },
              handle(_event, ctx) {
                ctx.log("ran");
              },
            });
            """
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "picky.ts", text: text,
                events: .given([
                    DryRunEvent(payload: ["name": "a", "state": 0]), DryRunEvent(payload: ["name": "b", "state": 0]),
                    DryRunEvent(payload: ["name": "a", "state": 0], origin: .meerkat),
                ])))
        #expect(report.runs.count == 3, "\(report)")
        #expect(report.runs[0].result == .completed)
        #expect(report.runs[1].result == .skipped(reason: "match: not matched"))
        #expect(report.runs[1].logs.isEmpty)
        #expect(report.runs[2].result == .skipped(reason: "the daemon's own event (no includeOwn)"))

        await #expect(throws: RuleDryRunner.Failure.self) {
            try await harness.runner.run(
                DryRunRequest(file: "picky.ts", text: text, events: .given([DryRunEvent(payload: ["nope": 1])])))
        }
        await harness.cleanup()
    }

    @Test func aFileWithSeveralRulesAsksWhichToRun() async throws {
        let harness = try Harness()
        let text = """
            import { rule } from "meerkat";
            const one = {
              on: "darwin.notification" as const,
              capabilities: { observe: { allow: ["darwin.notification" as const] } },
              params: { names: ["x"] },
              handle() {},
            };
            export const a = rule({ ...one, name: "a" });
            export const b = rule({ ...one, name: "b" });
            """
        let unnamed = try await harness.runner.run(DryRunRequest(file: "two.ts", text: text, events: .given([])))
        #expect(unnamed.outcome == .chooseRule, "\(unnamed)")
        #expect(unnamed.rules == ["a", "b"])
        let named = try await harness.runner.run(
            DryRunRequest(file: "two.ts", text: text, rule: "b", events: .given([])))
        #expect(named.outcome == .ran)
        #expect(named.rule == "two.ts#b")
        await harness.cleanup()
    }

    /// A handler that never gives up the thread stops only the dry run's
    /// host: the events after it are reported interrupted, and a running rule
    /// keeps its own host.
    @Test func aRunawayHandlerStopsOnlyItsRun() async throws {
        let harness = try Harness()
        let name = uniqueName()
        try harness.write(
            "live.ts",
            """
            import { rule } from "meerkat";
            export const live = rule({
              name: "live",
              on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
              params: { names: ["\(name)"] },
              async handle(_event, ctx) {
                await ctx.state.set("alive", true);
              },
            });
            """)
        await harness.engine.start()
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "runaway.ts",
                text: """
                    import { rule } from "meerkat";
                    export const runaway = rule({
                      name: "runaway",
                      on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
                      params: { names: ["test.dry"] },
                      timeoutSeconds: 0.2,
                      handle() {
                        for (;;) {}
                      },
                    });
                    """,
                events: .given([
                    DryRunEvent(payload: Self.emptyNotification), DryRunEvent(payload: Self.emptyNotification),
                ])
            ))
        #expect(report.runs.count == 2, "\(report)")
        #expect(report.runs[0].result == .timedOut(seconds: 0.2))
        guard case .interrupted = report.runs[1].result else {
            Issue.record("\(report.runs[1])")
            return
        }
        notify_post(name)
        #expect(try await eventually { try harness.store.value(rule: "live.ts#live", key: "alive") != nil })
        #expect(await harness.engine.hostStatus().restarts == 0)
        await harness.cleanup()
    }

    @Test func sampledEventsComeFromTheRulesSource() async throws {
        let harness = try Harness()
        let name = uniqueName()
        let run = Task {
            try await harness.runner.run(
                DryRunRequest(
                    file: "sample.ts",
                    text: """
                        import { rule } from "meerkat";
                        export const sample = rule({
                          name: "sample",
                          on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
                          params: { names: ["\(name)"] },
                          handle(event, ctx) {
                            ctx.log(event.name);
                          },
                        });
                        """,
                    events: .sampled(seconds: 30, maxEvents: 1)))
        }
        // Posted until the sample has started, which takes a compile.
        let poster = Task {
            while !Task.isCancelled {
                notify_post(name)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let report = try await run.value
        poster.cancel()
        #expect(report.runs.count == 1, "\(report)")
        #expect(report.runs.first?.logs.map(\.message) == [name])
        await harness.cleanup()
    }

    /// Injected, like `allowedPermissionKindWithoutGrantFailsWithoutPrompting`:
    /// a real status depends on what launched the tests.
    @Test func samplingAKindWithoutItsPermissionStartsNoSource() async throws {
        let harness = try Harness(permissionStatus: { _ in .denied })
        let failure = await #expect(throws: RuleDryRunner.Failure.self) {
            try await harness.runner.run(
                DryRunRequest(
                    file: "focus.ts",
                    text: """
                        import { rule } from "meerkat";
                        export const focus = rule({
                          name: "focus",
                          on: "window.focused",
                          capabilities: { observe: { allow: ["window.focused"] } },
                          handle() {},
                        });
                        """,
                    events: .sampled(seconds: 1, maxEvents: 1)))
        }
        #expect(failure?.description.contains("accessibility") == true)
        #expect(harness.hub.statistics().isEmpty)
        await harness.cleanup()
    }

    @Test func simulatedEffectsAskTheSameStatus() async throws {
        let harness = try Harness(permissionStatus: { _ in .denied })
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "list.ts",
                text: """
                    import { rule } from "meerkat";
                    export const list = rule({
                      name: "list",
                      on: "darwin.notification",
                      params: { names: ["test.list"] },
                      capabilities: { observe: { allow: ["darwin.notification"] }, windows: { control: true } },
                      async handle(_event, ctx) {
                        await ctx.windows.list("com.apple.TextEdit");
                      },
                    });
                    """,
                events: .given([DryRunEvent(payload: Self.emptyNotification)])))
        #expect(report.runs.count == 1, "\(report)")
        guard case .failed(let message) = report.runs.first?.result else {
            Issue.record("\(report)")
            return
        }
        #expect(message.contains("accessibility"))
        await harness.cleanup()
    }

    @Test func examplesAreTheKindsOwn() async throws {
        let harness = try Harness()
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "example.ts",
                text: """
                    import { rule } from "meerkat";
                    export const example = rule({
                      name: "example",
                      on: "memory.pressure",
                      handle(event, ctx) {
                        ctx.log(event.level);
                      },
                    });
                    """,
                events: .examples))
        #expect(!report.runs.isEmpty, "\(report)")
        #expect(report.runs.allSatisfy { $0.result == .completed }, "\(report.runs)")
        await harness.cleanup()
    }

    /// A check compiles the rules and nothing else: a file outside them,
    /// named by an import or a reference, is not read, so its diagnostics
    /// tell a client nothing about it, not even whether it exists.
    @Test func checkingReadsNothingOutsideTheRules() async throws {
        let harness = try Harness()
        let secret = harness.root.appendingPathComponent("secret.json")
        try Data(#"{"secretKeyName": "value"}"#.utf8).write(to: secret)
        let missing = harness.root.appendingPathComponent("missing.json")
        func diagnostics(_ path: URL) async throws -> [String] {
            let text = """
                /// <reference path="\(path.path)" />
                import cfg from "\(path.path)";
                const n: number = cfg;
                export {};
                """
            let check = try await harness.runner.check(file: "probe.ts", text: text)
            #expect(!check.compiles)
            return check.diagnostics.map { $0.message.replacingOccurrences(of: path.path, with: "PATH") }
        }
        let existing = try await diagnostics(secret)
        #expect(!existing.joined().contains("secretKeyName"), "\(existing)")
        let absent = try await diagnostics(missing)
        #expect(absent == existing)
        await harness.cleanup()
    }

    @Test func oneRunAtATime() async throws {
        let harness = try Harness()
        let first = Task {
            try await harness.runner.run(
                DryRunRequest(
                    file: "wait.ts",
                    text: """
                        import { rule } from "meerkat";
                        export const wait = rule({
                          name: "wait",
                          on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } },
                          params: { names: ["test.never"] },
                          handle() {},
                        });
                        """,
                    events: .sampled(seconds: 1, maxEvents: 1)))
        }
        // The first holds the slot from its start until its one-second sample
        // ends; the second asks within that.
        let started = try await eventually { harness.runner.isRunning }
        #expect(started)
        let second = await #expect(throws: RuleDryRunner.Failure.self) {
            try await harness.runner.run(DryRunRequest(file: "b.ts", text: "", events: .given([])))
        }
        #expect(second?.description.contains("already running") == true, "\(String(describing: second))")
        #expect(try await first.value.outcome == .ran)
        await harness.cleanup()
    }

    @Test(arguments: ["../up.ts", "lib/a.ts", ".hidden.ts", "a.d.ts", "a.js", ".ts", ""])
    func namesOutsideTheDirectoryAreRefused(file: String) async throws {
        let harness = try Harness()
        await #expect(throws: RuleDryRunner.Failure.self) {
            try await harness.runner.run(DryRunRequest(file: file, text: "", events: .given([])))
        }
        await harness.cleanup()
    }
}

/// The request and its answer as the XPC session carries them, through the
/// assembled daemon.
struct DryRunProtocolTests {
    @Test func aRequestAndReportSurviveTheWire() throws {
        let events: [DryRunRequest.Events] = [
            .given([DryRunEvent(payload: ["a": 1], time: 5, origin: .meerkat)]), .examples,
            .sampled(seconds: 2, maxEvents: 3),
        ]
        for events in events {
            let request = DaemonRequest.dryRun(DryRunRequest(file: "a.ts", text: "x", rule: "r", events: events))
            #expect(try JSONDecoder().decode(DaemonRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        let envelope = EventEnvelope(
            kind: "k", sequence: 1, time: 2, origin: .system, replayed: false, payload: ["a": 1])
        let results: [DryRunInvocation.Result] = [
            .completed, .failed(message: "m"), .timedOut(seconds: 1), .interrupted(reason: "r"),
            .skipped(reason: "s"),
        ]
        let reply = DaemonReply.dryRun(
            DryRunReport(
                outcome: .ran, rules: ["r"], rule: "a.ts#r", event: "k",
                fileLogs: [DryRunLog(level: .warn, message: "w")],
                runs: results.map {
                    DryRunInvocation(
                        event: envelope, result: $0,
                        effects: [
                            DryRunEffect(kind: "notify", request: ["title": "t"], outcome: .simulated(result: .null)),
                            DryRunEffect(kind: "state.get", request: [:], outcome: .read(result: 1)),
                            DryRunEffect(
                                kind: "exec", request: .null, outcome: .refused(message: "no"), truncated: true),
                        ], milliseconds: 1.5)
                }, compileMilliseconds: 1, loadMilliseconds: 2))
        #expect(try JSONDecoder().decode(DaemonReply.self, from: JSONEncoder().encode(reply)) == reply)
    }

    @Test func theDaemonRunsDrafts() async throws {
        let fixture = try DaemonEndToEndTests.Fixture()
        let report = try await fixture.daemon.dryRunner.run(
            DryRunRequest(
                file: "draft.ts",
                text: """
                    import { rule } from "meerkat";
                    export const draft = rule({
                      name: "draft",
                      on: "memory.pressure",
                      async handle(_event, ctx) {
                        await ctx.state.set("ran", true);
                      },
                    });
                    """,
                events: .examples))
        #expect(report.outcome == .ran, "\(report.diagnostics)")
        #expect(report.runs.first?.effects.map(\.kind) == ["state.set"])
        #expect(try fixture.store().value(rule: "draft.ts#draft", key: "ran") == nil)
        await fixture.cleanup()
    }
}

/// `EffectSimulator`, without a runtime.
struct EffectSimulatorTests {
    private func rule(_ capabilities: JSONValue = [:]) throws -> RuleDefinition {
        try RuleDefinition(
            file: "a.ts", raw: ["name": "r", "on": "memory.pressure", "capabilities": capabilities], catalog: .standard)
    }

    /// Every effect's placeholder is a valid result, so a new effect can't
    /// hand a handler something its type says is impossible.
    @Test(arguments: EffectCatalog.standard.effects.map(\.kind))
    func placeholdersAreValidResults(kind: String) throws {
        let effect = try #require(EffectCatalog.standard.effect(kind))
        switch effect.result {
        case .none:
            #expect(effect.result.placeholder == .null)
        case .value(let schema):
            #expect(SchemaValidator.violations(of: effect.result.placeholder, against: schema) == [])
        case .optional:
            #expect(effect.result.placeholder["found"] == false)
        }
    }

    @Test func aDeletedKeyIsGoneForTheRestOfTheRun() throws {
        var simulator = EffectSimulator(authorizer: EffectAuthorizer()) { _, _ in "stored" }
        let definition = try rule()
        let get: JSONValue = ["kind": "state.get", "key": "k"]
        #expect(
            simulator.perform(get, for: definition).effect.outcome == .read(result: ["found": true, "value": "stored"]))
        _ = simulator.perform(["kind": "state.delete", "key": "k"], for: definition)
        #expect(
            simulator.perform(get, for: definition).effect.outcome == .read(result: ["found": false, "value": .null]))
    }

    @Test func anInvalidRequestIsRefused() throws {
        var simulator = EffectSimulator(authorizer: EffectAuthorizer()) { _, _ in nil }
        let result = simulator.perform(["kind": "no.such.effect"], for: try rule())
        guard case .refused = result.effect.outcome, case .failure = result.outcome else {
            Issue.record("\(result.effect)")
            return
        }
    }

    /// What the executor refuses, a dry run refuses: both go through `admit`.
    @Test func requestChecksApplyInADryRun() throws {
        var simulator = EffectSimulator(authorizer: EffectAuthorizer()) { _, _ in nil }
        let large = String(repeating: "x", count: 1 << 20)
        let tooLarge = simulator.perform(["kind": "state.set", "key": "k", "value": .string(large)], for: try rule())
        #expect(tooLarge.outcome == .failure(message: "state.set: values are limited to 1 MiB of JSON"))

        let definition = try RuleDefinition(
            file: "a.ts",
            raw: [
                "name": "r", "on": "memory.pressure", "timeoutSeconds": 5, "capabilities": ["store": ["record": true]],
            ], catalog: .standard)
        let tooLong = simulator.perform(["kind": "store.record", "label": "l", "windowSeconds": 5], for: definition)
        guard case .failure(let message) = tooLong.outcome else {
            Issue.record("\(tooLong.outcome)")
            return
        }
        #expect(message.hasPrefix("store.record: windowSeconds"))
        let fits = simulator.perform(["kind": "store.record", "label": "l", "windowSeconds": 4], for: definition)
        #expect(fits.outcome == .success(value: "null"))
    }

    /// Reads of the outside world are simulated too: they can prompt for a
    /// permission, and what they return isn't the rule's yet.
    @Test func onlyStateIsRead() throws {
        var simulator = EffectSimulator(
            authorizer: EffectAuthorizer(permissionStatus: { _ in .granted })
        ) { _, _ in nil }
        let definition = try rule(["clipboard": ["read": true]])
        let result = simulator.perform(["kind": "clipboard.read"], for: definition)
        #expect(result.effect.outcome == .simulated(result: ["found": false, "value": .null]), "\(result.effect)")
    }
}
