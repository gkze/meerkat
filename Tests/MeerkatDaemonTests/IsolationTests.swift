import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatStore
import Testing
import notify

@testable import MeerkatDaemon

/// Regression tests for the isolation and lifecycle findings of the
/// independent review: each test is a scenario that used to misbehave.
@Suite(.serialized)
struct IsolationTests {
    typealias Fixture = DaemonEndToEndTests.Fixture

    /// A rule file stuck at top level is rejected; the other files load.
    /// At the daemon's own load deadline: each file's clock starts when its
    /// worker is created, so a shorter one lets a loaded machine fail
    /// `works.ts` too.
    @Test func hungTopLevelCodeOnlyRejectsItsFile() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "hang.ts",
            """
            import { rule } from "meerkat";
            // A condition the compiler cannot see through: the rule after the
            // loop must not be rejected as unreachable before it can hang.
            while (Date.now() > 0) {}
            export const never = rule({ name: "never", on: "memory.pressure", handle() {} });
            """)
        try fixture.write(
            "works.ts",
            """
            import { rule } from "meerkat";
            export const ok = rule({ name: "ok", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   async handle(_e, ctx) { await ctx.state.set("ran", true); } });
            """)
        try await fixture.daemon.start(listen: false)
        let report = await fixture.daemon.engine.report()
        #expect(
            report.rules.contains {
                $0.file == "hang.ts" && $0.state == .failed && ($0.reason ?? "").contains("did not finish")
            })
        #expect(report.rules.contains { $0.id == "works.ts#ok" && $0.state == .loaded })
        let store = try fixture.store()
        #expect(
            try await eventually {
                notify_post(name)
                return try store.value(rule: "works.ts#ok", key: "ran") == .bool(true)
            })
        await fixture.cleanup()
    }

    /// Patching a built-in in one file cannot reach another file's contexts:
    /// each file has its own worker.
    @Test func filesCannotReachEachOthersContexts() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "thief.ts",
            """
            import { rule } from "meerkat";
            const stolen: unknown[] = [];
            const original = Object.freeze;
            Object.freeze = ((value: object) => { stolen.push(value); return original(value); }) as typeof Object.freeze;
            export const look = rule({ name: "look", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   async handle(_e, ctx) {
                     const foreign = stolen.filter((value) => (value as { ruleId?: string }).ruleId === "victim.ts#exec");
                     await ctx.state.set("foreign", foreign.length);
                   } });
            """)
        try fixture.write(
            "victim.ts",
            """
            import { rule } from "meerkat";
            export const exec = rule({ name: "exec", on: "darwin.notification", params: { names: ["\(name)"] },
                   capabilities: { observe: { allow: ["darwin.notification"] }, exec: { allow: ["/usr/bin/true"] } },
                   async handle(_e, ctx) { await ctx.state.set("ran", true); } });
            """)
        try await fixture.daemon.start(listen: false)
        let store = try fixture.store()
        #expect(
            try await eventually {
                notify_post(name)
                return try store.value(rule: "victim.ts#exec", key: "ran") == .bool(true)
                    && store.value(rule: "thief.ts#look", key: "foreign") != nil
            })
        #expect(try store.value(rule: "thief.ts#look", key: "foreign") == .number(0))
        await fixture.cleanup()
    }

    /// A context used after its handler returned is refused.
    @Test func effectsOutsideTheInvocationAreRefused() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "late.ts",
            """
            import { rule } from "meerkat";
            export const late = rule({ name: "late", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   handle(_e, ctx) {
                     setTimeout(() => {
                       ctx.state.set("late", true).then(
                         () => console.log("late write accepted"),
                         (error) => console.log("late write refused: " + String(error)));
                     }, 200);
                   } });
            """)
        try await fixture.daemon.start(listen: false)
        let store = try fixture.store()
        #expect(
            try await eventually {
                notify_post(name)
                return try store.logs(rule: nil, limit: 50).contains { $0.message.hasPrefix("late write") }
            })
        let outcome = try store.logs(rule: nil, limit: 50).first { $0.message.hasPrefix("late write") }?.message
        #expect(outcome?.contains("refused") == true, "\(outcome ?? "nil")")
        #expect(try store.value(rule: "late.ts#late", key: "late") == nil)
        await fixture.cleanup()
    }

    /// Editing one file keeps the other files' rules subscribed: their source
    /// instance survives the reload, and the host restart is not a crash.
    @Test func reloadKeepsUnchangedRulesAndIsNotACrash() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "steady.ts",
            """
            import { rule } from "meerkat";
            export const steady = rule({ name: "steady", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   async handle(_e, ctx) { await ctx.state.set("count", ((await ctx.state.get<number>("count")) ?? 0) + 1); } });
            """)
        try fixture.write(
            "other.ts",
            """
            import { rule } from "meerkat";
            export const other = rule({ name: "other", on: "memory.pressure", handle() {} });
            """)
        try await fixture.daemon.start(listen: false)
        func steadyInstance() -> UInt64? {
            fixture.daemon.hub.statistics().first { $0.kind == "darwin.notification" }?.instance
        }
        let before = try #require(steadyInstance())

        try fixture.write(
            "other.ts",
            """
            import { rule } from "meerkat";
            export const other = rule({ name: "other", on: "memory.pressure", handle() { console.log("edited"); } });
            """)
        await fixture.daemon.engine.reload()
        #expect(steadyInstance() == before, "the unchanged rule's source was restarted")

        let store = try fixture.store()
        // Right after the reload the rule still runs: no crash backoff.
        notify_post(name)
        #expect(try await eventually(5) { try store.value(rule: "steady.ts#steady", key: "count") != nil })
        await fixture.cleanup()
    }

    /// Daemon status events reach rules without `includeOwn`, and only
    /// those about the rule's own file: another file's reasons hold its
    /// errors and what it was refused.
    @Test func ruleStatusEventsReachRules() async throws {
        let fixture = try Fixture()
        try fixture.write(
            "watcher.ts",
            """
            import { rule } from "meerkat";
            export const failures = rule({ name: "failures", on: "meerkat.rule", match: { state: "failed" },
                   async handle(event, ctx) {
                     const seen = ((await ctx.state.get("failed")) as string[] | undefined) ?? [];
                     await ctx.state.set("failed", [...seen, event.ruleId]);
                   } });
            // Refused as it loads: the path is outside its grant.
            export const refused = rule({ name: "refused", on: "fs.change", params: { paths: ["/tmp"] },
                   capabilities: { fs: { read: ["/usr"] } }, handle() {} });
            """)
        try fixture.write(
            "broken.ts",
            """
            import { rule } from "meerkat";
            export const x = rule({ name: "x", on: "memory.pressure", handle(e) { const n: number = e.level; } });
            """)
        try await fixture.daemon.start(listen: false)
        let store = try fixture.store()
        #expect(
            try await eventually {
                try store.value(rule: "watcher.ts#failures", key: "failed") == ["watcher.ts#refused"]
            })
        // broken.ts failed before watcher.ts's own rule did, so its status
        // would have been seen first.
        #expect(try store.value(rule: "watcher.ts#failures", key: "failed") == ["watcher.ts#refused"])
        await fixture.cleanup()
    }
}

struct LogBudgetTests {
    @Test func burstThenRefill() {
        var budget = LogBudget()
        let start = ContinuousClock.now
        let accepted = (0..<1200).filter { _ in budget.admit(now: start) != .drop }.count
        #expect(accepted == Int(LogBudget.capacity))
        // One second later 200 tokens have refilled; the first accepted line
        // reports what was dropped.
        #expect(budget.admit(now: start + .seconds(1)) == .accept(dropped: 200))
    }

    /// One file flooding its log leaves another's lines, and the host's own,
    /// alone; its drops are reported under it.
    @Test func eachFileHasItsOwnBudget() {
        var budgets = LogBudgets()
        let start = ContinuousClock.now
        var flooded = 0
        for _ in 0..<1200 where budgets.admit(rule: "a.ts#r", now: start).1 != .drop { flooded += 1 }
        #expect(flooded == Int(LogBudget.capacity))
        let ownFile = budgets.admit(rule: "a.ts", now: start)
        #expect(ownFile.1 == .drop, "the file's own lines share its budget")
        let other = budgets.admit(rule: "b.ts#r", now: start)
        #expect(other.file == "b.ts" && other.1 == .accept(dropped: 0))
        let host = budgets.admit(rule: nil, now: start)
        #expect(host.file == nil && host.1 == .accept(dropped: 0))
        let later = budgets.admit(rule: "a.ts#r", now: start + .seconds(1))
        #expect(later.file == "a.ts" && later.1 == .accept(dropped: 201))
    }
}
