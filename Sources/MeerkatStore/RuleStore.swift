import Foundation
import GRDB
import MeerkatKit
import SQLiteData

// MARK: - Tables

@Table("rule_state")
struct RuleStateRow {
    @Column("rule_id") var ruleID: String
    var key: String
    /// The value's canonical JSON.
    var value: String
    @Column("updated_unix") var updatedUnix: Double
}

@Table("rule_log")
struct RuleLogRow {
    let id: Int64
    @Column("rule_id") var ruleID: String?
    @Column("at_unix") var atUnix: Double
    var level: String
    var message: String
}

/// The daemon's durable rule data: per-rule key–value state that survives
/// reloads and restarts, and a bounded log of what rules printed.
///
/// State is keyed by rule id (`<file>#<name>`), so renaming a rule or its
/// file starts it with empty state; that is the identity rules have.
public final class RuleStore: Sendable {
    private let dbQueue: DatabaseQueue
    /// Log rows kept; older rows are deleted as new ones arrive.
    private static let logRetention = 20_000

    /// Creates the store if the file is missing or empty; refuses a file
    /// that holds anything but this build's schema, unchanged.
    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.prepare(dbQueue, at: path)
        // After the check: the journal mode persists in the file.
        try dbQueue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
    }

    // Names are spelled out, as in SampleStore.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("rules") { db in
            try db.create(table: "rule_state") { t in
                t.column("rule_id", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.column("updated_unix", .real).notNull()
                t.primaryKey(["rule_id", "key"])
            }
            try db.create(table: "rule_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rule_id", .text)
                t.column("at_unix", .real).notNull()
                t.column("level", .text).notNull()
                t.column("message", .text).notNull()
            }
            try db.create(index: "idx_rule_log_rule_time", on: "rule_log", columns: ["rule_id", "at_unix"])
        }
        return migrator
    }

    // MARK: - State

    public func value(rule: String, key: String) throws -> JSONValue? {
        let stored = try dbQueue.read { db in
            try RuleStateRow
                .where { $0.ruleID.eq(rule) && $0.key.eq(key) }
                .select(\.value)
                .fetchOne(db)
        }
        guard let stored else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: Data(stored.utf8))
    }

    /// A rule's state is bounded (`EffectLimits.stateKeys`, `stateBytes`),
    /// so a looping or hostile rule cannot fill the disk with it.
    public func setValue(_ value: JSONValue, rule: String, key: String) throws {
        let row = RuleStateRow(
            ruleID: rule, key: key, value: value.canonicalString,
            updatedUnix: Date().timeIntervalSince1970)
        try dbQueue.write { db in
            // The rule's other keys, which this write adds to or replaces among.
            let others = try Row.fetchOne(
                db,
                sql: """
                    SELECT count(*) AS keys, coalesce(sum(length(CAST(value AS BLOB))), 0) AS bytes
                    FROM rule_state WHERE rule_id = ? AND key != ?
                    """,
                arguments: [rule, key])
            let keys: Int = others?["keys"] ?? 0
            let bytes: Int = others?["bytes"] ?? 0
            guard keys < EffectLimits.stateKeys else { throw RuleStateLimitError.keys(EffectLimits.stateKeys) }
            guard bytes + row.value.utf8.count <= EffectLimits.stateBytes else {
                throw RuleStateLimitError.bytes(EffectLimits.stateBytes)
            }
            try RuleStateRow.insert {
                row
            } onConflict: {
                ($0.ruleID, $0.key)
            } doUpdate: { updated, excluded in
                updated.value = excluded.value
                updated.updatedUnix = excluded.updatedUnix
            }.execute(db)
        }
    }

    public func deleteValue(rule: String, key: String) throws {
        try dbQueue.write { db in
            try RuleStateRow.where { $0.ruleID.eq(rule) && $0.key.eq(key) }.delete().execute(db)
        }
    }

    // MARK: - Logs

    public func appendLog(rule: String?, level: LogLevel, message: String) throws {
        try dbQueue.write { db in
            try RuleLogRow.insert {
                RuleLogRow.Draft(
                    ruleID: rule, atUnix: Date().timeIntervalSince1970, level: level.rawValue, message: message)
            }.execute(db)
            // Trim in batches of 1% so most inserts skip the delete.
            let id = db.lastInsertedRowID
            if id % Int64(Self.logRetention / 100) == 0 {
                try RuleLogRow.where { $0.id.lte(id - Int64(Self.logRetention)) }.delete().execute(db)
            }
        }
    }

    /// Newest first.
    public func logs(rule: String?, limit: Int) throws -> [RuleLogEntry] {
        try dbQueue.read { db in
            let base = RuleLogRow.order { $0.id.desc() }.limit(max(limit, 0))
            let rows = try (rule.map { rule in base.where { $0.ruleID.eq(rule) } } ?? base).fetchAll(db)
            return rows.map {
                RuleLogEntry(
                    rule: $0.ruleID, time: $0.atUnix * 1000, level: LogLevel(rawValue: $0.level) ?? .info,
                    message: $0.message)
            }
        }
    }
}

/// A `state.set` that would take a rule's state past its bounds.
public enum RuleStateLimitError: Error, CustomStringConvertible {
    case keys(Int)
    case bytes(Int)

    public var description: String {
        switch self {
        case .keys(let limit): "a rule's state holds at most \(limit) keys; delete some first"
        case .bytes(let limit): "a rule's state holds at most \(TextBounds.size(limit)) of JSON; delete some first"
        }
    }
}
