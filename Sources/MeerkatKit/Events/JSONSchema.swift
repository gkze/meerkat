import Foundation

/// Projects a `TypeSchema` to JSON Schema (draft 2020-12, the dialect MCP
/// assumes when a schema names none), for clients that describe data that way.
///
/// `TypeSchema` stays the authority; this is a projection, like
/// `TypeScriptDeclarations`. It keeps the same strictness as
/// `SchemaValidator`: objects reject undeclared fields, optional fields are
/// absent rather than `null`, and a `.json` value accepts anything. The
/// conformance test runs every catalog example through the projected schema.
///
/// A `.named` object nested anywhere is declared once under `$defs` and
/// referenced by `$ref`, so a recursive or shared type is written once. The
/// root itself is written inline, because MCP requires a tool's input schema
/// to be an object schema at the top level, not a reference.
public enum JSONSchema {
    /// A standalone schema document for `schema`.
    public static func document(_ schema: TypeSchema) -> JSONValue {
        var definitions: [String: JSONValue] = [:]
        var seen: [String: ObjectSchema] = [:]

        func node(_ schema: TypeSchema, root: Bool = false) -> JSONValue {
            switch schema {
            case .string: return ["type": "string"]
            case .text(let bounds):
                // JSON Schema counts code points, the bounds count UTF-8
                // bytes: a byte maximum is also a code-point maximum, and a
                // minimum of one byte is one code point. The projection is
                // looser than the validator, never stricter.
                var fields: [String: JSONValue] = ["type": "string", "maxLength": .number(Double(bounds.maximum))]
                if bounds.minimum > 0 { fields["minLength"] = 1 }
                if let pattern = bounds.pattern { fields["pattern"] = .string(pattern.regex) }
                return .object(fields)
            case .number: return ["type": "number"]
            case .bounded(let bounds):
                var fields: [String: JSONValue] = ["type": bounds.integer ? "integer" : "number"]
                if let minimum = bounds.minimum {
                    fields[bounds.exclusiveMinimum ? "exclusiveMinimum" : "minimum"] = .number(minimum)
                }
                if let maximum = bounds.maximum { fields["maximum"] = .number(maximum) }
                return .object(fields)
            case .boolean: return ["type": "boolean"]
            case .json: return .object([:])
            case .enumeration(let cases): return ["type": "string", "enum": .array(cases.map { .string($0) })]
            case .array(let element, let bounds):
                var fields: [String: JSONValue] = ["type": "array", "items": node(element)]
                if bounds.minimum > 0 { fields["minItems"] = .number(Double(bounds.minimum)) }
                // JSON Schema counts duplicates, which a `distinct` maximum
                // does not: left out, so the projection stays the looser.
                if let maximum = bounds.maximum, !bounds.distinct { fields["maxItems"] = .number(Double(maximum)) }
                return .object(fields)
            case .record(let element): return ["type": "object", "additionalProperties": node(element)]
            case .object(let object): return objectNode(object)
            case .named(let name, let object):
                if root { return objectNode(object) }
                if let existing = seen[name] {
                    // As in `TypeScriptDeclarations`: one name, one shape.
                    precondition(existing == object, "schema name \(name) declared with two shapes")
                } else {
                    // Recorded before its fields are visited, so a type that
                    // contains itself ends in a reference instead of looping.
                    seen[name] = object
                    definitions[name] = objectNode(object)
                }
                return ["$ref": .string("#/$defs/\(name)")]
            }
        }

        func objectNode(_ object: ObjectSchema) -> JSONValue {
            var properties: [String: JSONValue] = [:]
            for field in object.fields {
                var property = node(field.schema)
                // Bounds and the default have keywords of their own, so the
                // description is the doc alone.
                if case .object(var fields) = property {
                    if let doc = field.doc, !doc.isEmpty { fields["description"] = .string(doc) }
                    if let value = field.default { fields["default"] = value }
                    property = .object(fields)
                }
                properties[field.name] = property
            }
            var result: [String: JSONValue] = [
                "type": "object",
                "properties": .object(properties),
                "additionalProperties": false,
            ]
            let required = object.fields.filter { !$0.optional }.map { JSONValue.string($0.name) }
            if !required.isEmpty { result["required"] = .array(required) }
            return .object(result)
        }

        var top = node(schema, root: true)
        if !definitions.isEmpty, case .object(var fields) = top {
            fields["$defs"] = .object(definitions)
            top = .object(fields)
        }
        return top
    }
}
