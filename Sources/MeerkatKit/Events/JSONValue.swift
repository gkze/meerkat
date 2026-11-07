import Foundation

/// A JSON document as a Swift value.
///
/// Event payloads, rule parameters and match predicates cross three
/// boundaries (the hub, XPC, JavaScript) as JSON. Holding them as a value lets
/// the daemon evaluate predicates and key source instances without decoding
/// into each event's Swift type, while typed payloads remain the authority for
/// what a payload contains.
///
/// Numbers are `Double`, as in JavaScript: integers above 2^53 lose
/// precision, which no current payload produces.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Converts an `Encodable` value through its JSON encoding, so the result
    /// is exactly what a JSON consumer of that value would see (including
    /// omitted nil optionals).
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONValue.encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value as `T`, for typed access at a trust boundary.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONValue.encoder.encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// This value with `other` over it: objects merge key by key, and
    /// anything else (arrays included) is replaced.
    public func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(let base) = self, case .object(let top) = other else { return other }
        return .object(base.merging(top) { $0.merging($1) })
    }

    /// Compact JSON with sorted keys: equal values always produce equal
    /// bytes, which is what makes this usable as a key.
    public var canonicalString: String {
        // Encoding a JSONValue cannot fail: every case maps to JSON.
        let data = (try? JSONValue.encoder.encode(self)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension JSONValue {
    /// A property-list value (a notification's `userInfo`, an IORegistry
    /// property) as JSON. Strings, numbers, booleans, arrays and string-keyed
    /// dictionaries map directly; dates become epoch milliseconds and data
    /// base64. Anything else (and non-finite numbers, non-string keys) is
    /// omitted, never stringified: right for an observation, which is read
    /// and not written back.
    ///
    /// - Parameter strict: nil when anything inside has no JSON form, rather
    ///   than leaving it out. For a value a rule may change and write back
    ///   (a user default), where a dropped array element would shift the
    ///   rest and be written back shortened.
    init?(propertyList value: Any, strict: Bool = false) {
        let convert = { (value: Any) in JSONValue(propertyList: value, strict: strict) }
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue.isFinite {
                self = .number(number.doubleValue)
            } else {
                return nil
            }
        case let date as Date:
            self = .number(date.timeIntervalSince1970 * 1000)
        case let data as Data:
            self = .string(data.base64EncodedString())
        case let array as [Any]:
            let items = array.compactMap(convert)
            guard !strict || items.count == array.count else { return nil }
            self = .array(items)
        case let dictionary as [AnyHashable: Any]:
            var object: [String: JSONValue] = [:]
            for (key, value) in dictionary {
                guard let key = key.base as? String, let converted = convert(value) else {
                    if strict { return nil }
                    continue
                }
                object[key] = converted
            }
            self = .object(object)
        default:
            return nil
        }
    }

    /// The value as a property list to store, or nil when it holds a null,
    /// which a property list cannot. Whole numbers are stored as integers,
    /// so a default other programs read as an integer stays one. The other
    /// direction is `init(propertyList:)`.
    var propertyList: Any? {
        switch self {
        case .null:
            return nil
        case .bool(let flag):
            return flag as NSNumber
        case .number(let number):
            // The bound keeps the conversion from trapping and the value
            // exact.
            if number.rounded() == number, abs(number) < 1e15 { return Int(number) as NSNumber }
            return number as NSNumber
        case .string(let text):
            return text
        case .array(let items):
            var list: [Any] = []
            for item in items {
                guard let converted = item.propertyList else { return nil }
                list.append(converted)
            }
            return list
        case .object(let fields):
            var dictionary: [String: Any] = [:]
            for (key, field) in fields {
                guard let converted = field.propertyList else { return nil }
                dictionary[key] = converted
            }
            return dictionary
        }
    }
}

// Literals, for parameters and configuration written in Swift. Not
// `ExpressibleByNilLiteral`: that would make `JSONValue?` comparisons with
// nil ambiguous between "absent" and JSON null.
extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
