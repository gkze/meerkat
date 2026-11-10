import Foundation
import GRDB
import SQLiteData
import Testing

@testable import MeerkatKit
@testable import MeerkatStore

struct SampleStoreTests {
    private func temporaryDB() throws -> (SampleStore, String) {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        return (try SampleStore(path: path), path)
    }

    private func cleanup(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func makeSample(
        index: Int, cpu: Double = 12.5, stamp: String? = nil, churn: ChurnResult? = nil,
        processes: [ProcessDelta]? = nil
    ) -> SystemSample {
        let memory = MemorySample(
            pageSize: 16_384,
            freeMB: 100, activeMB: 200, inactiveMB: 50, wiredMB: 25,
            compressedMB: 10, swapUsedMB: 5, swapTotalMB: 1_024
        )
        let defaultProcesses = [
            // Another user's process: the kernel refused everything but CPU.
            ProcessDelta(
                pid: 42, name: "WindowServer", path: "/System/x/WindowServer",
                cpuPct: cpu, cpuSeconds: cpu / 100 * 5, windowSeconds: 5,
                footprintMB: nil, diskReadMB: nil, diskWriteMB: nil, energyJoules: nil,
                startedAt: 1_000, uid: 88),
            ProcessDelta(
                pid: 43, name: "mediaanalysisd", path: nil,
                cpuPct: cpu / 2, cpuSeconds: cpu / 200 * 5, windowSeconds: 5,
                footprintMB: 100, diskReadMB: 0, diskWriteMB: 2.5, energyJoules: 1,
                startedAt: 2_000, uid: 501),
        ]
        return SystemSample(
            timestamp: stamp ?? String(format: "2026-10-24T03:%02d:00Z", index),
            host: "test-host", cpuCount: 10, windowSeconds: 5, cpuUsagePercent: cpu * 2,
            load1: 1, load5: 2, load15: 3,
            memory: memory, processes: processes ?? defaultProcesses, churn: churn
        )
    }

    private func read<T>(_ path: String, _ sql: String) throws -> T? where T: DatabaseValueConvertible {
        try DatabaseQueue(path: path).read { db in try T.fetchOne(db, sql: sql) }
    }

    @Test func insertPopulatesSampleAndProcessRows() throws {
        let (store, path) = try temporaryDB()
        defer { cleanup(path) }

        try store.insert(label: "unit", sample: makeSample(index: 1))
        try store.insert(label: "unit", sample: makeSample(index: 2))

        #expect(try store.sampleCount() == 2)

        let metrics = try store.allMetrics()
        try #require(metrics.count == 2)
        let cpu = try #require(metrics[0].metrics["cpu_usage_pct"])
        let top = try #require(metrics[0].metrics["top_cpu_pct"])
        let compressed = try #require(metrics[0].metrics["compressed_mb"])
        #expect(abs(cpu - 25) < 0.001)
        #expect(abs(top - 12.5) < 0.001)
        #expect(abs(compressed - 10) < 0.001)
        // No churn was measured, so there is no churn row.
        #expect(metrics[0].metrics["churn_events"] == nil)

        let usage = try store.processUsage()
        #expect(usage.count == 4)
        #expect(Set(usage.map(\.name)) == ["WindowServer", "mediaanalysisd"])
    }

    /// Repeated text and process identities are stored once and referenced.
    @Test func executablesAndProcessesAreStoredOnce() throws {
        let (store, path) = try temporaryDB()
        defer { cleanup(path) }

        for index in 1...3 { try store.insert(label: "unit", sample: makeSample(index: index)) }

        let executables: Int? = try read(path, "SELECT count(*) FROM executables")
        let processes: Int? = try read(path, "SELECT count(*) FROM processes")
        let hosts: Int? = try read(path, "SELECT count(*) FROM hosts")
        let rows: Int? = try read(path, "SELECT count(*) FROM process_samples")
        #expect(executables == 2)
        #expect(processes == 2)
        #expect(hosts == 1)
        #expect(rows == 6)
    }

    /// Counters the kernel refused are NULL, and the others keep their
    /// integer units exactly.
    @Test func unknownCountersAreNullAndKnownOnesExact() throws {
        let (store, path) = try temporaryDB()
        defer { cleanup(path) }

        try store.insert(label: "unit", sample: makeSample(index: 1))

        let refused: Int? = try read(
            path,
            """
            SELECT count(*) FROM process_samples JOIN processes ON processes.id = process_id
            WHERE pid = 42 AND footprint_bytes IS NULL AND disk_read_bytes IS NULL
              AND disk_write_bytes IS NULL AND energy_nj IS NULL
            """)
        #expect(refused == 1)
        let written: Int? = try read(
            path,
            "SELECT disk_write_bytes FROM process_samples JOIN processes ON processes.id = process_id WHERE pid = 43")
        #expect(written == 2_500_000)
        let started: Int? = try read(path, "SELECT started_us FROM processes WHERE pid = 43")
        #expect(started == 2_000_000)
    }

    @Test func churnRowsAreWrittenAndReadBack() throws {
        let (store, path) = try temporaryDB()
        defer { cleanup(path) }

        let churn = ChurnResult(
            root: "/tmp", windowSeconds: 4, totalEvents: 9,
            created: 1, modified: 2, removed: 3, renamed: 3,
            buckets: [ChurnBucket(path: "~/a", events: 5), ChurnBucket(path: "~/b", events: 4)],
            categories: [ChurnBucket(path: "caches", events: 9)]
        )
        try store.insert(label: "unit", sample: makeSample(index: 1, churn: churn))
        try store.insert(label: "unit", sample: makeSample(index: 2, churn: churn))
        let metrics = try store.allMetrics()
        #expect(metrics.first?.metrics["churn_events"] == 9)
        let paths: Int? = try read(path, "SELECT count(*) FROM paths")
        #expect(paths == 3)
    }

    @Test func labelMetricsGroupByLabelInOrder() throws {
        let (store, path) = try temporaryDB()
        defer { cleanup(path) }

        try store.insert(label: "before", sample: makeSample(index: 1, cpu: 10))
        try store.insert(label: "before", sample: makeSample(index: 2, cpu: 20))
        try store.insert(label: "after", sample: makeSample(index: 3, cpu: 40))

        let labels = try store.labelMetrics()
        #expect(labels.map(\.label) == ["after", "before"])
        #expect(labels.map(\.count) == [1, 2])
        // Machine-wide usage, as the sample reported it.
        #expect(labels[1].cpu == [20, 40])
        #expect(labels[1].compressedGB == [0.01, 0.01])
    }

    /// The store used to substitute "now" for an unparsable timestamp, which
    /// silently misplaced the sample in the time series.
    @Test func malformedTimestampIsRejected() throws {
        let (store, path) = try temporaryDB()
        defer { cleanup(path) }

        #expect(throws: SampleStoreError.self) {
            try store.insert(label: "unit", sample: makeSample(index: 1, stamp: "yesterday"))
        }
        #expect(try store.sampleCount() == 0)
    }

    @Test func retentionKeepsNewestAndSweepsWhatNoSampleUses() throws {
        let (store, path) = try temporaryDB()
        defer { cleanup(path) }

        for index in 1...5 {
            try store.insert(label: "unit", sample: makeSample(index: index))
        }
        let loner = ProcessDelta(
            pid: 9, name: "once", path: "/bin/once", cpuPct: 1, cpuSeconds: 0.05, windowSeconds: 5,
            footprintMB: 1, diskReadMB: 0, diskWriteMB: 0, energyJoules: 0, startedAt: 3_000, uid: 501)
        try store.insert(label: "unit", sample: makeSample(index: 0, processes: [loner]))
        #expect(try store.sampleCount() == 6)

        // Retention is per label: trimming "unit" leaves "other" alone.
        try store.insert(label: "other", sample: makeSample(index: 1))
        try store.retainNewest(2, label: "unit")
        #expect(try store.sampleCount() == 3)
        try store.retainNewest(1, label: "missing")
        #expect(try store.sampleCount() == 3)

        // Kept unit's newest two (timestamps 03:04 and 03:05) and other's
        // newest; unit's oldest sample's only process and executable went
        // with it.
        #expect(try store.processUsage().count == 6)
        let executables: Int? = try read(path, "SELECT count(*) FROM executables")
        let processes: Int? = try read(path, "SELECT count(*) FROM processes")
        #expect(executables == 2)
        #expect(processes == 2)

        try store.retainNewest(1, label: "unit")
        #expect(try store.sampleCount() == 2)
        #expect(try store.processUsage().count == 4)
    }

    /// Samples older than `maxAge`, measured from the newest sample, go.
    @Test func samplesPastTheAgeLimitAreDeleted() throws {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        defer { cleanup(path) }
        let store = try SampleStore(path: path, limits: .init(maxAge: 180, maxBytes: .max))

        for minute in [0, 1, 2, 5] {
            try store.insert(label: "unit", sample: makeSample(index: minute))
        }
        // 03:05 is newest; 03:02 is exactly three minutes older and stays.
        #expect(try store.sampleCount() == 2)
    }

    /// Over `maxBytes`, the oldest samples go until the store fits.
    @Test func theStoreStaysUnderItsSizeLimit() throws {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        defer { cleanup(path) }
        let limit = 200_000
        let store = try SampleStore(path: path, limits: .init(maxAge: 86_400, maxBytes: limit))
        let processes = (0..<50).map { index in
            ProcessDelta(
                pid: Int32(100 + index), name: "worker-\(index)", path: "/usr/bin/worker-\(index)",
                cpuPct: 1, cpuSeconds: 0.05, windowSeconds: 5, footprintMB: 10, diskReadMB: 1,
                diskWriteMB: 1, energyJoules: 1, startedAt: Double(index), uid: 501)
        }

        for index in 0..<200 {
            let stamp = String(format: "2026-10-24T03:%02d:%02dZ", index / 60, index % 60)
            try store.insert(label: "unit", sample: makeSample(index: 0, stamp: stamp, processes: processes))
            #expect(try store.usedBytes() <= limit)
        }
        let kept = try store.sampleCount()
        #expect(kept > 0 && kept < 200)
        // The newest sample survives; the oldest went first.
        let newest: Int? = try read(path, "SELECT max(captured_unix) FROM samples")
        #expect(newest == (try SampleStore.unixTime("2026-10-24T03:03:19Z")))
    }

    /// A file written by a schema this build does not define is refused
    /// instead of misread.
    @Test func aFileFromAnUnknownSchemaIsRefused() throws {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        defer { cleanup(path) }
        var other = DatabaseMigrator()
        other.registerMigration("other") { db in try db.create(table: "samples") { $0.column("raw", .text) } }
        try other.migrate(DatabaseQueue(path: path))

        #expect(throws: IncompatibleStoreError.self) { try SampleStore(path: path) }
        #expect(throws: IncompatibleStoreError.self) { try RuleStore(path: path) }
    }

    /// A migration whose body changed keeps its id, so the schema itself is
    /// compared: a file whose "samples" or "rules" migration created other
    /// tables is refused, for writing and for reading, and left unchanged.
    @Test func aFileFromAnEditedMigrationIsRefused() throws {
        for id in ["samples", "rules"] {
            let path = temporaryURL("meerkat-test", suffix: ".db").path
            defer { cleanup(path) }
            var edited = DatabaseMigrator()
            edited.registerMigration(id) { db in try db.create(table: "samples") { $0.column("raw", .text) } }
            try edited.migrate(DatabaseQueue(path: path))
            let before = try Data(contentsOf: URL(filePath: path))

            #expect(throws: IncompatibleStoreError.self) { try SampleStore(path: path) }
            #expect(throws: IncompatibleStoreError.self) { try SampleStore(readingFrom: path) }
            #expect(throws: IncompatibleStoreError.self) { try RuleStore(path: path) }
            #expect(try Data(contentsOf: URL(filePath: path)) == before)
        }
    }

    /// Reading opens a store read-only: a file that is not a store, empty
    /// or not, is refused rather than migrated, and a store is read as it is.
    @Test func readingNeitherCreatesNorMigrates() throws {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        defer { cleanup(path) }
        #expect(throws: (any Error).self) { try SampleStore(readingFrom: path) }
        #expect(!FileManager.default.fileExists(atPath: path))

        try DatabaseQueue(path: path).write { db in try db.create(table: "notes") { $0.column("text", .text) } }
        let foreign = try Data(contentsOf: URL(filePath: path))
        #expect(throws: IncompatibleStoreError.self) { try SampleStore(readingFrom: path) }
        // Refused for writing too, before anything in it changes.
        #expect(throws: IncompatibleStoreError.self) { try SampleStore(path: path) }
        #expect(try Data(contentsOf: URL(filePath: path)) == foreign)

        let (store, written) = try temporaryDB()
        defer { cleanup(written) }
        try store.insert(label: "unit", sample: makeSample(index: 1))
        let reader = try SampleStore(readingFrom: written)
        #expect(try reader.sampleCount() == 1)
        #expect(throws: (any Error).self) { try reader.insert(label: "unit", sample: makeSample(index: 2)) }
    }

    /// A store copied without its WAL sidecars, which a read-only open
    /// can't take, is still read, and the copy is left a store.
    @Test func aStoreWithoutItsSidecarsIsRead() throws {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        defer { cleanup(path) }
        do {
            let store = try SampleStore(path: path)
            try store.insert(label: "unit", sample: makeSample(index: 1))
        }
        // Everything in the main file, which stays in WAL mode.
        try DatabaseQueue(path: path).writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        // A copy of the file alone, as `cp samples.db` makes.
        let copy = temporaryURL("meerkat-test", suffix: ".db").path
        defer { cleanup(copy) }
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        #expect(!FileManager.default.fileExists(atPath: copy + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: copy + "-shm"))

        let reader = try SampleStore(readingFrom: copy)
        #expect(try reader.sampleCount() == 1)
        #expect(throws: (any Error).self) { try reader.insert(label: "unit", sample: makeSample(index: 2)) }
    }

    /// A sample that was committed is reported apart from a failed insert
    /// when only applying the limits afterwards fails.
    @Test func limitsFailingAfterCommitKeepTheSample() throws {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        defer { cleanup(path) }
        let store = try SampleStore(path: path, limits: .init(maxAge: 60, maxBytes: .max))
        try store.insert(label: "unit", sample: makeSample(index: 0))
        try DatabaseQueue(path: path).write { db in
            try db.execute(
                sql: "CREATE TRIGGER refuse BEFORE DELETE ON samples BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }

        // 03:05 puts 03:00 past the age limit, whose deletion fails.
        #expect(throws: LimitsNotAppliedError.self) { try store.insert(label: "unit", sample: makeSample(index: 5)) }
        #expect(try store.sampleCount() == 2)
    }

    /// A writer's path through the store: the folder is made, and each
    /// recorded sample is followed by its label's retention.
    @Test func recordingMakesTheFolderAndRetains() throws {
        let folder = temporaryURL("meerkat-test-folder", suffix: "")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SampleStore(path: folder.appendingPathComponent("nested/samples.db").path)
        for index in 1...3 { try store.record(makeSample(index: index), label: "unit", retain: 2) }
        try store.record(makeSample(index: 4), label: "other", retain: nil)
        #expect(try store.labelMetrics().map { "\($0.label) \($0.count)" }.sorted() == ["other 1", "unit 2"])
    }

    /// Retention that fails after the commit is the same committed-but-not-
    /// bounded failure as the store's limits, naming the retention.
    @Test func retentionFailingAfterCommitKeepsTheSample() throws {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        defer { cleanup(path) }
        let store = try SampleStore(path: path)
        try store.record(makeSample(index: 0), label: "unit", retain: 1)
        try DatabaseQueue(path: path).write { db in
            try db.execute(
                sql: "CREATE TRIGGER refuse BEFORE DELETE ON samples BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        let failure = #expect(throws: LimitsNotAppliedError.self) {
            try store.record(makeSample(index: 1), label: "unit", retain: 1)
        }
        #expect(failure?.retain == 1)
        #expect(try store.sampleCount() == 2)
    }

    /// The migrations and the `@Table` types are written separately, so a
    /// rename, retype, or nullability change in one must fail here rather
    /// than at the first query that touches the column.
    @Test(arguments: [
        TableShape(HostRow.self),
        TableShape(SampleRow.self),
        TableShape(ExecutableRow.self),
        TableShape(ProcessRow.self),
        TableShape(ProcessSampleRow.self),
        TableShape(PathRow.self),
        TableShape(ChurnRow.self),
        TableShape(ChurnPathRow.self),
        TableShape(ChurnCategoryRow.self),
    ])
    func migratedSchemaMatchesTableType(_ expected: TableShape) throws {
        let (_, path) = try temporaryDB()
        defer { cleanup(path) }

        let actual = try DatabaseQueue(path: path).read { db in
            try db.columns(in: expected.name).map { column in
                SchemaColumn(
                    name: column.name,
                    type: column.type.uppercased(),
                    // An INTEGER PRIMARY KEY aliases the rowid, which is never
                    // NULL even though SQLite does not report it as NOT NULL.
                    isNullable: !column.isNotNull && column.primaryKeyIndex == 0
                )
            }
        }
        #expect(actual == expected.columns)
    }
}

struct SchemaColumn: Equatable, CustomStringConvertible {
    let name: String
    let type: String
    let isNullable: Bool

    var description: String { "\(name) \(type)\(isNullable ? "" : " NOT NULL")" }
}

/// A `@Table` type's columns, as the SQLite schema should declare them.
struct TableShape: CustomTestStringConvertible, Sendable {
    let name: String
    let columns: [SchemaColumn]

    init<T: StructuredQueriesCore.Table>(_ table: T.Type) {
        name = T.tableName
        columns = T.TableColumns.allColumns.map { Self.column($0) }
    }

    var testDescription: String { name }

    private static func column<C: TableColumnExpression>(_ column: C) -> SchemaColumn {
        let (valueType, isNullable) = unwrapOptional(C.Value.QueryOutput.self)
        return SchemaColumn(name: column.name, type: sqliteType(valueType), isNullable: isNullable)
    }

    /// Declared SQLite types the migrations use for each Swift column type.
    private static func sqliteType(_ type: Any.Type) -> String {
        switch type {
        case is any BinaryInteger.Type: return "INTEGER"
        case is any BinaryFloatingPoint.Type: return "REAL"
        case is String.Type: return "TEXT"
        case let raw as any RawRepresentable.Type: return sqliteType(rawValueType(raw))
        default: return "unmapped \(type)"
        }
    }

    private static func rawValueType<R: RawRepresentable>(_: R.Type) -> Any.Type {
        R.RawValue.self
    }

    private static func unwrapOptional(_ type: Any.Type) -> (Any.Type, Bool) {
        if let optional = type as? any OptionalType.Type {
            return (optional.wrappedType, true)
        }
        return (type, false)
    }
}

private protocol OptionalType {
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalType {
    static var wrappedType: Any.Type { Wrapped.self }
}

/// A rule's state is bounded in keys and bytes; replacing a key never
/// counts against the bound twice.
struct RuleStateLimitTests {
    @Test func stateIsBoundedPerRule() throws {
        let path = temporaryURL("meerkat-test", suffix: ".db").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try RuleStore(path: path)
        for index in 0..<EffectLimits.stateKeys {
            try store.setValue(.number(Double(index)), rule: "a.ts#r", key: "k\(index)")
        }
        #expect(throws: RuleStateLimitError.self) { try store.setValue(.null, rule: "a.ts#r", key: "one-more") }
        // Replacing an existing key, and another rule's keys, are within bounds.
        try store.setValue(.string("again"), rule: "a.ts#r", key: "k0")
        try store.setValue(.null, rule: "b.ts#r", key: "k0")

        let big = JSONValue.string(String(repeating: "x", count: 1 << 20 - 16))
        let budget = EffectLimits.stateBytes / (1 << 20)
        for index in 0..<(budget - 1) { try store.setValue(big, rule: "c.ts#r", key: "big\(index)") }
        #expect(throws: RuleStateLimitError.self) {
            try store.setValue(big, rule: "c.ts#r", key: "big\(budget - 1)")
            try store.setValue(big, rule: "c.ts#r", key: "big\(budget)")
        }
    }
}

/// `compare` and MCP's `samples_compare` share `SampleComparison`.
struct SampleComparisonTests {
    static func samples(_ cpu: [Double], swap: Double = 0) -> [[String: Double]] {
        cpu.map { ["cpu_usage_pct": $0, "swap_mb": swap] }
    }

    @Test func twoLabelsHaveADeltaAndItsWarnings() throws {
        let comparison = SampleComparison([
            ("before", Self.samples([10, 12, 11])),
            ("after", Self.samples([30, 31, 29])),
        ])
        #expect(comparison.labels.map(\.label) == ["before", "after"])
        #expect(comparison.labels[0].metrics["cpu_usage_pct"] == Spread([10, 11, 12]))
        let change = try #require(comparison.delta?["cpu_usage_pct"])
        #expect(change.change == 19)
        #expect(change.percent.map { abs($0 - 172.727) < 0.01 } == true)
        // Separate ranges, and swap didn't move on either side.
        #expect(comparison.overlapping.isEmpty)
        #expect(comparison.noisy.isEmpty)
        // A zero median has a change but no percentage.
        #expect(comparison.delta?["swap_mb"] == SampleComparison.Change(change: 0, percent: nil))
    }

    @Test func overlapAndNoiseAreFlagged() {
        let comparison = SampleComparison([("a", Self.samples([10, 40])), ("b", Self.samples([20, 30]))])
        #expect(comparison.overlapping == ["cpu_usage_pct"])
        #expect(comparison.noisy == ["cpu_usage_pct"])
    }

    /// Records group by label in the order labels first appear; with other
    /// than two there is no delta.
    @Test func recordsGroupByLabel() {
        let records = [
            StoredMetrics(label: "b", metrics: ["cpu_usage_pct": 1]),
            StoredMetrics(label: "a", metrics: ["cpu_usage_pct": 2]),
            StoredMetrics(label: "b", metrics: ["cpu_usage_pct": 3]),
            StoredMetrics(label: "c", metrics: [:]),
        ]
        let comparison = SampleComparison(records)
        #expect(comparison.labels.map(\.label) == ["b", "a", "c"])
        #expect(comparison.labels.map(\.count) == [2, 1, 1])
        #expect(comparison.labels[2].metrics.isEmpty)
        #expect(comparison.delta == nil && comparison.overlapping.isEmpty)
    }
}
