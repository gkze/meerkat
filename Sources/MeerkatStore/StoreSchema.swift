import GRDB

/// A store file that does not hold this build's schema: written by a
/// different schema, or not a store at all. It is refused rather than read,
/// since its columns may not mean what this build's queries expect, and
/// rather than migrated, since that would change a file Meerkat did not
/// write.
public struct IncompatibleStoreError: Error, CustomStringConvertible {
    public let path: String

    public var description: String {
        "\(path) was written by a different schema than this build's, or is not a Meerkat store; move it aside"
    }
}

/// One table, index or trigger as SQLite records it. Optional throughout:
/// the file may come from anywhere, and a crafted schema table must not
/// trap the reader.
struct SchemaObject: Hashable {
    let type: String?
    let name: String?
    let table: String?
    let sql: String?
}

extension DatabaseMigrator {
    /// Makes `database` a store of this build's schema before it is written:
    /// an empty file is migrated, a file that holds the schema already is
    /// used as it is, and anything else is refused before it is changed.
    func prepare(_ database: DatabaseQueue, at path: String) throws {
        let empty = try database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") == 0 }
        if empty {
            try migrate(database)
        } else {
            try verify(database, at: path)
        }
    }

    /// Refuses `database` unless it holds exactly the schema these
    /// migrations create, with all of them recorded as applied. It only
    /// reads, so it also serves a store opened read-only.
    ///
    /// The schema itself is compared, not just the migration ids the file
    /// lists, because a migration whose body changed keeps its id. What is
    /// compared is the SQL GRDB generated, so a GRDB release that spelled the
    /// same schema differently would refuse existing files too; before 1.0
    /// the remedy is the same as for a schema change.
    func verify(_ database: some DatabaseReader, at path: String) throws {
        let expected = try expectedSchema()
        let matches = try database.read { db in
            try hasCompletedMigrations(db) && !hasBeenSuperseded(db) && Self.schema(db) == expected
        }
        guard matches else { throw IncompatibleStoreError(path: path) }
    }

    /// The schema these migrations create, read back from an in-memory
    /// database.
    func expectedSchema() throws -> Set<SchemaObject> {
        let database = try DatabaseQueue()
        try migrate(database)
        return try database.read(Self.schema)
    }

    /// Every object in `db` except SQLite's own and GRDB's migration table.
    static func schema(_ db: Database) throws -> Set<SchemaObject> {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT type, name, tbl_name, sql FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                """)
        return Set(rows.map { SchemaObject(type: $0["type"], name: $0["name"], table: $0["tbl_name"], sql: $0["sql"]) })
    }
}
