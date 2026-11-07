import Foundation
import MCP

/// What the MCP Swift SDK (with #314) leaves to the server on a transport
/// other than HTTP, and nothing else (docs/design/mcp.md, "The protocol layer
/// is the part to shrink"). Each part goes when an SDK release covers it.
///
/// The SDK itself answers `initialize` and `server/discover`, checks each
/// 2026-07-28 request's `_meta` version and client capabilities, answers an
/// unsupported version with `-32022`, and stamps 2026-07-28 results with
/// `resultType` and server identity.
enum MCPProtocol {
    /// Registers `handler` for `M` behind the era check.
    static func serve<M: MCP.Method>(
        _ type: M.Type, on server: Server, transport: SessionTransport,
        _ handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) async {
        await server.withMethodHandler(M.self) { parameters in
            _ = try await isModern(transport)
            return try await handler(parameters)
        }
    }

    /// Registers `handler` for `M`, whose 2026-07-28 result must carry caching
    /// hints that the SDK's result types have no fields for (upstream issue
    /// #243). Everything served this way reflects the running daemon (its
    /// rules, its status, the policy), so it is never fresh for reuse
    /// (`ttlMs: 0`), and it describes this user's machine (`private`).
    static func serveCached<M: MCP.Method>(
        _ type: M.Type, on server: Server, transport: SessionTransport,
        _ handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) async {
        await server.withMethodHandler(Cached<M>.self) { parameters in
            let modern = try await isModern(transport)
            let result = try await handler(parameters)
            return modern ? Cached<M>.Result(result, ttlMs: 0, cacheScope: .private) : Cached<M>.Result(result)
        }
    }

    /// Replaces the SDK's `subscriptions/listen` handler, which outside HTTP
    /// only holds the request open. This one acknowledges the subset of the
    /// filter `grant` returns (`notifications/subscriptions/acknowledged`,
    /// tagged with the stream's id) and holds the stream until the client
    /// cancels it, the session ends, or the server completes it.
    ///
    /// Must be registered after `Server.start`, which installs the SDK's own.
    static func serveListen(
        on server: Server,
        grant: @escaping @Sendable (SubscriptionsListen.NotificationFilter) -> SubscriptionsListen.NotificationFilter
    ) async {
        await server.withMethodHandler(SubscriptionsListen.self) { parameters in
            guard let id = Server.currentHandlerContext?.id else {
                throw MCPError.internalError("listen outside a request")
            }
            let granted = grant(parameters.notifications)
            try await server.notify(Acknowledged.message(.init(notifications: granted, _meta: tagged(id))))
            // Cancellation (`notifications/cancelled`, or the session ending) ends
            // the task; the SDK then sends no response, as the specification
            // requires. `completeSubscriptionsListen` answers it with `complete`.
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
    }

    /// Whether the request being handled is 2026-07-28; throws for a request
    /// that names no version outside a session that began with `initialize`.
    ///
    /// The SDK has already checked a 2026-07-28 request: it carries client
    /// capabilities in `_meta`, which the SDK requires of every such request.
    /// Any other request was made under the version `initialize` negotiated,
    /// which the transport recorded. Without one, the SDK would serve the
    /// request as legacy (or, in strict mode, drop it unanswered); the
    /// specification asks for `-32602`.
    static func isModern(_ transport: SessionTransport) async throws -> Bool {
        if Server.currentHandlerContext?.clientCapabilities != nil { return true }
        guard await transport.initializedVersion != nil else {
            throw MCPError.invalidParams("request _meta is missing \(ProtocolMetaKey.protocolVersion)")
        }
        return false
    }

    /// `_meta` naming a listen stream: the JSON-RPC id of its request, as the
    /// client sent it.
    static func tagged(_ id: ID) -> Metadata {
        let value: Value =
            switch id {
            case .string(let string): .string(string)
            case .number(let number): .int(number)
            }
        return Metadata(additionalFields: [ProtocolMetaKey.subscriptionId: value])
    }

    /// `M` with its result extended by the 2026-07-28 caching hints.
    enum Cached<M: MCP.Method>: MCP.Method {
        static var name: String { M.name }
        typealias Parameters = M.Parameters

        struct Result: Hashable, Codable, Sendable {
            var base: M.Result
            var ttlMs: Int?
            var cacheScope: Discover.CacheScope?

            init(_ base: M.Result, ttlMs: Int? = nil, cacheScope: Discover.CacheScope? = nil) {
                self.base = base
                self.ttlMs = ttlMs
                self.cacheScope = cacheScope
            }

            private enum CodingKeys: String, CodingKey { case ttlMs, cacheScope }

            // The hints sit beside the base result's own fields in one object.
            init(from decoder: any Decoder) throws {
                base = try M.Result(from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                ttlMs = try container.decodeIfPresent(Int.self, forKey: .ttlMs)
                cacheScope = try container.decodeIfPresent(Discover.CacheScope.self, forKey: .cacheScope)
            }

            func encode(to encoder: any Encoder) throws {
                try base.encode(to: encoder)
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
                try container.encodeIfPresent(cacheScope, forKey: .cacheScope)
            }
        }
    }

    /// `notifications/subscriptions/acknowledged`, which the SDK does not define.
    struct Acknowledged: MCP.Notification {
        static let name = "notifications/subscriptions/acknowledged"
        struct Parameters: Hashable, Codable, Sendable {
            var notifications: SubscriptionsListen.NotificationFilter
            var _meta: Metadata
        }
    }
}
