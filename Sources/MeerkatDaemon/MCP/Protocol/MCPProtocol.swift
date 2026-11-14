import Foundation
import MCP
import Synchronization

/// What the MCP Swift SDK (with #314) leaves to the server, and nothing else
/// (docs/design/mcp.md, "The protocol layer is the part to shrink"): caching
/// hints, and rejecting a request that names no version outside a session
/// begun with `initialize`. Each part goes when an SDK release covers it.
///
/// The SDK itself answers `initialize`, `server/discover` and
/// `subscriptions/listen`, checks each 2026-07-28 request's `_meta` version
/// and client capabilities, answers an unsupported version with `-32022`, and
/// stamps 2026-07-28 results with `resultType` and server identity.
enum MCPProtocol {
    /// Whether a server's client began with an accepted `initialize`, so a
    /// request that names no version was made under the version it agreed.
    /// Set from the SDK's own `initializeHook`, which runs exactly when the
    /// SDK accepts `initialize`: it keeps that state to itself. A 2026-07-28
    /// client never sends `initialize`, so its record stays unset.
    final class Initialized: Sendable {
        private let accepted = Atomic(false)

        var value: Bool { accepted.load(ordering: .acquiring) }

        func record() { accepted.store(true, ordering: .releasing) }
    }

    /// Registers `handler` for `M` behind the era check.
    static func serve<M: MCP.Method>(
        _ type: M.Type, on server: Server, initialized: Initialized,
        _ handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) async {
        await server.withMethodHandler(M.self) { parameters in
            _ = try isModern(initialized)
            return try await handler(parameters)
        }
    }

    /// Registers `handler` for `M`, whose 2026-07-28 result must carry caching
    /// hints that the SDK's result types have no fields for (upstream issue
    /// #243). Everything served this way reflects the running daemon (its
    /// rules, its status, the policy), so it is never fresh for reuse
    /// (`ttlMs: 0`), and it describes this user's machine (`private`).
    static func serveCached<M: MCP.Method>(
        _ type: M.Type, on server: Server, initialized: Initialized,
        _ handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) async {
        await server.withMethodHandler(Cached<M>.self) { parameters in
            let modern = try isModern(initialized)
            let result = try await handler(parameters)
            return modern ? Cached<M>.Result(result, ttlMs: 0, cacheScope: .private) : Cached<M>.Result(result)
        }
    }

    /// Whether the request being handled is 2026-07-28; throws for a request
    /// that names no version outside a session that began with `initialize`.
    ///
    /// The SDK has already checked a 2026-07-28 request: it carries client
    /// capabilities in `_meta`, which the SDK requires of every such request.
    /// Any other request was made under the version `initialize` negotiated.
    /// Without one, the SDK would serve the request as legacy (or, in strict
    /// mode, drop it unanswered); the specification asks for `-32602`.
    static func isModern(_ initialized: Initialized) throws -> Bool {
        if Server.currentHandlerContext?.clientCapabilities != nil { return true }
        guard initialized.value else {
            throw MCPError.invalidParams("request _meta is missing \(ProtocolMetaKey.protocolVersion)")
        }
        return false
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
}
