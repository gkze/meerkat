import Foundation
import MCP
import MeerkatIPC
import os

/// The HTTP clients of the MCP server, each with its own SDK `Server` on one
/// of the SDK's HTTP transports (docs/design/mcp.md, "Transport: Streamable
/// HTTP"). A client is one of:
///
/// - a session begun with `initialize`, on a `StatefulHTTPServerTransport`,
///   which later requests name with `Mcp-Session-Id`;
/// - a 2026-07-28 client, which names no session, on a
///   `StatelessHTTPServerTransport`, told apart by `MCP-Client-Identity`. The
///   stateless transport keys requests by JSON-RPC id alone, so clients that
///   send no identity share one server: their ids and cancellations can meet.
///
/// Every client counts against `clientLimit` and ends after `idleLimit` with
/// no open stream; an HTTP client that goes away says nothing, unlike
/// `meerkat mcp`, whose stdin closes. The SDK's transports do the rest:
/// framing, SSE, listen streams and the protocol's own header checks.
actor MCPHTTPClients {
    static let clientLimit = 64
    static let idleLimit = Duration.seconds(30 * 60)
    /// The SDK's stateful transport keeps every message it sends, for replay,
    /// until its session ends, and offers no way to bound or turn that off. A
    /// session that has been sent more than this is ended once no request is
    /// being answered, even with a standalone stream open; the specification
    /// has the client begin a new one when it gets 404. This goes when the SDK
    /// bounds its replay log.
    static let replayBudget = 64 << 20

    private enum Key: Hashable {
        case session(String)
        case client(String)
        case anonymous

        /// Whether the client's transport keeps what it sends (`replayBudget`).
        var replays: Bool {
            if case .session = self { return true }
            return false
        }
    }

    private struct Entry {
        /// Tells this entry from a later one under the same key, so a stream
        /// that outlives it is not counted against its successor.
        let id: Int
        let server: Server
        let respond: @Sendable (HTTPRequest) async -> HTTPResponse
        let initialized: MCPProtocol.Initialized
        var lastActive: ContinuousClock.Instant
        /// SSE responses still being written; a client with one is in use
        /// however long ago its last request came.
        var openStreams = 0
        /// Of those, the ones answering a request, rather than the session's
        /// standalone stream, which may stay open as long as the client runs.
        var openRequests = 0
        var bytesSent = 0
    }

    /// Why a client was not opened, as the response to send.
    private struct Refusal: Error {
        let response: HTTPResponse
    }

    private let service: MCPService
    private let token: MCPHTTPToken
    private var clients: [Key: Entry] = [:]
    /// Clients being opened, which count against `clientLimit` while their
    /// server starts: the actor takes other requests during that wait.
    private var opening = 0
    /// Bumped by `endAll`. A client opened under an earlier one was admitted
    /// with a token since replaced, and is not kept.
    private var generation = 0
    private var entries = 0
    private var closed = false
    private var sweep: Task<Void, Never>?
    private let clock = ContinuousClock()
    private static let logger = os.Logger(subsystem: DaemonService.label, category: "mcp-http")

    init(service: MCPService, token: MCPHTTPToken) {
        self.service = service
        self.token = token
    }

    var count: Int { clients.count }

    /// Whether a request may go on, from its head alone, so nothing of an
    /// unadmitted request's body is read: the bearer token, then `Host` and
    /// `Origin`, which must name exactly the listener's `port` (a page served
    /// from another port on this Mac is another origin). Nil admits it.
    nonisolated func admit(_ head: HTTPRequest, port: Int) -> HTTPResponse? {
        guard token.authorizes(head.header(HTTPHeaderName.authorization)) else {
            return .error(
                statusCode: 401, .invalidRequest("Unauthorized: send the token `meerkat mcp http` prints"),
                extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"])
        }
        return OriginValidator.localhost(port: port).validate(
            head, context: HTTPValidationContext(httpMethod: head.method))
    }

    /// One admitted request, answered. The token is checked again here: it
    /// may have been replaced while the body arrived.
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard token.authorizes(request.header(HTTPHeaderName.authorization)) else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized: the token was replaced"))
        }
        guard !closed else { return .error(statusCode: 503, .internalError("meerkatd is stopping")) }
        let generation = generation

        if let id = request.header(HTTPHeaderName.sessionID) {
            guard clients[.session(id)] != nil else {
                return .error(statusCode: 404, .invalidRequest("Not Found: session not found or expired"))
            }
            return await forward(request, to: .session(id))
        }
        guard request.method.uppercased() == "POST", let body = request.body,
            let message = try? JSONDecoder().decode(Message.self, from: body)
        else {
            return .error(statusCode: 400, .invalidRequest("Bad Request: missing \(HTTPHeaderName.sessionID)"))
        }
        if message.isModern || request.header(HTTPHeaderName.protocolVersion).map(Version.isModern) == true {
            let key = request.header(HTTPHeaderName.clientIdentity).map(Key.client) ?? .anonymous
            if clients[key] == nil {
                do {
                    try await open(key, generation: generation) { service, initialized in
                        let transport = StatelessHTTPServerTransport(
                            validationPipeline: StandardValidationPipeline(validators: [
                                AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(),
                                ProtocolVersionValidator(), MCPRoutingHeaderValidator(),
                            ]))
                        let server = try await service.startServer(on: transport, initialized: initialized)
                        return (server, { await transport.handleRequest($0) })
                    }
                } catch {
                    return error.response
                }
            }
            return await forward(request, to: key)
        }
        guard message.method == Initialize.name else {
            return .error(statusCode: 400, .invalidRequest("Bad Request: missing \(HTTPHeaderName.sessionID)"))
        }
        let id = UUID().uuidString
        do {
            try await open(.session(id), generation: generation) { service, initialized in
                let transport = StatefulHTTPServerTransport(
                    sessionIDGenerator: FixedSessionID(id: id),
                    validationPipeline: StandardValidationPipeline(validators: [
                        AcceptHeaderValidator(mode: .sseRequired), ContentTypeValidator(), ProtocolVersionValidator(),
                        MCPRoutingHeaderValidator(), SessionValidator(),
                    ]))
                let server = try await service.startServer(on: transport, initialized: initialized)
                return (server, { await transport.handleRequest($0) })
            }
        } catch {
            return error.response
        }
        // A session is kept only once the SDK accepts its `initialize`. The
        // transport refuses some before the server sees them, answering with
        // an error and no stream; the server refuses others inside a stream,
        // and `streamEnded` ends the session when that stream does.
        let response = await forward(request, to: .session(id))
        if case .stream = response {} else { await end(.session(id)) }
        return response
    }

    /// A JSON-RPC message as far as routing reads it. The SDK's transports
    /// classify the same way but keep their classifier to themselves; this
    /// reads what the 2026-07-28 specification says marks a request as
    /// sessionless: `server/discover`, `subscriptions/listen`, or a 2026-07-28
    /// version in `_meta`. The transport then checks the message in full.
    private struct Message: Decodable {
        let method: String?
        let params: Params?

        struct Params: Decodable {
            let meta: [String: Value]?
            enum CodingKeys: String, CodingKey { case meta = "_meta" }
        }

        var isModern: Bool {
            if method == Discover.name || method == SubscriptionsListen.name { return true }
            return params?.meta?[ProtocolMetaKey.protocolVersion]?.stringValue.map(Version.isModern) == true
        }
    }

    /// Starts a client's server with `make` and keeps it under `key`, unless
    /// the limit is reached, the router closed, the token was replaced since
    /// `generation`, or another request opened the same client meanwhile.
    private func open(
        _ key: Key, generation: Int,
        _ make: (MCPService, MCPProtocol.Initialized) async throws -> (
            Server, @Sendable (HTTPRequest) async -> HTTPResponse
        )
    ) async throws(Refusal) {
        guard clients.count + opening < Self.clientLimit else {
            throw Refusal(
                response: .error(statusCode: 503, .internalError("\(Self.clientLimit) MCP HTTP clients are open")))
        }
        opening += 1
        defer { opening -= 1 }
        let initialized = MCPProtocol.Initialized()
        let made: (server: Server, respond: @Sendable (HTTPRequest) async -> HTTPResponse)
        do {
            made = try await make(service, initialized)
        } catch {
            Self.logger.error("MCP HTTP client's server did not start: \(error, privacy: .public)")
            throw Refusal(response: .error(statusCode: 500, .internalError("the server did not start")))
        }
        guard !closed, generation == self.generation, clients[key] == nil else {
            await made.server.stop()
            if clients[key] != nil { return }
            throw Refusal(
                response: .error(statusCode: 503, .internalError("meerkatd is stopping or the token changed")))
        }
        entries += 1
        clients[key] = Entry(
            id: entries, server: made.server, respond: made.respond, initialized: initialized, lastActive: clock.now)
        if sweep == nil {
            sweep = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await self?.expire()
                }
            }
        }
        Self.logger.info("MCP HTTP client opened")
    }

    private func forward(_ request: HTTPRequest, to key: Key) async -> HTTPResponse {
        guard let entry = clients[key] else {
            return .error(statusCode: 404, .invalidRequest("Not Found: session not found or expired"))
        }
        clients[key]?.lastActive = clock.now
        let response = await entry.respond(request)
        if request.method.uppercased() == "DELETE", response.statusCode == 200 {
            await end(key, ifStill: entry.id)
            return response
        }
        guard case .stream(let stream, let headers) = response, clients[key]?.id == entry.id else { return response }
        let answersRequest = request.method.uppercased() == "POST"
        clients[key]?.openStreams += 1
        if answersRequest { clients[key]?.openRequests += 1 }
        // Copied off the actor, so one client's stream never waits on another's.
        let (relayed, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let pump = Task.detached {
            var bytes = 0
            var failure: (any Error)?
            do {
                for try await chunk in stream {
                    bytes += chunk.count
                    continuation.yield(chunk)
                }
            } catch {
                failure = error
            }
            // Counted before the client sees the end, so what it does next
            // meets the session as this stream left it.
            await self.streamEnded(key, entry: entry.id, answeredRequest: answersRequest, bytes: bytes)
            continuation.finish(throwing: failure)
        }
        continuation.onTermination = { _ in pump.cancel() }
        return .stream(relayed, headers: headers)
    }

    private func streamEnded(_ key: Key, entry id: Int, answeredRequest: Bool, bytes: Int) async {
        guard var entry = clients[key], entry.id == id else { return }
        entry.openStreams -= 1
        if answeredRequest { entry.openRequests -= 1 }
        entry.bytesSent += bytes
        entry.lastActive = clock.now
        clients[key] = entry
        guard entry.openRequests == 0 else { return }
        let refused = key.replays && !entry.initialized.value
        if refused || (key.replays && entry.bytesSent > Self.replayBudget) { await end(key, ifStill: id) }
    }

    /// Ends a client: stopping its server cancels its handlers, samples and
    /// listen streams included.
    private func end(_ key: Key, ifStill id: Int? = nil) async {
        guard let entry = clients[key], id == nil || entry.id == id else { return }
        clients[key] = nil
        await entry.server.stop()
        Self.logger.info("MCP HTTP client ended")
    }

    /// Ends every client idle past `idleLimit` with no open stream, each
    /// checked as it comes: ending one gives the others time to be used.
    private func expire() async {
        for key in Array(clients.keys) {
            guard let entry = clients[key], entry.openStreams == 0, clock.now - entry.lastActive > Self.idleLimit
            else { continue }
            await end(key)
        }
    }

    /// Ends every client: the token changed, and none may outlive the
    /// credential it was opened with. Each listen stream is answered with
    /// `complete` first.
    func endAll() async {
        generation += 1
        for key in Array(clients.keys) {
            try? await clients[key]?.server.completeAllSubscriptionsListen()
            await end(key)
        }
    }

    /// The listener is stopping: ends every client and opens no more.
    func close() async {
        closed = true
        sweep?.cancel()
        sweep = nil
        await endAll()
    }

    private struct FixedSessionID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }
}
