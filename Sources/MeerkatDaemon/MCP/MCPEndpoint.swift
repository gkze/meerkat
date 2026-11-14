import Foundation
import MCP
import MeerkatIPC
import os

/// One XPC session's MCP server (docs/design/mcp.md, "One `Server` per XPC
/// session").
///
/// The SDK's `Server` holds one connection's state: the legacy
/// `initialize`, its client capabilities and its in-flight requests. So
/// each session that sends MCP gets its own `Server` and transport, created
/// with the session's first message; the service, the policy and the hub's
/// sources are shared.
final class MCPEndpoint: Sendable {
    private let transport: SessionTransport
    /// Starts the server, every handler installed first; input queues in the
    /// transport until then. `close` waits for it so it never stops a
    /// half-started server. Nil when the server did not start.
    private let started: Task<Server?, Never>
    private static let logger = os.Logger(subsystem: DaemonService.label, category: "mcp")

    init(service: MCPService, push: @escaping @Sendable (Data) throws -> Void) {
        let transport = SessionTransport(push: push)
        self.transport = transport
        started = Task {
            do {
                let server = try await service.startServer(on: transport, initialized: MCPProtocol.Initialized())
                Self.logger.info("MCP session started")
                return server
            } catch {
                Self.logger.error("MCP server did not start: \(error, privacy: .public)")
                transport.finish()
                return nil
            }
        }
    }

    /// Queues one message from the client, in arrival order.
    func deliver(_ message: Data) throws(SessionTransport.DeliveryError) {
        try transport.deliver(message)
    }

    /// The client is gone (its XPC session was cancelled): stop the server,
    /// which cancels its in-flight handlers, samples and listen streams
    /// included. Their subscriptions are released as those tasks end.
    func close() async {
        transport.finish()
        await started.value?.stop()
        Self.logger.info("MCP session ended")
    }

    /// The daemon is stopping: answer each open listen stream with
    /// `complete` first, so the client can tell a clean end from a dropped
    /// connection, then close.
    func shutdown() async {
        try? await started.value?.completeAllSubscriptionsListen()
        await close()
    }
}
