import Foundation
import MeerkatIPC
import os

/// MCP over Streamable HTTP, beside `meerkat mcp` (docs/design/mcp.md,
/// "Transport: Streamable HTTP"), as `meerkat.json`'s `mcp.http` asks.
///
/// It serves the same `MCPService` as the XPC sessions; how a client reaches
/// it differs, and what an HTTP client may cost is bounded in
/// `MCPHTTPListener` and `MCPHTTPClients`. `apply` follows the file: a
/// changed port or switch ends every HTTP client and binds again. A port that
/// cannot be bound, or a token that cannot be read, leaves the listener off
/// with the reason in `status`, and the next reload of the file tries again;
/// XPC clients are not affected either way.
actor MCPHTTPServer {
    private enum State {
        case off
        case listening(MCPHTTPListener, MCPHTTPClients)
        case failed(String)
    }

    private let token: MCPHTTPToken
    private var state = State.off
    /// What `state` was made from; nil after a failure, so the same
    /// configuration is tried again.
    private var applied: MeerkatConfiguration.MCP.HTTP?
    private let logger = Logger(subsystem: DaemonService.label, category: "mcp-http")

    init(token: MCPHTTPToken = MCPHTTPToken()) {
        self.token = token
    }

    /// Listens as `http` says, serving `service`, when that differs from what
    /// applies now. The service is passed here, not at init, because the
    /// daemon's status, which the service reads, includes this listener's.
    func apply(_ http: MeerkatConfiguration.MCP.HTTP, serving service: MCPService) async {
        guard http != applied else { return }
        await stop()
        guard http.enabled else {
            applied = http
            return
        }
        do {
            // Loaded before the first request, which `authorizes` reads from memory.
            _ = try token.current()
            let clients = MCPHTTPClients(service: service, token: token)
            let listener = try await MCPHTTPListener.start(port: http.port, clients: clients)
            state = .listening(listener, clients)
            applied = http
            logger.info("MCP HTTP listening on \(listener.url, privacy: .public)")
        } catch {
            state = .failed("\(error)")
            logger.error("MCP HTTP not listening on port \(http.port): \(error, privacy: .public)")
        }
    }

    var status: MCPHTTPStatus {
        get async {
            switch state {
            case .off: .off
            case .listening(let listener, let clients):
                MCPHTTPStatus(state: .listening, url: listener.url, problem: nil, clients: await clients.count)
            case .failed(let problem): MCPHTTPStatus(state: .failed, url: nil, problem: problem, clients: 0)
            }
        }
    }

    /// The URL and token, for `meerkat mcp http`. Rotating ends every HTTP
    /// client, since each was admitted with the old token.
    func access(rotateToken: Bool) async throws -> MCPHTTPAccess {
        let value: String
        if rotateToken {
            value = try token.rotate()
            if case .listening(_, let clients) = state { await clients.endAll() }
            logger.info("MCP HTTP token replaced")
        } else {
            value = try token.current()
        }
        return MCPHTTPAccess(status: await status, token: value)
    }

    func stop() async {
        guard case .listening(let listener, let clients) = state else {
            state = .off
            return
        }
        state = .off
        applied = nil
        // Clients first: each listen stream is answered with `complete` before
        // its connection is closed, though nothing waits for the client to
        // have read it.
        await clients.close()
        await listener.stop()
    }
}
