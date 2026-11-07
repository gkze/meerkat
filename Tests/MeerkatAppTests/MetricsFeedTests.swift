import Foundation
import MeerkatIPC
import Synchronization
import Testing

@testable import MeerkatApp
@testable import MeerkatKit

/// How the Overview's feeds tell a lost daemon from one feed the daemon
/// refused or ended: only the first is "meerkatd isn't answering".
@MainActor
struct MetricsFeedTests {
    private let battery = BatterySampleEvent.descriptor.name
    private let churn = FSChurnEvent.descriptor.name
    private let lowPower = LowPowerModeEvent.descriptor.name

    private func model(_ daemon: FeedDaemon) -> MetricsModel {
        MetricsModel(client: daemon, isVisible: { true }, retryDelay: .milliseconds(100))
    }

    /// A polling source whose tick throws ends its own subscription
    /// (`fs.churn` losing its folder): that feed is marked with the reason
    /// and subscribes again on its own, the others keep running, and the
    /// connection is not called lost.
    @Test func oneFeedEndingLeavesTheOthersRunning() async throws {
        let daemon = FeedDaemon()
        let model = model(daemon)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(lowPower) == 1 && daemon.subscribes(churn) == 1 }
        try await Task.sleep(for: .milliseconds(200))
        let feeds = daemon.open

        daemon.end(churn, throwing: DaemonClient.ClientError.daemon("fs.churn could not measure /Volumes/Gone"))
        try await waitUntil { model.feedFailures[churn] != nil }
        #expect(model.feedFailures[churn] == "fs.churn could not measure /Volumes/Gone")
        #expect(model.feedFailure(.files) == "fs.churn could not measure /Volumes/Gone")
        #expect(model.feedFailure(.cpu) == nil)
        #expect(!model.connection.isUnavailable)
        // The others were never cancelled; only the churn feed comes back.
        try await waitUntil { daemon.subscribes(churn) == 2 }
        #expect(daemon.subscribes(lowPower) == 1)
        #expect(daemon.open == feeds)
    }

    /// `process.list` feeds only the pages' process tables: its failure is
    /// shown on those pages, not on the cards, whose numbers keep coming.
    @Test func aFailedProcessListShowsOnThePagesThatUseIt() async throws {
        let list = ProcessListEvent.descriptor.name
        let daemon = FeedDaemon()
        let model = model(daemon)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(list) == 1 }

        daemon.end(list, throwing: DaemonClient.ClientError.daemon("the process table could not be read"))
        try await waitUntil { model.feedFailures[list] != nil }
        for resource in [Resource.cpu, .memory, .disk, .power] {
            #expect(model.feedFailure(resource, onPage: true) == "the process table could not be read")
            #expect(model.feedFailure(resource) == nil)
        }
        #expect(model.feedFailure(.network, onPage: true) == nil)
        #expect(model.feedFailure(.files, onPage: true) == nil)
    }

    /// A payload on the resubscribed feed clears its mark.
    @Test func aFeedThatComesBackIsClear() async throws {
        let daemon = FeedDaemon()
        let model = model(daemon)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(lowPower) == 1 }

        daemon.end(lowPower, throwing: DaemonClient.ClientError.daemon("the notify registration failed"))
        try await waitUntil { model.feedFailures[lowPower] != nil }
        try await waitUntil { daemon.subscribes(lowPower) == 2 }
        try daemon.emit(lowPower, LowPowerModePayload.examples[1])
        try await waitUntil { model.feedFailures[lowPower] == nil }
        #expect(model.lowPowerMode)
        #expect(model.connection == .connected)
    }

    /// The battery that could not be read mid-run was there: the Mac still
    /// has a battery, and the feed tries again.
    @Test func aBatteryEndingMidRunIsNotNoBattery() async throws {
        let daemon = FeedDaemon()
        let model = model(daemon)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(battery) == 1 }

        daemon.end(battery, throwing: DaemonClient.ClientError.daemon("the battery could not be read"))
        try await waitUntil { model.feedFailures[battery] != nil }
        #expect(model.battery == .waiting)
        #expect(model.feedFailure(.power) == "the battery could not be read")
        #expect(!model.connection.isUnavailable)
        try await waitUntil { daemon.subscribes(battery) == 2 }
    }

    /// Refused when subscribing is the daemon's answer for a Mac without a
    /// battery: settled, not a failure, and not asked again.
    @Test func aBatteryRefusedAtSubscribeIsNoBattery() async throws {
        let daemon = FeedDaemon(refusing: [battery: "battery.sample: this Mac has no battery"])
        let model = model(daemon)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.battery != .waiting }

        #expect(model.battery == .unavailable("battery.sample: this Mac has no battery"))
        #expect(model.feedFailures.isEmpty)
        #expect(!model.connection.isUnavailable)
        try await Task.sleep(for: .milliseconds(400))
        #expect(daemon.subscribes(battery) == 1)
    }

    /// Losing the connection is still every feed's problem: the page says
    /// so and subscribes everything again.
    @Test func aLostConnectionStopsEveryFeed() async throws {
        let daemon = FeedDaemon()
        let model = model(daemon)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(lowPower) == 1 }

        daemon.end(churn, throwing: DaemonClient.ClientError.unreachable("connection invalid"))
        try await waitUntil { model.connection.isUnavailable }
        #expect(model.feedFailures.isEmpty)
        try await waitUntil { daemon.subscribes(lowPower) == 2 }
    }
}

extension MetricsModel.Connection {
    fileprivate var isUnavailable: Bool {
        if case .unavailable = self { true } else { false }
    }
}

/// Holds every subscription open until the test ends one, refusing the kinds
/// in `refusing` when they subscribe; counts subscribes per kind.
private final class FeedDaemon: DaemonConnection {
    private struct State {
        var subscribes: [String: Int] = [:]
        var streams: [String: (id: Int, continuation: AsyncThrowingStream<EventEnvelope, any Error>.Continuation)] =
            [:]
        var nextID = 0
    }

    private let state = Mutex(State())
    private let refusing: [String: String]

    init(refusing: [String: String] = [:]) { self.refusing = refusing }

    func subscribes(_ kind: String) -> Int { state.withLock { $0.subscribes[kind] ?? 0 } }
    /// The subscriptions currently held open.
    var open: Int { state.withLock { $0.streams.count } }

    /// Ends `kind`'s subscription with `error`, or with none, as a source
    /// that stops without a word does.
    func end(_ kind: String, throwing error: (any Error)? = nil) {
        state.withLock { $0.streams.removeValue(forKey: kind) }?.continuation.finish(throwing: error)
    }

    func emit<Payload: EventPayload>(_ kind: String, _ payload: Payload) throws {
        let envelope = EventEnvelope(
            kind: kind, sequence: 1, time: Date().timeIntervalSince1970 * 1000, origin: .system, replayed: false,
            payload: try JSONValue(encoding: payload))
        _ = state.withLock { $0.streams[kind] }?.continuation.yield(envelope)
    }

    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        throw DaemonClient.ClientError.unexpectedReply("\(request)")
    }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        state.withLock { $0.subscribes[kind, default: 0] += 1 }
        if let reason = refusing[kind] { throw DaemonClient.ClientError.daemon(reason) }
        let (stream, continuation) = AsyncThrowingStream<EventEnvelope, any Error>.makeStream()
        let id = state.withLock { state in
            state.nextID += 1
            state.streams[kind] = (state.nextID, continuation)
            return state.nextID
        }
        // Cancelled by the model: no longer open, unless already replaced.
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                if state.streams[kind]?.id == id { state.streams[kind] = nil }
            }
        }
        return stream
    }
}

/// The process card's tiles chart only what the daemon measured.
@MainActor
struct ProcessCardFeedTests {
    private let kind = ProcessSampleEvent.descriptor.name

    /// Another user's process reports CPU only: its memory, energy and disk
    /// tiles get no points, not a line at zero.
    @Test func anUnreadableCounterAddsNoPoint() async throws {
        let daemon = FeedDaemon()
        let target = ProcessTarget(Self.delta(cpu: 12, footprint: nil))
        let model = ProcessCardModel(target: target, client: daemon)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(kind) == 1 }

        try daemon.emit(kind, ProcessSamplePayload(process: Self.delta(cpu: 12, footprint: nil), running: true))
        try await waitUntil { model.cpu.points.count == 1 }
        #expect(model.memory.points.isEmpty)
        #expect(model.energy.points.isEmpty)
        #expect(model.disk.points.isEmpty)

        try daemon.emit(kind, ProcessSamplePayload(process: Self.delta(cpu: 3, footprint: 80), running: true))
        try await waitUntil { model.cpu.points.count == 2 }
        #expect(model.memory.points.map(\.value) == [80])
    }

    /// The daemon ending the feed (reads failing in a row) is the card's
    /// problem, in its words; the card follows the process again, and the
    /// next sample clears the problem.
    @Test func anEndedFeedIsTheCardsProblemUntilItComesBack() async throws {
        let daemon = FeedDaemon()
        let model = card(daemon, running: true)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(kind) == 1 }
        daemon.end(kind, throwing: DaemonClient.ClientError.daemon("process 4242 could not be read 5 times in a row"))
        try await waitUntil { model.problem != nil }
        #expect(model.problem == "process 4242 could not be read 5 times in a row")
        try await waitUntil { daemon.subscribes(kind) == 2 }
        try daemon.emit(kind, ProcessSamplePayload(process: Self.delta(cpu: 2, footprint: nil), running: true))
        try await waitUntil { model.problem == nil }
        #expect(model.running)
    }

    /// A feed that ends with no word while the process runs still says so,
    /// rather than leaving the tiles silently frozen.
    @Test func aSilentEndIsStillAProblem() async throws {
        let daemon = FeedDaemon()
        let model = card(daemon, running: true)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(kind) == 1 }
        daemon.end(kind)
        try await waitUntil { model.problem != nil }
        try await waitUntil { daemon.subscribes(kind) == 2 }
    }

    /// A process that exited while the feed was down is not followed again,
    /// and is no problem: the card shows it has exited.
    @Test func anExitedProcessIsNotFollowedAgain() async throws {
        let daemon = FeedDaemon()
        let model = card(daemon, running: false)
        model.start()
        defer { model.stop() }
        try await waitUntil { daemon.subscribes(kind) == 1 }
        daemon.end(kind, throwing: DaemonClient.ClientError.daemon("process 4242 is not running"))
        try await waitUntil { !model.running }
        #expect(model.problem == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(daemon.subscribes(kind) == 1)
    }

    private func card(_ daemon: FeedDaemon, running: Bool) -> ProcessCardModel {
        ProcessCardModel(
            target: ProcessTarget(Self.delta(cpu: 1, footprint: nil)), client: daemon,
            retryDelay: .milliseconds(100), isRunning: { _ in running })
    }

    private static func delta(cpu: Double, footprint: Double?) -> ProcessDelta {
        ProcessDelta(
            pid: 4242, name: "worker", path: "/usr/local/bin/worker", cpuPct: cpu, cpuSeconds: 1, windowSeconds: 1,
            footprintMB: footprint, diskReadMB: footprint.map { _ in 0 }, diskWriteMB: footprint.map { _ in 0 },
            energyJoules: footprint.map { _ in 1 }, startedAt: 1_792_887_367_209, uid: 0)
    }
}
