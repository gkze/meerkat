import Foundation
import MeerkatKit
import Synchronization
import Testing

@testable import MeerkatIPC

/// The client's side of a daemon that may not answer, or may restart.
struct DaemonClientTests {
    /// A daemon that takes a request and never answers is not answering,
    /// which a bounded ping reports in time.
    @Test func aSilentDaemonDoesNotAnswerAPing() async {
        let started = ContinuousClock.now
        await #expect(throws: DaemonDidNotAnswer.self) {
            try await SilentDaemon().daemonIdentity(within: .milliseconds(100))
        }
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func anAnsweringDaemonGivesItsIdentityInTime() async throws {
        let identity = try await AnsweringDaemon().daemonIdentity(within: .seconds(5))
        #expect(identity == DaemonIdentity(pid: 42, startedAt: 1_000))
    }

    @Test func theCallersCancellationEndsABoundedRequest() async {
        let waiting = Task { try await SilentDaemon().send(.status, within: .seconds(3600)) }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    /// Each subscription is checked against the daemon that accepted it: a
    /// new subscription that reached the new daemon first must not make the
    /// old daemon's subscription look current.
    @Test func onlySubscriptionsAnotherDaemonAcceptedAreRecreated() {
        let old = DaemonIdentity(pid: 100, startedAt: 1_000)
        let new = DaemonIdentity(pid: 200, startedAt: 2_000)
        let accepted: [UInt64: DaemonIdentity?] = [1: old, 2: new, 3: nil]
        #expect(DaemonClient.stale(accepted, current: new) == [1])
        #expect(DaemonClient.stale(accepted, current: old) == [2])
        // The same pid with a later start is a different daemon.
        #expect(DaemonClient.stale([1: old], current: DaemonIdentity(pid: 100, startedAt: 3_000)) == [1])
    }

    /// One classification for the CLI's exit status and the app's pages:
    /// only the daemon's own answer is a refusal, and an error that is not
    /// about the daemon is not classified.
    @Test(
        arguments: [
            (DaemonClient.ClientError.daemon("no such kind"), DaemonFailure.refused),
            (.differentBuild("unknown case"), .differentBuild),
            (.unreachable("down"), .unavailable),
            (.unexpectedReply("status"), .unavailable),
            (.resubscribeFailed(kind: "cpu.sample", reason: "starting"), .unavailable),
        ] as [(DaemonClient.ClientError, DaemonFailure)])
    func failuresAreClassifiedByWhoseTheyAre(error: DaemonClient.ClientError, failure: DaemonFailure) {
        #expect(DaemonFailure(classifying: error) == failure)
    }

    @Test func aDaemonThatDidNotAnswerIsUnavailable() {
        #expect(DaemonFailure(classifying: DaemonDidNotAnswer(limit: .seconds(2))) == .unavailable)
        #expect(DaemonFailure(classifying: CocoaError(.fileReadNoSuchFile)) == nil)
    }
}

/// `events`, the typed form of a subscription.
struct TypedEventsTests {
    private static func envelope(_ payload: JSONValue) -> EventEnvelope {
        EventEnvelope(
            kind: ProcessSampleEvent.descriptor.name, sequence: 1, time: 0, origin: .system, replayed: false,
            payload: payload)
    }

    /// It reads the subscription as it is read, and a consumer that stops
    /// reading ends the subscription.
    @Test func itDecodesAndEndsWithItsConsumer() async throws {
        let daemon = StreamingDaemon(sending: [Self.envelope(.object(["running": .bool(false)]))])
        let parameters = ProcessSampleParameters(pid: 1, startedAt: 1)
        for try await (payload, _) in try await daemon.client.events(ProcessSampleEvent.self, parameters: parameters) {
            #expect(!payload.running && payload.process == nil)
            break
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !daemon.ended, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(daemon.ended)
    }

    @Test func aPayloadOfAnotherShapeIsADifferentBuild() async throws {
        let daemon = StreamingDaemon(sending: [Self.envelope(.object(["running": .string("yes")]))])
        let parameters = ProcessSampleParameters(pid: 1, startedAt: 1)
        let failure = await #expect(throws: DaemonClient.ClientError.self) {
            for try await _ in try await daemon.client.events(ProcessSampleEvent.self, parameters: parameters) {}
        }
        #expect(failure.flatMap { DaemonFailure(classifying: $0) } == .differentBuild)
    }
}

/// Takes requests and never answers them, ignoring cancellation, like an
/// XPC reply that never comes.
private struct SilentDaemon: DaemonConnection {
    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        throw CancellationError()
    }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        AsyncThrowingStream { _ in }
    }
}

private struct AnsweringDaemon: DaemonConnection {
    func send(_ request: DaemonRequest) async throws -> DaemonReply { .pong(pid: 42, startedAt: 1_000) }

    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
    {
        AsyncThrowingStream { _ in }
    }
}

/// One subscription, sending `envelopes` and then holding it open; says
/// when it ended.
private final class StreamingDaemon: Sendable {
    private let envelopes: [EventEnvelope]
    private let state = Mutex(false)
    var ended: Bool { state.withLock { $0 } }
    var client: Client { Client(daemon: self) }

    init(sending envelopes: [EventEnvelope]) { self.envelopes = envelopes }

    struct Client: DaemonConnection {
        let daemon: StreamingDaemon

        func send(_ request: DaemonRequest) async throws -> DaemonReply {
            throw DaemonClient.ClientError.unexpectedReply("\(request)")
        }

        func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<
            EventEnvelope, any Error
        > {
            let (stream, continuation) = AsyncThrowingStream<EventEnvelope, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(DaemonClient.subscriptionBuffer))
            continuation.onTermination = { [daemon] _ in daemon.state.withLock { $0 = true } }
            for envelope in daemon.envelopes { continuation.yield(envelope) }
            return stream
        }
    }
}
