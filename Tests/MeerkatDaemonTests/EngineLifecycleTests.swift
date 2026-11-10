import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRuntimeBindings
import MeerkatStore
import Testing
import notify

@testable import MeerkatDaemon

/// The engine's own state across reloads, disables and host faults, with the
/// real compiler and runtime.
@Suite(.serialized)
struct EngineLifecycleTests {
    typealias Fixture = DaemonEndToEndTests.Fixture

    /// A disable lasts while its file is unchanged: through a reload in
    /// which the file failed to load (its helper threw). A file whose name
    /// holds the `#` that ends a file's name in a rule id is not loaded, and
    /// fails under its own name.
    @Test func aDisableLastsWhileItsFileIsUnchanged() async throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.paths.rulesDirectory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try fixture.write("lib/gate.ts", "export const open: boolean = true;\n")
        let source = """
            import { rule } from "meerkat";
            import { open } from "./lib/gate";
            if (!open) throw new Error("closed");
            export const r = rule({ name: "r", on: "memory.pressure", handle() {} });
            """
        try fixture.write("plain.ts", source)
        try fixture.write("odd#name.ts", source)
        try await fixture.daemon.start(listen: false)
        let engine = fixture.daemon.engine
        let ids = ["plain.ts#r"]
        for id in ids { try await engine.setEnabled(id, enabled: false) }
        let odd = await engine.report().rules.first { $0.file == "odd#name.ts" }
        #expect(odd?.id == "odd#name.ts" && odd?.state == .failed)
        #expect(odd?.reason == RuleID.refusal(file: "odd#name.ts"))

        await engine.reload()
        try fixture.write("lib/gate.ts", "export const open: boolean = false;\n")
        await engine.reload()
        let failingReport = await engine.report()
        let failing = failingReport.rules
        let failed = failing.filter { $0.state == .failed }.map(\.file).sorted()
        #expect(failed == ["odd#name.ts", "plain.ts"], "\(failing)")
        // The loader's diagnostic gives the thrown message once, with its
        // stack, though V8's stack starts with the message too.
        let thrown = failingReport.diagnostics.first { $0.tool == .loader && $0.file == "plain.ts" }?.message ?? ""
        #expect(thrown.components(separatedBy: "Error: closed").count == 2, "\(thrown)")
        #expect(thrown.contains("\n    at "), "\(thrown)")
        try fixture.write("lib/gate.ts", "export const open: boolean = true;\n")
        await engine.reload()

        let rules = await engine.report().rules
        for id in ids {
            #expect(rules.first { $0.id == id }?.state == .disabled, "\(id): \(rules)")
        }
        await fixture.cleanup()
    }

    /// A compile that throws (here, a cache it cannot write) leaves nothing
    /// running, and the next reload compiles again though no source changed.
    @Test func aCompileThatThrowsRetiresTheHostAndIsRetried() async throws {
        let fixture = try Fixture()
        try fixture.write(
            "steady.ts",
            """
            import { rule } from "meerkat";
            export const steady = rule({ name: "steady", on: "memory.pressure", handle() {} });
            """)
        try await fixture.daemon.start(listen: false)
        let engine = fixture.daemon.engine
        #expect(await engine.hostStatus().state == .running)

        let cache = fixture.paths.cacheDirectory
        try FileManager.default.removeItem(at: cache)
        try Data().write(to: cache)
        await engine.reload()
        let report = await engine.report()
        #expect(report.rules.isEmpty, "\(report.rules)")
        #expect(report.diagnostics.contains { $0.tool == .compiler && $0.kind == .toolFailure }, "\(report)")
        let host = await engine.hostStatus()
        #expect(host.state == .idle && host.workers == 0, "\(host)")

        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        await engine.reload(force: false)
        let rules = await engine.report().rules
        #expect(rules.contains { $0.id == "steady.ts#steady" && $0.state == .loaded }, "\(rules)")
        await fixture.cleanup()
    }

    /// An effect still waiting when its rule is disabled is refused, not
    /// performed, though the invocation that asked for it still runs.
    @Test func effectsWaitingWhenTheRuleIsDisabledDoNotRun() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "queued.ts",
            """
            import { rule } from "meerkat";
            export const queued = rule({
              name: "queued", on: "darwin.notification", params: { names: ["\(name)"] }, timeoutSeconds: 10,
              capabilities: { observe: { allow: ["darwin.notification"] }, exec: { allow: ["/bin/sleep"] } },
              async handle(_event, ctx) {
                // One rule's effects run in order: the second waits for the first.
                const slow = ctx.exec({ path: "/bin/sleep", args: ["1"] });
                const after = ctx.state.set("after", true).then(() => "ran", (e) => `refused: ${e.message}`);
                ctx.log("requested");
                await slow;
                ctx.log(await after);
              },
            });
            """)
        try await fixture.daemon.start(listen: false)
        let store = try fixture.store()
        let messages = { try store.logs(rule: "queued.ts#queued", limit: 20).map(\.message) }
        notify_post(name)
        // The host delivers in order, so both effects are queued by the time
        // the log line that follows them is stored.
        let requested = try await eventually { try messages().contains("requested") }
        if !requested { Issue.record(await fixture.diagnosis()) }
        try await fixture.daemon.engine.setEnabled("queued.ts#queued", enabled: false)
        #expect(try await eventually { try messages().contains { $0.hasPrefix("refused") || $0 == "ran" } })
        let seen = try messages()
        #expect(seen.contains("refused: the rule that asked for this was disabled or reloaded"), "\(seen)")
        #expect(try store.value(rule: "queued.ts#queued", key: "after") == nil)
        await fixture.cleanup()
    }

    /// FSEvents reports the folder's real path, not the symlink the daemon
    /// was given: an edit to `meerkat.json` there still applies.
    @Test func settingsEditsApplyWhereTheFolderIsASymlink() async throws {
        let fixture = try Fixture(linkedRules: true)
        try await fixture.daemon.start(listen: false)
        try #"{ "samples": { "maxAgeDays": 0 } }"#.write(
            to: fixture.paths.rulesDirectory.appendingPathComponent("meerkat.json"), atomically: true,
            encoding: .utf8)
        #expect(
            try await eventually {
                await fixture.daemon.engine.report().diagnostics.contains { $0.file == "meerkat.json" }
            })
        await fixture.cleanup()
    }

    /// A `meerkat.json` that is a symlink out of the rules folder, as dotfile
    /// managers set it up: FSEvents reports writes where they land, so its
    /// target's folder is watched too.
    @Test func settingsEditsApplyWhereTheFileIsASymlink() async throws {
        let fixture = try Fixture()
        let dotfiles = fixture.root.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("meerkat.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.rulesDirectory.appendingPathComponent("meerkat.json"), withDestinationURL: target)
        try await fixture.daemon.start(listen: false)
        // Written in place, as an editor following the link does.
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data(#"{ "samples": { "maxAgeDays": 0 } }"#.utf8))
        try handle.close()
        #expect(
            try await eventually {
                await fixture.daemon.engine.report().diagnostics.contains { $0.file == "meerkat.json" }
            })
        await fixture.cleanup()
    }

    /// A `meerkat.json` link made while the daemon runs is followed too, and
    /// what is watched is the target, not its folder, which FSEvents would
    /// watch whole.
    @Test func settingsEditsApplyWhereTheLinkIsMadeLater() async throws {
        let fixture = try Fixture()
        let dotfiles = fixture.root.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("meerkat.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        try await fixture.daemon.start(listen: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.rulesDirectory.appendingPathComponent("meerkat.json"), withDestinationURL: target)
        let watched = {
            fixture.daemon.hub.statistics().filter { $0.kind == "fs.change" }
                .flatMap { $0.parameters["paths"]?.arrayValue ?? [] }.compactMap(\.stringValue)
        }
        #expect(try await eventually { watched().contains { $0.hasSuffix("/dotfiles/meerkat.json") } }, "\(watched())")
        #expect(!watched().contains { $0.hasSuffix("/dotfiles") }, "\(watched())")
        // Written in place, as an editor following the link does.
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data(#"{ "samples": { "maxAgeDays": 0 } }"#.utf8))
        try handle.close()
        #expect(
            try await eventually {
                await fixture.daemon.engine.report().diagnostics.contains { $0.file == "meerkat.json" }
            })
        await fixture.cleanup()
    }

    /// A handler that ends the host by holding its thread past a long
    /// timeout fails too rarely for the breaker's minute; it is disabled for
    /// its faults instead. Each fault is also the handler's failure.
    @Test func aRuleThatKeepsEndingTheHostIsDisabled() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "spin.ts",
            """
            import { rule } from "meerkat";
            export const spin = rule({ name: "spin", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   timeoutSeconds: 0.2, handle() { for (;;) {} } });
            """)
        try fixture.write(
            "other.ts",
            """
            import { rule } from "meerkat";
            export const other = rule({ name: "other", on: "memory.pressure", handle() {} });
            """)
        try await fixture.daemon.start(listen: false)
        let engine = fixture.daemon.engine
        let spin = { await engine.report().rules.first { $0.id == "spin.ts#spin" } }
        // Poke it until it is disabled: each fault restarts the host after
        // the backoff, and events meanwhile are dropped.
        let disabledInTime = try await eventually(30) {
            notify_post(name)
            return await spin()?.state == .disabled
        }
        if !disabledInTime { Issue.record(await fixture.diagnosis()) }
        let disabled = await spin()
        #expect(disabled?.reason?.contains("ended the handler host 3 times") == true, "\(String(describing: disabled))")
        #expect(disabled?.failures == 3)
        let other = await engine.report().rules.first { $0.id == "other.ts#other" }
        #expect(other?.state == .loaded && other?.failures == 0)
        await fixture.cleanup()
    }

    /// A file whose own code (here a timer, outside any handler) keeps ending
    /// the host is excluded, stays out across reloads while it is unchanged,
    /// and loads again once edited. The fault names the file as the runtime
    /// does (`<entry>.ts`), which is the key `fileHashes` keeps it by.
    @Test func aFileThatKeepsEndingTheHostIsExcludedUntilItChanges() async throws {
        let fixture = try Fixture()
        try fixture.write(
            "busy.ts",
            """
            import { rule } from "meerkat";
            setTimeout(() => { for (;;) {} }, 0);
            export const idle = rule({ name: "idle", on: "memory.pressure", handle() {} });
            """)
        try fixture.write(
            "other.ts",
            """
            import { rule } from "meerkat";
            export const other = rule({ name: "other", on: "memory.pressure", handle() {} });
            """)
        try await fixture.daemon.start(listen: false)
        let engine = fixture.daemon.engine
        let busy = { await engine.report().rules.first { $0.id == "busy.ts" } }
        let excludedInTime = try await eventually(60) { await busy()?.reason?.hasPrefix("excluded") == true }
        if !excludedInTime { Issue.record(await fixture.diagnosis()) }
        let excluded = await busy()
        #expect(excluded?.reason == "excluded: its code ended the handler host 3 times within 5 minutes")

        await engine.reload()
        let stillExcluded = await busy()
        #expect(stillExcluded?.state == .failed && stillExcluded?.reason == excluded?.reason)
        let other = await engine.report().rules.first { $0.id == "other.ts#other" }
        #expect(other?.state == .loaded)

        try fixture.write(
            "busy.ts",
            """
            import { rule } from "meerkat";
            export const idle = rule({ name: "idle", on: "memory.pressure", handle() {} });
            """)
        await engine.reload()
        let rules = await engine.report().rules
        #expect(rules.first { $0.id == "busy.ts#idle" }?.state == .loaded, "\(rules)")
        #expect(!rules.contains { $0.id == "busy.ts" })
        await fixture.cleanup()
    }

    /// A heap is the file's: running out of it is charged to the file, not
    /// to the handler that happened to allocate last, and that handler's
    /// invocation is interrupted rather than failed.
    @Test func exhaustingTheHeapIsChargedToTheFile() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "hog.ts",
            """
            import { rule } from "meerkat";
            export const hog = rule({ name: "hog", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   timeoutSeconds: 30, handle() {
                     const keep = [];
                     for (;;) keep.push(new Array(1 << 16).fill(keep.length));
                   } });
            """)
        try await fixture.daemon.start(listen: false)
        let engine = fixture.daemon.engine
        let faulted = try await eventually(60) {
            notify_post(name)
            return await engine.hostStatus().lastExit?.contains("heap limit") == true
        }
        if !faulted { Issue.record(await fixture.diagnosis()) }
        let exit = await engine.hostStatus().lastExit
        #expect(exit?.hasPrefix("hog.ts passed its JavaScript heap limit") == true, "\(String(describing: exit))")
        #expect(exit?.contains("(while hog.ts#hog ran)") == true)
        let logs = try await engine.logs(rule: "hog.ts", limit: 20)
        #expect(
            logs.contains { $0.message.contains("heap limit") && $0.message.hasSuffix("the handler host restarts") })
        let hog = await engine.report().rules.first { $0.id == "hog.ts#hog" }
        #expect(hog?.failures == 0)
        await fixture.cleanup()
    }
}
