import Foundation
import GRDB
import MeerkatKit
import SQLiteData

/// The metrics `compare` ranks on, in the order every summary table shows
/// them. Live samples and stored ones report the same keys, so the database
/// and the terminal never disagree.
public enum SampleMetric: String, Sendable, CaseIterable {
    case cpuUsage = "cpu_usage_pct"
    case churnEvents = "churn_events"
    case compressed = "compressed_mb"
    case swap = "swap_mb"
    case free = "free_mb"
    case topCPU = "top_cpu_pct"
}

/// The metrics present, by name.
private func byName(_ metrics: [SampleMetric: Double?]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: metrics.compactMap { metric, value in value.map { (metric.rawValue, $0) } })
}

extension SystemSample {
    public var coreMetrics: [String: Double] {
        byName([
            .cpuUsage: cpuUsagePercent,
            .topCPU: processes.first?.cpuPct ?? 0,
            .free: memory.freeMB,
            .compressed: memory.compressedMB,
            .swap: memory.swapUsedMB,
            .churnEvents: churn.map { Double($0.totalEvents) },
        ])
    }
}

/// One sample's comparable metrics, as `compare` reads them back.
public struct StoredMetrics: Sendable {
    public let label: String
    public let metrics: [String: Double]

    public init(label: String, metrics: [String: Double]) {
        self.label = label
        self.metrics = metrics
    }
}

public enum SampleStoreError: Error, CustomStringConvertible {
    case invalidTimestamp(String)

    public var description: String {
        switch self {
        case .invalidTimestamp(let timestamp):
            return "sample timestamp is not ISO 8601: \(timestamp)"
        }
    }
}

/// `insert` committed the sample, but applying the store's limits afterwards
/// failed: the sample is kept, and the store may stay over its budget until
/// a later insert applies them. Distinct from an insert that failed, which
/// a writer may repeat; repeating this one would record the sample twice.
public struct LimitsNotAppliedError: Error, CustomStringConvertible {
    public let cause: any Error

    public var description: String {
        "the sample was recorded, but the store's age and size limits could not be applied: \(cause)"
    }
}

// MARK: - Tables
//
// Swift mirrors of the schema created by the migrator below. Queries are built
// from these types and compiled to SQL by StructuredQueries, so a column
// rename or type change fails at compile time instead of at run time.
// Optionality matches the column's nullability.
//
// Each table holds what was measured, once, as integers in the sampler's own
// units; percentages and MB are computed when read. Repeated text (hosts,
// executables, paths) lives in lookup tables, and a column the kernel would
// not report is NULL, never zero.

@Table("hosts")
struct HostRow {
    let id: Int
    var name: String
    @Column("cpu_count") var cpuCount: Int
}

@Table("samples")
struct SampleRow {
    let id: Int
    @Column("host_id") var hostID: Int
    /// Unix seconds; sample timestamps carry no finer precision.
    @Column("captured_unix") var capturedUnix: Int
    var label: String
    /// Measured time between the two process snapshots.
    @Column("window_ms") var windowMilliseconds: Int
    @Column("cpu_usage_pct") var cpuUsagePercent: Double?
    var load1: Double
    var load5: Double
    var load15: Double
    @Column("free_bytes") var freeBytes: Int
    @Column("active_bytes") var activeBytes: Int
    @Column("inactive_bytes") var inactiveBytes: Int
    @Column("wired_bytes") var wiredBytes: Int
    @Column("compressed_bytes") var compressedBytes: Int
    @Column("swap_used_bytes") var swapUsedBytes: Int
    @Column("swap_total_bytes") var swapTotalBytes: Int
}

/// What ran: one row per distinct short name and executable path.
@Table("executables")
struct ExecutableRow {
    let id: Int
    var name: String
    var path: String?
}

/// Which process ran it: pid plus start time is the identity the daemon
/// uses everywhere, so one row follows one process across samples.
@Table("processes")
struct ProcessRow {
    let id: Int
    var pid: Int
    @Column("started_us") var startedMicroseconds: Int
    var uid: Int
    @Column("executable_id") var executableID: Int
}

/// What a process did in one sample's window.
@Table("process_samples")
struct ProcessSampleRow {
    @Column("sample_id") var sampleID: Int
    @Column("process_id") var processID: Int
    @Column("cpu_us") var cpuMicroseconds: Int
    @Column("footprint_bytes") var footprintBytes: Int?
    @Column("disk_read_bytes") var diskReadBytes: Int?
    @Column("disk_write_bytes") var diskWriteBytes: Int?
    @Column("energy_nj") var energyNanojoules: Int?
}

@Table("paths")
struct PathRow {
    let id: Int
    var path: String
}

/// Filesystem activity, for samples that measured it.
@Table("churn")
struct ChurnRow {
    @Column("sample_id") var sampleID: Int
    @Column("root_path_id") var rootPathID: Int
    @Column("window_ms") var windowMilliseconds: Int
    /// Not the sum of the four below: an event can carry several flags or
    /// none of them.
    var events: Int
    var created: Int
    var modified: Int
    var removed: Int
    var renamed: Int
}

@Table("churn_paths")
struct ChurnPathRow {
    @Column("sample_id") var sampleID: Int
    @Column("path_id") var pathID: Int
    var events: Int
}

@Table("churn_categories")
struct ChurnCategoryRow {
    @Column("sample_id") var sampleID: Int
    var category: String
    var events: Int
}

/// Time-series store for samples: SQLite through GRDB, queried with
/// SQLiteData's type-safe builder.
public final class SampleStore {
    /// Bounds the store keeps by itself after every insert, whatever the
    /// writer asked for; a rule's or the CLI's `retain` can only tighten
    /// them.
    public struct Limits: Sendable, Equatable {
        /// Samples this much older than the newest one are deleted. Measured
        /// from the newest sample, not the clock, so a store that stops
        /// receiving samples keeps its history.
        public var maxAge: TimeInterval
        /// Bytes of database pages in use (the file's size once vacuumed);
        /// the oldest samples go first.
        public var maxBytes: Int

        public init(maxAge: TimeInterval, maxBytes: Int) {
            self.maxAge = maxAge
            self.maxBytes = maxBytes
        }

        public init(maxAgeDays: Int, maxMegabytes: Int) {
            self.init(maxAge: TimeInterval(maxAgeDays) * 86_400, maxBytes: maxMegabytes * 1_000_000)
        }

        public static let standard = Limits(
            maxAgeDays: SampleBudget.maxAgeDays, maxMegabytes: SampleBudget.maxMegabytes)
    }

    private let dbQueue: DatabaseQueue
    public let limits: Limits

    /// Opens the store at `path` for writing, creating it if the file is
    /// missing or empty. A file that holds anything but this build's schema
    /// is refused unchanged (`IncompatibleStoreError`).
    public init(path: String, limits: Limits = .standard) throws {
        self.limits = limits
        // GRDB enables foreign keys by default, which the cascades rely on.
        // The CLI and the daemon can write the same file, so a writer waits
        // for the other instead of failing.
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try Self.migrator.prepare(dbQueue, at: path)
        // Only once the file is known to be a store, since the journal mode
        // persists in the file. Set directly: `Configuration.journalMode =
        // .wal` would also lower `synchronous` to NORMAL.
        try dbQueue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        try Self.enableIncrementalVacuum(dbQueue)
    }

    /// Opens an existing store only to read it: nothing is created, migrated
    /// or vacuumed, and a file that does not hold this build's schema is
    /// refused (`IncompatibleStoreError`). Writes through it fail.
    ///
    /// A store is in WAL mode, and SQLite can't open one read-only without
    /// its `-wal` and `-shm` files, which a copied or restored store has
    /// lost. Then a read-write connection that only reads makes them, and
    /// the store is opened read-only again: those files are all it adds.
    public init(readingFrom path: String) throws {
        limits = .standard
        // The read-write open below would create a missing file.
        guard FileManager.default.fileExists(atPath: path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        func open() throws -> DatabaseQueue {
            let queue = try DatabaseQueue(path: path, configuration: configuration)
            try Self.migrator.verify(queue, at: path)
            return queue
        }
        do {
            dbQueue = try open()
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
            // Held open until the read-only one is, so the files it made
            // are there whatever SQLite does on close.
            let maker = try DatabaseQueue(path: path)
            try maker.read { db in _ = try Int.fetchOne(db, sql: "PRAGMA schema_version") }
            dbQueue = try withExtendedLifetime(maker) { try open() }
        }
    }

    // MARK: - Schema
    //
    // The migration spells out names instead of deriving them from the
    // `@Table` types above, so renaming a Swift property cannot change the
    // file's columns; `SampleStoreTests` checks that the migrated schema
    // still matches those types. A file whose schema differs from what this
    // migrator creates is refused (`IncompatibleStoreError`).

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("samples") { db in
            try db.create(table: "hosts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("cpu_count", .integer).notNull()
                t.uniqueKey(["name", "cpu_count"])
            }
            try db.create(table: "samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("host_id", .integer).notNull().references("hosts")
                t.column("captured_unix", .integer).notNull()
                t.column("label", .text).notNull()
                t.column("window_ms", .integer).notNull()
                t.column("cpu_usage_pct", .real)
                for name in ["load1", "load5", "load15"] {
                    t.column(name, .real).notNull()
                }
                for name in [
                    "free_bytes", "active_bytes", "inactive_bytes", "wired_bytes",
                    "compressed_bytes", "swap_used_bytes", "swap_total_bytes",
                ] {
                    t.column(name, .integer).notNull()
                }
            }
            try db.create(table: "executables") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("path", .text)
            }
            // UNIQUE treats NULLs as distinct, so the key folds a missing path
            // into one value.
            try db.execute(
                sql: "CREATE UNIQUE INDEX idx_executables_identity ON executables(name, ifnull(path, ''))")
            try db.create(table: "processes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pid", .integer).notNull()
                t.column("started_us", .integer).notNull()
                t.column("uid", .integer).notNull()
                t.column("executable_id", .integer).notNull().references("executables")
                // exec keeps the pid and start time but changes the executable.
                t.uniqueKey(["pid", "started_us", "executable_id"])
            }
            try db.create(table: "process_samples", options: .withoutRowID) { t in
                t.column("sample_id", .integer).notNull()
                    .references("samples", onDelete: .cascade)
                t.column("process_id", .integer).notNull().references("processes")
                t.column("cpu_us", .integer).notNull()
                for name in ["footprint_bytes", "disk_read_bytes", "disk_write_bytes", "energy_nj"] {
                    t.column(name, .integer)
                }
                t.primaryKey(["sample_id", "process_id"])
            }
            try db.create(table: "paths") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
            }
            try db.create(table: "churn") { t in
                t.primaryKey("sample_id", .integer)
                    .references("samples", onDelete: .cascade)
                t.column("root_path_id", .integer).notNull().references("paths")
                for name in ["window_ms", "events", "created", "modified", "removed", "renamed"] {
                    t.column(name, .integer).notNull()
                }
            }
            try db.create(table: "churn_paths", options: .withoutRowID) { t in
                t.column("sample_id", .integer).notNull()
                    .references("samples", onDelete: .cascade)
                t.column("path_id", .integer).notNull().references("paths")
                t.column("events", .integer).notNull()
                t.primaryKey(["sample_id", "path_id"])
            }
            try db.create(table: "churn_categories", options: .withoutRowID) { t in
                t.column("sample_id", .integer).notNull()
                    .references("samples", onDelete: .cascade)
                t.column("category", .text).notNull()
                t.column("events", .integer).notNull()
                t.primaryKey(["sample_id", "category"])
            }
            try db.create(index: "idx_samples_time", on: "samples", columns: ["captured_unix"])
            try db.create(index: "idx_samples_label_time", on: "samples", columns: ["label", "captured_unix"])
            // Following one process, or one program, across samples; the
            // orphan sweep after retention also uses them.
            try db.create(index: "idx_process_samples_process", on: "process_samples", columns: ["process_id"])
            try db.create(index: "idx_processes_executable", on: "processes", columns: ["executable_id"])
            try db.create(index: "idx_churn_paths_path", on: "churn_paths", columns: ["path_id"])
        }
        return migrator
    }

    /// `PRAGMA auto_vacuum` is ignored on a file that already holds tables, so
    /// set it and rewrite the file once instead of silently no-opping later.
    private static func enableIncrementalVacuum(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.writeWithoutTransaction { db in
            let mode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
            guard mode != 2 else { return }
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: - Writing

    /// Records one sample in a transaction, then applies `limits`. Throws
    /// `LimitsNotAppliedError` when only the second step failed.
    public func insert(label: String, sample: SystemSample) throws {
        let capturedUnix = try Self.unixTime(sample.timestamp)
        let memory = sample.memory

        // Lookups then inserts, in one IMMEDIATE transaction so two writers
        // cannot both miss a row and race to create it.
        try dbQueue.writeWithoutTransaction { db in
            try db.inTransaction(.immediate) {
                let hostID = try Self.hostID(name: sample.host, cpuCount: sample.cpuCount, db)
                let draft = SampleRow.Draft(
                    hostID: hostID,
                    capturedUnix: capturedUnix,
                    label: label,
                    windowMilliseconds: Self.milliseconds(sample.windowSeconds),
                    cpuUsagePercent: sample.cpuUsagePercent,
                    load1: sample.load1,
                    load5: sample.load5,
                    load15: sample.load15,
                    freeBytes: Self.bytes(megabytes: memory.freeMB),
                    activeBytes: Self.bytes(megabytes: memory.activeMB),
                    inactiveBytes: Self.bytes(megabytes: memory.inactiveMB),
                    wiredBytes: Self.bytes(megabytes: memory.wiredMB),
                    compressedBytes: Self.bytes(megabytes: memory.compressedMB),
                    swapUsedBytes: Self.bytes(megabytes: memory.swapUsedMB),
                    swapTotalBytes: Self.bytes(megabytes: memory.swapTotalMB)
                )
                try SampleRow.insert { draft }.execute(db)
                let sampleID = Int(db.lastInsertedRowID)

                let processRows = try sample.processes.map { process in
                    let identity = process.identity
                    let executableID = try Self.executableID(name: process.name, path: process.path, db)
                    let processID = try Self.processID(
                        pid: Int(identity.pid), startedMicroseconds: Int(identity.startMicroseconds),
                        uid: Int(process.uid), executableID: executableID, db)
                    return ProcessSampleRow(
                        sampleID: sampleID,
                        processID: processID,
                        cpuMicroseconds: Int((process.cpuSeconds * 1e6).rounded()),
                        footprintBytes: process.footprintMB.map(Self.bytes(megabytes:)),
                        diskReadBytes: process.diskReadMB.map(Self.bytes(megabytes:)),
                        diskWriteBytes: process.diskWriteMB.map(Self.bytes(megabytes:)),
                        energyNanojoules: process.energyJoules.map { Int(($0 * 1e9).rounded()) }
                    )
                }
                if !processRows.isEmpty {
                    try ProcessSampleRow.insert { processRows }.execute(db)
                }

                if let churn = sample.churn {
                    let row = ChurnRow(
                        sampleID: sampleID,
                        rootPathID: try Self.pathID(churn.root, db),
                        windowMilliseconds: Self.milliseconds(churn.windowSeconds),
                        events: churn.totalEvents,
                        created: churn.created,
                        modified: churn.modified,
                        removed: churn.removed,
                        renamed: churn.renamed
                    )
                    try ChurnRow.insert { row }.execute(db)
                    // Bucket and category keys come from dictionaries, so each
                    // is unique within the sample.
                    let paths = try churn.buckets.map {
                        ChurnPathRow(sampleID: sampleID, pathID: try Self.pathID($0.path, db), events: $0.events)
                    }
                    if !paths.isEmpty { try ChurnPathRow.insert { paths }.execute(db) }
                    let categories = churn.categories.map {
                        ChurnCategoryRow(sampleID: sampleID, category: $0.path, events: $0.events)
                    }
                    if !categories.isEmpty { try ChurnCategoryRow.insert { categories }.execute(db) }
                }
                return .commit
            }
        }
        do {
            try enforceLimits()
        } catch {
            throw LimitsNotAppliedError(cause: error)
        }
    }

    private static func hostID(name: String, cpuCount: Int, _ db: Database) throws -> Int {
        if let id = try HostRow.where({ $0.name.eq(name) && $0.cpuCount.eq(cpuCount) }).select(\.id).fetchOne(db) {
            return id
        }
        try HostRow.insert { HostRow.Draft(name: name, cpuCount: cpuCount) }.execute(db)
        return Int(db.lastInsertedRowID)
    }

    private static func executableID(name: String, path: String?, _ db: Database) throws -> Int {
        if let id = try ExecutableRow.where({ $0.name.eq(name) && $0.path.is(path) }).select(\.id).fetchOne(db) {
            return id
        }
        try ExecutableRow.insert { ExecutableRow.Draft(name: name, path: path) }.execute(db)
        return Int(db.lastInsertedRowID)
    }

    private static func processID(
        pid: Int, startedMicroseconds: Int, uid: Int, executableID: Int, _ db: Database
    ) throws -> Int {
        let existing =
            try ProcessRow
            .where {
                $0.pid.eq(pid) && $0.startedMicroseconds.eq(startedMicroseconds) && $0.executableID.eq(executableID)
            }
            .select(\.id)
            .fetchOne(db)
        if let existing { return existing }
        try ProcessRow.insert {
            ProcessRow.Draft(pid: pid, startedMicroseconds: startedMicroseconds, uid: uid, executableID: executableID)
        }.execute(db)
        return Int(db.lastInsertedRowID)
    }

    private static func pathID(_ path: String, _ db: Database) throws -> Int {
        if let id = try PathRow.where({ $0.path.eq(path) }).select(\.id).fetchOne(db) { return id }
        try PathRow.insert { PathRow.Draft(path: path) }.execute(db)
        return Int(db.lastInsertedRowID)
    }

    // MARK: - Retention

    /// Keeps the newest `count` samples recorded under `label` and deletes
    /// that label's older ones. Other labels are untouched: each writer
    /// bounds its own series, and `limits` bounds the store as a whole.
    public func retainNewest(_ count: Int, label: String) throws {
        guard count > 0 else { return }
        try deleteSamples { db in
            let newest =
                SampleRow
                .where { $0.label.eq(label) }
                .order { ($0.capturedUnix.desc(), $0.id.desc()) }
                .limit(count)
                .select(\.id)
            try SampleRow.where { $0.label.eq(label) && !$0.id.in(newest) }.delete().execute(db)
        }
    }

    /// Bytes of pages in use; free pages are excluded, since incremental
    /// vacuum hands them back to the file system.
    public func usedBytes() throws -> Int {
        try dbQueue.read { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let size = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return (pages - free) * size
        }
    }

    /// Applies `limits`: age first, then size. Over the size limit, it
    /// deletes the oldest samples until the store is at 90% of it, so that
    /// a store at its limit does not delete on every insert.
    func enforceLimits() throws {
        let cutoff = try dbQueue.read { db in
            try SampleRow.select { $0.capturedUnix.max() }.fetchOne(db).flatMap { $0 }
        }.map { $0 - Int(limits.maxAge) }
        if let cutoff,
            try dbQueue.read({ db in try SampleRow.where { $0.capturedUnix.lt(cutoff) }.fetchCount(db) }) > 0
        {
            try deleteSamples { db in try SampleRow.where { $0.capturedUnix.lt(cutoff) }.delete().execute(db) }
        }

        // Lookup rows are not deleted with samples until nothing uses them,
        // so each pass estimates from the average and the loop is bounded.
        for _ in 0..<8 {
            let used = try usedBytes()
            let count = try sampleCount()
            guard used > limits.maxBytes, count > 0 else { return }
            let excess = used - limits.maxBytes * 9 / 10
            let perSample = max(used / count, 1)
            let oldest = min(max((excess + perSample - 1) / perSample, 1), count)
            try deleteSamples { db in
                let doomed =
                    SampleRow
                    .order { ($0.capturedUnix, $0.id) }
                    .limit(oldest)
                    .select(\.id)
                try SampleRow.where { $0.id.in(doomed) }.delete().execute(db)
            }
        }
    }

    /// Runs `delete`, then removes what no remaining sample refers to. Child
    /// rows go through `ON DELETE CASCADE`; processes, executables, paths and
    /// hosts are swept here, and the freed pages are returned to the file
    /// system.
    private func deleteSamples(_ delete: (Database) throws -> Void) throws {
        try dbQueue.write { db in
            try delete(db)
            try ProcessRow.where { !$0.id.in(ProcessSampleRow.select(\.processID)) }.delete().execute(db)
            try ExecutableRow.where { !$0.id.in(ProcessRow.select(\.executableID)) }.delete().execute(db)
            try PathRow.where {
                !$0.id.in(ChurnPathRow.select(\.pathID)) && !$0.id.in(ChurnRow.select(\.rootPathID))
            }.delete().execute(db)
            try HostRow.where { !$0.id.in(SampleRow.select(\.hostID)) }.delete().execute(db)
        }
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
    }

    // MARK: - Reading

    public func sampleCount() throws -> Int {
        try dbQueue.read { db in try SampleRow.fetchCount(db) }
    }

    /// Every sample's comparable metrics, oldest first, under the keys of
    /// `SystemSample.coreMetrics`.
    public func allMetrics() throws -> [StoredMetrics] {
        try dbQueue.read { db in
            try Self.metrics(of: SampleRow.order { ($0.capturedUnix, $0.id) }, in: db).map(\.metrics)
        }
    }

    /// The newest `limit` samples recorded under `label`, newest first, with
    /// when each was captured. Reads only those samples' rows, so its cost
    /// does not grow with the store.
    public func recentMetrics(label: String, limit: Int) throws -> [TimedMetrics] {
        try dbQueue.read { db in
            let selected = SampleRow.where { $0.label.eq(label) }
                .order { ($0.capturedUnix.desc(), $0.id.desc()) }
                .limit(max(limit, 0))
            return try Self.metrics(of: selected, in: db)
        }
    }

    /// The metrics of the samples `selected` picks, in its order.
    private static func metrics(of selected: SelectOf<SampleRow>, in db: Database) throws -> [TimedMetrics] {
        let topCPU =
            try ProcessSampleRow
            .where { $0.sampleID.in(selected.select(\.id)) }
            .group(by: \.sampleID)
            .select { ($0.sampleID, $0.cpuMicroseconds.max()) }
            .fetchAll(db)
        let churn = try ChurnRow.where { $0.sampleID.in(selected.select(\.id)) }
            .select { ($0.sampleID, $0.events) }
            .fetchAll(db)
        let rows =
            try selected
            .select {
                (
                    $0.id, $0.capturedUnix, $0.label, $0.windowMilliseconds, $0.cpuUsagePercent,
                    $0.freeBytes, $0.compressedBytes, $0.swapUsedBytes
                )
            }
            .fetchAll(db)
        return timed(rows, topCPU: topCPU, churn: churn)
    }

    /// One sample's metrics and its capture time (Unix seconds).
    public struct TimedMetrics: Sendable {
        public let capturedUnix: Int
        public let metrics: StoredMetrics
    }

    /// Sample rows (id, captured, label, window, cpu, free, compressed,
    /// swap) as metrics, with each sample's busiest process and churn count.
    private static func timed(
        _ rows: [(Int, Int, String, Int, Double?, Int, Int, Int)], topCPU: [(Int, Int?)], churn: [(Int, Int)]
    ) -> [TimedMetrics] {
        let topCPU = Dictionary(uniqueKeysWithValues: topCPU.compactMap { id, cpu in cpu.map { (id, $0) } })
        let churnEvents = Dictionary(uniqueKeysWithValues: churn)
        return rows.map { id, captured, label, window, cpu, free, compressed, swap in
            let metrics = byName([
                .cpuUsage: cpu,
                .topCPU: percentOfOneCore(topCPU[id] ?? 0, windowMilliseconds: window),
                .free: megabytes(free),
                .compressed: megabytes(compressed),
                .swap: megabytes(swap),
                .churnEvents: churnEvents[id].map(Double.init),
            ])
            return TimedMetrics(capturedUnix: captured, metrics: StoredMetrics(label: label, metrics: metrics))
        }
    }

    public struct LabelMetrics: Sendable {
        public let label: String
        public let count: Int
        /// Machine-wide, percent of all cores.
        public let cpu: [Double]
        public let compressedGB: [Double]
        public let swapGB: [Double]
    }

    public struct ProcessUsage: Sendable {
        public let sampleID: Int
        public let name: String
        /// Percent of one core over the sample's window.
        public let cpuPct: Double
    }

    public func labelMetrics() throws -> [LabelMetrics] {
        let rows = try dbQueue.read { db in
            try SampleRow
                .order { ($0.label, $0.capturedUnix, $0.id) }
                .select { ($0.label, $0.cpuUsagePercent, $0.compressedBytes, $0.swapUsedBytes) }
                .fetchAll(db)
        }
        var order: [String] = []
        var grouped: [String: (count: Int, cpu: [Double], compressed: [Double], swap: [Double])] = [:]
        for (label, cpu, compressed, swap) in rows {
            if grouped[label] == nil { order.append(label) }
            var entry = grouped[label] ?? (0, [], [], [])
            entry.count += 1
            if let cpu { entry.cpu.append(cpu) }
            entry.compressed.append(Self.megabytes(compressed) / 1000)
            entry.swap.append(Self.megabytes(swap) / 1000)
            grouped[label] = entry
        }
        return order.compactMap { label in
            grouped[label].map {
                LabelMetrics(
                    label: label, count: $0.count, cpu: $0.cpu,
                    compressedGB: $0.compressed, swapGB: $0.swap)
            }
        }
    }

    public func processUsage() throws -> [ProcessUsage] {
        try dbQueue.read { db in
            try ProcessSampleRow
                .join(ProcessRow.all) { $0.processID.eq($1.id) }
                .join(ExecutableRow.all) { $1.executableID.eq($2.id) }
                .join(SampleRow.all) { $0.sampleID.eq($3.id) }
                .select { ($0.sampleID, $2.name, $0.cpuMicroseconds, $3.windowMilliseconds) }
                .fetchAll(db)
                .map { sampleID, name, cpu, window in
                    ProcessUsage(
                        sampleID: sampleID, name: name,
                        cpuPct: Self.percentOfOneCore(cpu, windowMilliseconds: window))
                }
        }
    }

    // MARK: - Units
    //
    // The sampler reports integers (bytes, nanojoules, timebase ticks) and
    // its payload converts them to decimal MB and seconds; rounding the
    // conversion back recovers the integer exactly at these magnitudes.

    static func bytes(megabytes: Double) -> Int { Int((megabytes * 1_000_000).rounded()) }
    static func megabytes(_ bytes: Int) -> Double { Double(bytes) / 1_000_000 }
    static func milliseconds(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    static func percentOfOneCore(_ cpuMicroseconds: Int, windowMilliseconds: Int) -> Double {
        Double(cpuMicroseconds) / Double(max(windowMilliseconds, 1)) / 10
    }

    /// Samples are stamped by `ISO8601DateFormatter` with internet date-time
    /// options; anything else is a caller bug, not a reason to invent a time.
    static func unixTime(_ timestamp: String) throws -> Int {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: timestamp) else {
            throw SampleStoreError.invalidTimestamp(timestamp)
        }
        return Int(date.timeIntervalSince1970)
    }
}
