import Foundation
import Testing

@testable import MeerkatKit

/// The JSON Schema projection of `TypeSchema` accepts what the source schema
/// accepts and rejects what it rejects. Every catalog example goes through
/// the projected schema, and hand-made counterexamples check the strictness
/// `SchemaValidator` enforces (undeclared fields, missing required fields,
/// `null` for an optional field).
struct JSONSchemaTests {
    @Test(arguments: EventCatalog.standard.kinds.map(\.name))
    func catalogExamplesMatchProjection(_ name: String) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        let payload = JSONSchema.document(kind.payloadSchema)
        for example in try kind.payloadExamples() {
            let problems = SubsetValidator(payload).violations(of: example)
            #expect(problems.isEmpty, "\(name) payload: \(problems)")
        }
        let parameters = JSONSchema.document(kind.parametersSchema)
        for example in try kind.parameterExamples() {
            let problems = SubsetValidator(parameters).violations(of: example)
            #expect(problems.isEmpty, "\(name) parameters: \(problems)")
        }
    }

    /// The parameters schema is what MCP clients see as input: it must be an
    /// object schema at the top, not a reference.
    @Test(arguments: EventCatalog.standard.kinds.map(\.name))
    func parametersAreObjectSchemas(_ name: String) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        #expect(JSONSchema.document(kind.parametersSchema)["type"] == "object")
    }

    static let sample = TypeSchema.named(
        "Outer",
        ObjectSchema([
            .init("name", .string, doc: "A name."),
            .init("mode", .enumeration(["fast", "slow"]), optional: true),
            .init("inner", .named("Inner", ObjectSchema([.init("count", .number)]))),
            .init("again", .array(.named("Inner", ObjectSchema([.init("count", .number)])))),
            .init("tags", .record(.boolean)),
            .init("anything", .json, optional: true),
        ]))

    @Test func shapeOfProjection() {
        let document = JSONSchema.document(Self.sample)
        #expect(document["type"] == "object")
        #expect(document["required"] == ["name", "inner", "again", "tags"])
        #expect(document["additionalProperties"] == false)
        #expect(document["properties"]?["name"] == ["type": "string", "description": "A name."])
        // A named type is declared once and referenced from both uses.
        #expect(document["properties"]?["inner"] == ["$ref": "#/$defs/Inner"])
        #expect(document["properties"]?["again"]?["items"] == ["$ref": "#/$defs/Inner"])
        #expect(document["$defs"]?.objectValue?.keys.sorted() == ["Inner"])
        #expect(document["properties"]?["anything"] == .object([:]))
    }

    @Test func projectionAgreesWithSchemaValidator() {
        let valid: JSONValue = [
            "name": "x", "inner": ["count": 1], "again": [["count": 2]], "tags": ["a": true],
        ]
        let counterexamples: [JSONValue] = [
            // Undeclared field.
            ["name": "x", "inner": ["count": 1], "again": [], "tags": [:], "extra": 1],
            // Missing required field.
            ["name": "x", "again": [], "tags": [:]],
            // Optional fields are absent, never null.
            ["name": "x", "inner": ["count": 1], "again": [], "tags": [:], "mode": .null],
            // Not one of the enumeration's values.
            ["name": "x", "inner": ["count": 1], "again": [], "tags": [:], "mode": "medium"],
            // Wrong type inside a reference and inside a record.
            ["name": "x", "inner": ["count": "1"], "again": [], "tags": [:]],
            ["name": "x", "inner": ["count": 1], "again": [], "tags": ["a": 1]],
        ]
        let validator = SubsetValidator(JSONSchema.document(Self.sample))
        #expect(validator.violations(of: valid).isEmpty)
        #expect(SchemaValidator.violations(of: valid, against: Self.sample).isEmpty)
        for value in counterexamples {
            #expect(!validator.violations(of: value).isEmpty, "\(value)")
            #expect(!SchemaValidator.violations(of: value, against: Self.sample).isEmpty, "\(value)")
        }
    }

    @Test func recursiveNamedTypeEndsInReference() {
        // A tree whose children are trees.
        let tree = TypeSchema.named(
            "Tree", ObjectSchema([.init("children", .array(.named("Tree", ObjectSchema([]))))]))
        let document = JSONSchema.document(tree)
        #expect(document["properties"]?["children"]?["items"] == ["$ref": "#/$defs/Tree"])
    }
}

/// Validates against exactly the keywords `JSONSchema` writes. Any other
/// keyword is reported, so a projection that starts emitting one fails here
/// until this validator, and so the conformance argument, covers it.
private struct SubsetValidator {
    let root: JSONValue

    init(_ root: JSONValue) { self.root = root }

    static let keywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "enum", "$ref", "$defs",
        "description", "minimum", "maximum", "$schema", "title",
    ]

    func violations(of value: JSONValue) -> [String] { check(value, against: root, at: "$") }

    private func check(_ value: JSONValue, against schema: JSONValue, at path: String) -> [String] {
        if case .bool(let allowed) = schema { return allowed ? [] : ["\(path): no value is allowed"] }
        guard case .object(let keywords) = schema else { return ["\(path): schema is not an object"] }
        if let unknown = keywords.keys.first(where: { !Self.keywords.contains($0) }) {
            return ["\(path): unsupported keyword \(unknown)"]
        }
        if case .string(let reference)? = keywords["$ref"] {
            let name = String(reference.dropFirst("#/$defs/".count))
            guard reference.hasPrefix("#/$defs/"), let target = root["$defs"]?[name] else {
                return ["\(path): unresolved reference \(reference)"]
            }
            return check(value, against: target, at: path)
        }
        if case .array(let cases)? = keywords["enum"], !cases.contains(value) {
            return ["\(path): \(value) is not one of \(cases)"]
        }
        switch (keywords["type"], value) {
        case (nil, _), ("string"?, .string), ("boolean"?, .bool):
            return []
        case ("number"?, .number(let number)), ("integer"?, .number(let number)):
            if keywords["type"] == "integer", number.rounded() != number { return ["\(path): \(number) is not whole"] }
            if let minimum = keywords["minimum"]?.numberValue, number < minimum { return ["\(path): below minimum"] }
            if let maximum = keywords["maximum"]?.numberValue, number > maximum { return ["\(path): above maximum"] }
            return []
        case ("array"?, .array(let items)):
            guard let element = keywords["items"] else { return [] }
            return items.enumerated().flatMap { check($1, against: element, at: "\(path)[\($0)]") }
        case ("object"?, .object(let fields)):
            let properties = keywords["properties"]?.objectValue ?? [:]
            var problems: [String] = []
            for case .string(let name) in keywords["required"]?.arrayValue ?? [] where fields[name] == nil {
                problems.append("\(path).\(name): required field is missing")
            }
            for (name, item) in fields.sorted(by: { $0.key < $1.key }) {
                if let property = properties[name] {
                    problems += check(item, against: property, at: "\(path).\(name)")
                } else if let additional = keywords["additionalProperties"] {
                    problems += check(item, against: additional, at: "\(path).\(name)")
                }
            }
            return problems
        default:
            return ["\(path): \(value) does not have type \(keywords["type"] ?? .null)"]
        }
    }
}
