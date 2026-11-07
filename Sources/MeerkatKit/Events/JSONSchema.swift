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
            case .number: return ["type": "number"]
            case .bounded(let bounds):
                var fields: [String: JSONValue] = ["type": bounds.integer ? "integer" : "number"]
                if let minimum = bounds.minimum { fields["minimum"] = .number(minimum) }
                if let maximum = bounds.maximum { fields["maximum"] = .number(maximum) }
                return .object(fields)
            case .boolean: return ["type": "boolean"]
            case .json: return .object([:])
            case .enumeration(let cases): return ["type": "string", "enum": .array(cases.map { .string($0) })]
            case .array(let element): return ["type": "array", "items": node(element)]
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
                if let doc = field.doc, !doc.isEmpty, case .object(var fields) = property {
                    fields["description"] = .string(doc)
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
