import Foundation
import MeerkatIPC
import MeerkatKit

/// What MCP clients may reach, and how much each call may cost
/// (docs/design/mcp.md, "Harm model"): `meerkat.json`'s `mcp` section as
/// the server applies it. `DaemonSettings` hands out the current one, so a
/// change to the file applies to the next request.
struct MCPPolicy: Sendable {
    var limits: MeerkatConfiguration.MCP.Limits
    var events: MeerkatConfiguration.MCP.Events

    init(_ configuration: MeerkatConfiguration.MCP) {
        limits = configuration.limits
        events = configuration.events
    }

    /// The defaults: what applies with no `meerkat.json`.
    static let standard = MCPPolicy(MeerkatConfiguration.MCP())

    /// Kinds delivered only to rules are never sampleable: the hub refuses
    /// every external subscriber to them.
    func allows(_ kind: AnyEventKind) -> Bool { kind.audience == .everyone && events.allows(kind.descriptor) }

    /// The kinds `events_sample` accepts, in catalog order.
    func sampleableKinds(_ catalog: EventCatalog) -> [String] {
        catalog.kinds.filter(allows).map(\.descriptor.name)
    }
}
