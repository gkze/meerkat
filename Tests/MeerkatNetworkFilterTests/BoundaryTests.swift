import Foundation
import MeerkatNetworkFilter
import Testing

/// The verdict, the audit token, the messages and the daemon's subtraction:
/// everything that crosses a boundary.
struct VerdictTests {
    /// Every kind of flow is allowed and counted; there is nothing else to
    /// return (`NewFlowVerdict` has no other value).
    @Test(arguments: FlowKind.allCases) func everyFlowIsAllowedAndCounted(kind: FlowKind) {
        #expect(FlowPolicy.verdict(for: kind) == .allowAndCount)
        #expect(FlowPolicy.verdict(for: kind).statistics == .low)
    }
}

struct AuditTokenTests {
    func token(_ words: [UInt32]) -> Data {
        words.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test func readsPidVersionAndUser() {
        let key = ProcessKey(auditToken: token([0, 501, 20, 501, 20, 4_242, 100_007, 9]))
        #expect(key == ProcessKey(pid: 4_242, version: 9, uid: 501))
    }

    @Test(arguments: [0, 31, 33, 64]) func anyOtherSizeIsNoProcess(size: Int) {
        #expect(ProcessKey(auditToken: Data(repeating: 1, count: size)) == nil)
    }

    @Test(arguments: [Int32(0), -1, .min]) func aPidThatIsNotPositiveIsNoProcess(pid: Int32) {
        #expect(ProcessKey(auditToken: token([0, 0, 0, 0, 0, UInt32(bitPattern: pid), 0, 0])) == nil)
    }
}

struct FilterProtocolTests {
    let build = "0.2.0 (20)"

    func sample(processes: Int = 3, hosts: Int = 2) -> FilterSnapshot {
        var ledger = FlowLedger()
        ledger.collectsHosts = true
        for pid in 1...max(processes, 1) {
            let flow = UUID()
            ledger.record(report(flow, .opened, .test(Int32(pid)), remote: endpoint("h\(pid % max(hosts, 1)).example")))
            ledger.record(report(flow, .statistics, .test(Int32(pid)), in: UInt64(pid) * 10, out: 1))
        }
        return FilterSnapshot(
            instance: UUID(), build: build, snapshot: ledger.snapshot(), openFlows: ledger.openFlowCount)
    }

    @Test func roundTrips() throws {
        let snapshot = sample()
        let decoded = try JSONDecoder().decode(FilterSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(try decoded.validated(build: build) == snapshot)
    }

    @Test func equalStatesEncodeEqually() throws {
        var a = FlowLedger()
        var b = FlowLedger()
        let flows = (1...50).map { _ in UUID() }
        for (index, flow) in flows.enumerated() { a.record(report(flow, .opened, .test(Int32(index + 1)))) }
        for (index, flow) in flows.enumerated().reversed() { b.record(report(flow, .opened, .test(Int32(index + 1)))) }
        let instance = UUID()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(
            try encoder.encode(FilterSnapshot(instance: instance, build: build, snapshot: a.snapshot(), openFlows: 0))
                == encoder.encode(
                    FilterSnapshot(instance: instance, build: build, snapshot: b.snapshot(), openFlows: 0)))
    }

    @Test(arguments: ["\"pid\":1,", "\"host\":\"h1.example\""]) func aKeyThatCouldNotBeMadeCannotBeDecoded(
        field: String
    )
        throws
    {
        // Sorted keys, so the text edited below is where it is looked for.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: encoder.encode(sample()), encoding: .utf8))
        let broken =
            field.hasPrefix("\"pid\"")
            ? json.replacingOccurrences(of: field, with: "\"pid\":0,")
            : json.replacingOccurrences(of: field, with: "\"host\":\"\(String(repeating: "x", count: 254))\"")
        #expect(broken != json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FilterSnapshot.self, from: Data(broken.utf8)) }
    }

    @Test func validationRejectsWhatTheExtensionCouldNotHaveSent() {
        let limits = FlowLedger.Limits(flows: 4, processes: 2, hosts: 1)
        #expect(throws: FilterSnapshot.Invalid.tooManyProcesses(3)) {
            try sample(processes: 3).validated(limits: limits, build: build)
        }
        #expect(throws: FilterSnapshot.Invalid.otherBuild(extension: build, daemon: "other")) {
            try sample().validated(build: "other")
        }
    }

    @Test func validationRejectsDuplicatesAndImpossibleFlowCounts() throws {
        let snapshot = sample(processes: 2)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        var object = try #require(json)
        var processes = try #require(object["processes"] as? [Any])
        processes.append(processes[0])
        object["processes"] = processes
        let duplicated = try JSONDecoder().decode(
            FilterSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: FilterSnapshot.Invalid.duplicateProcess) { try duplicated.validated(build: build) }

        object = try #require(json)
        object["openFlows"] = -1
        let negative = try JSONDecoder().decode(
            FilterSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: FilterSnapshot.Invalid.openFlows(-1)) { try negative.validated(build: build) }
    }

    /// Arbitrary corruption of a valid reply never traps: it decodes and
    /// validates, or it is refused with an error.
    @Test func corruptRepliesNeverTrap() throws {
        let valid = try JSONEncoder().encode(sample(processes: 20, hosts: 10))
        var rng = SplitMix64(seed: 7)
        var refused = 0
        for _ in 0..<20_000 {
            var bytes = [UInt8](valid)
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                case 1 where bytes.count > 1: bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng))
                default:
                    bytes.insert(
                        UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...bytes.count, using: &rng))
                }
            }
            do {
                _ = try JSONDecoder().decode(FilterSnapshot.self, from: Data(bytes)).validated(build: build)
            } catch {
                refused += 1
            }
        }
        #expect(refused > 0)
    }

    @Test func theMachServiceIsUnderTheAppGroup() {
        // A sandboxed extension may listen only on a name its app group prefixes.
        #expect(FilterService.machServiceName(team: "TEAM123").hasPrefix(FilterService.appGroup(team: "TEAM123") + "."))
        #expect(FilterService.appGroup(team: "TEAM123").hasPrefix("TEAM123."))
    }
}

struct UsageDifferTests {
    let build = "b"

    func snapshot(_ instance: UUID, _ totals: [ProcessKey: ByteTotals]) -> FilterSnapshot {
        var processes: [ProcessKey: ByteTotals] = [:]
        for (key, value) in totals { processes[key] = value }
        return FilterSnapshot(
            instance: instance, build: build,
            snapshot: FlowLedger.Snapshot(processes: processes, hosts: [:], counters: LedgerCounters()), openFlows: 0)
    }

    @Test func theFirstSnapshotIsABaseline() {
        var differ = UsageDiffer()
        let delta = differ.next(snapshot(UUID(), [.test(1): ByteTotals(bytesIn: 500)]))
        #expect(delta.baseline)
        #expect(delta.processes.isEmpty)
    }

    @Test func subtractsAndSkipsWhatDidNotMove() {
        var differ = UsageDiffer()
        let instance = UUID()
        _ = differ.next(snapshot(instance, [.test(1): ByteTotals(bytesIn: 500), .test(2): ByteTotals(bytesIn: 9)]))
        let delta = differ.next(
            snapshot(
                instance,
                [
                    .test(1): ByteTotals(bytesIn: 800, bytesOut: 4), .test(2): ByteTotals(bytesIn: 9),
                    .test(3): ByteTotals(bytesOut: 2),
                ]))
        #expect(
            delta.processes == [.test(1): ByteTotals(bytesIn: 300, bytesOut: 4), .test(3): ByteTotals(bytesOut: 2)])
        #expect(!delta.baseline)
    }

    @Test func aRestartedExtensionIsANewBaselineNotANegativeRate() {
        var differ = UsageDiffer()
        _ = differ.next(snapshot(UUID(), [.test(1): ByteTotals(bytesIn: 5_000)]))
        let delta = differ.next(snapshot(UUID(), [.test(1): ByteTotals(bytesIn: 10)]))
        #expect(delta.baseline)
        #expect(delta.processes.isEmpty)
    }

    @Test func aTotalThatWentDownReportsNothingForThatKey() {
        var differ = UsageDiffer()
        let instance = UUID()
        _ = differ.next(snapshot(instance, [.test(1): ByteTotals(bytesIn: 5_000), .test(2): ByteTotals(bytesIn: 1)]))
        let delta = differ.next(
            snapshot(instance, [.test(1): ByteTotals(bytesIn: 10), .test(2): ByteTotals(bytesIn: 3)]))
        #expect(delta.processes == [.test(2): ByteTotals(bytesIn: 2)])
        #expect(delta.restarted == 1)
    }

    /// Readers never interfere: two daemons reading the same totals each get
    /// the full delta.
    @Test func readersAreIndependent() {
        var first = UsageDiffer()
        var second = UsageDiffer()
        let instance = UUID()
        let before = snapshot(instance, [.test(1): ByteTotals(bytesIn: 1)])
        let after = snapshot(instance, [.test(1): ByteTotals(bytesIn: 101)])
        _ = first.next(before)
        _ = second.next(before)
        #expect(first.next(after).processes == [.test(1): ByteTotals(bytesIn: 100)])
        #expect(second.next(after).processes == [.test(1): ByteTotals(bytesIn: 100)])
    }
}
