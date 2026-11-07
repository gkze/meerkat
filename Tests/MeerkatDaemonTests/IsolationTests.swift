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

struct ChildProcessTests {
    /// More stdin than a pipe holds, echoed back: neither side may block.
    @Test func largeInputDoesNotDeadlock() async throws {
        let input = String(repeating: "0123456789abcdef", count: 16_384)  // 256 KiB
        let result = try await ChildProcess.run(
            path: "/bin/cat", arguments: [], environment: [:], stdin: input,
            timeout: 10, outputLimit: 1 << 20)
        #expect(result.status == 0 && !result.timedOut)
        #expect(result.stdout.count == input.count)
    }

    /// A timeout ends the whole group, and a grandchild holding the pipes
    /// does not keep the effect waiting.
    @Test func timeoutKillsTheGroupAndReturns() async throws {
        let started = ContinuousClock.now
        let result = try await ChildProcess.run(
            path: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30"],
            environment: ["PATH": "/bin:/usr/bin"], stdin: nil,
            timeout: 0.5, outputLimit: 1024)
        #expect(result.timedOut)
        // SIGTERM ends it: the child does not inherit the daemon's SIG_IGN
        // (`childrenDoNotInheritIgnoredSignals`).
        #expect(result.signal == SIGTERM)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// The daemon ignores SIGTERM and SIGPIPE (meerkatd/main.swift); a child
    /// starts with both at their default, so the timeout's SIGTERM ends it
    /// and a write to a closed pipe stops it. This process stands in for the
    /// daemon while the children start.
    @Test func childrenDoNotInheritIgnoredSignals() async throws {
        let previous = (term: signal(SIGTERM, SIG_IGN), pipe: signal(SIGPIPE, SIG_IGN))
        defer {
            signal(SIGTERM, previous.term)
            signal(SIGPIPE, previous.pipe)
        }
        for (name, number) in [("TERM", SIGTERM), ("PIPE", SIGPIPE)] {
            // A shell cannot catch or reset a signal ignored when it started,
            // so it exits 3 only if it inherited SIG_IGN.
            let result = try await ChildProcess.run(
                path: "/bin/sh", arguments: ["-c", "kill -\(name) $$; exit 3"],
                environment: ["PATH": "/bin:/usr/bin"], stdin: nil, timeout: 10, outputLimit: 1024)
            #expect(result.signal == number, "SIG\(name): \(result)")
        }
    }

    @Test func outputIsCappedWithoutStallingTheChild() async throws {
        let result = try await ChildProcess.run(
            path: "/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero"],
            environment: ["PATH": "/bin:/usr/bin"], stdin: nil,
            timeout: 10, outputLimit: 4096)
        #expect(result.status == 0 && result.stdout.utf8.count == 4096)
    }

    @Test func missingExecutableFailsToSpawn() async {
        await #expect(throws: ChildProcess.Failure.self) {
            _ = try await ChildProcess.run(
                path: "/nonexistent/tool", arguments: [], environment: [:], stdin: nil,
                timeout: 1, outputLimit: 16)
        }
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
