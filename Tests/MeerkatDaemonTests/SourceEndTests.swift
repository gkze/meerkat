import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization
import Testing

@testable import MeerkatDaemon

/// A source that ends when its test says, as a source fails.
final class EndingSource: EventSource {
    let paths: [String]
    let fail: @Sendable (String) -> Void

    init(paths: [String], fail: @escaping @Sendable (String) -> Void) {
        self.paths = paths
        self.fail = fail
    }

    func start() throws {}
    func stop() {}
}

/// Each kind's sources, for a test to find by what it subscribed with.
final class EndingSources: Sendable {
    private let sources = Mutex<[EndingSource]>([])
    /// Subscriptions naming a path that contains one of these are refused,
    /// once each.
    private let refusals = Mutex<Set<String>>([])

    func refuseOnce(containing text: String) { refusals.withLock { _ = $0.insert(text) } }

    func make(_ paths: [String], fail: @escaping @Sendable (String) -> Void) throws -> EndingSource {
        let refused = refusals.withLock { refusals in
            guard let text = refusals.first(where: { text in paths.contains { $0.contains(text) } }) else {
                return false
            }
            refusals.remove(text)
            return true
        }
        if refused { throw EventError.sourceUnavailable("refused for the test") }
        let source = EndingSource(paths: paths, fail: fail)
        sources.withLock { $0.append(source) }
        return source
    }

    func all(containing text: String) -> [EndingSource] {
        sources.withLock { $0.filter { $0.paths.contains { $0.contains(text) } } }
    }
}

/// `test.failing`, for rules, `events_sample` and dry runs.
enum FailingEvent: EventKind {
    struct Parameters: EventParameters {
        var channel: String
        static var objectSchema: ObjectSchema { ObjectSchema([.field("channel", String.self)]) }
        static var examples: [Self] { [Self(channel: "a")] }
    }

    struct Payload: EventPayload {
        var value: Int
        static var schema: TypeSchema { .object(ObjectSchema([.field("value", Int.self)])) }
        static var examples: [Self] { [Self(value: 1)] }
    }

    static let descriptor = EventDescriptor(
        "test.failing", "A source its test fails.", mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open, source: "test")
    static let sources = EndingSources()

    static func makeSource(
        _ parameters: Parameters, environment: SourceEnvironment, emit: Emitter<Payload>
    ) throws -> any EventSource {
        try sources.make([parameters.channel]) { emit.fail($0) }
    }
}

/// `fs.change` as the rule engine's watcher subscribes to it, standing in for
/// the real one: its test can refuse it or end it.
enum WatchedFolders: EventKind {
    struct Parameters: EventParameters {
        var paths: [String]
        var latency: Double
        static var objectSchema: ObjectSchema {
            ObjectSchema([.init("paths", .array(.string)), .init("latency", .number)])
        }
        static var examples: [Self] { [Self(paths: ["/tmp"], latency: 1)] }
    }

    struct Payload: EventPayload {
        var path: String
        static var schema: TypeSchema { .object(ObjectSchema([.field("path", String.self)])) }
        static var examples: [Self] { [Self(path: "/tmp/a.ts")] }
    }

    static let descriptor = EventDescriptor(
        "fs.change", "The watcher's source, for its test.", mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open, source: "test")
    static let sources = EndingSources()

    static func makeSource(
        _ parameters: Parameters, environment: SourceEnvironment, emit: Emitter<Payload>
    ) throws -> any EventSource {
        try sources.make(parameters.paths) { emit.fail($0) }
    }
}

/// What a source that fails (B5) and a watcher that is lost do to their
/// subscribers, each of which says why with `EventHub.stopReason`.
@Suite(.serialized)
struct SourceEndTests {
    struct Harness {
        let root = temporaryURL("meerkat-ending")
        let rules: URL
        let hub: EventHub
        let store: RuleStore
        let engine: RuleEngine
        let runner: RuleDryRunner

        init(_ kinds: [AnyEventKind]) throws {
            let replaced = Set(kinds.map(\.descriptor.name))
            hub = EventHub(
                catalog: EventCatalog(
                    EventCatalog.standard.kinds.filter { !replaced.contains($0.descriptor.name) } + kinds))
            rules = root.appendingPathComponent("rules")
            let cache = root.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            store = try RuleStore(path: root.appendingPathComponent("rules.db").path)
            let configuration = RuleEngine.Configuration(
                rulesDirectory: rules, cacheDirectory: cache, toolchain: try typeScriptToolchain(),
                runtime: DenoRuntime.handlerRuntime, reloadDebounce: .milliseconds(50))
            let wired = ruleEngine(
                configuration, hub: hub, store: store, notifier: SilentNotifier(),
                sampleDatabase: root.appendingPathComponent("samples.db"))
            engine = wired.engine
            runner = wired.runner
        }

        func cleanup() async {
            await engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let reason = "its event source failed: broke"

    private func listening(_ channel: String) -> String {
        """
        import { rule } from "meerkat";
        export const r = rule({ name: "r", on: "test.failing", params: { channel: "\(channel)" }, handle() {} });
        """
    }

    @Test func aRuleWhoseSourceFailsFailsAndSaysWhy() async throws {
        let harness = try Harness([AnyEventKind(FailingEvent.self)])
        let channel = uniqueName()
        try listening(channel).write(
            to: harness.rules.appendingPathComponent("listens.ts"), atomically: true, encoding: .utf8)
        await harness.engine.start()
        let rule = { await harness.engine.report().rules.first { $0.id == "listens.ts#r" } }
        let loaded = await rule()
        #expect(loaded?.state == .loaded, "\(String(describing: loaded))")
        let source = try #require(FailingEvent.sources.all(containing: channel).first)

        source.fail("broke")
        #expect(try await eventually { await rule()?.state == .failed })
        #expect(await rule()?.reason == Self.reason)
        let logs = try harness.store.logs(rule: "listens.ts#r", limit: 20)
        #expect(logs.contains { $0.level == .error && $0.message == Self.reason }, "\(logs)")
        await harness.cleanup()
    }

    @Test func aSampleWhoseSourceFailsSaysWhy() async throws {
        let hub = EventHub(catalog: EventCatalog([AnyEventKind(FailingEvent.self)]))
        let sampler = EventSampler(
            hub: hub, policy: MCPPolicy(.init(events: .init(allow: ["test.failing"]))),
            permissionStatus: { $0.status })
        let channel = uniqueName()
        let sample = Task {
            try await sampler.run(
                .init(kind: "test.failing", parameters: ["channel": .string(channel)], maxEvents: 10, maxSeconds: 20))
        }
        #expect(try await eventually { !FailingEvent.sources.all(containing: channel).isEmpty })
        FailingEvent.sources.all(containing: channel)[0].fail("broke")
        let result = try await sample.value
        #expect(result.stopped == .sourceStopped)
        #expect(result.reason == Self.reason)
    }

    /// A partial sample would read as a quiet one, so the run fails instead.
    @Test func aDryRunWhoseSourceFailsFailsAndSaysWhy() async throws {
        let harness = try Harness([AnyEventKind(FailingEvent.self)])
        let channel = uniqueName()
        let text = listening(channel)
        let run = Task {
            try await harness.runner.run(
                DryRunRequest(file: "listens.ts", text: text, events: .sampled(seconds: 20, maxEvents: 10)))
        }
        #expect(try await eventually(30) { !FailingEvent.sources.all(containing: channel).isEmpty })
        FailingEvent.sources.all(containing: channel)[0].fail("broke")
        do {
            let report = try await run.value
            Issue.record("expected the run to fail, got \(report)")
        } catch {
            #expect("\(error)" == "test.failing: \(Self.reason)")
        }
        await harness.cleanup()
    }

    /// A watcher that could not start, or whose source ended, is started
    /// again by the next reload, as the problem it reports says.
    @Test func aWatcherThatCouldNotStartOrEndedIsStartedAgainByTheNextReload() async throws {
        let harness = try Harness([AnyEventKind(WatchedFolders.self)])
        let folder = harness.root.lastPathComponent
        let problem = {
            await harness.engine.report().diagnostics.first { $0.message.contains("watch") }?.message
        }
        await harness.engine.start()
        #expect(await problem() == nil)
        let first = try #require(WatchedFolders.sources.all(containing: folder).first)

        first.fail("broke")
        #expect(
            try await eventually {
                await problem()?.contains("the rules folder is no longer watched: \(Self.reason)") == true
            })
        // The reload tries again, and cannot start it.
        WatchedFolders.sources.refuseOnce(containing: folder)
        await harness.engine.reload()
        let refused = await problem()
        #expect(refused?.contains("cannot watch the rules folder") == true, "\(String(describing: refused))")
        #expect(WatchedFolders.sources.all(containing: folder).count == 1)

        await harness.engine.reload()
        #expect(await problem() == nil)
        #expect(WatchedFolders.sources.all(containing: folder).count == 2)
        await harness.cleanup()
    }
}
