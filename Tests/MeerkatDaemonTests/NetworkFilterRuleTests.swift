import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatNetworkFilter
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization
import Testing

@testable import MeerkatDaemon

/// A network filter the test turns on and off, as the user does in Settings
/// and as the filter's crash guard does.
final class SwitchedFilter: NetworkFilterReading {
    let on = Mutex(false)
    let instance = UUID()

    func totals(wantsHosts _: Bool) throws(NetworkFilterUnavailable) -> FilterSnapshot {
        guard on.withLock({ $0 }) else { throw .off }
        return FilterSnapshot(
            instance: instance, build: "b",
            snapshot: FlowLedger.Snapshot(processes: [:], hosts: [:], counters: LedgerCounters()), openFlows: 0)
    }
}

/// Rules on what the network filter measures wait for it: one refused, or
/// ended, while it is off resumes once it answers, with no rule file
/// changing and no reload.
@Suite(.serialized)
struct NetworkFilterRuleTests {
    struct Harness {
        let root = temporaryURL("meerkat-filter-rules")
        let filter = SwitchedFilter()
        let hub = EventHub()
        let store: RuleStore
        let engine: RuleEngine

        init() throws {
            hub.environment.provideNetworkFilter(filter)
            let rules = root.appendingPathComponent("rules")
            let cache = root.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            store = try RuleStore(path: root.appendingPathComponent("rules.db").path)
            let configuration = RuleEngine.Configuration(
                rulesDirectory: rules, cacheDirectory: cache, toolchain: try typeScriptToolchain(),
                runtime: DenoRuntime.handlerRuntime, reloadDebounce: .milliseconds(50),
                networkFilterRetry: .milliseconds(50))
            let wired = ruleEngine(
                configuration, hub: hub, store: store, notifier: SilentNotifier(),
                sampleDatabase: root.appendingPathComponent("samples.db"))
            engine = wired.engine
            try """
            import { rule } from "meerkat";
            export const flows = rule({
              name: "flows",
              on: "network.flows",
              params: { interval: 5 },
              capabilities: { observe: { allow: ["network.flows"] } },
              handle() {},
            });
            """.write(to: rules.appendingPathComponent("net.ts"), atomically: true, encoding: .utf8)
        }

        func state() async -> RuleSummary.State? {
            await engine.report().rules.first { $0.id == "net.ts#flows" }?.state
        }

        func cleanup() async {
            await engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func aRuleRefusedWhileTheFilterIsOffResumesWhenItIsOn() async throws {
        let harness = try Harness()
        await harness.engine.start()
        #expect(await harness.state() == .failed)
        // Asked again while it stays off: still failed, not a loop of loads.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await harness.state() == .failed)

        harness.filter.on.withLock { $0 = true }
        #expect(try await eventually { await harness.state() == .loaded })
        #expect(harness.hub.statistics().contains { $0.kind == "network.flows" })
        await harness.cleanup()
    }

    /// The source ends after `PollingSource.failureLimit` windows the filter
    /// does not answer, as when it is turned off or its crash guard holds it.
    @Test func aRuleWhoseFilterStopsResumesWhenItIsBack() async throws {
        let harness = try Harness()
        harness.filter.on.withLock { $0 = true }
        await harness.engine.start()
        #expect(await harness.state() == .loaded)

        harness.filter.on.withLock { $0 = false }
        #expect(try await eventually(45) { await harness.state() == .failed })

        harness.filter.on.withLock { $0 = true }
        #expect(try await eventually { await harness.state() == .loaded })
        await harness.cleanup()
    }
}
