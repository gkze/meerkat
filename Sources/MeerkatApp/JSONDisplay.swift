import Foundation
import MeerkatKit

// Generic rendering of event payloads. The explorer knows no payload types,
// so everything it shows is derived from the JSON itself.

extension JSONValue {
    /// One line for a table cell: scalars in full, containers by size,
    /// object fields in key order.
    var summary: String {
        switch self {
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            return fields.sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value.inlineText)" }
                .joined(separator: "   ")
        case .array(let items):
            return items.isEmpty ? "[]" : items.map(\.inlineText).joined(separator: ", ")
        default:
            return inlineText
        }
    }

    /// A scalar as text, or a container as its size.
    var inlineText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return Self.format(value)
        case .string(let value): return value
        case .array(let items): return "[\(items.count)]"
        case .object(let fields): return "{\(fields.count)}"
        }
    }

    var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }

    var prettyPrinted: String {
        guard let data = try? JSONEncoder.meerkat(pretty: true).encode(self) else { return inlineText }
        return String(decoding: data, as: UTF8.self)
    }

    /// Integers without a fraction (pids, counts, byte totals); other numbers
    /// to at most four places. Never grouped, so values read as data.
    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...4)))
    }
}

/// A payload as a tree for `OutlineGroup`.
struct JSONNode: Identifiable {
    /// The path from the payload root. Array elements are keyed by index:
    /// a node only ever describes one immutable payload, and the outline is
    /// rebuilt (by view identity) when the selected event changes.
    let id: String
    let key: String
    let value: JSONValue
    /// For an array element, the value of its first identifying field, so
    /// a collapsed row reads `[0] en0` rather than a bare index.
    var hint: String? = nil

    /// Fields that name an array element, in order of preference.
    static let identifyingFields = ["name", "path", "pid"]

    var children: [JSONNode]? {
        switch value {
        case .object(let fields):
            return fields.sorted(by: { $0.key < $1.key }).map {
                JSONNode(id: "\(id).\($0.key)", key: $0.key, value: $0.value)
            }
        case .array(let items):
            return items.enumerated().map {
                JSONNode(
                    id: "\(id)[\($0.offset)]", key: "[\($0.offset)]", value: $0.element,
                    hint: Self.identifyingText(of: $0.element))
            }
        default:
            return nil
        }
    }

    /// The first identifying field holding a scalar, if `value` is an object.
    static func identifyingText(of value: JSONValue) -> String? {
        guard case .object(let fields) = value else { return nil }
        for field in identifyingFields {
            guard let candidate = fields[field], !candidate.isContainer, candidate != .null else { continue }
            return candidate.inlineText
        }
        return nil
    }

    /// The top-level rows for a payload. A scalar payload is one row.
    static func roots(of payload: JSONValue) -> [JSONNode] {
        JSONNode(id: "$", key: "value", value: payload).children
            ?? [JSONNode(id: "$", key: "value", value: payload)]
    }
}
