import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization
import Testing
import notify

@testable import MeerkatDaemon

@Suite(.serialized)
struct DeadlineEndToEndTests {
    typealias Fixture = DaemonEndToEndTests.Fixture

    /// File A spends 1.5 s of synchronous work per event (within its 30 s);
    /// file B, with a 1 s timeout, runs in a worker of its own meanwhile.
    @Test func waitingBehindAnotherFileIsNotATimeout() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "slow.ts",
            """
            import { rule } from "meerkat";
            export const slow = rule({ name: "slow", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] }, timeoutSeconds: 30,
                   handle() { const end = Date.now() + 1500; while (Date.now() < end) {} } });
            """)
        try fixture.write(
            "quick.ts",
            """
            import { rule } from "meerkat";
            export const quick = rule({ name: "quick", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] }, timeoutSeconds: 1,
                   async handle(_e, ctx) { await ctx.state.set("ran", true); } });
            """)
        try await fixture.daemon.start(listen: false)
        notify_post(name)
        let store = try fixture.store()
        #expect(try await eventually(10) { try store.value(rule: "quick.ts#quick", key: "ran") == .bool(true) })
        let rules = await fixture.daemon.engine.report().rules
        #expect(rules.first { $0.id == "quick.ts#quick" }?.failures == 0)
        #expect(rules.first { $0.id == "slow.ts#slow" }?.failures == 0)
        await fixture.cleanup()
    }

    /// A promise that never settles is abandoned without killing the host.
    @Test func pendingPromiseTimesOutWithoutARestart() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "pending.ts",
            """
            import { rule } from "meerkat";
            export const pending = rule({ name: "pending", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] }, timeoutSeconds: 0.5,
                   handle() { return new Promise<void>(() => {}); } });
            """)
        try await fixture.daemon.start(listen: false)
        notify_post(name)
        #expect(
            try await eventually(10) {
                await fixture.daemon.engine.report().rules.first { $0.id == "pending.ts#pending" }?.failures == 1
            })
        let host = await fixture.daemon.engine.hostStatus()
        #expect(host.restarts == 0 && host.workers == 1 && host.state == .running)
        await fixture.cleanup()
    }

    /// A timer that spins stalls the host; the stall is logged against the
    /// file, and another file's rule is not charged.
    @Test func timerStallIsBlamedOnItsFile() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "spinner.ts",
            """
            import { rule } from "meerkat";
            setTimeout(() => { for (;;) {} }, 100);
            export const idle = rule({ name: "idle", on: "memory.pressure", handle() {} });
            """)
        try fixture.write(
            "bystander.ts",
            """
            import { rule } from "meerkat";
            export const b = rule({ name: "b", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   async handle(_e, ctx) { await ctx.state.set("ran", true); } });
            """)
        try await fixture.daemon.start(listen: false)
        let store = try fixture.store()
        #expect(
            try await eventually(10) {
                try store.logs(rule: "spinner.ts", limit: 20).contains {
                    $0.message.contains("held the JavaScript thread")
                }
            })
        // The stall is blamed on its file alone: the bystander still runs
        // once the host is back, and has no failures counted against it.
        #expect(
            try await eventually(10) {
                notify_post(name)
                return try store.value(rule: "bystander.ts#b", key: "ran") == .bool(true)
            })
        let bystander = await fixture.daemon.engine.report().rules.first { $0.id == "bystander.ts#b" }
        #expect(bystander?.failures == 0)
        await fixture.cleanup()
    }
}

struct RegexBoundTests {
    @Test func catastrophicPatternIsCutOff() throws {
        let match = try MatchPredicate(["path": ["regex": "(a|a)*b"]], schema: FSChangePayload.schema)
        let payload: JSONValue = [
            "path": .string(String(repeating: "a", count: 16_000)), "changes": [],
            "itemType": "file", "streamFlags": [], "eventId": 1,
        ]
        let started = ContinuousClock.now
        #expect(match.evaluate(payload) == .regexAborted(pattern: "(a|a)*b", reason: "hit its time limit"))
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func ordinaryPatternsStillMatch() throws {
        let match = try MatchPredicate(["path": ["regex": "/notes/.*\\.md$"]], schema: FSChangePayload.schema)
        let hit: JSONValue = [
            "path": "/Users/x/notes/a.md", "changes": [], "itemType": "file", "streamFlags": [], "eventId": 1,
        ]
        #expect(match.evaluate(hit) == .match)
        #expect(throws: MatchError.self) {
            try MatchPredicate(["path": ["regex": "(unclosed"]], schema: FSChangePayload.schema)
        }
    }
}

@Suite(.serialized)
struct ReloadAndBlameTests {
    typealias Fixture = DaemonEndToEndTests.Fixture

    /// An editor's save dance (several writes, the last restoring identical
    /// content) must leave the rules loaded, not cancelled mid-compile.
    @Test func saveBurstKeepsRulesLoaded() async throws {
        let fixture = try Fixture()
        let source = """
            import { rule } from "meerkat";
            export const steady = rule({ name: "steady", on: "memory.pressure", handle() {} });
            """
        try fixture.write("steady.ts", source)
        try await fixture.daemon.start(listen: false)
        for index in 0..<6 {
            try fixture.write("steady.ts", source + "\n// edit \(index)\n")
            try await Task.sleep(for: .milliseconds(120))
        }
        try fixture.write("steady.ts", source)
        // Loaded at every look while the watcher's debounce and any reload
        // it starts run their course.
        let loaded = {
            await fixture.daemon.engine.report().rules.contains { $0.id == "steady.ts#steady" && $0.state == .loaded }
        }
        let stayed = try await throughout(2, loaded)
        if !stayed { Issue.record(await fixture.diagnosis()) }
        await fixture.cleanup()
    }

    /// Code a handler left running (an un-awaited continuation) that stalls
    /// the host is charged to its file: after an `await`, the runtime cannot
    /// tell which rule's code is running, only which file's.
    @Test func stallAfterTheInvocationIsChargedToItsFile() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "lingering.ts",
            """
            import { rule } from "meerkat";
            export const lingering = rule({ name: "lingering", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   handle(_e, ctx) { void ctx.state.set("x", 1).finally(() => { for (;;) {} }); } });
            """)
        try await fixture.daemon.start(listen: false)
        notify_post(name)
        let store = try fixture.store()
        #expect(
            try await eventually(15) {
                try store.logs(rule: "lingering.ts", limit: 20).contains {
                    $0.message.contains("held the JavaScript thread")
                }
            })
        await fixture.cleanup()
    }
}

@Suite(.serialized)
struct LifecycleEdgeTests {
    typealias Fixture = DaemonEndToEndTests.Fixture

    /// Disabling and re-enabling a rule while its handler runs leaves it
    /// loaded: the old dispatcher ending is not the source stopping.
    @Test func disableThenEnableDuringAnInvocation() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "busy.ts",
            """
            import { rule } from "meerkat";
            export const busy = rule({ name: "busy", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   async handle(_e, ctx) {
                     const end = Date.now() + 800; while (Date.now() < end) {}
                     await ctx.state.set("finished", Date.now());
                   } });
            """)
        try await fixture.daemon.start(listen: false)
        let engine = fixture.daemon.engine
        notify_post(name)
        #expect(
            try await eventually { await engine.report().rules.first { $0.id == "busy.ts#busy" }?.invocations == 1 })
        try await engine.setEnabled("busy.ts#busy", enabled: false)
        try await engine.setEnabled("busy.ts#busy", enabled: true)
        // Only an invocation of the new run can store (the first one's
        // effects are refused with its run), and it starts once the first
        // has ended, its dispatcher with it.
        notify_post(name)
        let store = try fixture.store()
        #expect(try await eventually { try store.value(rule: "busy.ts#busy", key: "finished") != nil })
        let rule = await engine.report().rules.first { $0.id == "busy.ts#busy" }
        #expect(rule?.state == .loaded, "\(String(describing: rule))")
        await fixture.cleanup()
    }
}

struct HostPlumbingTests {
    /// A runtime that cannot start.
    final class FailingTransport: HandlerHostTransport {
        struct Failure: Error {}
        func start(
            receive: @escaping @Sendable (HostToDaemon) -> Void, terminated: @escaping @Sendable (String) -> Void
        ) throws {
            throw Failure()
        }
        func send(_ message: DaemonToHost) {}
        func stop(reason: String) {}
    }

    /// A runtime that is ready at once, loads every entry with no rules, and
    /// answers an invocation as `invoked` says, given the invocation, its
    /// rule, and how to send and to stop.
    final class ScriptedTransport: HandlerHostTransport {
        typealias Delegate = (receive: @Sendable (HostToDaemon) -> Void, terminated: @Sendable (String) -> Void)
        let invoked: @Sendable (UInt64, String, Delegate) -> Void
        private let current = Mutex<Delegate?>(nil)

        init(invoked: @escaping @Sendable (UInt64, String, Delegate) -> Void) { self.invoked = invoked }

        func start(
            receive: @escaping @Sendable (HostToDaemon) -> Void, terminated: @escaping @Sendable (String) -> Void
        ) throws {
            current.withLock { $0 = (receive, terminated) }
            receive(.ready)
        }

        func send(_ message: DaemonToHost) {
            guard let delegate = current.withLock({ $0 }) else { return }
            switch message {
            case .load(_, let entries, _, _, _):
                delegate.receive(
                    .loaded(results: entries.map { EntryResult(entry: $0.module, rules: [], error: nil) }))
            case .invoke(let invocation, let rule, _, _):
                invoked(invocation, rule, delegate)
            default:
                break
            }
        }

        func stop(reason: String) { current.withLock { $0 }?.terminated(reason) }
    }

    /// Runs one invocation of `spin.ts#spin` in a host over `transport`, and
    /// returns its result and the reason the host exited with.
    private func invokeOnce(_ transport: ScriptedTransport) async throws -> (HandlerHost.InvocationResult, String?) {
        let host = HandlerHost(transport: transport)
        try await host.start()
        let loaded = try await host.load(modules: [], entries: ["spin"], rejected: [:], entryDeadline: .seconds(5))
        #expect(loaded.map(\.file) == ["spin.ts"])
        let event = EventEnvelope(kind: "timer", sequence: 1, time: 0, origin: .system, replayed: false, payload: [:])
        let result = await host.invoke(rule: "spin.ts#spin", event: event, timeout: .seconds(1))
        var exit: String?
        for await event in host.events {
            if case .exited(let reason) = event { exit = reason }
        }
        return (result, exit)
    }

    /// The fault's kind, not whether it names an invocation, makes that
    /// invocation an overrun; and the host exits with the runtime's own
    /// sentence for the fault.
    @Test func anOverrunTimesOutItsInvocation() async throws {
        let ended = "spin.ts#spin held the JavaScript thread for 5.1 s"
        let (result, exit) = try await invokeOnce(
            ScriptedTransport { invocation, rule, delegate in
                delegate.receive(
                    .fault(
                        file: "spin.ts", rule: rule, invocation: invocation, kind: .overran,
                        reason: "held the JavaScript thread for 5.1 s"))
                delegate.terminated(ended)
            })
        #expect(result == .overran)
        #expect(exit == ended)
    }

    /// A fault that is the file's alone interrupts the invocation running
    /// then, which is not charged to its rule, even when it names it.
    @Test func aFilesFaultInterruptsTheInvocation() async throws {
        let ended = "spin.ts passed its JavaScript heap limit of 256 MiB"
        let (result, exit) = try await invokeOnce(
            ScriptedTransport { invocation, _, delegate in
                delegate.receive(
                    .fault(
                        file: "spin.ts", rule: nil, invocation: invocation, kind: .outOfMemory,
                        reason: "passed its JavaScript heap limit of 256 MiB"))
                delegate.terminated(ended)
            })
        #expect(result == .interrupted(ended))
        #expect(exit == ended)
    }

    /// An event with no JSON form never reaches the runtime, and its rule is
    /// not charged for it: the outcome says why, in the encoder's words.
    @Test func anEventWithNoJSONFormIsNotDelivered() async throws {
        let host = HandlerHost(
            transport: ScriptedTransport { _, _, _ in Issue.record("the event reached the runtime") })
        try await host.start()
        _ = try await host.load(modules: [], entries: ["spin"], rejected: [:], entryDeadline: .seconds(5))
        let event = EventEnvelope(
            kind: "timer", sequence: 1, time: .nan, origin: .system, replayed: false, payload: [:])
        let result = await host.invoke(rule: "spin.ts#spin", event: event, timeout: .seconds(1))
        guard case .undeliverable(let reason) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(reason.contains("time"), "\(reason)")
        #expect(result.failure(timeout: .seconds(1)) == nil)
        await host.stop(reason: "done")
    }

    /// A host whose runtime cannot start ends its event stream, so the
    /// engine's loop over it (and the actor) are released.
    @Test func failedStartFinishesTheHost() async throws {
        let host = HandlerHost(transport: FailingTransport())
        await #expect(throws: HandlerHost.HostError.self) { try await host.start() }
        let finished = try await eventually(5) {
            var ended = false
            for await event in host.events {
                if case .exited = event { ended = true }
            }
            return ended
        }
        #expect(finished)
        #expect(!(await host.isAlive))
    }
}
