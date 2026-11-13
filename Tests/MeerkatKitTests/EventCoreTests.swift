import Foundation
import Synchronization
import Testing

@testable import MeerkatKit

/// Contracts of the catalog, the hub and the pure decision logic. Live OS
/// sources are exercised in `EventSourceTests`.
struct EventCatalogTests {
    @Test func namesAreUniqueAndDotted() {
        let names = EventCatalog.standard.kinds.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.range(of: #"^[a-z]+(\.[a-zA-Z]+)?$"#, options: .regularExpression) != nil, "\(name)")
        }
    }

    /// Every payload example must match its schema exactly: a field added to
    /// a Swift payload without updating its schema (or the reverse) fails here.
    @Test(arguments: EventCatalog.standard.kinds.map(\.name))
    func payloadExamplesMatchSchema(_ name: String) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        let examples = try kind.payloadExamples()
        #expect(!examples.isEmpty)
        for example in examples {
            let problems = SchemaValidator.violations(of: example, against: kind.payloadSchema)
            #expect(problems.isEmpty, "\(name): \(problems)")
        }
    }

    @Test(arguments: EventCatalog.standard.kinds.map(\.name))
    func parameterExamplesRoundTrip(_ name: String) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        for example in try kind.parameterExamples() {
            let problems = SchemaValidator.violations(of: example, against: .object(kind.parametersSchema))
            #expect(problems.isEmpty, "\(name): \(problems)")
            // Normalizing is idempotent: the normalized form is its own key.
            let normalized = try kind.normalized(example).json
            #expect(try kind.normalized(normalized).json == normalized)
        }
    }

    @Test func unknownParameterIsRejected() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "cpu.sample"))
        #expect(throws: EventError.invalidParameters("unknown field \"intervall\"")) {
            try kind.normalized(.object(["intervall": .number(2)])).json
        }
    }

    @Test func parameterDefaultsAreApplied() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "cpu.sample"))
        #expect(try kind.normalized(.object([:])).json == .object(["interval": .number(1)]))
        #expect(try kind.normalized(.null).json == .object(["interval": .number(1)]))
    }

    /// Each default is a valid value of its field.
    @Test(arguments: EventCatalog.standard.kinds.map(\.name))
    func defaultsAreValid(_ name: String) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        for field in kind.parametersSchema.fields {
            guard let value = field.default else { continue }
            #expect(SchemaValidator.violations(of: value, against: field.schema).isEmpty, "\(name).\(field.name)")
        }
    }

    /// A nested object's defaults are filled as a top-level field's are,
    /// and null is every field left out.
    @Test func admittingFillsNestedDefaultsAndNamesUnknownFields() throws {
        let schema = ObjectSchema([
            .init("count", .bounded(.integer(1...10)), default: 3),
            .init(
                "items",
                .array(.object(ObjectSchema([.init("on", .boolean, default: false), .field("id", String.self)])))
            ),
            .init("inner", .object(ObjectSchema([.init("limit", .number, default: 5)])), optional: true),
        ])
        #expect(
            try schema.admit(["items": [["id": "a"]], "inner": [:]])
                == ["count": 3, "items": [["id": "a", "on": false]], "inner": ["limit": 5]])
        #expect(throws: SchemaMismatch(problems: ["args: unknown fields \"a\", \"b\""])) {
            try schema.admit(["a": 1, "b": 2, "items": []], at: "args")
        }
        #expect(throws: SchemaMismatch(problems: ["items: required field is missing"])) { try schema.admit(.null) }
        #expect(throws: SchemaMismatch(problems: ["count: 11 is more than 10"])) {
            try schema.admit(["count": 11, "items": []])
        }
        // Null for a field with a default is its default, at any depth; for
        // one without, it is refused.
        #expect(
            try schema.admit(["count": .null, "items": [["id": "a", "on": .null]], "inner": ["limit": .null]])
                == ["count": 3, "items": [["id": "a", "on": false]], "inner": ["limit": 5]])
        #expect(throws: SchemaMismatch(problems: ["inner: null where the schema expects a value"])) {
            try schema.admit(["items": [], "inner": .null])
        }
        // A section that defaults to `{}` takes it, with its own defaults.
        let sections = ObjectSchema([
            .init("inner", .object(ObjectSchema([.init("limit", .number, default: 5)])), default: [:])
        ])
        #expect(try sections.admit(["inner": .null]) == ["inner": ["limit": 5]])
    }

    /// The schema's bounds are the parameters' bounds, whether they come
    /// from a rule or are built in Swift and validated.
    @Test func boundsComeFromTheSchema() throws {
        let top = try #require(EventCatalog.standard.kind(named: "process.top"))
        #expect(throws: EventError.self) { try top.normalized(.object(["count": .number(101)])) }
        #expect(throws: EventError.self) { try top.normalized(.object(["count": .number(2.5)])) }
        #expect(throws: EventError.self) { try top.normalized(.object(["interval": .number(2), "rankInterval": 1])) }
        #expect(throws: EventError.self) { try ProcessTopParameters(count: 0).validate() }
        #expect(throws: EventError.self) { try ProcessTopParameters(interval: .nan).validate() }
        try ProcessTopParameters(count: 100).validate()
    }

    @Test func outOfRangeParameterIsRejected() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "cpu.sample"))
        #expect(throws: EventError.self) { try kind.normalized(.object(["interval": .number(0)])).json }
        #expect(throws: EventError.self) { try kind.normalized(.object(["interval": .string("1")])).json }
    }

    @Test func tildePathsNormalizeToTheSameKey() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "fs.change"))
        let tilde = try kind.normalized(.object(["paths": .array([.string("~/Library")])])).json
        let absolute = try kind.normalized(.object(["paths": .array([.string(NSHomeDirectory() + "/Library/")])])).json
        #expect(tilde == absolute)
        #expect(throws: EventError.self) { try kind.normalized(.object(["paths": .array([.string("relative")])])).json }
    }

    /// One decode gives the key and what is observed, so a grant is checked
    /// against the paths the source watches, not a second resolution.
    @Test func normalizedParametersSayWhatTheyObserve() throws {
        let fs = try #require(EventCatalog.standard.kind(named: "fs.change"))
        let watched = try fs.normalized(.object(["paths": .array([.string("~/Library")])]))
        #expect(watched.kind == "fs.change")
        #expect(watched.json["paths"] == .array((watched.observedPaths?.paths ?? []).map(JSONValue.string)))
        #expect(watched.observedProcess == nil)
        let sample = try #require(EventCatalog.standard.kind(named: "process.sample"))
        let followed = try sample.normalized(.object(["pid": .number(1), "startedAt": .number(1_792_887_367_209)]))
        #expect(followed.observedProcess == ProcessIdentity(pid: 1, startedAt: 1_792_887_367_209))
        #expect(followed.observedPaths == nil)
    }

    /// Subscribing with decoded parameters shares the instance a JSON
    /// subscription with the same parameters made.
    @Test func decodedParametersShareTheSource() throws {
        let hub = EventHub()
        let kind = try #require(EventCatalog.standard.kind(named: "memory.pressure"))
        let byJSON = try hub.subscribe("memory.pressure")
        defer { byJSON.cancel() }
        let decoded = try hub.subscribe(kind.normalized(.null))
        defer { decoded.cancel() }
        #expect(decoded.parameters == byJSON.parameters)
        #expect(hub.statistics().filter { $0.kind == "memory.pressure" }.map(\.subscribers) == [2])
    }

    @Test func noParametersRejectsFields() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "memory.pressure"))
        #expect(try kind.normalized(.object([:])).json == .object([:]))
        #expect(throws: EventError.self) { try kind.normalized(.object(["x": .number(1)])).json }
    }
}

struct SchemaValidatorTests {
    let schema = TypeSchema.object(
        ObjectSchema([
            .field("name", String.self),
            .optional("count", Int.self),
            .init("level", .enumeration(["low", "high"])),
        ]))

    @Test func acceptsMatchingValue() {
        let value: JSONValue = .object(["name": .string("a"), "level": .string("low")])
        #expect(SchemaValidator.violations(of: value, against: schema).isEmpty)
    }

    @Test func reportsMissingExtraAndWrongFields() {
        let value: JSONValue = .object(["count": .null, "level": .string("medium"), "extra": .bool(true)])
        let problems = SchemaValidator.violations(of: value, against: schema)
        #expect(problems.contains("$.name: required field is missing"))
        #expect(problems.contains("$.count: null where the schema expects a value"))
        #expect(problems.contains("$.extra: field is not declared in the schema"))
        #expect(problems.contains { $0.hasPrefix("$.level:") })
    }
}

// MARK: - Hub

/// A test-only event kind whose source records its lifecycle and lets the
/// test emit on demand.
enum ProbeEvent: EventKind {
    struct Parameters: EventParameters {
        var channel: String
        static var objectSchema: ObjectSchema { ObjectSchema([.field("channel", String.self)]) }
        static var examples: [Self] { [Self(channel: "a")] }
    }

    struct Payload: EventPayload, Equatable {
        var value: Int
        static var schema: TypeSchema { .object(ObjectSchema([.field("value", Int.self)])) }
        static var examples: [Self] { [Self(value: 1)] }
    }

    static let descriptor = EventDescriptor(
        "test.probe", "test", mechanism: .push, semantics: .state,
        loss: .none, observation: .open, source: "test")

    static let registry = ProbeRegistry()

    static func makeSource(
        _ parameters: Parameters, environment: SourceEnvironment,
        emit: Emitter<Payload>
    ) throws -> any EventSource {
        let source = ProbeSource(channel: parameters.channel, emit: emit)
        registry.add(source)
        return source
    }
}

final class ProbeRegistry: Sendable {
    private let sources = Mutex<[ProbeSource]>([])
    func add(_ source: ProbeSource) { sources.withLock { $0.append(source) } }
    func all(channel: String) -> [ProbeSource] { sources.withLock { $0.filter { $0.channel == channel } } }
}

final class ProbeSource: EventSource {
    let channel: String
    let emit: Emitter<ProbeEvent.Payload>
    let starts = Atomic<Int>(0)
    let stops = Atomic<Int>(0)

    init(channel: String, emit: Emitter<ProbeEvent.Payload>) {
        self.channel = channel
        self.emit = emit
    }

    /// A channel named `empty…` has no value to read at the start.
    func start() throws {
        starts.add(1, ordering: .relaxed)
        if !channel.hasPrefix("empty") { emit.current(.init(value: 0)) }
    }

    func stop() { stops.add(1, ordering: .relaxed) }
}

struct EventHubTests {
    let hub = EventHub(catalog: EventCatalog([AnyEventKind(ProbeEvent.self)]))

    private func next(_ subscription: EventSubscription) async -> EventEnvelope? {
        var iterator = subscription.events.makeAsyncIterator()
        return await iterator.next()
    }

    @Test func equalParametersShareOneSource() async throws {
        let channel = UUID().uuidString
        let first = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        let second = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        let sources = ProbeEvent.registry.all(channel: channel)
        #expect(sources.count == 1)
        #expect(hub.statistics().first?.subscribers == 2)

        first.cancel()
        #expect(sources[0].stops.load(ordering: .relaxed) == 0)
        second.cancel()
        #expect(sources[0].stops.load(ordering: .relaxed) == 1)
        #expect(hub.statistics().isEmpty)
    }

    @Test func stateIsReplayedToLateSubscribers() async throws {
        let channel = UUID().uuidString
        let first = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        let initial = try #require(await next(first))
        #expect(initial.payload == .object(["value": .number(0)]))
        // A push state source's first value is its current value: a replay.
        #expect(initial.replayed)

        ProbeEvent.registry.all(channel: channel)[0].emit(.init(value: 7))
        let late = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        let replay = try #require(await next(late))
        #expect(replay.payload == .object(["value": .number(7)]))
        #expect(replay.replayed)
        #expect(replay.sequence == 2)
        let change = try #require(await next(first))
        #expect(change.payload == .object(["value": .number(7)]) && !change.replayed)
        first.cancel()
        late.cancel()
    }

    /// The hub marks what the source says it read at the start, not its
    /// first event: with nothing to read then, the first change is a change.
    @Test func aChangeAfterAnEmptyStartIsNotAReplay() async throws {
        let channel = "empty-" + UUID().uuidString
        let first = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        ProbeEvent.registry.all(channel: channel)[0].emit.changed(.init(value: 3))
        let change = try #require(await next(first))
        #expect(change.sequence == 1 && !change.replayed)
        first.cancel()
    }

    /// A change that beats the start read to the ring is not followed by a
    /// replayed current value: what the source read then came after it.
    @Test func aStartReadAfterAChangeIsNotAReplay() async throws {
        let channel = "empty-" + UUID().uuidString
        let first = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        let source = ProbeEvent.registry.all(channel: channel)[0]
        source.emit.changed(.init(value: 3))
        source.emit.current(.init(value: 5))
        var events = first.events.makeAsyncIterator()
        let change = try #require(await events.next())
        let read = try #require(await events.next())
        #expect(!change.replayed && read.sequence == 2 && !read.replayed)
        first.cancel()
    }

    /// A reported value equal to the latest is no change and is left out.
    @Test func anUnchangedValueIsLeftOut() async throws {
        let channel = UUID().uuidString
        let first = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        var events = first.events.makeAsyncIterator()
        _ = await events.next()
        let source = ProbeEvent.registry.all(channel: channel)[0]
        source.emit.changed(.init(value: 0))
        source.emit.changed(.init(value: 4))
        let next = try #require(await events.next())
        #expect(next.payload == .object(["value": .number(4)]) && next.sequence == 2)
        first.cancel()
    }

    @Test func replayGoesToThatSubscriberOnly() async throws {
        let channel = UUID().uuidString
        let parameters: JSONValue = .object(["channel": .string(channel)])
        let first = try hub.subscribe("test.probe", parameters: parameters)
        let second = try hub.subscribe("test.probe", parameters: parameters)
        var firstEvents = first.events.makeAsyncIterator()
        var secondEvents = second.events.makeAsyncIterator()
        _ = await firstEvents.next()
        _ = await secondEvents.next()
        hub.replayLatest(to: first)
        let replay = try #require(await firstEvents.next())
        #expect(replay.replayed && replay.payload == .object(["value": .number(0)]))
        ProbeEvent.registry.all(channel: channel)[0].emit(.init(value: 9))
        // The second subscriber's next event is the new one, not a replay.
        #expect(await secondEvents.next()?.payload == .object(["value": .number(9)]))
        first.cancel()
        second.cancel()
    }

    @Test func unknownKindAndBadParametersThrow() {
        #expect(throws: EventError.unknownEvent("nope")) { try hub.subscribe("nope") }
        #expect(throws: EventError.self) { try hub.subscribe("test.probe", parameters: .object([:])) }
    }

    @Test func fullRingDropsOldestAndCounts() async throws {
        let hub = EventHub(catalog: EventCatalog([AnyEventKind(ProbeEvent.self)]), retainedEvents: 2)
        let channel = UUID().uuidString
        let subscription = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        let source = ProbeEvent.registry.all(channel: channel)[0]
        for value in 1...5 { source.emit(.init(value: value)) }
        #expect(hub.statistics().first?.dropped == 4)

        var iterator = subscription.events.makeAsyncIterator()
        #expect(await iterator.next()?.payload == .object(["value": .number(4)]))
        #expect(await iterator.next()?.payload == .object(["value": .number(5)]))
        subscription.cancel()
    }

    @Test func onlyTheLaggingSubscriberDrops() async throws {
        let hub = EventHub(catalog: EventCatalog([AnyEventKind(ProbeEvent.self)]), retainedEvents: 2)
        let channel = UUID().uuidString
        let parameters: JSONValue = .object(["channel": .string(channel)])
        let reader = try hub.subscribe("test.probe", parameters: parameters)
        let lagging = try hub.subscribe("test.probe", parameters: parameters)
        let source = ProbeEvent.registry.all(channel: channel)[0]
        var readerEvents = reader.events.makeAsyncIterator()
        var values: [JSONValue] = []
        for value in 1...4 {
            source.emit(.init(value: value))
            values.append(await readerEvents.next()!.payload)
        }
        // The reader kept up (its first read was the replayed value 0).
        #expect(values == [0, 1, 2, 3].map { .object(["value": .number(Double($0))]) })
        // The other subscriber missed its replay of value 0 and values 1 and
        // 2; it resumes at the oldest event still held.
        #expect(hub.statistics().first?.dropped == 3)
        #expect(await next(lagging)?.payload == .object(["value": .number(3)]))
        reader.cancel()
        lagging.cancel()
    }

    @Test func readPositionOutlivesIterators() async throws {
        let channel = UUID().uuidString
        let subscription = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        let source = ProbeEvent.registry.all(channel: channel)[0]
        for value in 1...2 { source.emit(.init(value: value)) }
        // Each helper call makes a fresh iterator; reading continues anyway.
        #expect(await next(subscription)?.sequence == 1)
        #expect(await next(subscription)?.sequence == 2)
        #expect(await next(subscription)?.sequence == 3)
        subscription.cancel()
    }

    @Test func waitingReaderWakesAndCancelEndsIt() async throws {
        let channel = UUID().uuidString
        let subscription = try hub.subscribe("test.probe", parameters: .object(["channel": .string(channel)]))
        _ = await next(subscription)
        let waiting = Task { await next(subscription) }
        // The event must arrive while the task is suspended in `next`.
        #expect(await eventually { hub.isWaiting(subscription) })
        ProbeEvent.registry.all(channel: channel)[0].emit(.init(value: 1))
        #expect(await waiting.value?.payload == .object(["value": .number(1)]))

        let ended = Task { await next(subscription) }
        #expect(await eventually { hub.isWaiting(subscription) })
        subscription.cancel()
        #expect(await ended.value == nil)
        #expect(hub.statistics().isEmpty)
    }

    /// A source that fails after starting ends every subscriber's stream,
    /// unread events included, with its reason, and is stopped; the next
    /// subscriber starts a new source.
    @Test func aFailedSourceEndsEveryStream() async throws {
        let channel = UUID().uuidString
        let parameters: JSONValue = .object(["channel": .string(channel)])
        let reader = try hub.subscribe("test.probe", parameters: parameters)
        let lagging = try hub.subscribe("test.probe", parameters: parameters)
        _ = await next(reader)
        let waiting = Task { await next(reader) }
        #expect(await eventually { hub.isWaiting(reader) })
        let source = ProbeEvent.registry.all(channel: channel)[0]

        source.emit.fail("probe broke")
        #expect(await waiting.value == nil)
        #expect(await next(lagging) == nil)
        #expect(hub.endReason(of: reader) == "probe broke")
        #expect(hub.endReason(of: lagging) == "probe broke")
        #expect(hub.statistics().isEmpty)
        #expect(await eventually { source.stops.load(ordering: .relaxed) == 1 })
        // What a failed source emits afterwards goes nowhere.
        source.emit(.init(value: 1))

        let restarted = try hub.subscribe("test.probe", parameters: parameters)
        #expect(ProbeEvent.registry.all(channel: channel).count == 2)
        #expect(await next(restarted)?.sequence == 1)
        #expect(hub.endReason(of: restarted) == nil)
        // Cancelling forgets the reason, and cannot reach the new instance.
        reader.cancel()
        lagging.cancel()
        #expect(hub.endReason(of: reader) == nil)
        #expect(hub.statistics().first?.subscribers == 1)
        restarted.cancel()
        #expect(source.stops.load(ordering: .relaxed) == 1)
    }

    /// Delivering and reading change the one ring in place: a duplicated ring
    /// would cost `retainedEvents` slots per event.
    @Test func aFullRingIsNotDuplicated() async throws {
        let hub = EventHub(catalog: EventCatalog([AnyEventKind(ProbeEvent.self)]), retainedEvents: 4)
        let channel = UUID().uuidString
        let parameters: JSONValue = .object(["channel": .string(channel)])
        let subscription = try hub.subscribe("test.probe", parameters: parameters)
        let source = ProbeEvent.registry.all(channel: channel)[0]
        for value in 1...7 { source.emit(.init(value: value)) }
        let storage = try #require(hub.ringStorage()["test.probe"] ?? nil)

        source.emit(.init(value: 8))
        #expect(hub.ringStorage()["test.probe"] == storage)
        _ = await next(subscription)
        #expect(hub.ringStorage()["test.probe"] == storage)
        hub.replayLatest(to: subscription)
        #expect(hub.ringStorage()["test.probe"] == storage)
        subscription.cancel()
    }

    /// The ring holds what some subscriber has not read, and the newest event
    /// for replays; read events no longer keep their payloads alive.
    @Test func readEventsAreReleased() async throws {
        let hub = EventHub(catalog: EventCatalog([AnyEventKind(ProbeEvent.self)]), retainedEvents: 16)
        let channel = UUID().uuidString
        let parameters: JSONValue = .object(["channel": .string(channel)])
        let reader = try hub.subscribe("test.probe", parameters: parameters)
        let lagging = try hub.subscribe("test.probe", parameters: parameters)
        let source = ProbeEvent.registry.all(channel: channel)[0]
        for value in 1...5 { source.emit(.init(value: value)) }
        #expect(hub.heldEvents() == ["test.probe": 6])

        for _ in 1...6 { _ = await next(reader) }
        // The lagging subscriber has read none of events 2 to 6.
        #expect(hub.heldEvents() == ["test.probe": 5])
        #expect(await next(lagging)?.replayed == true)
        #expect(await next(lagging)?.sequence == 2)
        #expect(await next(lagging)?.sequence == 3)
        #expect(hub.heldEvents() == ["test.probe": 3])

        lagging.cancel()
        #expect(hub.heldEvents() == ["test.probe": 1])
        let late = try hub.subscribe("test.probe", parameters: parameters)
        let replay = try #require(await next(late))
        #expect(replay.replayed && replay.payload == .object(["value": .number(5)]))
        #expect(hub.statistics().first?.dropped == 0)
        reader.cancel()
        late.cancel()
    }
}

// MARK: - Pure decision logic

struct HotProcessDetectorTests {
    private func row(pid: Int32 = 10, cpu: Double, started: Double = 1_000) -> ProcessDelta {
        ProcessDelta(
            pid: pid, name: "p\(pid)", path: nil, cpuPct: cpu, cpuSeconds: cpu / 100, windowSeconds: 1,
            footprintMB: 1, diskReadMB: 0, diskWriteMB: 0, energyJoules: 0, startedAt: started, uid: 501)
    }

    @Test func episodeStartsAfterSustainAndEndsOnce() {
        var detector = HotProcessDetector(
            parameters: ProcessHotParameters(metric: .cpuPercent, above: 50, sustainSeconds: 10))
        #expect(detector.update(rows: [row(cpu: 90)], now: 0).isEmpty)
        #expect(detector.update(rows: [row(cpu: 90)], now: 5).isEmpty)
        let started = detector.update(rows: [row(cpu: 95)], now: 10)
        #expect(started.map(\.phase) == [.started])
        #expect(started.first?.aboveForSeconds == 10)
        #expect(detector.update(rows: [row(cpu: 99)], now: 15).isEmpty)
        #expect(detector.update(rows: [row(cpu: 10)], now: 20).map(\.phase) == [.ended])
        #expect(detector.update(rows: [row(cpu: 10)], now: 25).isEmpty)
    }

    @Test func dipBeforeSustainResetsTheClock() {
        var detector = HotProcessDetector(
            parameters: ProcessHotParameters(metric: .cpuPercent, above: 50, sustainSeconds: 10))
        _ = detector.update(rows: [row(cpu: 90)], now: 0)
        _ = detector.update(rows: [row(cpu: 20)], now: 5)
        #expect(detector.update(rows: [row(cpu: 90)], now: 10).isEmpty)
        #expect(detector.update(rows: [row(cpu: 90)], now: 20).map(\.phase) == [.started])
    }

    @Test func exitEndsEpisodeAndPidReuseIsANewProcess() {
        var detector = HotProcessDetector(parameters: ProcessHotParameters(metric: .cpuPercent, above: 50))
        #expect(detector.update(rows: [row(cpu: 90, started: 1)], now: 0).map(\.phase) == [.started])
        // Same pid, different start time: the old process is gone.
        let output = detector.update(rows: [row(cpu: 90, started: 2)], now: 1)
        #expect(output.map(\.phase).sorted { $0.rawValue < $1.rawValue } == [.ended, .started])
    }
}

struct ProcessIdentityTests {
    @Test func deltasPairByIdentityNotPid() {
        let early = ProcessIdentity(pid: 99, startMicroseconds: 1)
        let reused = ProcessIdentity(pid: 99, startMicroseconds: 2)
        func counters(_ identity: ProcessIdentity, cpu: Double, written: UInt64) -> ProcessCounters {
            ProcessCounters(
                identity: identity, uid: 501, name: "x", path: nil, cpuSeconds: cpu,
                usage: ResourceUsage(
                    footprintBytes: 0, diskReadBytes: 0, diskWriteBytes: written, energyNanojoules: 0))
        }
        let before = ProcessSnapshot(
            takenAt: Date(timeIntervalSince1970: 0),
            counters: [early: counters(early, cpu: 100, written: 1_000_000)])
        let after = ProcessSnapshot(
            takenAt: Date(timeIntervalSince1970: 1),
            counters: [reused: counters(reused, cpu: 1, written: 10)])
        // Pairing by pid alone would report -99 s of CPU and a wrapped write.
        #expect(ProcessSampler.deltas(previous: before, current: after, top: .max).isEmpty)
    }

    /// A process whose rusage the kernel refused reports CPU only: its
    /// footprint, disk and energy are unknown, not zero.
    @Test func refusedCountersStayUnknown() throws {
        let identity = ProcessIdentity(pid: 99, startMicroseconds: 1)
        func counters(cpu: Double) -> ProcessCounters {
            ProcessCounters(identity: identity, uid: 0, name: "x", path: nil, cpuSeconds: cpu, usage: nil)
        }
        let before = ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 0), counters: [identity: counters(cpu: 1)])
        let after = ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 1), counters: [identity: counters(cpu: 2)])
        let row = try #require(ProcessSampler.deltas(previous: before, current: after, top: .max).first)
        #expect(row.cpuSeconds == 1)
        #expect(row.footprintMB == nil && row.diskReadMB == nil && row.diskWriteMB == nil && row.energyJoules == nil)
    }

    @Test func identitySurvivesTheMillisecondRoundTrip() {
        let identity = ProcessIdentity(pid: 7, startMicroseconds: 1_792_887_367_209_920)
        #expect(ProcessIdentity(pid: 7, startedAt: identity.startedAt) == identity)
    }

    /// A number from outside reaches an integer conversion that would trap.
    @Test(arguments: [1e300, -1e300, 0])
    func processSampleRefusesAStartTimeNoProcessHas(startedAt: Double) {
        #expect(throws: EventError.self) { try ProcessSampleParameters(pid: 1, startedAt: startedAt).validate() }
    }

    @Test(arguments: [1e30, 0x20_0000_0000_0002])
    func fileChangesRefuseAnEventIdPastJSONIntegers(sinceEventId: Double) {
        let parameters = FSChangeParameters(paths: ["/tmp"], sinceEventId: sinceEventId)
        #expect(throws: EventError.self) { try parameters.validate() }
    }

    @Test func processTableHasThisProcessWithItsParent() throws {
        let me = try #require(ProcessTable.all().first { $0.pid == getpid() })
        #expect(me.parentPid == getppid())
        #expect(me.uid == getuid())
        #expect(ProcessTable.record(pid: getpid()) == me)
    }
}

struct ChurnAccumulatorTests {
    @Test func countsFlagsBucketsAndCategories() {
        var accumulator = ChurnAccumulator(root: "/Users/x", depth: 3, home: "/Users/x")
        accumulator.record([
            FSEvent(
                path: "/Users/x/src/a.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated), id: 1),
            FSEvent(
                path: "/Users/x/src/b.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), id: 2
            ),
            FSEvent(
                path: "/Users/x/.cache/z", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved), id: 3),
        ])
        let result = accumulator.result(windowSeconds: 1, topBuckets: 10)
        #expect(result.totalEvents == 3)
        #expect((result.created, result.modified, result.removed, result.renamed) == (1, 1, 1, 0))
        #expect(result.buckets.first == ChurnBucket(path: "~/src", events: 2))
        #expect(result.categories.contains(ChurnBucket(path: "authored", events: 2)))
        #expect(result.categories.contains(ChurnBucket(path: "caches", events: 1)))
    }
}

struct ChurnCategoryTests {
    /// Ordinary home-directory paths that a substring match misfiled.
    @Test(arguments: [
        ("/Users/x/.aws/config", ChurnCategory.other),
        ("/Users/x/.android/avd/x.ini", .other),
        ("/Applications/Foo.app/Contents/Info.plist", .other),
        ("/Users/x/.ollama/models/blobs/sha256-1", .other),
        ("/Users/x/.oh-my-zsh/lib/git.zsh", .authored),
        ("/Users/x/src/x.logger.ts", .authored),
        ("/Users/x/.config/x", .other),
        ("/Users/x/src/a.swift", .authored),
        ("/Users/x/lib/libfoo.a", .binaryArtifacts),
        ("/Users/x/out/Foo.dSYM/Contents/Resources/DWARF/Foo", .binaryArtifacts),
        ("/Users/x/app/node_modules", .packages),
        ("/Users/x/app/node_modules/x/index.js", .packages),
        ("/Users/x/app/build/x.o", .buildOutput),
        ("/Users/x/nix/result", .buildOutput),
        ("/Users/x/Documents/result-summary.pdf", .other),
        ("/Users/x/Pictures/result-1.png", .other),
        ("/Users/x/Documents/result/report.docx", .other),
        ("/Users/x/Library/Application Support/result-cache/x", .appMetadata),
        ("/Users/x/Library/Logs/foo.log", .logs),
        ("/Users/x/server.log", .logs),
        ("/Users/x/Desktop/.DS_Store", .appMetadata),
        ("/Users/x/.cache/z", .caches),
        ("/Users/x/repo/.git/index", .vcsMetadata),
    ])
    func classifiesByWholeComponentsAndOwnExtension(_ path: String, _ expected: ChurnCategory) {
        #expect(ChurnCategory.classify(path) == expected, "\(path)")
    }
}

struct FileScopeTests {
    @Test func excludedPathsAreNotCounted() {
        var accumulator = ChurnAccumulator(
            root: "/", depth: 3, home: "/Users/x", exclude: ["/private/var/folders", "/Users/x/Library/Caches"])
        accumulator.record([
            FSEvent(path: "/private/var/folders/ab/T/f", flags: 0, id: 1),
            FSEvent(path: "/Users/x/Library/Caches/app/blob", flags: 0, id: 2),
            FSEvent(path: "/Users/x/Library/CachesNot/kept", flags: 0, id: 3),
            FSEvent(path: "/Users/x/src/a.swift", flags: 0, id: 4),
        ])
        let result = accumulator.result(windowSeconds: 1, topBuckets: 10)
        // A sibling that merely shares the prefix ("CachesNot") still counts.
        #expect(result.totalEvents == 2)
        #expect(result.excluded == ["/private/var/folders", "/Users/x/Library/Caches"])
    }

    /// No root: the host's scope, read when the window opens, plus the
    /// subscription's own exclusions. A root replaces the scope.
    @Test func churnParametersResolveTheirScope() {
        let environment = SourceEnvironment(homeDirectory: "/Users/x")
        environment.provideFileScope { FileScope(root: "/", exclude: ["/private/var/db"]) }
        #expect(
            FSChurnParameters(exclude: ["/tmp"]).scope(in: environment)
                == FileScope(root: "/", exclude: ["/private/var/db", "/tmp"]))
        #expect(
            FSChurnParameters(root: "/Users/x").scope(in: environment) == FileScope(root: "/Users/x", exclude: []))
    }
}

struct ProcessSampleTests {
    /// Samples until `done`, then for `settle` more, so a test can see what
    /// a source sends after the event it waited for.
    private func collect(
        _ parameters: ProcessSampleParameters, settle: Duration = .zero,
        until done: @escaping @Sendable ([ProcessSamplePayload]) -> Bool
    ) async throws -> [ProcessSamplePayload] {
        let got = Mutex<[ProcessSamplePayload]>([])
        let source = ProcessSampleSource(
            parameters: parameters, identity: try #require(parameters.observedProcess),
            emit: Emitter { value, _ in
                if let payload = try? value.decode(as: ProcessSamplePayload.self) {
                    got.withLock { $0.append(payload) }
                }
            })
        try source.start()
        defer { source.stop() }
        for _ in 0..<60 where !done(got.withLock { $0 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: settle)
        return got.withLock { $0 }
    }

    /// The test process itself: idle or not, it is sampled every interval.
    @Test func followsAProcessWhileItRuns() async throws {
        let me = try #require(ProcessTable.record(pid: getpid()))
        let samples = try await collect(
            ProcessSampleParameters(pid: getpid(), startedAt: me.identity.startedAt, interval: 0.5)
        ) { $0.count >= 2 }
        #expect(samples.count >= 2)
        #expect(samples.allSatisfy { $0.running && $0.process?.pid == getpid() })
        #expect(samples.first?.process?.footprintMB != nil)
    }

    /// A start time this pid never had is another process: reported as not
    /// running, once, and never sampled.
    @Test func aReusedPidIsNotFollowed() async throws {
        // Two more intervals, in which a source that kept sampling would
        // have sent again.
        let samples = try await collect(
            ProcessSampleParameters(pid: getpid(), startedAt: 1, interval: 0.5), settle: .milliseconds(1_200)
        ) { !$0.isEmpty }
        #expect(samples == [ProcessSamplePayload(process: nil, running: false)])
    }

    /// `proc_pid_rusage` refuses another user's process (launchd is
    /// root's): it is read through `ps`, and running, not reported exited.
    @Test func followsAnotherUsersProcess() async throws {
        let launchd = try #require(ProcessTable.record(pid: 1))
        try #require(launchd.uid != getuid())
        let samples = try await collect(
            ProcessSampleParameters(pid: 1, startedAt: launchd.identity.startedAt, interval: 0.5)
        ) { $0.count >= 3 }
        #expect(samples.count >= 3)
        #expect(samples.allSatisfy { $0.running && $0.process?.pid == 1 })
        #expect(samples.allSatisfy { $0.process?.footprintMB == nil })
    }

    /// Refused and exited are told apart: one is read through `ps`, the
    /// other named.
    @Test func aTargetedSnapshotTellsRefusedFromExited() throws {
        let launchd = try #require(ProcessTable.record(pid: 1))
        let gone = try #require(ProcessIdentity(pid: getpid(), startedAt: 1))
        let (snapshot, exited) = try ProcessSampler.snapshot(of: [launchd.identity, gone])
        let row = try #require(snapshot.counters[launchd.identity])
        #expect(row.usage == nil && row.cpuSeconds > 0)
        #expect(snapshot.counters[gone] == nil)
        #expect(exited == [gone])
    }
}

struct ProcessTopTests {
    /// Every refresh re-reads the ranked rows of other users' processes, as
    /// the ranking does, so none of them leaves before the next ranking
    /// unless it exits.
    @Test func aRefreshKeepsOtherUsersRows() async throws {
        let got = Mutex<[ProcessTopPayload]>([])
        let source = ProcessTopSource(
            parameters: ProcessTopParameters(interval: 0.5, rankInterval: 2, count: 100),
            environment: SourceEnvironment(),
            emit: Emitter { value, _ in
                if let payload = try? value.decode(as: ProcessTopPayload.self) {
                    got.withLock { $0.append(payload) }
                }
            })
        try source.start()
        defer { source.stop() }
        // The second ranking, then the refreshes before the third.
        #expect(await eventually { got.withLock { payloads in payloads.count >= 4 } })
        let payloads = got.withLock { $0 }
        let ranking = try #require(payloads.first)
        let others = Set(ranking.cpu.filter { $0.uid != getuid() }.compactMap(\.identity))
        try #require(!others.isEmpty, "no other user's process was busy in the ranking window")
        let refreshes = payloads.dropFirst().filter { $0.rankedAt == ranking.rankedAt }
        #expect(!refreshes.isEmpty)
        for refresh in refreshes {
            let kept = Set(refresh.cpu.compactMap(\.identity))
            let running = others.filter { ProcessTable.record(pid: $0.pid)?.identity == $0 }
            #expect(running.isSubset(of: kept))
        }
    }
}

struct PollingSourceTests {
    private struct Unreadable: Error, CustomStringConvertible {
        var description: String { "unreadable" }
    }

    /// A failed tick is skipped and shown; only a run of `failureLimit`
    /// failures ends the subscription, once, and a success in between
    /// starts the run again.
    @Test func aMeasurementThatKeepsFailingEndsTheSubscription() async throws {
        let ticks = Mutex(0)
        let failedAt = Mutex<[(tick: Int, reason: String)]>([])
        let emit = Emitter<MemorySample>(
            sink: { _ in }, fail: { reason in failedAt.withLock { $0.append((ticks.withLock { $0 }, reason)) } })
        let source = PollingSource(label: "test", interval: 0.01, failingThrough: emit) {
            let tick = ticks.withLock { tick in
                tick += 1
                return tick
            }
            if tick == 3 { return }
            throw Unreadable()
        }
        try source.start()
        #expect(await eventually { !failedAt.withLock { $0.isEmpty } })
        #expect(source.detail?.contains("last: unreadable") == true)
        // Long enough for the ticks after the run to fail again unreported.
        try await Task.sleep(for: .milliseconds(100))
        source.stop()
        let failures = failedAt.withLock { $0 }
        #expect(failures.map(\.tick) == [3 + PollingSource.failureLimit])
        #expect(failures.first?.reason.contains("unreadable") == true)
    }

    @Test func aSourceThatDoesNotFailHasNoDetail() async throws {
        let ticks = Mutex(0)
        let source = PollingSource(label: "test", interval: 0.01) { ticks.withLock { $0 += 1 } }
        try source.start()
        #expect(await eventually { ticks.withLock { $0 } >= 3 })
        source.stop()
        #expect(source.detail == nil)
    }
}

struct SamplerCostTests {
    /// Names come from the route message rather than a per-interface
    /// `if_indextoname`; on this machine's real interfaces they must agree.
    @Test func interfaceNamesMatchTheKernelsIndex() throws {
        let counters = try InterfaceCounters.read()
        #expect(!counters.isEmpty)
        for (index, interface) in counters {
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(index, &name) != nil else { continue }
            #expect(interface.name == String(nulTerminated: name), "interface \(index)")
        }
    }

    /// One snapshot serves every caller while it is young enough; an older
    /// one is replaced.
    @Test func processSnapshotsAreSharedWhileFresh() throws {
        let shared = SharedProcessSnapshot()
        let first = try shared.current(maxAge: 60, network: NoNetworkFilter())
        #expect(try shared.current(maxAge: 60, network: NoNetworkFilter()).takenAt == first.takenAt)
        Thread.sleep(forTimeInterval: 0.05)
        #expect(try shared.current(maxAge: 0.01, network: NoNetworkFilter()).takenAt > first.takenAt)
    }
}

struct EmitterTests {
    /// A payload JSON cannot carry reaches the hub as such, not as nothing.
    @Test func aNonFiniteNumberIsReportedNotDropped() {
        let emitted = Mutex<[Emission]>([])
        let emit = Emitter<CPUSamplePayload>(sink: { emission in emitted.withLock { $0.append(emission) } })
        emit(CPUSamplePayload(usagePercent: .nan, busyCores: 0, cpuCount: 1, load1: 0, load5: 0, load15: 0))
        guard case .unencodable? = emitted.withLock({ $0.first }) else {
            Issue.record("\(emitted.withLock { $0 })")
            return
        }
    }
}

/// A kind behind a permission this process cannot have (a test runner has no
/// Bluetooth usage description), whose source records being made.
enum GatedEvent: EventKind {
    static let made = Atomic<Int>(0)
    static let descriptor = EventDescriptor(
        "test.gated", "test", mechanism: .push, semantics: .occurrence, loss: .none, permission: .required(.bluetooth),
        observation: .named, source: "test")

    static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment, emit: Emitter<EmptyPayload>
    ) throws -> any EventSource {
        made.add(1, ordering: .relaxed)
        return ClosureSource(start: {}, stop: {})
    }
}

struct PermissionGateTests {
    /// The descriptor's permission is asked before any source exists, on
    /// every path to one, so no source can touch what the permission guards
    /// without it.
    @Test func noSourceIsMadeWithoutThePermission() throws {
        let kind = AnyEventKind(GatedEvent.self)
        let hub = EventHub(catalog: EventCatalog([kind]))
        #expect(throws: EventError.self) { try hub.subscribe("test.gated") }
        let parameters = try kind.normalized(.null)
        #expect(throws: EventError.self) {
            try kind.makeSource(parameters, environment: SourceEnvironment()) { _ in }
        }
        #expect(GatedEvent.made.load(ordering: .relaxed) == 0)
    }
}
