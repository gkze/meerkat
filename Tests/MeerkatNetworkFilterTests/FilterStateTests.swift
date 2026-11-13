import Foundation
import Synchronization
import Testing

@testable import MeerkatNetworkFilter

/// The state the provider and the XPC side share.
struct FilterStateTests {
    let build = "0.2.0 (21)"
    let app = ProcessKey.test(100)

    func totals(_ reply: FilterReply) -> FilterSnapshot? {
        guard case .snapshot(let snapshot) = reply else { return nil }
        return snapshot
    }

    @Test func refusesAnotherBuild() {
        let state = FilterState(build: build)
        #expect(
            state.reply(to: FilterRequest(build: "other", wantsHosts: false))
                == .refused("the network filter is build \(build), meerkatd build other"))
    }

    @Test func repliesWithItsInstanceAndTotals() throws {
        let state = FilterState(build: build)
        let flow = UUID()
        state.record(report(flow, .opened, app))
        state.record(report(flow, .statistics, app, in: 40, out: 4))
        let snapshot = try #require(totals(state.reply(to: FilterRequest(build: build, wantsHosts: false))))
        #expect(snapshot.instance == state.instance)
        #expect(
            snapshot.processes == [FilterSnapshot.Process(process: app, totals: ByteTotals(bytesIn: 40, bytesOut: 4))])
        #expect(snapshot.openFlows == 1)
        #expect(try snapshot.validated(build: build) == snapshot)
    }

    /// Hosts are collected only after a daemon asks, and only for as long as
    /// the lease lasts after its last request.
    @Test func hostsFollowTheLease() throws {
        let state = FilterState(build: build)
        let flow = UUID()
        let remote = endpoint("example.com")
        state.record(report(flow, .opened, app, remote: remote), at: 0)
        state.record(report(flow, .statistics, app, in: 10), at: 1)
        #expect(
            try #require(totals(state.reply(to: FilterRequest(build: build, wantsHosts: false), at: 2))).hosts.isEmpty)

        _ = state.reply(to: FilterRequest(build: build, wantsHosts: true), at: 3)
        state.record(report(flow, .statistics, app, in: 30), at: 4)
        let leased = try #require(totals(state.reply(to: FilterRequest(build: build, wantsHosts: false), at: 5)))
        #expect(leased.hosts.map(\.totals) == [ByteTotals(bytesIn: 20)])

        // The lease runs out: the next report drops the table.
        state.record(report(flow, .statistics, app, in: 50), at: 3 + HostLease.standardDuration)
        #expect(
            try #require(totals(state.reply(to: FilterRequest(build: build, wantsHosts: false), at: 70))).hosts.isEmpty)
    }

    /// Reports from many threads and replies to many readers at once: each
    /// reader's totals only grow, and the last ones are exact.
    @Test func concurrentReportsAndRepliesStayConsistent() async throws {
        let state = FilterState(build: build)
        let writers = 8
        let flowsPerWriter = 2_000
        let regressions = Atomic<Int>(0)
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    let process = ProcessKey.test(Int32(1 + writer))
                    for _ in 0..<flowsPerWriter {
                        let flow = UUID()
                        state.record(report(flow, .opened, process))
                        state.record(report(flow, .statistics, process, in: 3, out: 1))
                        state.record(report(flow, .closed, process, in: 5, out: 2))
                    }
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    var differ = UsageDiffer()
                    var last: [ProcessKey: ByteTotals] = [:]
                    for _ in 0..<500 {
                        guard
                            case .snapshot(let snapshot) = state.reply(
                                to: FilterRequest(build: build, wantsHosts: true))
                        else { continue }
                        let delta = differ.next(snapshot)
                        regressions.add(delta.restarted, ordering: .relaxed)
                        for entry in snapshot.processes {
                            if let before = last[entry.process], entry.totals.bytesIn < before.bytesIn {
                                regressions.add(1, ordering: .relaxed)
                            }
                            last[entry.process] = entry.totals
                        }
                    }
                }
            }
        }
        #expect(regressions.load(ordering: .relaxed) == 0)
        let final = try #require(totals(state.reply(to: FilterRequest(build: build, wantsHosts: false))))
        #expect(final.processes.count == writers)
        for entry in final.processes {
            #expect(
                entry.totals == ByteTotals(bytesIn: UInt64(5 * flowsPerWriter), bytesOut: UInt64(2 * flowsPerWriter)))
        }
        #expect(final.openFlows == 0)
    }
}

/// Opens come from the verdict path, not from NetworkExtension's reports:
/// the queue between them.
struct FilterStateOpeningTests {
    let build = "b"
    let app = ProcessKey.test(100)

    func snapshot(_ state: FilterState) throws -> FilterSnapshot {
        guard case .snapshot(let snapshot) = state.reply(to: FilterRequest(build: build, wantsHosts: false)) else {
            throw Refused()
        }
        return snapshot
    }

    struct Refused: Error {}

    /// The shape macOS 27 delivers: an open at the verdict, then only
    /// statistics and a close.
    @Test func aFlowOpenedAtTheVerdictIsCounted() throws {
        let state = FilterState(build: build)
        let flow = UUID()
        state.opened(report(flow, .opened, app))
        state.record(report(flow, .statistics, app, in: 4_000, out: 100))
        state.record(report(flow, .closed, app, in: 9_000, out: 200))
        let totals = try snapshot(state)
        #expect(totals.processes.first?.totals == ByteTotals(bytesIn: 9_000, bytesOut: 200))
        #expect(totals.counters.untracked == 0)
    }

    @Test func aReplySeesQueuedOpens() throws {
        let state = FilterState(build: build)
        state.opened(report(UUID(), .opened, app))
        state.opened(report(UUID(), .opened, app))
        #expect(try snapshot(state).openFlows == 2)
    }

    /// A full queue drops opens, counted; their flows are then untracked,
    /// never counted from zero twice.
    @Test func aFullQueueDropsOpensAndCountsThem() throws {
        let state = FilterState(build: build, limits: FlowLedger.Limits(flows: 4, processes: 8, hosts: 8))
        let flows = (0..<6).map { _ in UUID() }
        for flow in flows { state.opened(report(flow, .opened, app)) }
        #expect(state.openingsDropped == 2)
        for flow in flows { state.record(report(flow, .statistics, app, in: 10)) }
        let totals = try snapshot(state)
        #expect(totals.processes.first?.totals == ByteTotals(bytesIn: 40))
        #expect(totals.counters.untracked == 2)
    }

    /// The reference property, with every open arriving through the queue.
    @Test(arguments: LedgerPropertyTests.seeds.prefix(8)) func opensThroughTheQueueMatchTheReference(seed: UInt64)
        throws
    {
        var stream = ReportStream(seed: seed)
        let state = FilterState(
            build: build, limits: FlowLedger.Limits(flows: 100_000, processes: 100_000, hosts: 100_000))
        var reference = ReferenceLedger()
        for _ in 0..<10_000 {
            let next = stream.next()
            if next.event == .opened { state.opened(next) } else { state.record(next) }
            reference.record(next)
        }
        let totals = try snapshot(state)
        #expect(
            Dictionary(uniqueKeysWithValues: totals.processes.map { ($0.process, $0.totals) }) == reference.processes,
            "seed \(seed)")
    }
}
