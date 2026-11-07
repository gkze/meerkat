import Foundation
import MCP
import MeerkatKit

// The seam between the daemon's JSON (`JSONValue`) and the SDK's (`Value`).
// Both are plain JSON, so each converts through its encoding: the SDK's
// `Value.init(_:)` takes any `Codable`, and this is the other direction.
// Nothing past the MCP handlers uses the SDK's type for the daemon's data.

extension JSONValue {
    // Qualified: inside this extension `Value` is `ExpressibleByDictionaryLiteral`'s
    // associated type, which is `JSONValue` itself.
    init(mcp value: MCP.Value) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
