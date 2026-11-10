import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization
import Testing

@testable import MeerkatDaemon

/// A rule may observe only what it declares (docs/design/effects.md,
/// "Observation"): each class of kind with and without its grant, as the
/// rule loads.
struct ObservationLoadTests {
    let root = temporaryURL("meerkat-observe")

    /// `root/state` stands for the daemon's state folder.
    var state: URL { root.appendingPathComponent("state") }

    func scope(fileScope: FileScope = .standard) -> ObservationScope {
        let state = state.path
        return ObservationScope(protectedRead: [state, CapabilityGrants.resolved(state)], fileScope: { fileScope })
    }

    func decode(
        _ on: String, params: JSONValue? = nil, capabilities: JSONValue? = nil, scope: ObservationScope? = nil
    ) throws -> RuleDefinition {
        var raw: [String: JSONValue] = ["name": "r", "on": .string(on)]
        raw["params"] = params
        raw["capabilities"] = capabilities
        let scope = scope ?? self.scope()
        let definition = try RuleDefinition(file: "a.ts", raw: .object(raw), catalog: .standard, observation: scope)
        // And as it subscribes, where the file scope is decided.
        try scope.requireFileScope(of: definition, in: .standard)
        return definition
    }

    /// Why the rule does not load; nil when it loads.
    func refusal(
        _ on: String, params: JSONValue? = nil, capabilities: JSONValue? = nil, scope: ObservationScope? = nil
    ) -> String? {
        do {
            _ = try decode(on, params: params, capabilities: capabilities, scope: scope)
            return nil
        } catch {
            return "\(error)"
        }
    }

    func folders(_ names: String...) throws {
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    @Test func openKindsNeedNoGrant() {
        for kind in ["memory.pressure", "power.source", "meerkat.dropped", "usb.attached"] {
            #expect(refusal(kind) == nil, "\(kind)")
        }
    }

    @Test func namedKindsNeedTheirName() {
        #expect(
            refusal("window.focused")
                == "\"on\": observing window.focused needs capabilities: { observe: { allow: [\"window.focused\"] } }")
        #expect(refusal("window.focused", capabilities: ["observe": ["allow": ["window.focused"]]]) == nil)
        #expect(refusal("window.focused", capabilities: ["observe": ["allow": ["log.entry"]]]) != nil)
        #expect(refusal("log.entry", params: ["predicate": "subsystem == \"x\""]) != nil)
    }

    /// `observe.allow` takes only kinds observed by name, and says what any
    /// other needs instead.
    @Test func observeNamesOnlyNamedKinds() {
        let given = { (kind: String) in
            refusal("memory.pressure", capabilities: ["observe": ["allow": .array([.string(kind)])]])
        }
        #expect(given("nope") == "\"capabilities.observe.allow\": unknown event \"nope\"")
        #expect(given("cpu.sample")?.hasSuffix("cpu.sample is not observed by name; it needs no grant") == true)
        #expect(given("fs.change")?.contains("it needs capabilities: { fs: { read: [\"…\"] } }") == true)
        #expect(given("process.top")?.contains("it needs capabilities: { process: { observe: \"own\" } }") == true)
        #expect(given("pasteboard.changed") == nil)
    }

    @Test(arguments: ["process.spawned", "process.top", "process.list", "app.launched"])
    func processKindsNeedALevel(_ kind: String) {
        #expect(
            refusal(kind) == "\"on\": observing \(kind) needs capabilities: { process: { observe: \"own\" } }")
        #expect(refusal(kind, capabilities: ["process": ["observe": "own"]]) == nil)
        #expect(refusal(kind, capabilities: ["process": ["observe": "all"]]) == nil)
        #expect(
            refusal(kind, capabilities: ["process": ["observe": "some"]])
                == "\"capabilities.process.observe\" must be \"own\" or \"all\"")
    }

    /// launchd is root's: following it needs every user's processes, and
    /// that is known when the rule loads.
    @Test func followingAnotherUsersProcessNeedsAll() throws {
        try #require(getuid() != 0, "the test needs a process of another user")
        let launchd = try #require(ProcessTable.record(pid: 1))
        let params: JSONValue = ["pid": 1, "startedAt": .number(launchd.identity.startedAt)]
        let refused = refusal("process.sample", params: params, capabilities: ["process": ["observe": "own"]])
        #expect(
            refused
                == "\"params\": pid 1 is another user's process: observing it needs capabilities: { process: { observe: \"all\" } }"
        )
        #expect(refusal("process.sample", params: params, capabilities: ["process": ["observe": "all"]]) == nil)

        let own = try #require(ProcessTable.record(pid: getpid()))
        let mine: JSONValue = ["pid": .number(Double(getpid())), "startedAt": .number(own.identity.startedAt)]
        #expect(refusal("process.sample", params: mine, capabilities: ["process": ["observe": "own"]]) == nil)
    }

    @Test func watchedPathsMustBeInsideFsRead() throws {
        try folders("a", "b")
        defer { try? FileManager.default.removeItem(at: root) }
        // As `fs.change` normalizes it.
        let a = (root.appendingPathComponent("a").path as NSString).standardizingPath
        let params: JSONValue = ["paths": .array([.string(a)])]
        let needed = "\"on\": watching \(a) with fs.change needs capabilities: { fs: { read: [\"\(a)\"] } }"
        #expect(refusal("fs.change", params: params) == needed)
        let other = ["fs": ["read": .array([.string(root.appendingPathComponent("b").path)])]] as JSONValue
        #expect(refusal("fs.change", params: params, capabilities: other) == needed)
        #expect(refusal("fs.change", params: params, capabilities: ["fs": ["read": .array([.string(a)])]]) == nil)
        // Writing a folder is not reading it.
        #expect(refusal("fs.change", params: params, capabilities: ["fs": ["write": .array([.string(a)])]]) != nil)
    }

    /// The state folder through a symlink in a granted folder, and the
    /// folder above it, are refused even where `fs.read` covers them.
    @Test func theStateFolderIsNeverWatched() throws {
        try folders("state", "other")
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: state)
        let grant: JSONValue = ["fs": ["read": .array([.string(root.path)])]]
        let watching = { (path: String) in
            refusal("fs.change", params: ["paths": .array([.string(path)])], capabilities: grant)
        }
        #expect(watching(root.appendingPathComponent("other").path) == nil)
        for path in [link.path, root.path, state.appendingPathComponent("rules.db").path] {
            let refused = watching(path)
            #expect(
                refused?.contains("which holds Meerkat's state; no rule may watch it") == true,
                "\(path): \(refused ?? "loaded")")
        }
        // The same with a grant of the whole disk.
        #expect(
            refusal("fs.change", params: ["paths": .array([.string(link.path)])], capabilities: ["fs": ["read": ["/"]]])
                != nil)
        // By its name on the data volume, which is a firmlink's and no
        // symlink's, and from the volume's mount point above it, with a
        // grant of the volume or of the disk.
        let onDataVolume = "/System/Volumes/Data" + CapabilityGrants.resolved(state.path)
        #expect(FileManager.default.fileExists(atPath: onDataVolume), "\(onDataVolume)")
        for disk in ["/System/Volumes/Data", "/"] {
            for path in [onDataVolume, onDataVolume + "/rules.db", "/System/Volumes/Data"] {
                let refused = refusal(
                    "fs.change", params: ["paths": .array([.string(path)])],
                    capabilities: ["fs": ["read": .array([.string(disk)])]])
                #expect(
                    refused?.contains("which holds Meerkat's state; no rule may watch it") == true,
                    "\(disk): \(path): \(refused ?? "loaded")")
            }
        }
        // The volume's grant still covers what is on it, by any name.
        #expect(
            refusal(
                "fs.change", params: ["paths": .array([.string(root.appendingPathComponent("other").path)])],
                capabilities: ["fs": ["read": ["/System/Volumes/Data"]]]) == nil)
    }

    /// `fs.churn` without a root measures `meerkat.json`'s scope: the grant
    /// must cover it, and the state folder in it must be left out.
    @Test func churnWithoutARootNeedsTheFileScope() throws {
        try folders("state", "other")
        defer { try? FileManager.default.removeItem(at: root) }
        let grant: JSONValue = ["fs": ["read": .array([.string(root.path)])]]
        let whole = scope(fileScope: FileScope(root: root.path, exclude: []))
        #expect(refusal("fs.churn", capabilities: grant, scope: whole)?.contains("holds Meerkat's state") == true)
        let leftOut = scope(fileScope: FileScope(root: root.path, exclude: [state.path]))
        #expect(refusal("fs.churn", capabilities: grant, scope: leftOut) == nil)
        // The subscription's own exclusions count too.
        #expect(
            refusal("fs.churn", params: ["exclude": .array([.string(state.path)])], capabilities: grant, scope: whole)
                == nil)
        let elsewhere = scope(fileScope: FileScope(root: "/usr", exclude: []))
        #expect(
            refusal("fs.churn", capabilities: grant, scope: elsewhere)
                == "\"on\": watching /usr with fs.churn needs capabilities: { fs: { read: [\"/usr\"] } } (it measures meerkat.json's files scope)"
        )
        // A root is checked as it is, whatever the scope.
        let rooted: JSONValue = ["root": .string(root.appendingPathComponent("other").path)]
        #expect(refusal("fs.churn", params: rooted, capabilities: grant, scope: elsewhere) == nil)
    }

    @Test func levelsIncludeTheOnesBelow() throws {
        let all = try CapabilityGrants(["process": ["observe": "all"]])
        let own = try CapabilityGrants(["process": ["observe": "own"]])
        let shape = GrantDescriptor.Shape.level(["own", "all"])
        #expect(all.allows("process.observe", subject: "own", shape: shape))
        #expect(all.allows("process.observe", subject: "all", shape: shape))
        #expect(own.allows("process.observe", subject: "own", shape: shape))
        #expect(!own.allows("process.observe", subject: "all", shape: shape))
        #expect(!CapabilityGrants.none.allows("process.observe", subject: "own", shape: shape))
    }
}

/// What a rule sees of the events it may observe: the rule's view, taken in
/// Swift before `match`.
struct ObservationViewTests {
    let scope = ObservationScope(protectedRead: [])

    func definition(_ on: String, capabilities: JSONValue, file: String = "a.ts") throws -> RuleDefinition {
        try RuleDefinition(
            file: file, raw: ["name": "r", "on": .string(on), "capabilities": capabilities], catalog: .standard,
            observation: scope)
    }

    static func spawned(_ record: ProcessRecord) -> JSONValue {
        [
            "process": [
                "pid": .number(Double(record.pid)), "startedAt": .number(record.identity.startedAt),
                "parentPid": .number(Double(record.parentPid)), "uid": .number(Double(record.uid)),
                "name": .string(record.command),
            ]
        ]
    }

    static func envelope(_ kind: String, _ payload: JSONValue) -> EventEnvelope {
        EventEnvelope(kind: kind, sequence: 1, time: 0, origin: .system, replayed: false, payload: payload)
    }

    @Test func ownSeesOnlyTheUsersProcesses() throws {
        try #require(getuid() != 0, "the test needs a process of another user")
        let kind = try #require(EventCatalog.standard.kind(named: "process.spawned"))
        let launchd = Self.envelope("process.spawned", Self.spawned(try #require(ProcessTable.record(pid: 1))))
        let mine = Self.envelope("process.spawned", Self.spawned(try #require(ProcessTable.record(pid: getpid()))))

        let own = try #require(
            scope.view(of: kind, for: try definition("process.spawned", capabilities: ["process": ["observe": "own"]])))
        #expect(own(launchd) == nil)
        #expect(own(mine) == mine)
        // Every user's processes need no view at all.
        #expect(
            scope.view(of: kind, for: try definition("process.spawned", capabilities: ["process": ["observe": "all"]]))
                == nil)
    }

    @Test func aRuleSeesOnlyItsOwnFilesDropReports() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "meerkat.dropped"))
        let view = try #require(scope.view(of: kind, for: try definition("meerkat.dropped", capabilities: [:])))
        let report = { (file: String) in
            Self.envelope(
                "meerkat.dropped",
                [
                    "kind": "fs.change", "parameters": ["paths": ["/Users/b/secret"]], "file": .string(file),
                    "dropped": 2,
                ])
        }
        #expect(view(report("a.ts")) == report("a.ts"))
        #expect(view(report("b.ts")) == nil)
    }
}

/// `test.processes`: process events on demand, from the processes a test
/// names, for the dispatcher's view.
enum ProcessFeedEvent: EventKind {
    typealias Parameters = NoParameters
    typealias Payload = ProcessSpawnedPayload

    static let descriptor = EventDescriptor(
        "test.processes", "Processes a test reports.", mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes, source: "test")
    static let feed = ProcessFeed()

    static func makeSource(
        _ parameters: Parameters, environment: SourceEnvironment, emit: Emitter<Payload>
    ) throws -> any EventSource {
        feed.add(emit)
        return IdleSource()
    }
}

/// Emits only when its test reports something.
final class IdleSource: EventSource {
    func start() throws {}
    func stop() {}
}

final class ProcessFeed: Sendable {
    private let emitters = Mutex<[Emitter<ProcessSpawnedPayload>]>([])

    func add(_ emit: Emitter<ProcessSpawnedPayload>) { emitters.withLock { $0.append(emit) } }

    var started: Bool { emitters.withLock { !$0.isEmpty } }

    func report(_ record: ProcessRecord) throws {
        let payload = try ObservationViewTests.spawned(record).decode(as: ProcessSpawnedPayload.self)
        for emit in emitters.withLock({ $0 }) { emit(payload) }
    }
}

/// Rules in the real runtime, against a hub with `test.processes`.
@Suite(.serialized)
struct ObservationDeliveryTests {
    struct Harness {
        let root = temporaryURL("meerkat-observing")
        let rules: URL
        let hub: EventHub
        let store: RuleStore
        let settings: DaemonSettings
        let engine: RuleEngine
        let runner: RuleDryRunner

        init() throws {
            hub = EventHub(catalog: EventCatalog(EventCatalog.standard.kinds + [AnyEventKind(ProcessFeedEvent.self)]))
            rules = root.appendingPathComponent("rules")
            let cache = root.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            store = try RuleStore(path: root.appendingPathComponent("rules.db").path)
            let settings = DaemonSettings(rulesDirectory: rules, catalog: hub.catalog)
            self.settings = settings
            hub.environment.provideFileScope { settings.current.files.scope }
            let configuration = RuleEngine.Configuration(
                rulesDirectory: rules, cacheDirectory: cache, toolchain: try typeScriptToolchain(),
                runtime: DenoRuntime.handlerRuntime, reloadDebounce: .milliseconds(50), settings: settings)
            let wired = ruleEngine(
                configuration, hub: hub, store: store, notifier: SilentNotifier(),
                sampleDatabase: root.appendingPathComponent("samples.db"))
            engine = wired.engine
            runner = wired.runner
        }

        func write(_ name: String, _ text: String) throws {
            try text.write(to: rules.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func rule(_ id: String) async -> RuleSummary? {
            await engine.report().rules.first { $0.id == id }
        }

        func cleanup() async {
            await engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// With `"own"`, an event about launchd (root's) never reaches the
    /// handler; with `"all"`, it does.
    @Test func ownDropsOtherUsersProcessesAtDispatch() async throws {
        try #require(getuid() != 0, "the test needs a process of another user")
        let harness = try Harness()
        for level in ["own", "all"] {
            try harness.write(
                "\(level).ts",
                """
                import { rule } from "meerkat";
                export const r = rule({
                  name: "r",
                  on: "test.processes",
                  capabilities: { process: { observe: "\(level)" } },
                  handle(event, ctx) {
                    ctx.log(`pid ${event.process.pid}`);
                  },
                });
                """)
        }
        await harness.engine.start()
        #expect(await harness.rule("own.ts#r")?.state == .loaded)
        #expect(await harness.rule("all.ts#r")?.state == .loaded)
        #expect(ProcessFeedEvent.feed.started)

        try ProcessFeedEvent.feed.report(try #require(ProcessTable.record(pid: 1)))
        try ProcessFeedEvent.feed.report(try #require(ProcessTable.record(pid: getpid())))
        let logged = { (rule: String) in
            Set(((try? harness.store.logs(rule: rule, limit: 20)) ?? []).map(\.message).filter { $0.hasPrefix("pid ") })
        }
        #expect(try await eventually { logged("all.ts#r").count == 2 })
        #expect(try await eventually { logged("own.ts#r").contains("pid \(getpid())") })
        #expect(logged("own.ts#r") == ["pid \(getpid())"])
        await harness.cleanup()
    }

    /// The dry run refuses what loading refuses, and skips what the rule
    /// would not see.
    @Test func aDryRunDecidesAsLoadingDoes() async throws {
        let harness = try Harness()
        let refused = try await harness.runner.run(
            DryRunRequest(
                file: "watch.ts",
                text: """
                    import { rule } from "meerkat";
                    export const r = rule({
                      name: "r",
                      on: "fs.change",
                      params: { paths: ["/tmp"] },
                      capabilities: { fs: { read: ["/usr"] } },
                      handle() {},
                    });
                    """,
                events: .examples))
        #expect(refused.outcome == .rejected)
        #expect(
            refused.diagnostics.contains { $0.message.contains("needs capabilities: { fs: { read: [\"/tmp\"] } }") },
            "\(refused.diagnostics)")
        // The file scope, which the engine decides as a rule subscribes.
        let granted = harness.root.appendingPathComponent("granted")
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        try #"{ "files": { "root": "/usr", "exclude": [] } }"#.write(
            to: harness.settings.file, atomically: true, encoding: .utf8)
        harness.settings.reload()
        let outOfScope = try await harness.runner.run(
            DryRunRequest(file: "churn.ts", text: Self.churnRule(granting: granted), events: .examples))
        #expect(outOfScope.outcome == .rejected)
        #expect(
            outOfScope.diagnostics.contains { $0.message.contains("(it measures meerkat.json's files scope)") },
            "\(outOfScope.diagnostics)")

        try #require(getuid() != 0, "the test needs a process of another user")
        let launchd = try #require(ProcessTable.record(pid: 1))
        let mine = try #require(ProcessTable.record(pid: getpid()))
        let report = try await harness.runner.run(
            DryRunRequest(
                file: "own.ts",
                text: """
                    import { rule } from "meerkat";
                    export const r = rule({
                      name: "r",
                      on: "test.processes",
                      capabilities: { process: { observe: "own" } },
                      handle() {},
                    });
                    """,
                events: .given([
                    DryRunEvent(payload: ObservationViewTests.spawned(launchd)),
                    DryRunEvent(payload: ObservationViewTests.spawned(mine)),
                ])))
        #expect(report.outcome == .ran, "\(report.diagnostics)")
        guard report.runs.count == 2, case .skipped(let reason) = report.runs[0].result else {
            Issue.record("\(report.runs)")
            await harness.cleanup()
            return
        }
        #expect(reason.contains("outside what the rule may observe"))
        #expect(report.runs[1].result == .completed)
        await harness.cleanup()
    }

    /// `meerkat.json`'s file scope moving out of a loaded `fs.churn` rule's
    /// grant fails it, with why; moving back resumes it.
    @Test func churnFailsWhenTheFileScopeLeavesItsGrant() async throws {
        let harness = try Harness()
        let granted = harness.root.appendingPathComponent("granted")
        let elsewhere = harness.root.appendingPathComponent("elsewhere")
        for folder in [granted, elsewhere] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let settings = { (root: URL) in
            try #"{ "files": { "root": "\#(root.path)", "exclude": [] } }"#.write(
                to: harness.settings.file, atomically: true, encoding: .utf8)
        }
        try settings(granted)
        try harness.write(
            "churn.ts",
            """
            import { rule } from "meerkat";
            export const r = rule({
              name: "r",
              on: "fs.churn",
              params: { window: 0.5, every: 1 },
              capabilities: { fs: { read: ["\(granted.path)"] } },
              handle() {},
            });
            """)
        await harness.engine.start()
        let loaded = await harness.rule("churn.ts#r")
        #expect(loaded?.state == .loaded, "\(String(describing: loaded))")

        try settings(elsewhere)
        #expect(try await eventually { await harness.rule("churn.ts#r")?.state == .failed })
        let reason = await harness.rule("churn.ts#r")?.reason ?? ""
        #expect(reason.hasPrefix("\"on\": watching"), "\(reason)")
        #expect(reason.hasSuffix("(it measures meerkat.json's files scope)"), "\(reason)")
        #expect(harness.hub.statistics().allSatisfy { $0.kind != "fs.churn" })

        try settings(granted)
        #expect(try await eventually { await harness.rule("churn.ts#r")?.state == .loaded })
        await harness.cleanup()
    }

    static func churnRule(granting granted: URL) -> String {
        """
        import { rule } from "meerkat";
        export const r = rule({
          name: "r",
          on: "fs.churn",
          params: { window: 0.5, every: 1 },
          capabilities: { fs: { read: ["\(granted.path)"] } },
          handle() {},
        });
        """
    }

    /// Enabling a rule decides its file scope again: one disabled while the
    /// scope moved outside its grant does not measure it once enabled.
    @Test func enablingDecidesTheFileScope() async throws {
        let harness = try Harness()
        let granted = harness.root.appendingPathComponent("granted")
        let elsewhere = harness.root.appendingPathComponent("elsewhere")
        for folder in [granted, elsewhere] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let settings = { (root: URL) in
            try #"{ "files": { "root": "\#(root.path)", "exclude": [] } }"#.write(
                to: harness.settings.file, atomically: true, encoding: .utf8)
        }
        try settings(granted)
        try harness.write("churn.ts", Self.churnRule(granting: granted))
        await harness.engine.start()
        #expect(await harness.rule("churn.ts#r")?.state == .loaded)
        try await harness.engine.setEnabled("churn.ts#r", enabled: false)
        try settings(elsewhere)
        // Applied as a change to meerkat.json would apply it.
        harness.settings.reload()
        await harness.engine.recheckFileScope()
        #expect(await harness.rule("churn.ts#r")?.state == .disabled)

        try await harness.engine.setEnabled("churn.ts#r", enabled: true)
        let enabled = await harness.rule("churn.ts#r")
        #expect(enabled?.state == .failed, "\(String(describing: enabled))")
        #expect(harness.hub.statistics().allSatisfy { $0.kind != "fs.churn" })

        // And it resumes as any rule failed for its scope does.
        try settings(granted)
        #expect(try await eventually { await harness.rule("churn.ts#r")?.state == .loaded })
        await harness.cleanup()
    }

    /// A rule that is out of its scope as it loads, and still is after a
    /// reload, resumes once `meerkat.json` moves the scope back inside its
    /// grant, with no rule file changing.
    @Test func aRuleLoadedOutOfScopeResumes() async throws {
        let harness = try Harness()
        let granted = harness.root.appendingPathComponent("granted")
        let elsewhere = harness.root.appendingPathComponent("elsewhere")
        for folder in [granted, elsewhere] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let settings = { (root: URL) in
            try #"{ "files": { "root": "\#(root.path)", "exclude": [] } }"#.write(
                to: harness.settings.file, atomically: true, encoding: .utf8)
        }
        try settings(elsewhere)
        try harness.write("churn.ts", Self.churnRule(granting: granted))
        await harness.engine.start()
        #expect(await harness.rule("churn.ts#r")?.state == .failed)
        await harness.engine.reload()
        let reloaded = await harness.rule("churn.ts#r")
        #expect(reloaded?.state == .failed, "\(String(describing: reloaded))")
        #expect(harness.hub.statistics().allSatisfy { $0.kind != "fs.churn" })

        try settings(granted)
        #expect(try await eventually { await harness.rule("churn.ts#r")?.state == .loaded })
        await harness.cleanup()
    }
}
