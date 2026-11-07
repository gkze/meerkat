import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRuntimeBindings
import MeerkatStore
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

struct OwnProcessProtectionTests {
    /// Rules run inside the daemon, so signalling it would stop them all.
    /// This test process stands in for the daemon; `continue` would be
    /// harmless if the refusal failed.
    @Test func theDaemonCannotBeSignalled() async throws {
        let directory = temporaryURL("meerkat-protect")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeerkatStore.RuleStore(path: directory.appendingPathComponent("rules.db").path)
        let executor = EffectExecutor(
            store: store, ownProcesses: OwnProcesses(), notifier: NoNotifier(),
            sampleDatabasePath: directory.appendingPathComponent("s.db").path)
        let record = try #require(ProcessTable.record(pid: getpid()))
        let definition = try RuleDefinition(
            file: "a.ts",
            raw: [
                "name": "r", "on": "memory.pressure", "capabilities": ["process": ["signal": true]],
            ], catalog: .standard)
        let outcome = await executor.perform(
            [
                "kind": "process.signal", "signal": "continue",
                "target": ["pid": .number(Double(record.pid)), "startedAt": .number(record.identity.startedAt)],
            ], for: definition)
        guard case .failure(let message) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("the daemon itself"))
    }

    /// Nor a process the daemon started (`log stream`, a compiler, another
    /// rule's `exec`): this process stands in for the daemon again, and a
    /// child it started for `continue`.
    @Test func theDaemonsChildrenCannotBeSignalled() async throws {
        let directory = temporaryURL("meerkat-protect")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeerkatStore.RuleStore(path: directory.appendingPathComponent("rules.db").path)
        let executor = EffectExecutor(
            store: store, ownProcesses: OwnProcesses(), notifier: NoNotifier(),
            sampleDatabasePath: directory.appendingPathComponent("s.db").path)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let record = try #require(ProcessTable.record(pid: child.processIdentifier))
        let definition = try RuleDefinition(
            file: "a.ts",
            raw: [
                "name": "r", "on": "memory.pressure", "capabilities": ["process": ["signal": true]],
            ], catalog: .standard)
        let outcome = await executor.perform(
            [
                "kind": "process.signal", "signal": "continue",
                "target": ["pid": .number(Double(record.pid)), "startedAt": .number(record.identity.startedAt)],
            ], for: definition)
        guard case .failure(let message) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("was started by the daemon"))
    }

    /// Nor what those started in turn: a shell's `sleep` stands in for the
    /// process an `exec` child or a helper runs.
    @Test func whatTheDaemonsChildrenStartCannotBeSignalled() async throws {
        let directory = temporaryURL("meerkat-protect")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeerkatStore.RuleStore(path: directory.appendingPathComponent("rules.db").path)
        let executor = EffectExecutor(
            store: store, ownProcesses: OwnProcesses(), notifier: NoNotifier(),
            sampleDatabasePath: directory.appendingPathComponent("s.db").path)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep 30 & echo $!; wait"]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        defer { shell.terminate() }
        var line = ""
        while !line.contains("\n") {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { break }
            line += String(decoding: data, as: UTF8.self)
        }
        let pid = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        let record = try #require(ProcessTable.record(pid: pid))
        #expect(record.parentPid == shell.processIdentifier)
        let definition = try RuleDefinition(
            file: "a.ts",
            raw: [
                "name": "r", "on": "memory.pressure", "capabilities": ["process": ["signal": true]],
            ], catalog: .standard)
        let outcome = await executor.perform(
            [
                "kind": "process.signal", "signal": "continue",
                "target": ["pid": .number(Double(record.pid)), "startedAt": .number(record.identity.startedAt)],
            ], for: definition)
        guard case .failure(let message) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("was started by the daemon"))
    }

    struct NoNotifier: Notifier {
        func post(_ plan: NotificationPlan) async throws {}
        func withdraw(identifier: String) async throws {}
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
