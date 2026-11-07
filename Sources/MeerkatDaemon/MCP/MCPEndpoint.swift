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
    private let server: Server
    /// Starts the server and installs the handlers before any input is let
    /// through; `close` waits for it so it never stops a half-started server.
    private let started: Task<Void, Never>
    private static let logger = os.Logger(subsystem: DaemonService.label, category: "mcp")

    init(service: MCPService, push: @escaping @Sendable (Data) throws -> Void) {
        let transport = SessionTransport(push: push)
        // Not `.strict`: the SDK's strict mode drops a request that comes before
        // `initialize` without answering it. `MCPProtocol.isModern` rejects such
        // a request instead.
        let server = Server(
            name: "meerkatd", version: Daemon.version, title: "Meerkat",
            instructions: MCPService.instructions, capabilities: MCPService.capabilities)
        let slots = SampleSlots { service.policy.limits.concurrentSamples }
        self.transport = transport
        self.server = server
        started = Task {
            do {
                try await server.start(transport: transport)
            } catch {
                Self.logger.error("MCP server did not start: \(error, privacy: .public)")
                transport.finish()
                return
            }
            await service.register(on: server, transport: transport, slots: slots)
            await transport.open()
            Self.logger.info("MCP session started")
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
        await started.value
        await server.stop()
        Self.logger.info("MCP session ended")
    }

    /// The daemon is stopping: answer each open listen stream with
    /// `complete` first, so the client can tell a clean end from a dropped
    /// connection, then close.
    func shutdown() async {
        await started.value
        try? await server.completeAllSubscriptionsListen()
        await close()
    }
}
