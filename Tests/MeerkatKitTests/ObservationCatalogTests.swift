import Foundation
import Testing

@testable import MeerkatKit

/// Each kind's `observation` against what the kind can tell the daemon:
/// the paths its parameters watch, the process they name, and what a rule
/// sees of its payloads. The daemon decides from these, so a kind that
/// declared one and lacked the other would be observed unchecked.
struct ObservationCatalogTests {
    static let kinds = EventCatalog.standard.kinds.map(\.name)

    @Test(arguments: kinds)
    func pathKindsSayWhatTheyWatch(_ name: String) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        #expect((kind.descriptor.observation == .paths) == kind.watchesPaths, "\(name)")
    }

    /// A kind about processes whose payloads name a user must hide other
    /// users' processes from a rule that may see only its own.
    @Test(arguments: kinds)
    func processKindsHideOtherUsers(_ name: String) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        let withUser = try kind.payloadExamples().filter { $0.canonicalString.contains("\"uid\":") }
        guard kind.descriptor.observation == .processes, !withUser.isEmpty else { return }
        let view = try #require(kind.view, "\(name) carries uids but no view")
        for example in withUser {
            #expect(view(example, RuleView(file: "a.ts", user: nil)) == example, "\(name)")
            #expect(view(example, RuleView(file: "a.ts", user: 9999)) != example, "\(name)")
        }
    }

    /// The classification the design sets: what each kind carries decides
    /// its grant, so a change here is a change of policy.
    @Test func theClassificationIsTheDesigns() {
        let byClass = Dictionary(grouping: EventCatalog.standard.kinds, by: \.descriptor.observation)
            .mapValues { Set($0.map(\.name)) }
        #expect(byClass[.paths] == ["fs.change", "fs.churn"])
        #expect(
            byClass[.processes] == [
                "process.exec", "process.exited", "process.hot", "process.list", "process.sample", "process.spawned",
                "process.top", "app.activated", "app.deactivated", "app.hidden", "app.launched", "app.terminated",
                "app.unhidden",
            ])
        #expect(
            byClass[.named] == [
                "network.flows", "window.focused", "input.activity", "pasteboard.changed", "camera.inUse",
                "audio.inUse",
                "network.wifi", "bluetooth.devices", "session.logins", "log.entry", "darwin.notification",
                "distributed.notification", "iokit.attached", "iokit.detached", "power.assertions",
            ])
        #expect(byClass[.open]?.count == 49)
    }

    /// An open kind is about this Mac, not about other users' processes:
    /// one whose payload names a process or a user (a number `pid`, `uid`,
    /// or one ending in `Pid` or `Uid`, at any depth; a device's string
    /// `uid` is not one) needs a grant, whether or not its examples happen
    /// to carry one.
    @Test(arguments: kinds)
    func openKindsNameNoProcess(_ name: String) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        guard kind.descriptor.observation == .open else { return }
        #expect(Self.processFields(kind.payloadSchema).isEmpty, "\(name)")
    }

    /// The fields of `schema` that name a process or a user, by path.
    static func processFields(_ schema: TypeSchema, at path: String = "") -> [String] {
        switch schema {
        case .array(let element, _), .record(let element):
            return processFields(element, at: path + "[]")
        case .object(let object), .named(_, let object):
            return object.fields.flatMap { field -> [String] in
                let named =
                    field.schema == .number
                    && (["pid", "uid"].contains(field.name) || field.name.hasSuffix("Pid")
                        || field.name.hasSuffix("Uid"))
                return (named ? [path + "." + field.name] : [])
                    + processFields(field.schema, at: path + "." + field.name)
            }
        default:
            return []
        }
    }

    /// The walk finds what it is for, in a kind known to carry pids.
    @Test func processFieldsAreFound() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "power.assertions"))
        #expect(Self.processFields(kind.payloadSchema) == [".assertions[].pid", ".assertions[].onBehalfOfPid"])
    }

    @Test func processSampleNamesItsProcess() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "process.sample"))
        let parameters = try kind.normalized(.object(["pid": .number(1), "startedAt": .number(1_000)]))
        #expect(parameters.observedProcess == ProcessIdentity(pid: 1, startedAt: 1_000))
    }

    @Test func churnWithoutARootWatchesTheFileScope() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "fs.churn"))
        #expect(try #require(kind.normalized(.object([:])).observedPaths).paths == nil)
        let rooted = try #require(
            kind.normalized(.object(["root": .string("/tmp"), "exclude": .array([.string("/tmp/x")])])).observedPaths)
        #expect(rooted.paths == ["/tmp"])
        #expect(rooted.exclude.count == 1)
    }

    /// `process.top`'s rows are filtered, not the whole event dropped.
    @Test func processTopKeepsTheUsersRows() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "process.top"))
        let row = { (uid: Int) -> JSONValue in
            .object([
                "pid": .number(Double(uid + 100)), "name": .string("p"), "cpuPct": .number(1), "cpuSeconds": .number(1),
                "windowSeconds": .number(1), "startedAt": .number(1_000), "uid": .number(Double(uid)),
            ])
        }
        let payload = JSONValue.object([
            "cpu": .array([row(0), row(501)]), "io": .array([row(0)]), "memory": .array([]),
            "diskReadMBps": .number(1), "diskWriteMBps": .number(2), "rankWindowSeconds": .number(5),
            "rankedAt": .number(1_000),
        ])
        let seen = try #require(kind.view?(payload, RuleView(file: "a.ts", user: 501)))
        #expect(seen["cpu"]?.arrayValue?.count == 1)
        #expect(seen["cpu"]?.arrayValue?.first?["uid"] == .number(501))
        #expect(seen["io"]?.arrayValue?.isEmpty == true)
        #expect(seen["diskWriteMBps"] == .number(2))
    }

    /// `process.list` too: a rule that may see only its own processes gets
    /// the listing of those, not no listing.
    @Test func processListKeepsTheUsersRows() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "process.list"))
        let row = { (uid: Int) -> JSONValue in
            .object([
                "pid": .number(Double(uid + 100)), "name": .string("p"), "cpuPct": .number(0), "cpuSeconds": .number(0),
                "windowSeconds": .number(5), "startedAt": .number(1_000), "uid": .number(Double(uid)),
            ])
        }
        let payload = JSONValue.object(["processes": .array([row(0), row(501), row(0)])])
        let seen = try #require(kind.view?(payload, RuleView(file: "a.ts", user: 501)))
        #expect(seen["processes"]?.arrayValue?.map { $0["uid"] } == [.number(501)])
    }
}

/// `meerkat.dropped` reports per rule file, and a rule sees only its own
/// file's: another file's subscription parameters are its paths and names.
struct DroppedByFileTests {
    @Test func dropsAreCountedPerSubscriber() async throws {
        let hub = EventHub(catalog: EventCatalog([AnyEventKind(ProbeEvent.self)]), retainedEvents: 2)
        let channel = UUID().uuidString
        let parameters: JSONValue = .object(["channel": .string(channel)])
        let a = try hub.subscribe("test.probe", parameters: parameters, subscriber: .rule(file: "a.ts"))
        let b = try hub.subscribe("test.probe", parameters: parameters, subscriber: .rule(file: "b.ts"))
        let client = try hub.subscribe("test.probe", parameters: parameters)
        let source = ProbeEvent.registry.all(channel: channel)[0]
        for value in 1...5 { source.emit(.init(value: value)) }
        let counts = Dictionary(uniqueKeysWithValues: hub.dropCounts().map { ($0.key.subscriber, $0.dropped) })
        #expect(counts == [.rule(file: "a.ts"): 4, .rule(file: "b.ts"): 4, .external: 4])
        for subscription in [a, b, client] { subscription.cancel() }
        // What a stopped source dropped is still reported, once.
        #expect(hub.takeRetiredDropCounts().count == 3)
        #expect(hub.takeRetiredDropCounts().isEmpty)
    }

    @Test func eachReportNamesItsFile() async throws {
        let hub = EventHub(
            catalog: EventCatalog([AnyEventKind(ProbeEvent.self), AnyEventKind(MeerkatDroppedEvent.self)]),
            retainedEvents: 2)
        let reports = try hub.subscribe("meerkat.dropped")
        defer { reports.cancel() }
        let channel = UUID().uuidString
        let parameters: JSONValue = .object(["channel": .string(channel)])
        let a = try hub.subscribe("test.probe", parameters: parameters, subscriber: .rule(file: "a.ts"))
        defer { a.cancel() }
        let client = try hub.subscribe("test.probe", parameters: parameters)
        defer { client.cancel() }
        let source = ProbeEvent.registry.all(channel: channel)[0]
        for value in 1...5 { source.emit(.init(value: value)) }

        // Checked every 5 seconds.
        var files: [JSONValue?] = []
        var events = reports.events.makeAsyncIterator()
        for _ in 0..<2 {
            let report = try #require(await events.next())
            #expect(report.payload["kind"] == "test.probe")
            #expect(report.payload["dropped"] == .number(4))
            files.append(report.payload["file"])
        }
        #expect(Set(files.map { $0?.stringValue ?? "client" }) == ["a.ts", "client"])
    }

    @Test func aRuleSeesOnlyItsOwnFilesReports() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "meerkat.dropped"))
        let view = try #require(kind.view)
        let report = { (file: String?) -> JSONValue in
            var fields: [String: JSONValue] = [
                "kind": .string("fs.change"), "parameters": .object(["paths": .array([.string("/private")])]),
                "dropped": .number(3),
            ]
            if let file { fields["file"] = .string(file) }
            return .object(fields)
        }
        let rule = RuleView(file: "a.ts", user: nil)
        #expect(view(report("a.ts"), rule) == report("a.ts"))
        #expect(view(report("b.ts"), rule) == nil)
        #expect(view(report(nil), rule) == nil)
    }
}

/// The design notes list the catalog's kinds in hand-written tables: each
/// must name exactly the kinds the catalog has, so a new or renamed kind
/// can't leave a note stale.
struct DesignNoteKindTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The cells of the rows of the table whose header row is `header`.
    static func rows(of header: String, in note: String) throws -> [[String]] {
        let text = try String(contentsOf: root.appendingPathComponent("docs/design/\(note)"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: header), "\(note) has no table \(header)")
        // Past the header and its delimiter row.
        return lines[(start + 2)...].prefix { $0.hasPrefix("|") }.map { row in
            row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        }
    }

    /// The backticked names in `cell`.
    static func kinds(in cell: String) -> [String] {
        cell.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    @Test func meerkatdsCatalogTableNamesEveryKind() throws {
        let listed = try Self.rows(of: "| Family | Events | Mechanism |", in: "meerkatd.md").flatMap {
            Self.kinds(in: $0[2])
        }
        #expect(listed.count == Set(listed).count, "a kind is listed twice")
        #expect(Set(listed) == Set(EventCatalog.standard.kinds.map(\.name)))
    }

    /// The observation table's `paths` and `named` rows list their kinds;
    /// the other two name families or describe them.
    @Test func effectsObservationTableListsEachClasssKinds() throws {
        let rows = try Self.rows(of: "| Observation | Kinds | Grant | Checked |", in: "effects.md")
        let byClass = Dictionary(grouping: EventCatalog.standard.kinds, by: \.descriptor.observation)
            .mapValues { Set($0.map(\.name)) }
        for observation in [EventDescriptor.Observation.paths, .named] {
            let row = try #require(rows.first { Self.kinds(in: $0[1]) == [observation.rawValue] }, "\(observation)")
            #expect(Set(Self.kinds(in: row[2])) == byClass[observation], "\(observation)")
        }
    }
}
