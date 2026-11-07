import Foundation
import Testing

@testable import MeerkatDaemon
@testable import MeerkatKit

/// The daemon's pure decision logic: definitions, match, rate, breaker.
struct RuleDefinitionTests {
    let catalog = EventCatalog.standard

    private func decode(_ fields: [String: JSONValue]) throws -> RuleDefinition {
        try RuleDefinition(file: "a.ts", raw: .object(fields), catalog: catalog)
    }

    @Test func minimalDefinitionGetsDefaults() throws {
        let rule = try decode(["name": "r", "on": "memory.pressure"])
        #expect(rule.id == "a.ts#r")
        #expect(rule.parameters.json == .object([:]))
        #expect(rule.grants == .none)
        #expect(rule.timeout == .seconds(5))
        #expect(!rule.includeOwn)
    }

    @Test func parametersAreNormalizedWithDefaults() throws {
        let rule = try decode(["name": "r", "on": "cpu.sample", "params": ["interval": 2]])
        #expect(rule.parameters.json == .object(["interval": 2]))
        #expect(try decode(["name": "r", "on": "cpu.sample"]).parameters.json == .object(["interval": 1]))
    }

    @Test(
        arguments: [
            (["name": "r", "on": "nope"], "\"on\": unknown event \"nope\""),
            (["name": "", "on": "timer"], "\"name\" must be a non-empty string"),
            (["name": "r", "on": "timer", "extra": 1], "unknown field \"extra\""),
            (
                ["name": "r", "on": "timer", "params": ["every": 0]],
                "\"params\": invalid parameters: \"every\" must be between 1.0 and 604800.0 seconds, got 0.0"
            ),
            (
                ["name": "r", "on": "timer", "params": ["every": 5], "timeoutSeconds": 99],
                "\"timeoutSeconds\" must be a number between 0.1 and 60.0"
            ),
            (
                ["name": "r", "on": "timer", "params": ["every": 5], "capabilities": ["root": true]],
                "\"capabilities\": unknown capability \"root\""
            ),
            (
                ["name": "r", "on": "timer", "params": ["every": 5], "capabilities": ["exec": ["allow": ["bin/ls"]]]],
                "\"capabilities.exec.allow\": \"bin/ls\" must be an absolute, normalized path"
            ),
            (
                [
                    "name": "r", "on": "timer", "params": ["every": 5],
                    "rate": ["throttleSeconds": 1, "debounceSeconds": 1],
                ],
                "\"rate\": use throttleSeconds or debounceSeconds, not both"
            ),
        ] as [([String: JSONValue], String)])
    func invalidDefinitionsExplainThemselves(_ fields: [String: JSONValue], _ message: String) {
        #expect(throws: RuleDefinitionError(message)) { try decode(fields) }
    }

    @Test func grantsDecode() throws {
        let rule = try decode([
            "name": "r", "on": "timer", "params": ["every": 5],
            "capabilities": [
                "notify": true, "process": ["signal": true],
                "exec": ["allow": ["/usr/bin/true"]], "http": ["allow": ["https://Example.com"]],
                "store": ["record": true],
            ],
        ])
        #expect(
            rule.grants.has("notify") && rule.grants.has("process.signal") && !rule.grants.has("process.priority")
                && rule.grants.has("store.record"))
        #expect(rule.grants.list("exec") == ["/usr/bin/true"])
        #expect(rule.grants.httpOrigins == [URLOrigin("https://example.com:443")!])
    }
}

struct MatchPredicateTests {
    let pressure = MemoryPressurePayload.schema
    let change = FSChangePayload.schema
    let spawned = ProcessSpawnedPayload.schema

    @Test func literalsAndOperators() throws {
        let match = try MatchPredicate(["level": "critical"], schema: pressure)
        #expect(match.matches(["level": "critical"]))
        #expect(!match.matches(["level": "warning"]))

        let any = try MatchPredicate(["level": ["in": ["warning", "critical"]]], schema: pressure)
        #expect(any.matches(["level": "warning"]))
        #expect(!any.matches(["level": "normal"]))
    }

    @Test func enumerationTyposAreLoadErrors() {
        #expect(throws: MatchError.self) { try MatchPredicate(["level": "critcal"], schema: pressure) }
        #expect(throws: MatchError.self) { try MatchPredicate(["levle": "critical"], schema: pressure) }
    }

    @Test func stringOperatorsAndArrays() throws {
        let match = try MatchPredicate(
            [
                "path": ["glob": "/Users/*/notes/*.md", "regex": "notes"],
                "changes": ["includesAny": ["created", "renamed"]],
                "itemType": "file",
            ], schema: change)
        let hit: JSONValue = [
            "path": "/Users/x/notes/a.md", "changes": ["created"], "itemType": "file",
            "streamFlags": [], "eventId": 1,
        ]
        #expect(match.matches(hit))
        var miss = hit.objectValue!
        miss["changes"] = ["modified"]
        #expect(!match.matches(.object(miss)))
        #expect(throws: MatchError.self) { try MatchPredicate(["changes": ["includes": "bogus"]], schema: change) }
        #expect(throws: MatchError.self) { try MatchPredicate(["path": ["regex": "("]], schema: change) }
    }

    @Test func nestedFieldsAndNumbers() throws {
        let match = try MatchPredicate(["process": ["uid": ["gte": 500], "name": ["prefix": "node"]]], schema: spawned)
        let payload = try JSONValue(encoding: ProcessSpawnedPayload(process: .example))
        #expect(match.matches(payload))
        #expect(throws: MatchError.self) { try MatchPredicate(["process": ["uid": ["glob": "5*"]]], schema: spawned) }
    }

    @Test func absentOptionalFieldNeverMatches() throws {
        let schema = ProcessExecPayload.schema
        let match = try MatchPredicate(["previousPath": ["prefix": "/bin"]], schema: schema)
        #expect(!match.matches(try JSONValue(encoding: ProcessExecPayload(process: .example, previousPath: nil))))
        #expect(match.matches(try JSONValue(encoding: ProcessExecPayload(process: .example, previousPath: "/bin/zsh"))))
    }
}

struct RateAndBreakerTests {
    @Test func throttleAdmitsFirstPerWindow() {
        var limiter = RateLimiter(spec: RateSpec(throttle: 10))
        let results = [0, 9.9, 10].map { limiter.admit(now: $0) }
        #expect(results == [true, false, true])
    }

    @Test func perMinuteCapRolls() {
        var limiter = RateLimiter(spec: RateSpec(maxPerMinute: 2))
        let results = [0, 1, 2, 60.5].map { limiter.admit(now: $0) }
        #expect(results == [true, true, false, true])
    }

    @Test func breakerTripsOnFailuresAndRunaways() {
        var breaker = CircuitBreaker()
        let failures = (0..<5).map { breaker.recordFailure(now: Double($0)) }
        #expect(failures.prefix(4).allSatisfy { $0 == nil })
        #expect(failures[4] != nil)

        var fresh = CircuitBreaker()
        let spaced = [0.0, 61].map { fresh.recordFailure(now: $0) }
        #expect(spaced == [nil, nil], "failures outside the window are forgotten")

        var runaway = CircuitBreaker()
        let invocations = (0...CircuitBreaker.maximumInvocations).map {
            runaway.recordInvocation(now: Double($0) * 0.1)
        }
        #expect(invocations.dropLast().allSatisfy { $0 == nil })
        #expect(invocations.last! != nil)
    }
}

struct EffectRequestTests {
    @Test func requestsDecode() throws {
        let signal = try EffectRequest([
            "kind": "process.signal", "signal": "stop",
            "target": ["pid": 10, "startedAt": 1_700_000_000_000],
        ])
        #expect(signal.action == .signal(target: ProcessIdentity(pid: 10, startedAt: 1_700_000_000_000), signal: .stop))
        #expect(throws: EffectError.self) {
            try EffectRequest(["kind": "process.signal", "signal": "stop", "target": ["pid": 10]])
        }
        #expect(throws: EffectError.self) { try EffectRequest(["kind": "format.disk"]) }
        let exec = try EffectRequest(["kind": "exec", "path": "/usr/bin/true", "args": ["-x"]])
        #expect(exec.action == .exec(ExecSpec(path: "/usr/bin/true", arguments: ["-x"], timeout: 10, stdin: nil)))
    }
}
