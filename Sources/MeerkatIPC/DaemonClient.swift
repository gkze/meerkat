import Foundation
import MeerkatKit
import Synchronization
import XPC

/// What clients ask of `meerkatd`: requests and event streams.
public protocol DaemonConnection: Sendable {
    func send(_ request: DaemonRequest) async throws -> DaemonReply
    /// Streams `kind` until the returned stream is dropped or cancelled.
    func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<EventEnvelope, any Error>
}

extension DaemonConnection {
    public func subscribe(_ kind: String) async throws -> AsyncThrowingStream<EventEnvelope, any Error> {
        try await subscribe(kind, parameters: .object([:]))
    }

    public func status() async throws -> DaemonStatus {
        guard case .status(let status) = try await send(.status) else {
            throw DaemonClient.ClientError.unexpectedReply("status")
        }
        return status
    }

    public func catalog() async throws -> [CatalogEntry] {
        guard case .catalog(let entries) = try await send(.catalog) else {
            throw DaemonClient.ClientError.unexpectedReply("catalog")
        }
        return entries
    }

    public func rules() async throws -> RulesReport { try await rulesReport(.rules) }
    public func reloadRules() async throws -> RulesReport { try await rulesReport(.reloadRules) }

    public func setRule(_ rule: String, enabled: Bool) async throws -> RulesReport {
        try await rulesReport(.setRuleEnabled(rule: rule, enabled: enabled))
    }

    private func rulesReport(_ request: DaemonRequest) async throws -> RulesReport {
        guard case .rules(let report) = try await send(request) else {
            throw DaemonClient.ClientError.unexpectedReply("rules")
        }
        return report
    }

    public func logs(rule: String?, limit: Int) async throws -> [RuleLogEntry] {
        guard case .logs(let entries) = try await send(.ruleLogs(rule: rule, limit: limit)) else {
            throw DaemonClient.ClientError.unexpectedReply("logs")
        }
        return entries
    }

    public func dryRun(_ request: DryRunRequest) async throws -> DryRunReport {
        guard case .dryRun(let report) = try await send(.dryRun(request)) else {
            throw DaemonClient.ClientError.unexpectedReply("dry run")
        }
        return report
    }

    /// Typed convenience over `subscribe`. It reads `subscribe`'s stream
    /// only as it is read itself, so the subscription's one buffer, and the
    /// policy `subscribe` documents for it, is the only one.
    public func events<Kind: EventKind>(_ kind: Kind.Type, parameters: Kind.Parameters) async throws
        -> AsyncThrowingStream<(Kind.Payload, EventEnvelope), any Error>
    {
        let raw = EnvelopeReader(
            try await subscribe(Kind.descriptor.name, parameters: try JSONValue(encoding: parameters)))
        return AsyncThrowingStream {
            guard let envelope = try await raw.next() else { return nil }
            do {
                return (try envelope.payload.decode(as: Kind.Payload.self), envelope)
            } catch {
                // The daemon's payload does not match this build's type.
                throw DaemonClient.ClientError.differentBuild("\(Kind.descriptor.name): \(error)")
            }
        }
    }
}

/// What a failed request says about meerkatd, decided once here for every
/// client (the CLI's exit status, the app's `DaemonFault`), from the error
/// the client threw. Nil for an error that is not about the daemon.
public enum DaemonFailure: Sendable, Equatable {
    /// meerkatd answered: it refused the request or ended the
    /// subscription, in its own words. Only that request failed; asking the
    /// same daemon again repeats it.
    case refused
    /// meerkatd answered in a form this client cannot read, or could not
    /// read the request: it is a different build. Restarting it from this
    /// build fixes it; asking again does not.
    case differentBuild
    /// meerkatd was not reached, did not answer in time, answered with
    /// something nobody asked for, or lost a subscription across a restart:
    /// the daemon, not the request, is what failed.
    case unavailable

    public init?(classifying error: any Error) {
        switch error {
        case let error as DaemonClient.ClientError:
            switch error {
            case .daemon: self = .refused
            case .differentBuild: self = .differentBuild
            case .unreachable, .unexpectedReply, .resubscribeFailed: self = .unavailable
            }
        case is DaemonDidNotAnswer: self = .unavailable
        default: return nil
        }
    }
}

/// One subscription's iterator, read by the one consumer of the stream
/// `events` makes from it, which calls `next` only after the last call
/// returned.
private final class EnvelopeReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<EventEnvelope, any Error>.Iterator

    init(_ stream: AsyncThrowingStream<EventEnvelope, any Error>) { iterator = stream.makeAsyncIterator() }

    func next() async throws -> EventEnvelope? { try await iterator.next() }
}

/// The CLI's and the app's connection to `meerkatd`.
///
/// Subscriptions survive a daemon restart: XPC gives an idle session no
/// signal when the daemon is replaced, so while any subscription is active
/// the client pings every few seconds and recreates each subscription that a
/// different daemon accepted. Each subscription records the daemon that
/// accepted it (from `.subscribed`), not one identity for the client: a
/// subscribe that reaches a new daemon before the heartbeat does must not
/// make the old daemon's subscriptions look current.
///
/// A recreated subscription carries on without a word to its reader, who
/// missed what happened between the two daemons; `reconnected` is that
/// word, and also comes when a request is answered after one could not
/// reach meerkatd. A request that reached it and timed out
/// (`send(_:within:)`) is not a lost daemon, so the next answer is not
/// "back".
public final class DaemonClient: DaemonConnection {
    public enum ClientError: Error, CustomStringConvertible {
        case unreachable(String)
        /// The daemon refused a request or ended a subscription: its answer,
        /// which a retry against the same daemon would repeat.
        case daemon(String)
        case unexpectedReply(String)
        /// meerkatd answered in a form this client cannot decode, or could
        /// not decode the request: it is a different build from this client
        /// (for example, one not restarted since an upgrade). Retrying
        /// against the same daemon repeats it; restarting the agent from
        /// this build fixes it.
        case differentBuild(String)
        /// A subscription could not be recreated on a restarted daemon. Not
        /// the daemon's verdict on it: the new daemon may still be starting,
        /// so subscribing again later can succeed.
        case resubscribeFailed(kind: String, reason: String)

        public var description: String {
            switch self {
            case .unreachable(let detail):
                return "cannot reach meerkatd (\(detail)). Is the agent installed? Run `meerkat agent status`."
            case .daemon(let message): return message
            case .unexpectedReply(let request): return "unexpected reply to \(request)"
            case .differentBuild(let detail):
                return
                    "meerkatd is a different build from this client (\(detail)). Restart it with `meerkat agent restart`."
            case .resubscribeFailed(let kind, let reason):
                return "could not resubscribe to \(kind) after meerkatd restarted (\(reason))"
            }
        }
    }

    private struct Subscription: Sendable {
        let kind: String
        let parameters: JSONValue
        let continuation: AsyncThrowingStream<EventEnvelope, any Error>.Continuation
        /// The daemon that accepted it; nil while its subscribe is in flight.
        var daemon: DaemonIdentity?
    }

    private struct State: Sendable {
        var session: SessionBox?
        var subscriptions: [UInt64: Subscription] = [:]
        var nextSubscription: UInt64 = 1
        var heartbeat: Task<Void, Never>?
        var nextSessionToken: UInt64 = 1
        /// Events discarded from a full subscription buffer.
        var dropped: UInt64 = 0
        /// Where `DaemonPush.mcp` messages go; nil drops them.
        var mcp: AsyncStream<Data>.Continuation?
        /// The last request did not reach meerkatd.
        var unreached = false
    }

    private struct SessionBox: Sendable {
        let value: XPCSession
        /// Identifies the session to its own cancellation handler, which
        /// must not clear a newer session.
        let token: UInt64
    }

    private let state = Mutex(State())
    private let reconnected: @Sendable () -> Void
    private static let heartbeatInterval: Duration = .seconds(3)

    /// `reconnected` is called, on no particular thread, when this client
    /// reaches meerkatd again: a request is answered after one could not
    /// reach it, or the heartbeat recreated subscriptions on a new daemon.
    public init(reconnected: @escaping @Sendable () -> Void = {}) {
        self.reconnected = reconnected
    }

    deinit {
        let (session, heartbeat) = state.withLock { ($0.session, $0.heartbeat) }
        heartbeat?.cancel()
        session?.value.cancel(reason: "client released")
    }

    // MARK: - Requests

    public func send(_ request: DaemonRequest) async throws -> DaemonReply {
        do {
            let reply = try await exchange(request)
            reached(true)
            return reply
        } catch let error as ClientError {
            // Only an unreachable daemon is a lost one: a refusal or a
            // different build is meerkatd answering.
            if case .unreachable = error { reached(false) } else { reached(true) }
            throw error
        }
    }

    private func reached(_ answered: Bool) {
        let back = state.withLock { state in
            defer { state.unreached = !answered }
            return answered && state.unreached
        }
        if back { reconnected() }
    }

    private func exchange(_ request: DaemonRequest) async throws -> DaemonReply {
        let session = try connect()
        do {
            let reply: DaemonReply = try await withCheckedThrowingContinuation { continuation in
                do {
                    // The reply is decoded here rather than by XPC, so a
                    // transport failure (`XPCRichError`) and a reply this
                    // build cannot decode stay distinct.
                    try session.value.send(request) { (result: Result<XPCReceivedMessage, XPCRichError>) in
                        continuation.resume(
                            with: Result {
                                let message = try result.get()
                                do {
                                    return try message.decode(as: DaemonReply.self)
                                } catch {
                                    throw ClientError.differentBuild("\(error)")
                                }
                            })
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            switch reply {
            case .failure(let message): throw ClientError.daemon(message)
            case .undecodableRequest(let message): throw ClientError.differentBuild(message)
            default: return reply
            }
        } catch let error as ClientError {
            throw error
        } catch {
            // The session may be unusable; the next request makes a new one.
            dropSession(session)
            throw ClientError.unreachable("\(error)")
        }
    }

    // MARK: - Subscriptions

    /// Events a subscription holds for a consumer that has not read them.
    /// This buffer is the client's, after the daemon's ring: an event it
    /// discards was delivered as far as the daemon knows, so `meerkat.dropped`
    /// and the daemon's statistics never count it; `droppedEvents` does.
    public static let subscriptionBuffer = 256

    /// Events this client's subscriptions discarded, oldest first, because
    /// their consumer fell more than `subscriptionBuffer` events behind.
    public var droppedEvents: UInt64 { state.withLock(\.dropped) }

    public func subscribe(_ kind: String, parameters: JSONValue) async throws -> AsyncThrowingStream<
        EventEnvelope, any Error
    > {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: EventEnvelope.self,
            bufferingPolicy: .bufferingNewest(Self.subscriptionBuffer))
        let id = state.withLock { state -> UInt64 in
            let id = state.nextSubscription
            state.nextSubscription += 1
            state.subscriptions[id] = Subscription(kind: kind, parameters: parameters, continuation: continuation)
            return id
        }
        // The stream keeps its client (and so the XPC session) alive until it
        // terminates; a caller may hold only the stream.
        continuation.onTermination = { _ in
            _ = self.state.withLock { $0.subscriptions.removeValue(forKey: id) }
            Task { _ = try? await self.send(.unsubscribe(subscription: id)) }
        }
        do {
            let daemon = try await requestSubscription(id, kind: kind, parameters: parameters)
            await record(id, acceptedBy: daemon)
        } catch {
            _ = state.withLock { $0.subscriptions.removeValue(forKey: id) }
            continuation.finish(throwing: error)
            throw error
        }
        startHeartbeat()
        return stream
    }

    // MARK: - MCP

    /// The daemon's MCP messages for this client, in the order it sent them.
    ///
    /// One stream per client: calling this again finishes the previous one.
    /// Unlike subscriptions, MCP state does not survive a daemon restart, so
    /// nothing is resent; the bridge ends when the daemon changes (see
    /// `meerkat mcp`).
    public func mcpMessages() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let previous = state.withLock { state in
            defer { state.mcp = continuation }
            return state.mcp
        }
        previous?.finish()
        return stream
    }

    /// Queues one MCP message for this session's server in the daemon.
    public func sendMCP(_ message: Data) async throws {
        guard case .done = try await send(.mcp(message: message)) else { throw ClientError.unexpectedReply("mcp") }
    }

    // MARK: - Connection

    /// The one session, created on first use. Creation happens under the
    /// lock: concurrent first requests must not each create a session, since
    /// releasing an XPC session without cancelling it is an API misuse that
    /// libxpc traps on.
    private func connect() throws -> SessionBox {
        try state.withLock { state in
            if let session = state.session { return session }
            let token = state.nextSessionToken
            state.nextSessionToken += 1
            let session: XPCSession
            do {
                session = try XPCSession(
                    machService: DaemonService.machService,
                    requirement: .isFromSameTeam(),
                    incomingMessageHandler: { [weak self] (push: DaemonPush) -> (any Encodable)? in
                        self?.receive(push)
                        return nil
                    },
                    cancellationHandler: { [weak self] _ in
                        self?.forget(token)
                    }
                )
            } catch {
                throw ClientError.unreachable("\(error)")
            }
            let box = SessionBox(value: session, token: token)
            state.session = box
            return box
        }
    }

    /// The session was cancelled (by us or by the system); the next request
    /// connects again.
    private func forget(_ token: UInt64) {
        state.withLock { state in
            if state.session?.token == token { state.session = nil }
        }
    }

    private func dropSession(_ session: SessionBox) {
        let dropped = state.withLock { state -> Bool in
            guard state.session?.token == session.token else { return false }
            state.session = nil
            return true
        }
        if dropped { session.value.cancel(reason: "request failed") }
    }

    private func receive(_ push: DaemonPush) {
        switch push {
        case .event(let id, let envelope):
            if case .dropped = state.withLock({ $0.subscriptions[id] })?.continuation.yield(envelope) {
                state.withLock { $0.dropped += 1 }
            }
        case .ended(let id, let reason):
            state.withLock { $0.subscriptions.removeValue(forKey: id) }?
                .continuation.finish(throwing: ClientError.daemon(reason))
        case .mcp(let message):
            _ = state.withLock { $0.mcp }?.yield(message)
        }
    }

    /// Creates or recreates subscription `id`; returns the daemon that
    /// accepted it.
    private func requestSubscription(_ id: UInt64, kind: String, parameters: JSONValue) async throws
        -> DaemonIdentity
    {
        let reply = try await send(.subscribe(subscription: id, kind: kind, parameters: parameters))
        guard case .subscribed(_, let daemon) = reply else { throw ClientError.unexpectedReply("subscribe") }
        return daemon
    }

    /// Records the daemon that accepted `id`. A stream that ended while its
    /// subscribe was in flight sent its unsubscribe before the daemon held
    /// it, or to the daemon before a restart, so it is released again here:
    /// otherwise the daemon runs its source for nobody until the session
    /// ends. Unsubscribing what the daemon doesn't hold does nothing.
    private func record(_ id: UInt64, acceptedBy daemon: DaemonIdentity) async {
        let current = state.withLock { state -> Bool in
            guard state.subscriptions[id] != nil else { return false }
            state.subscriptions[id]?.daemon = daemon
            return true
        }
        if !current { _ = try? await send(.unsubscribe(subscription: id)) }
    }

    /// The subscriptions `current` does not hold: those a different daemon
    /// accepted. One still being subscribed is left to its subscribe.
    static func stale(_ accepted: [UInt64: DaemonIdentity?], current: DaemonIdentity) -> [UInt64] {
        accepted.filter { _, daemon in daemon.map { $0 != current } ?? false }.keys.sorted()
    }

    private func startHeartbeat() {
        let interval = Self.heartbeatInterval
        state.withLock { state in
            guard state.heartbeat == nil else { return }
            state.heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, await self.checkDaemon() else { return }
                }
            }
        }
    }

    /// Returns false when no subscriptions remain, ending the heartbeat.
    private func checkDaemon() async -> Bool {
        // Check and clear in one step, so a subscription added meanwhile
        // either sees this heartbeat still running or starts its own.
        let subscriptions = state.withLock { state -> [UInt64: Subscription] in
            if state.subscriptions.isEmpty { state.heartbeat = nil }
            return state.subscriptions
        }
        guard !subscriptions.isEmpty else { return false }
        // Bounded: a daemon that takes the ping and never answers must not
        // stall the heartbeat, which would then never recreate anything.
        // Unanswered is checked again at the next beat.
        guard let current = try? await daemonIdentity() else { return true }
        // A new daemon has none of the old one's subscriptions; recreate each
        // with its original id so the streams continue.
        let stale = Self.stale(subscriptions.mapValues(\.daemon), current: current)
        defer { if !stale.isEmpty { reconnected() } }
        for id in stale {
            guard let subscription = subscriptions[id] else { continue }
            do {
                let daemon = try await requestSubscription(
                    id, kind: subscription.kind, parameters: subscription.parameters)
                await record(id, acceptedBy: daemon)
            } catch {
                subscription.continuation.finish(
                    throwing: ClientError.resubscribeFailed(kind: subscription.kind, reason: "\(error)"))
                _ = state.withLock { $0.subscriptions.removeValue(forKey: id) }
            }
        }
        return true
    }
}
