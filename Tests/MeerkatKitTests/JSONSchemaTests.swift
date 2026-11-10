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
        let parameters = JSONSchema.document(.object(kind.parametersSchema))
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
        #expect(JSONSchema.document(.object(kind.parametersSchema))["type"] == "object")
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
            .init("label", .text(TextBounds(1...8)), default: "x"),
            .init("few", .array(.string, .atMost(2)), optional: true),
            .init("wait", .bounded(.positive(atMost: 5)), optional: true),
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
        // Bounds and defaults have keywords; the description stays the doc.
        #expect(document["properties"]?["label"] == ["type": "string", "minLength": 1, "maxLength": 8, "default": "x"])
        #expect(document["properties"]?["few"]?["maxItems"] == 2)
        // A maximum counted over distinct items is not JSON Schema's, which
        // counts duplicates: the projection leaves it out, staying looser.
        let distinct = JSONSchema.document(
            .object(ObjectSchema([.init("names", .array(.string, ItemBounds(1, 4, distinct: true)))])))
        #expect(distinct["properties"]?["names"]?["minItems"] == 1)
        #expect(distinct["properties"]?["names"]?["maxItems"] == nil)
        #expect(document["properties"]?["wait"]?["exclusiveMinimum"] == 0)
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
            // Out of a string's, a list's and a number's bounds.
            ["name": "x", "inner": ["count": 1], "again": [], "tags": [:], "label": ""],
            ["name": "x", "inner": ["count": 1], "again": [], "tags": [:], "label": "ninechars"],
            ["name": "x", "inner": ["count": 1], "again": [], "tags": [:], "few": ["a", "b", "c"]],
            ["name": "x", "inner": ["count": 1], "again": [], "tags": [:], "wait": 0],
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
        "description", "minimum", "maximum", "$schema", "title", "minLength", "maxLength", "minItems", "maxItems",
        "exclusiveMinimum", "default", "pattern",
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
        case ("string"?, .string(let text)):
            // JSON Schema counts code points.
            let length = Double(text.unicodeScalars.count)
            if let minimum = keywords["minLength"]?.numberValue, length < minimum { return ["\(path): too short"] }
            if let maximum = keywords["maxLength"]?.numberValue, length > maximum { return ["\(path): too long"] }
            if let pattern = keywords["pattern"]?.stringValue,
                text.range(of: pattern, options: .regularExpression) == nil
            {
                return ["\(path): does not match \(pattern)"]
            }
            return []
        case (nil, _), ("boolean"?, .bool):
            return []
        case ("number"?, .number(let number)), ("integer"?, .number(let number)):
            if keywords["type"] == "integer", number.rounded() != number { return ["\(path): \(number) is not whole"] }
            if let minimum = keywords["minimum"]?.numberValue, number < minimum { return ["\(path): below minimum"] }
            if let minimum = keywords["exclusiveMinimum"]?.numberValue, number <= minimum {
                return ["\(path): not above exclusiveMinimum"]
            }
            if let maximum = keywords["maximum"]?.numberValue, number > maximum { return ["\(path): above maximum"] }
            return []
        case ("array"?, .array(let items)):
            if let maximum = keywords["maxItems"]?.numberValue, Double(items.count) > maximum {
                return ["\(path): too many items"]
            }
            if let minimum = keywords["minItems"]?.numberValue, Double(items.count) < minimum {
                return ["\(path): too few items"]
            }
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

/// The generated declarations state a field's bounds and default from the
/// schema, so neither is written in its doc.
struct FieldDocumentationTests {
    typealias Field = ObjectSchema.Field

    @Test func boundsAndDefaultFollowTheDoc() {
        #expect(
            Field("interval", .bounded(NumberBounds(1...3600)), default: 5, doc: "Seconds between samples")
                .documentation
                == "Seconds between samples, 1–3600. Default 5.")
        #expect(
            Field("id", .text(.name(256)), doc: "The rule's own name.").documentation
                == "The rule's own name. 1–256 bytes, one line.")
        #expect(Field("sound", .boolean, default: false).documentation == "Default false.")
        #expect(Field("wait", .bounded(.positive(atMost: 30))).documentation == "More than 0, at most 30.")
        #expect(Field("plain", .string).documentation == nil)
    }

    @Test func textBoundsCountBytesAndRefuseNUL() {
        let bounds = TextBounds(1...4)
        #expect(bounds.violation("abcd") == nil)
        #expect(bounds.violation("é é") != nil)
        #expect(bounds.violation("") != nil)
        #expect(bounds.violation("a\u{0}") != nil)
        #expect(TextBounds.name(8).violation("a\nb") != nil)
        #expect(TextBounds(1...8).violation("a\nb") == nil)
    }
}
