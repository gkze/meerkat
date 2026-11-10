import Foundation
import MeerkatIPC
import MeerkatKit
import Synchronization
import XPC
import os

/// The daemon's XPC endpoint.
///
/// Peers must be signed by the same team as the daemon, which in practice
/// means the CLI and the app from the same Meerkat.app. Each session owns
/// its subscriptions and, once it sends MCP, its MCP server; both end when
/// the session does, so a client that quits or crashes never leaves sources
/// running.
final class DaemonServer: Sendable {
    private let hub: EventHub
    private let engine: RuleEngine
    private let dryRunner: RuleDryRunner
    private let mcp: MCPService
    /// Every session's MCP server, so stopping the daemon can end them cleanly.
    private let endpoints = Mutex<[ObjectIdentifier: MCPEndpoint]>([:])
    private let status: @Sendable () async -> DaemonStatus
    /// Unix epoch milliseconds when this daemon process started.
    private let startedAt: Double
    /// Held only to keep the listener alive and cancel it.
    private let listener = Mutex<XPCListener?>(nil)
    private let logger = Logger(subsystem: DaemonService.label, category: "xpc")

    init(
        hub: EventHub, engine: RuleEngine, dryRunner: RuleDryRunner, mcp: MCPService, startedAt: Double,
        status: @escaping @Sendable () async -> DaemonStatus
    ) {
        self.startedAt = startedAt
        self.hub = hub
        self.engine = engine
        self.dryRunner = dryRunner
        self.mcp = mcp
        self.status = status
    }

    func start() throws {
        let server = self
        let listener = try XPCListener(service: DaemonService.machService, requirement: .isFromSameTeam()) { request in
            request.accept { session in
                SessionHandler(
                    server: server, session: session, subscriptions: Subscriptions(),
                    mcp: MCPSlot(server: server, session: session))
            }
        }
        self.listener.withLock { $0 = listener }
        logger.info("listening on \(DaemonService.machService, privacy: .public)")
    }

    /// Stops accepting sessions and ends every MCP server; listen streams are
    /// completed rather than dropped.
    func stop() async {
        listener.withLock { listener in
            listener?.cancel()
            listener = nil
        }
        let open = endpoints.withLock { endpoints in
            defer { endpoints.removeAll() }
            return Array(endpoints.values)
        }
        await withTaskGroup(of: Void.self) { group in
            for endpoint in open { group.addTask { await endpoint.shutdown() } }
        }
    }

    // MARK: - MCP

    fileprivate func openEndpoint(for session: XPCSession) -> MCPEndpoint {
        let endpoint = MCPEndpoint(service: mcp) { message in
            try session.send(DaemonPush.mcp(message: message))
        }
        endpoints.withLock { $0[ObjectIdentifier(endpoint)] = endpoint }
        return endpoint
    }

    fileprivate func closeEndpoint(_ endpoint: MCPEndpoint) async {
        let owned = endpoints.withLock { $0.removeValue(forKey: ObjectIdentifier(endpoint)) } != nil
        // Already removed means `stop` is shutting it down.
        if owned { await endpoint.close() }
    }

    // MARK: - Requests

    fileprivate func handle(_ request: DaemonRequest, session: XPCSession, subscriptions: Subscriptions) async
        -> DaemonReply
    {
        switch request {
        case .ping:
            return .pong(pid: getpid(), startedAt: startedAt)
        case .status:
            return .status(await status())
        case .catalog:
            return .catalog(CatalogEntry.entries(hub.catalog))
        case .subscribe(let id, let kind, let parameters):
            subscriptions.begin(id)
            do {
                let subscription = try hub.subscribe(kind, parameters: parameters)
                // Forwarding starts only once the subscription is registered,
                // so a stream that ends at once cannot race its own entry.
                let registered = ExitSignal()
                let forward = Task.detached { [hub] in
                    await registered.wait()
                    guard !Task.isCancelled else { return }
                    var sendFailed = false
                    for await envelope in subscription.events {
                        do {
                            try session.send(DaemonPush.event(subscription: id, envelope: envelope))
                        } catch {
                            sendFailed = true
                            break
                        }
                    }
                    // The stream ended without the client asking (its source
                    // failed): tell the client rather than leave it waiting.
                    if !Task.isCancelled, !sendFailed {
                        try? session.send(DaemonPush.ended(subscription: id, reason: hub.stopReason(of: subscription)))
                    }
                    subscriptions.forwardEnded(id, subscription: subscription.id)
                }
                let accepted = subscriptions.insert(id, subscription: subscription, forward: forward)
                registered.fire()
                guard accepted else {
                    return .failure("subscription \(id) was cancelled before it started")
                }
                return .subscribed(
                    parameters: subscription.parameters, daemon: DaemonIdentity(pid: getpid(), startedAt: startedAt))
            } catch {
                subscriptions.abandon(id)
                return .failure("\(error)")
            }
        case .unsubscribe(let id):
            subscriptions.remove(id)
            return .done
        case .rules:
            return .rules(await engine.report())
        case .reloadRules:
            await engine.reload()
            return .rules(await engine.report())
        case .setRuleEnabled(let rule, let enabled):
            do {
                try await engine.setEnabled(rule, enabled: enabled)
                return .rules(await engine.report())
            } catch {
                return .failure("\(error)")
            }
        case .ruleLogs(let rule, let limit):
            do {
                return .logs(try await engine.logs(rule: rule, limit: RuleLogEntry.clampedLimit(limit)))
            } catch {
                return .failure("\(error)")
            }
        case .dryRun(let request):
            do {
                return .dryRun(try await dryRunner.run(request))
            } catch {
                return .failure("\(error)")
            }
        case .mcp:
            // Handled in `SessionHandler`, in arrival order, before any task.
            return .failure("MCP message reached the request handler")
        }
    }
}

/// One session's active subscriptions.
///
/// Requests are handled in tasks, so a `subscribe` can finish after its
/// session was cancelled; once closed, anything inserted is cancelled at
/// once instead of outliving the session.
private final class Subscriptions: Sendable {
    private struct State {
        var entries: [UInt64: (subscription: EventSubscription, forward: Task<Void, Never>)] = [:]
        /// Ids whose subscribe request is being handled.
        var starting: Set<UInt64> = []
        /// Ids unsubscribed while their subscribe was still starting
        /// (requests run in separate tasks), so the late insert is cancelled.
        var tombstones: Set<UInt64> = []
        var closed = false
    }

    private let state = Mutex(State())

    func begin(_ id: UInt64) {
        _ = state.withLock { $0.starting.insert(id) }
    }

    func abandon(_ id: UInt64) {
        state.withLock { state in
            state.starting.remove(id)
            state.tombstones.remove(id)
        }
    }

    /// Registers a started subscription. Returns false (and cancels it) when
    /// the session closed or the client unsubscribed while it started.
    @discardableResult
    func insert(_ id: UInt64, subscription: EventSubscription, forward: Task<Void, Never>) -> Bool {
        // A client reusing an id replaces its earlier subscription.
        let (previous, rejected) = state.withLock {
            state -> ((subscription: EventSubscription, forward: Task<Void, Never>)?, Bool) in
            state.starting.remove(id)
            guard !state.closed, state.tombstones.remove(id) == nil else { return (nil, true) }
            defer { state.entries[id] = (subscription, forward) }
            return (state.entries[id], false)
        }
        if rejected {
            forward.cancel()
            subscription.cancel()
        }
        previous?.forward.cancel()
        previous?.subscription.cancel()
        return !rejected
    }

    func remove(_ id: UInt64) {
        guard
            let entry = state.withLock({ state -> (subscription: EventSubscription, forward: Task<Void, Never>)? in
                guard let entry = state.entries.removeValue(forKey: id) else {
                    // Only a subscribe still starting can need a tombstone; an
                    // unknown id is nothing to remove.
                    if state.starting.contains(id) { state.tombstones.insert(id) }
                    return nil
                }
                return entry
            })
        else { return }
        entry.forward.cancel()
        entry.subscription.cancel()
    }

    /// A forwarding task stopped (send failed, or it was cancelled): release
    /// its subscription if it is still the one registered under `id`.
    func forwardEnded(_ id: UInt64, subscription: UInt64) {
        let entry = state.withLock { state -> (subscription: EventSubscription, forward: Task<Void, Never>)? in
            guard state.entries[id]?.subscription.id == subscription else { return nil }
            return state.entries.removeValue(forKey: id)
        }
        entry?.subscription.cancel()
    }

    /// Ends every subscription and refuses new ones.
    func close() {
        let all = state.withLock { state in
            defer {
                state.entries.removeAll()
                state.closed = true
            }
            return Array(state.entries.values)
        }
        for entry in all {
            entry.forward.cancel()
            entry.subscription.cancel()
        }
    }
}

/// One session's MCP server, made when the session first sends MCP. A
/// session that never does (the CLI's other commands, the app) has none.
private final class MCPSlot: Sendable {
    private let server: DaemonServer
    private let session: XPCSession
    private let state = Mutex<(endpoint: MCPEndpoint?, closed: Bool)>((nil, false))

    init(server: DaemonServer, session: XPCSession) {
        self.server = server
        self.session = session
    }

    /// The session's server, made on first use; nil once the session closed.
    func endpoint() -> MCPEndpoint? {
        state.withLock { state in
            guard !state.closed else { return nil }
            if let endpoint = state.endpoint { return endpoint }
            let endpoint = server.openEndpoint(for: session)
            state.endpoint = endpoint
            return endpoint
        }
    }

    func close() {
        let endpoint = state.withLock { state in
            state.closed = true
            return state.endpoint
        }
        guard let endpoint else { return }
        let server = server
        Task { await server.closeEndpoint(endpoint) }
    }
}

private struct SessionHandler: XPCPeerHandler {
    let server: DaemonServer
    let session: XPCSession
    let subscriptions: Subscriptions
    let mcp: MCPSlot

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        let request: DaemonRequest
        do {
            request = try message.decode(as: DaemonRequest.self)
        } catch {
            return DaemonReply.undecodableRequest("\(error)")
        }
        // XPC calls this one message at a time per session, so queueing here,
        // rather than in a task like other requests, keeps the client's order.
        if case .mcp(let bytes) = request {
            guard let endpoint = mcp.endpoint() else { return DaemonReply.failure("the session is closed") }
            do {
                try endpoint.deliver(bytes)
                return DaemonReply.done
            } catch {
                return DaemonReply.failure("\(error)")
            }
        }
        let box = MessageBox(value: message)
        let (server, session, subscriptions) = (server, session, subscriptions)
        return message.handoffReply(to: .global(qos: .userInitiated)) {
            Task {
                let reply = await server.handle(request, session: session, subscriptions: subscriptions)
                box.value.reply(reply)
            }
        }
    }

    func handleCancellation(error: XPCRichError) {
        subscriptions.close()
        mcp.close()
    }
}

/// The received message is replied to exactly once, from the task that
/// computed the reply; the box carries it there.
private struct MessageBox: @unchecked Sendable {
    let value: XPCReceivedMessage
}
