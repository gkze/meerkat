import Foundation

/// The shape of an event payload or parameter set, as TypeScript sees it.
///
/// Swift has no reflection that recovers a `Codable` type's JSON shape, so each
/// payload states its schema next to its declaration. Two checks keep them in
/// step: `SchemaValidator` runs every catalog example through its schema in
/// the tests, and the generated `meerkat.d.ts` is compared with the checked-in
/// copy.
public indirect enum TypeSchema: Sendable, Equatable {
    case string
    case number
    /// A number within bounds, a whole number when `integer` is set. Event
    /// payloads say only `number`; configuration declares its ranges so the
    /// generated JSON Schema and the validator enforce the same ones.
    case bounded(NumberBounds)
    case boolean
    /// A string restricted to these values, emitted as a union of literals.
    case enumeration([String])
    case array(TypeSchema)
    /// String keys mapping to values of one schema.
    case record(TypeSchema)
    /// Any JSON value.
    case json
    case object(ObjectSchema)
    /// A named object declared once in the generated file and referenced by
    /// name everywhere else.
    case named(String, ObjectSchema)
}

extension TypeSchema {
    /// The object behind `.object` and `.named`; nil for every other case.
    public var objectSchema: ObjectSchema? {
        switch self {
        case .object(let object), .named(_, let object): return object
        default: return nil
        }
    }
}

public struct NumberBounds: Sendable, Equatable {
    public var minimum: Double?
    public var maximum: Double?
    public var integer: Bool

    public init(minimum: Double? = nil, maximum: Double? = nil, integer: Bool = false) {
        self.minimum = minimum
        self.maximum = maximum
        self.integer = integer
    }

    /// A whole number in `range`.
    public static func integer(_ range: ClosedRange<Int>) -> Self {
        Self(minimum: Double(range.lowerBound), maximum: Double(range.upperBound), integer: true)
    }

    /// Why `value` is out of bounds, or nil.
    func violation(_ value: Double) -> String? {
        let shown = Self.format(value)
        if integer, value.rounded() != value { return "\(shown) is not a whole number" }
        if let minimum, value < minimum { return "\(shown) is less than \(Self.format(minimum))" }
        if let maximum, value > maximum { return "\(shown) is more than \(Self.format(maximum))" }
        return nil
    }

    /// A bound as people write it: `30`, not `30.0`.
    public static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

public struct ObjectSchema: Sendable, Equatable {
    public var fields: [Field]

    public init(_ fields: [Field]) {
        self.fields = fields
    }

    public struct Field: Sendable, Equatable {
        public var name: String
        public var schema: TypeSchema
        /// Optional fields may be absent from the JSON. They are never `null`
        /// (payloads encode nil by omitting the key), unless the schema is
        /// `.json`, whose values include null.
        public var optional: Bool
        public var doc: String?

        public init(_ name: String, _ schema: TypeSchema, optional: Bool = false, doc: String? = nil) {
            self.name = name
            self.schema = schema
            self.optional = optional
            self.doc = doc
        }
    }
}

/// A type whose JSON encoding `schema` describes.
public protocol SchemaDescribed {
    static var schema: TypeSchema { get }
}

extension String: SchemaDescribed { public static var schema: TypeSchema { .string } }
extension Double: SchemaDescribed { public static var schema: TypeSchema { .number } }
extension Int: SchemaDescribed { public static var schema: TypeSchema { .number } }
extension Int32: SchemaDescribed { public static var schema: TypeSchema { .number } }
extension UInt32: SchemaDescribed { public static var schema: TypeSchema { .number } }
extension UInt64: SchemaDescribed { public static var schema: TypeSchema { .number } }
extension Bool: SchemaDescribed { public static var schema: TypeSchema { .boolean } }
extension JSONValue: SchemaDescribed { public static var schema: TypeSchema { .json } }

extension Array: SchemaDescribed where Element: SchemaDescribed {
    public static var schema: TypeSchema { .array(Element.schema) }
}

extension Dictionary: SchemaDescribed where Key == String, Value: SchemaDescribed {
    public static var schema: TypeSchema { .record(Value.schema) }
}

/// String-backed enums describe themselves from their cases.
extension SchemaDescribed where Self: CaseIterable & RawRepresentable, RawValue == String {
    public static var schema: TypeSchema { .enumeration(allCases.map(\.rawValue)) }
}

extension ObjectSchema.Field {
    /// A required field whose schema comes from its Swift type.
    public static func field<T: SchemaDescribed>(_ name: String, _ type: T.Type, doc: String? = nil) -> Self {
        Self(name, T.schema, doc: doc)
    }

    /// An optional field: `T?` in Swift, `name?: T` in TypeScript.
    public static func optional<T: SchemaDescribed>(_ name: String, _ type: T.Type, doc: String? = nil) -> Self {
        Self(name, T.schema, optional: true, doc: doc)
    }
}

// MARK: - Validation

/// Checks a JSON value against a schema, both ways: missing required fields,
/// wrong types and fields the schema does not declare are all reported.
public enum SchemaValidator {
    public static func violations(of value: JSONValue, against schema: TypeSchema, at path: String = "$") -> [String] {
        switch (schema, value) {
        case (.json, _):
            return []
        case (.string, .string), (.number, .number), (.boolean, .bool):
            return []
        case (.bounded(let bounds), .number(let number)):
            return bounds.violation(number).map { ["\(path): \($0)"] } ?? []
        case (.enumeration(let cases), .string(let text)):
            return cases.contains(text) ? [] : ["\(path): \"\(text)\" \(notOneOf(cases, text))"]
        case (.array(let element), .array(let items)):
            return items.enumerated().flatMap { index, item in
                violations(of: item, against: element, at: "\(path)[\(index)]")
            }
        case (.record(let element), .object(let fields)):
            return fields.sorted { $0.key < $1.key }.flatMap { key, item in
                violations(of: item, against: element, at: "\(path).\(key)")
            }
        case (.object(let object), .object(let fields)), (.named(_, let object), .object(let fields)):
            var problems: [String] = []
            let declared = Set(object.fields.map(\.name))
            for field in object.fields {
                switch fields[field.name] {
                case nil where field.optional:
                    continue
                case nil:
                    problems.append("\(path).\(field.name): required field is missing")
                case .null? where field.schema != .json:
                    problems.append("\(path).\(field.name): null where the schema expects a value")
                case let item?:
                    problems += violations(of: item, against: field.schema, at: "\(path).\(field.name)")
                }
            }
            for key in fields.keys.sorted() where !declared.contains(key) {
                problems.append("\(path).\(key): field is not declared in the schema")
            }
            return problems
        default:
            return ["\(path): \(describe(value)) does not match \(describe(schema))"]
        }
    }

    /// A short list in full; a long one (every event kind) by its size, with
    /// the nearest value when one is close, since that is usually a typo.
    static func notOneOf(_ cases: [String], _ text: String) -> String {
        guard cases.count > 8 else { return "is not one of " + cases.map { "\"\($0)\"" }.joined(separator: ", ") }
        let nearest = cases.map { ($0, distance($0, text)) }.min { $0.1 < $1.1 }
        let hint = nearest.flatMap { $0.1 <= 2 ? "; did you mean \"\($0.0)\"?" : nil } ?? ""
        return "is not one of the \(cases.count) allowed values\(hint)"
    }

    /// Levenshtein distance, for typo suggestions over short identifiers.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func describe(_ schema: TypeSchema) -> String {
        switch schema {
        case .string: return "string"
        case .number: return "number"
        case .bounded(let bounds): return bounds.integer ? "whole number" : "number"
        case .boolean: return "boolean"
        case .enumeration: return "enumeration"
        case .array: return "array"
        case .record: return "record"
        case .json: return "JSON"
        case .object: return "object"
        case .named(let name, _): return name
        }
    }
}
