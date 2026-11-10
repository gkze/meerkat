import Foundation

/// The shape of an event payload, a parameter set, an effect request or the
/// configuration, as TypeScript and JSON Schema see it.
///
/// Swift has no reflection that recovers a `Codable` type's JSON shape, so each
/// payload states its schema next to its declaration. Two checks keep them in
/// step: `SchemaValidator` runs every catalog example through its schema in
/// the tests, and the generated `meerkat.d.ts` is compared with the checked-in
/// copy.
///
/// Where a value comes from outside (parameters, requests, tool arguments,
/// rule definitions), the schema is also the authority for its bounds and
/// defaults: `ObjectSchema.admit` and `decode` enforce the bounds and fill
/// the defaults, and the generated documentation states them
/// (`Field.documentation`), so none is written twice.
public indirect enum TypeSchema: Sendable, Equatable {
    case string
    case text(TextBounds)
    case number
    /// A number within bounds, a whole number when `integer` is set.
    case bounded(NumberBounds)
    case boolean
    /// A string restricted to these values, emitted as a union of literals.
    case enumeration([String])
    case array(TypeSchema, ItemBounds = ItemBounds())
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

    /// The bounds as people read them: `1–3600`, `1–256 bytes, one line`,
    /// `at most 4`. Nil when there are none.
    public var boundsText: String? {
        switch self {
        case .bounded(let bounds): return bounds.text
        case .text(let bounds): return bounds.text
        case .array(_, let bounds): return bounds.text
        default: return nil
        }
    }
}

public struct NumberBounds: Sendable, Equatable {
    public var minimum: Double?
    public var maximum: Double?
    public var integer: Bool
    public var exclusiveMinimum: Bool

    public init(minimum: Double? = nil, maximum: Double? = nil, integer: Bool = false, exclusiveMinimum: Bool = false) {
        self.minimum = minimum
        self.maximum = maximum
        self.integer = integer
        self.exclusiveMinimum = exclusiveMinimum
    }

    /// More than `minimum`, at most `maximum`: a duration that must pass.
    public static func positive(atMost maximum: Double) -> Self {
        Self(minimum: 0, maximum: maximum, exclusiveMinimum: true)
    }

    public init(_ range: ClosedRange<Double>) {
        self.init(minimum: range.lowerBound, maximum: range.upperBound)
    }

    /// A whole number in `range`.
    public static func integer(_ range: ClosedRange<Int>) -> Self {
        Self(minimum: Double(range.lowerBound), maximum: Double(range.upperBound), integer: true)
    }

    /// Why `value` is out of bounds, or nil.
    public func violation(_ value: Double) -> String? {
        let shown = Self.format(value)
        // NaN compares false with every bound, so it is refused before them.
        guard value.isFinite else { return "\(shown) is not a finite number" }
        if integer, value.rounded() != value { return "\(shown) is not a whole number" }
        if let minimum, exclusiveMinimum, value <= minimum {
            return "\(shown) is not more than \(Self.format(minimum))"
        }
        if let minimum, value < minimum { return "\(shown) is less than \(Self.format(minimum))" }
        if let maximum, value > maximum { return "\(shown) is more than \(Self.format(maximum))" }
        return nil
    }

    /// `1–3600`, `at least 0`, `at most 1`, `more than 0, at most 30`; nil
    /// when unbounded.
    public var text: String? {
        if exclusiveMinimum, let minimum {
            return "more than \(Self.format(minimum))" + (maximum.map { ", at most \(Self.format($0))" } ?? "")
        }
        return switch (minimum, maximum) {
        case (let minimum?, let maximum?): "\(Self.format(minimum))–\(Self.format(maximum))"
        case (let minimum?, nil): "at least \(Self.format(minimum))"
        case (nil, let maximum?): "at most \(Self.format(maximum))"
        case (nil, nil): nil
        }
    }

    /// A bound as people write it: `30`, not `30.0`.
    public static func format(_ value: Double) -> String {
        exactInteger(value).map(String.init) ?? String(value)
    }

    /// `value` as an `Int` when it is a whole number small enough to be one
    /// exactly; the bound also keeps the conversion from trapping.
    static func exactInteger(_ value: Double) -> Int? {
        value.rounded() == value && abs(value) < 1e15 ? Int(value) : nil
    }
}

/// How many items an array may hold.
public struct ItemBounds: Sendable, Equatable {
    public var minimum: Int
    public var maximum: Int?
    /// An item equal to an earlier one is not counted. The schema keeps it:
    /// the type the array decodes into must drop it, as each such type's
    /// decoder does.
    public var distinct: Bool

    public init(_ minimum: Int = 0, _ maximum: Int? = nil, distinct: Bool = false) {
        self.minimum = minimum
        self.maximum = maximum
        self.distinct = distinct
    }

    public static func atMost(_ maximum: Int, distinct: Bool = false) -> Self {
        Self(0, maximum, distinct: distinct)
    }

    /// Why `items` are too few or too many, or nil.
    func violation(_ items: [JSONValue]) -> String? {
        let count = distinct ? Set(items).count : items.count
        if count < minimum { return minimum == 1 ? "must not be empty" : "fewer than \(minimum) items" }
        if let maximum, count > maximum { return "more than \(maximum)\(distinct ? " different" : "") items" }
        return nil
    }

    /// `at most 4`, `1–64`, `at least 1`; nil when unbounded.
    public var text: String? {
        switch (minimum, maximum) {
        case (0, nil): nil
        case (0, let maximum?): "at most \(maximum)"
        case (let minimum, nil): "at least \(minimum)"
        case (let minimum, let maximum?): "\(minimum)–\(maximum)"
        }
    }
}

/// How long a string may be, in UTF-8 bytes: what the limits protect is
/// storage and the identifiers built from the string, which count bytes.
/// A bounded string never holds NUL, which would end it early in the C APIs
/// and identifiers it reaches.
public struct TextBounds: Sendable, Equatable {
    public var minimum: Int
    public var maximum: Int
    /// A name rather than text: no line break either.
    public var singleLine: Bool
    public var pattern: Pattern?

    /// A regular expression the text must contain a match of (JSON
    /// Schema's `pattern`), and what a text without one is not.
    public struct Pattern: Sendable, Equatable {
        public let regex: String
        /// `must be an IOKit class name`.
        public let refusal: String

        public init(_ regex: String, refusal: String) {
            self.regex = regex
            self.refusal = refusal
        }

        /// Not empty and not only spaces and tabs.
        public static let notBlank = Self("[^ \\t]", refusal: "must not be blank")
    }

    public init(_ range: ClosedRange<Int>, singleLine: Bool = false, pattern: Pattern? = nil) {
        minimum = range.lowerBound
        maximum = range.upperBound
        self.singleLine = singleLine
        self.pattern = pattern
    }

    /// A name of 1 to `maximum` bytes on one line.
    public static func name(_ maximum: Int) -> Self { Self(1...maximum, singleLine: true) }

    /// Why `text` is out of bounds, or nil.
    public func violation(_ text: String) -> String? {
        let bytes = text.utf8.count
        if bytes < minimum { return minimum == 1 ? "must not be empty" : "is shorter than \(Self.size(minimum))" }
        if bytes > maximum { return "is longer than \(Self.size(maximum))" }
        if text.unicodeScalars.contains("\0") { return "must not contain NUL" }
        if singleLine, text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return "must be one line" }
        if let pattern, text.range(of: pattern.regex, options: .regularExpression) == nil { return pattern.refusal }
        return nil
    }

    public var text: String {
        // A range in one unit: `1–1024 bytes`, not `1–1 KiB`.
        let length = minimum == 0 ? "at most \(Self.size(maximum))" : "\(minimum)–\(maximum) bytes"
        return singleLine ? length + ", one line" : length
    }

    /// `256 bytes`, `1 MiB`.
    public static func size(_ bytes: Int) -> String {
        if bytes >= 1 << 20, bytes % (1 << 20) == 0 { return "\(bytes >> 20) MiB" }
        if bytes >= 1 << 10, bytes % (1 << 10) == 0 { return "\(bytes >> 10) KiB" }
        return "\(bytes) bytes"
    }
}

public struct ObjectSchema: Sendable, Equatable {
    public var fields: [Field]

    public init(_ fields: [Field]) {
        self.fields = fields
    }

    public func field(_ name: String) -> Field? { fields.first { $0.name == name } }

    /// `values` with each absent field that has a default set to it, in
    /// nested objects too: what a decode reads, so the schema is the one
    /// place a default is written.
    public func withDefaults(_ values: [String: JSONValue]) -> [String: JSONValue] {
        var values = values
        for field in fields {
            if let value = values[field.name] ?? field.default {
                values[field.name] = field.schema.withDefaults(value)
            }
        }
        return values
    }

    /// A value from outside, as this schema admits it: null is `{}`, every
    /// field left out, and a field given as null that has a default has its
    /// default, at any depth; fields the schema does not declare are named
    /// on their own first, since a misspelt field is the likeliest mistake;
    /// then every other violation; then the defaults are filled. Problems
    /// are prefixed with `path`, as `SchemaValidator` prefixes them.
    public func admit(_ raw: JSONValue, at path: String = "") throws(SchemaMismatch) -> [String: JSONValue] {
        let given = TypeSchema.object(self).defaultingNulls(raw == .null ? JSONValue.object([:]) : raw)
        if case .object(let values) = given {
            let declared = Set(fields.map(\.name))
            let unknown = values.keys.filter { !declared.contains($0) }.sorted()
            guard unknown.isEmpty else {
                let names = unknown.map { "\"\($0)\"" }.joined(separator: ", ")
                let text = "unknown field\(unknown.count == 1 ? "" : "s") \(names)"
                throw SchemaMismatch(problems: [path.isEmpty ? text : "\(path): \(text)"])
            }
        }
        let problems = SchemaValidator.violations(of: given, against: .object(self), at: path)
        guard problems.isEmpty, case .object(let values) = given else {
            throw SchemaMismatch(problems: problems)
        }
        return withDefaults(values)
    }

    /// `admit`, then decoded as `T`, whose `Decodable` conformance the
    /// schema describes. Throws `SchemaMismatch`, naming the field for one
    /// that does not decode, or what `T`'s own decoder threw for a check of
    /// its own.
    public func decode<T: Decodable>(_ raw: JSONValue, as type: T.Type = T.self, at path: String = "") throws -> T {
        let values = try admit(raw, at: path)
        do {
            return try JSONValue.object(values).decode(as: T.self)
        } catch let error as DecodingError {
            throw SchemaMismatch(decoding: error, at: path)
        }
    }

    public struct Field: Sendable, Equatable {
        public var name: String
        public var schema: TypeSchema
        /// Optional fields may be absent from the JSON. They are never `null`
        /// (payloads encode nil by omitting the key), unless the schema is
        /// `.json`, whose values include null.
        public var optional: Bool
        /// The value an absent field has; a field with one is optional.
        public var `default`: JSONValue?
        public var doc: String?

        public init(
            _ name: String, _ schema: TypeSchema, optional: Bool = false, default: JSONValue? = nil,
            doc: String? = nil
        ) {
            self.name = name
            self.schema = schema
            self.optional = optional || `default` != nil
            self.default = `default`
            self.doc = doc
        }

        /// `doc` with the bounds and default the schema declares, as the
        /// generated declarations show it: "Seconds between samples,
        /// 1–3600. Default 5."
        public var documentation: String? {
            var text = doc ?? ""
            if let bounds = schema.boundsText {
                if text.isEmpty {
                    text = bounds.capitalizedFirst + "."
                } else if text.hasSuffix(".") {
                    text += " \(bounds.capitalizedFirst)."
                } else {
                    text += ", \(bounds)."
                }
            }
            if let value = `default` {
                if !text.isEmpty, !text.hasSuffix(".") { text += "." }
                text += (text.isEmpty ? "" : " ") + "Default \(value.canonicalString)."
            }
            return text.isEmpty ? nil : text
        }
    }
}

extension TypeSchema {
    /// `value` without the nulls given for fields that have a default, in
    /// nested objects too, so those fields take their default. A `.json`
    /// field keeps its null, which is a value there.
    func defaultingNulls(_ value: JSONValue) -> JSONValue {
        switch (self, value) {
        case (.object(let object), .object(var values)), (.named(_, let object), .object(var values)):
            for field in object.fields {
                guard let item = values[field.name] else { continue }
                if item == .null, field.default != nil, field.schema != .json {
                    values[field.name] = nil
                } else {
                    values[field.name] = field.schema.defaultingNulls(item)
                }
            }
            return .object(values)
        case (.array(let element, _), .array(let items)): return .array(items.map(element.defaultingNulls))
        case (.record(let element), .object(let values)): return .object(values.mapValues(element.defaultingNulls))
        default: return value
        }
    }

    /// `value` with the defaults of every object in it filled.
    func withDefaults(_ value: JSONValue) -> JSONValue {
        switch (self, value) {
        case (.object(let object), .object(let values)), (.named(_, let object), .object(let values)):
            .object(object.withDefaults(values))
        case (.array(let element, _), .array(let items)): .array(items.map(element.withDefaults))
        case (.record(let element), .object(let values)): .object(values.mapValues(element.withDefaults))
        default: value
        }
    }
}

/// Why a value from outside does not fit its schema, in words its sender can
/// act on.
public struct SchemaMismatch: Error, CustomStringConvertible, Equatable {
    /// Each problem on its own, for a sender that lists them.
    public let problems: [String]

    public var description: String { problems.joined(separator: "; ") }

    public init(problems: [String]) { self.problems = problems }

    /// `DecodingError`'s own description is a debug dump; a sender needs the
    /// field path and the problem.
    init(decoding: DecodingError, at root: String) {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return ([root].filter { !$0.isEmpty } + keys).joined(separator: ".")
        }
        func at(_ context: DecodingError.Context, _ text: String) -> String {
            let place = path(context)
            return place.isEmpty ? text : "\(place): \(text)"
        }
        let description =
            switch decoding {
            case .keyNotFound(let key, let context): at(context, "missing \"\(key.stringValue)\"")
            case .typeMismatch(let type, let context): at(context, "expected \(type)")
            case .valueNotFound(let type, let context): at(context, "expected \(type), got null")
            case .dataCorrupted(let context): at(context, context.debugDescription)
            @unknown default: "\(decoding)"
            }
        problems = [description]
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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
/// wrong types, values out of bounds and fields the schema does not declare
/// are all reported.
public enum SchemaValidator {
    /// - Parameter path: where `value` is, prefixed to each problem; empty
    ///   names fields alone (`interval: 0 is less than 1`).
    public static func violations(of value: JSONValue, against schema: TypeSchema, at path: String = "$") -> [String] {
        func child(_ name: String) -> String { path.isEmpty ? name : "\(path).\(name)" }
        func problem(_ text: String) -> String { path.isEmpty ? text : "\(path): \(text)" }
        switch (schema, value) {
        case (.json, _):
            return []
        case (.string, .string), (.number, .number), (.boolean, .bool):
            return []
        case (.text(let bounds), .string(let text)):
            return bounds.violation(text).map { [problem($0)] } ?? []
        case (.bounded(let bounds), .number(let number)):
            return bounds.violation(number).map { [problem($0)] } ?? []
        case (.enumeration(let cases), .string(let text)):
            return cases.contains(text) ? [] : [problem("\"\(text)\" \(notOneOf(cases, text))")]
        case (.array(let element, let bounds), .array(let items)):
            if let violation = bounds.violation(items) { return [problem(violation)] }
            return items.enumerated().flatMap { index, item in
                violations(of: item, against: element, at: "\(path)[\(index)]")
            }
        case (.record(let element), .object(let fields)):
            return fields.sorted { $0.key < $1.key }.flatMap { key, item in
                violations(of: item, against: element, at: child(key))
            }
        case (.object(let object), .object(let fields)), (.named(_, let object), .object(let fields)):
            var problems: [String] = []
            let declared = Set(object.fields.map(\.name))
            for field in object.fields {
                switch fields[field.name] {
                case nil where field.optional:
                    continue
                case nil:
                    problems.append("\(child(field.name)): required field is missing")
                case .null? where field.schema != .json:
                    problems.append("\(child(field.name)): null where the schema expects a value")
                case let item?:
                    problems += violations(of: item, against: field.schema, at: child(field.name))
                }
            }
            for key in fields.keys.sorted() where !declared.contains(key) {
                problems.append("\(child(key)): field is not declared in the schema")
            }
            return problems
        default:
            return [problem("\(describe(value)) does not match \(describe(schema))")]
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
        case .string, .text: return "string"
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
