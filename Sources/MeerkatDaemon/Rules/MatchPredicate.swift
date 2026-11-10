import Darwin
import Foundation
import MeerkatKit

/// A rule's `match`, compiled against the event's payload schema.
///
/// Compiling against the schema turns author mistakes into load errors
/// instead of rules that silently never fire: unknown fields, operators that
/// do not apply to a field's type, enumeration values that do not exist, and
/// invalid regular expressions are all rejected. Evaluation is a pure
/// function of the payload, bounded in time (see `BoundedRegex`).
struct MatchPredicate: Sendable, Equatable {
    enum Outcome: Equatable {
        case match, noMatch
        /// A `regex` stopped without an answer (its time limit, or another
        /// ICU error); the event is treated as not matching, and the caller
        /// should say so.
        case regexAborted(pattern: String, reason: String)
    }

    private let fields: [FieldTest]

    init(_ raw: JSONValue, schema: TypeSchema) throws {
        guard let object = schema.objectSchema else {
            throw MatchError("this event's payload cannot be matched")
        }
        fields = try Self.compile(raw, object: object, path: "")
    }

    private init(fields: [FieldTest]) {
        self.fields = fields
    }

    func matches(_ payload: JSONValue) -> Bool {
        evaluate(payload) == .match
    }

    func evaluate(_ payload: JSONValue) -> Outcome {
        for field in fields {
            let outcome = field.evaluate(payload[field.name])
            if outcome != .match { return outcome }
        }
        return .match
    }

    // MARK: - Compilation

    private static func compile(_ raw: JSONValue, object: ObjectSchema, path: String) throws -> [FieldTest] {
        guard let entries = raw.objectValue else { throw MatchError("\(label(path)) must be an object of fields") }
        return try entries.sorted(by: { $0.key < $1.key }).map { name, value in
            guard let field = object.fields.first(where: { $0.name == name }) else {
                let known = object.fields.map(\.name).joined(separator: ", ")
                throw MatchError("\(label(path + name)) is not a payload field (fields: \(known))")
            }
            return FieldTest(name: name, test: try compile(value, schema: field.schema, path: path + name))
        }
    }

    private static func compile(_ raw: JSONValue, schema: TypeSchema, path: String) throws -> Test {
        switch schema {
        case .string, .text:
            return try stringTest(raw, cases: nil, path: path)
        case .enumeration(let cases):
            return try stringTest(raw, cases: cases, path: path)
        case .number, .bounded:
            return try numberTest(raw, path: path)
        case .boolean:
            guard case .bool = raw else { throw MatchError("\(label(path)) is a boolean; match it with true or false") }
            return .equals(raw)
        case .array(let element, _):
            return try arrayTest(raw, element: element, path: path)
        case .object(let object), .named(_, let object):
            return .nested(MatchPredicate(fields: try compile(raw, object: object, path: path + ".")))
        case .record(let element):
            // Keys are data, so each listed key is matched against the
            // element schema; an absent key never matches.
            guard let entries = raw.objectValue else { throw MatchError("\(label(path)) must be an object of keys") }
            return .nested(
                MatchPredicate(
                    fields: try entries.sorted(by: { $0.key < $1.key }).map { key, value in
                        FieldTest(name: key, test: try compile(value, schema: element, path: "\(path).\(key)"))
                    }))
        case .json:
            // A free-form value compares by equality only.
            return .equals(raw)
        }
    }

    private static func stringTest(_ raw: JSONValue, cases: [String]?, path: String) throws -> Test {
        func checked(_ value: JSONValue, _ location: String) throws -> String {
            guard let text = value.stringValue else { throw MatchError("\(label(location)) must be a string") }
            if let cases, !cases.contains(text) {
                throw MatchError(
                    "\(label(location)): \"\(text)\" is not one of \(cases.map { "\"\($0)\"" }.joined(separator: ", "))"
                )
            }
            return text
        }
        if case .string = raw { return .equals(.string(try checked(raw, path))) }
        guard let ops = raw.objectValue, !ops.isEmpty else {
            throw MatchError("\(label(path)) must be a string or an object of string operators")
        }
        var tests: [StringOp] = []
        for (op, value) in ops.sorted(by: { $0.key < $1.key }) {
            let at = "\(path).\(op)"
            switch op {
            case "eq": tests.append(.eq(try checked(value, at)))
            case "ne": tests.append(.ne(try checked(value, at)))
            case "in":
                guard let list = value.arrayValue else { throw MatchError("\(label(at)) must be an array") }
                tests.append(.in(Set(try list.map { try checked($0, at) })))
            case "glob", "prefix", "suffix", "regex":
                guard let text = value.stringValue else { throw MatchError("\(label(at)) must be a string") }
                if op == "glob", text.utf16.count > RuleLimits.maximumPatternLength {
                    throw MatchError("\(label(at)): globs are limited to \(RuleLimits.maximumPatternLength) characters")
                }
                switch op {
                case "glob": tests.append(.glob(text))
                case "prefix": tests.append(.prefix(text))
                case "suffix": tests.append(.suffix(text))
                default:
                    guard text.utf16.count <= RuleLimits.maximumPatternLength else {
                        throw MatchError(
                            "\(label(at)): regular expressions are limited to \(RuleLimits.maximumPatternLength) characters"
                        )
                    }
                    do {
                        tests.append(.regex(CompiledRegex(regex: try BoundedRegex(text))))
                    } catch {
                        throw MatchError("\(label(at)): invalid regular expression \"\(text)\"")
                    }
                }
            default:
                throw MatchError("\(label(at)) is not a string operator (eq, ne, in, glob, regex, prefix, suffix)")
            }
        }
        return .string(tests)
    }

    private static func numberTest(_ raw: JSONValue, path: String) throws -> Test {
        if case .number = raw { return .equals(raw) }
        guard let ops = raw.objectValue, !ops.isEmpty else {
            throw MatchError("\(label(path)) must be a number or an object of number operators")
        }
        var tests: [NumberOp] = []
        for (op, value) in ops.sorted(by: { $0.key < $1.key }) {
            let at = "\(path).\(op)"
            if op == "in" {
                guard let list = value.arrayValue, list.allSatisfy({ $0.numberValue != nil }) else {
                    throw MatchError("\(label(at)) must be an array of numbers")
                }
                tests.append(.in(Set(list.compactMap(\.numberValue))))
                continue
            }
            guard let number = value.numberValue else { throw MatchError("\(label(at)) must be a number") }
            switch op {
            case "eq": tests.append(.eq(number))
            case "ne": tests.append(.ne(number))
            case "gt": tests.append(.gt(number))
            case "gte": tests.append(.gte(number))
            case "lt": tests.append(.lt(number))
            case "lte": tests.append(.lte(number))
            default: throw MatchError("\(label(at)) is not a number operator (eq, ne, gt, gte, lt, lte, in)")
            }
        }
        return .number(tests)
    }

    private static func arrayTest(_ raw: JSONValue, element: TypeSchema, path: String) throws -> Test {
        guard let ops = raw.objectValue, !ops.isEmpty else {
            throw MatchError("\(label(path)) is an array; match it with includes, includesAny, includesAll or empty")
        }
        func elementValue(_ value: JSONValue, _ at: String) throws -> JSONValue {
            if case .enumeration(let cases) = element {
                guard let text = value.stringValue, cases.contains(text) else {
                    throw MatchError(
                        "\(label(at)): must be one of \(cases.map { "\"\($0)\"" }.joined(separator: ", "))")
                }
            }
            let problems = SchemaValidator.violations(of: value, against: element, at: at)
            guard problems.isEmpty else { throw MatchError(problems.joined(separator: "; ")) }
            return value
        }
        var tests: [ArrayOp] = []
        for (op, value) in ops.sorted(by: { $0.key < $1.key }) {
            let at = "\(path).\(op)"
            switch op {
            case "includes": tests.append(.includes(try elementValue(value, at)))
            case "includesAny", "includesAll":
                guard let list = value.arrayValue else { throw MatchError("\(label(at)) must be an array") }
                let values = try list.map { try elementValue($0, at) }
                tests.append(op == "includesAny" ? .includesAny(values) : .includesAll(values))
            case "empty":
                guard let flag = value.boolValue else { throw MatchError("\(label(at)) must be a boolean") }
                tests.append(.empty(flag))
            default:
                throw MatchError("\(label(at)) is not an array operator (includes, includesAny, includesAll, empty)")
            }
        }
        return .array(tests)
    }

    private static func label(_ path: String) -> String {
        path.isEmpty ? "match" : "\"\(path)\""
    }

    // MARK: - Tests

    private struct FieldTest: Sendable, Equatable {
        let name: String
        let test: Test

        func evaluate(_ value: JSONValue?) -> Outcome {
            // An absent field never matches: `match` cannot express "absent".
            guard let value else { return .noMatch }
            return test.evaluate(value)
        }
    }

    private indirect enum Test: Sendable, Equatable {
        case equals(JSONValue)
        case string([StringOp])
        case number([NumberOp])
        case array([ArrayOp])
        case nested(MatchPredicate)

        func evaluate(_ value: JSONValue) -> Outcome {
            func outcome(_ matched: Bool) -> Outcome { matched ? .match : .noMatch }
            switch self {
            case .equals(let expected): return outcome(value == expected)
            case .string(let ops):
                guard let text = value.stringValue else { return .noMatch }
                for op in ops {
                    let result = op.evaluate(text)
                    if result != .match { return result }
                }
                return .match
            case .number(let ops):
                guard let number = value.numberValue else { return .noMatch }
                return outcome(ops.allSatisfy { $0.matches(number) })
            case .array(let ops):
                guard let items = value.arrayValue else { return .noMatch }
                return outcome(ops.allSatisfy { $0.matches(items) })
            case .nested(let predicate):
                return predicate.evaluate(value)
            }
        }
    }

    private enum StringOp: Sendable, Equatable {
        case eq(String)
        case ne(String)
        case `in`(Set<String>)
        case glob(String)
        case prefix(String)
        case suffix(String)
        case regex(CompiledRegex)

        func evaluate(_ text: String) -> Outcome {
            func outcome(_ matched: Bool) -> Outcome { matched ? .match : .noMatch }
            switch self {
            case .eq(let expected): return outcome(text == expected)
            case .ne(let expected): return outcome(text != expected)
            case .in(let set): return outcome(set.contains(text))
            case .glob(let pattern):
                // fnmatch backtracks on `*`; bounded like regex inputs.
                guard text.utf16.count <= RuleLimits.maximumMatchInput else { return .noMatch }
                return outcome(fnmatch(pattern, text, 0) == 0)
            case .prefix(let prefix): return outcome(text.hasPrefix(prefix))
            case .suffix(let suffix): return outcome(text.hasSuffix(suffix))
            case .regex(let compiled):
                guard text.utf16.count <= RuleLimits.maximumMatchInput else { return .noMatch }
                switch compiled.regex.evaluate(text) {
                case .match: return .match
                case .noMatch: return .noMatch
                case .aborted(let reason): return .regexAborted(pattern: compiled.regex.pattern, reason: reason)
                }
            }
        }
    }

    private enum NumberOp: Sendable, Equatable {
        case eq(Double)
        case ne(Double)
        case gt(Double)
        case gte(Double)
        case lt(Double)
        case lte(Double)
        case `in`(Set<Double>)

        func matches(_ number: Double) -> Bool {
            switch self {
            case .eq(let x): return number == x
            case .ne(let x): return number != x
            case .gt(let x): return number > x
            case .gte(let x): return number >= x
            case .lt(let x): return number < x
            case .lte(let x): return number <= x
            case .in(let set): return set.contains(number)
            }
        }
    }

    private enum ArrayOp: Sendable, Equatable {
        case includes(JSONValue)
        case includesAny([JSONValue])
        case includesAll([JSONValue])
        case empty(Bool)

        func matches(_ items: [JSONValue]) -> Bool {
            switch self {
            case .includes(let value): return items.contains(value)
            case .includesAny(let values): return values.contains(where: items.contains)
            case .includesAll(let values): return values.allSatisfy(items.contains)
            case .empty(let flag): return items.isEmpty == flag
            }
        }
    }
}

/// Equality by pattern, so equal definitions compare equal.
private struct CompiledRegex: Sendable, Equatable {
    let regex: BoundedRegex

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.regex.pattern == rhs.regex.pattern }
}

struct MatchError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
