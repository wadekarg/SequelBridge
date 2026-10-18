//
//  RealSchemaTests.swift
//  SequelBridgeTests
//
//  Exercises schema shapes copied verbatim from the production servers —
//  MariaDB zero-dates, ON UPDATE CURRENT_TIMESTAMP, latin1 columns, MyISAM.
//  Needs SB_MYSQL_VERIFY=1 and SB_MYSQL_REAL_DB (default "sbreal").
//

import Foundation
import Testing
@testable import SequelBridge

private struct REnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_MYSQL_VERIFY"] == "1" && e["SB_MYSQL_REAL_DB"] != nil }
    static var host: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_MYSQL_PORT"] ?? "3309") ?? 3309 }
    static var user: String { e["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { e["SB_MYSQL_PASS"] ?? "" }
    static var db:   String { e["SB_MYSQL_REAL_DB"] ?? "sbreal" }
}

@MainActor
@Suite("Production schema shapes", .enabled(if: REnv.enabled), .serialized)
struct RealSchemaTests {

    static let table = "legacy_notes"

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        let conn = Connection(name: "real", alias: alias, connectionType: .tcpip,
                              host: REnv.host, port: REnv.port, username: REnv.user, database: REnv.db)
        try await engine.attach(conn, password: REnv.pass)
        return engine
    }

    @Test("metadata loads for a MyISAM latin1 table")
    func metadata() async throws {
        let engine = try await makeEngine("r1")
        let cols = try await engine.fetchColumns(alias: "r1", database: REnv.db, table: Self.table)
        #expect(cols.map(\.name) == ["id", "note", "user", "dlt_flg", "create_ts", "last_updt_ts"])

        let id = try #require(cols.first { $0.name == "id" })
        #expect(id.extra.lowercased().contains("auto_increment"))

        let updated = try #require(cols.first { $0.name == "last_updt_ts" })
        #expect(updated.extra.lowercased().contains("on update"))

        let meta = try await engine.fetchTableMeta(alias: "r1", database: REnv.db, table: Self.table)
        #expect(meta[0] == "MyISAM")
    }

    @Test("browsing a table containing MariaDB zero-dates")
    func zeroDateBrowse() async throws {
        let engine = try await makeEngine("r2")
        let tbl = SQLBuilder.duckTable(alias: "r2", database: REnv.db, table: Self.table)
        let r = try await engine.query("SELECT id, user, create_ts FROM \(tbl) ORDER BY id")
        #expect(r.rows.count == 3)
        // Whatever the representation, it must not be empty or crash the read.
        for row in r.rows {
            #expect(!row[2].isEmpty, "create_ts rendered empty for row \(row)")
        }
    }

    @Test("a zero-date column round-trips through the structure panel's ALTER")
    func zeroDateAlter() async throws {
        let engine = try await makeEngine("r3")
        let original = try await engine.fetchColumns(alias: "r3", database: REnv.db, table: Self.table)
        let dlt = try #require(original.first { $0.name == "dlt_flg" })
        #expect(dlt.defaultValue == "N")

        var widened = ColumnEdit(from: dlt)
        widened.length = "2"
        let stmts = SQLBuilder.alterStatements(database: REnv.db, table: Self.table,
                                               columnEdits: [widened], originalColumns: original,
                                               deletedColumnNames: [], indexEdits: [], deletedIndexNames: [])
        for sql in stmts { try await engine.mysqlExecute(alias: "r3", sql: sql) }

        let after = try await engine.fetchColumns(alias: "r3", database: REnv.db, table: Self.table)
        #expect(try #require(after.first { $0.name == "dlt_flg" }).dataType.lowercased() == "varchar(2)")
    }
}

/// Temporal fidelity is engine-independent, so it runs wherever a server is
/// configured — not only against the replicated production schema.
private struct TEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_MYSQL_PORT"] ?? "3309") ?? 3309 }
    static var user: String { e["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { e["SB_MYSQL_PASS"] ?? "" }
    static var db:   String { e["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
}

@MainActor
@Suite("Temporal fidelity", .enabled(if: TEnv.enabled), .serialized)
struct TemporalTests {

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        let conn = Connection(name: "tz", alias: alias, connectionType: .tcpip,
                              host: TEnv.host, port: TEnv.port, username: TEnv.user, database: TEnv.db)
        try await engine.attach(conn, password: TEnv.pass)
        return engine
    }

    /// Builds the fixture entirely server-side so no client-side conversion can
    /// contaminate what is stored.
    func makeFixture(_ engine: QueryEngine, _ alias: String, _ table: String) async throws {
        let t = SQLBuilder.mysqlTable(database: TEnv.db, table: table)
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(t)")
        try await engine.mysqlExecute(alias: alias, sql: """
            CREATE TABLE \(t) (`id` INT NOT NULL PRIMARY KEY, `dt` DATETIME NULL, `ts` TIMESTAMP NULL) ENGINE=InnoDB
            """)
        try await engine.mysqlExecute(alias: alias, sql: """
            INSERT INTO \(t) VALUES (1, '2026-03-01 12:34:56', '2026-03-01 12:34:56'),
                                    (2, '2026-08-01 12:34:56', '2026-08-01 12:34:56')
            """)
    }

    @Test("a TIMESTAMP column reads back exactly as stored, in winter and summer")
    func timestampNotShifted() async throws {
        let alias = "tz1"
        let engine = try await makeEngine(alias)
        try await makeFixture(engine, alias, "tz_fidelity")

        let r = try await engine.query("""
            SELECT id, dt, ts FROM \(SQLBuilder.duckTable(alias: alias, database: TEnv.db, table: "tz_fidelity")) ORDER BY id
            """)
        #expect(r.rows.count == 2)
        // DATETIME is naive and already correct; TIMESTAMP must match it.
        #expect(r.rows[0][1] == "2026-03-01 12:34:56")
        #expect(r.rows[0][2] == "2026-03-01 12:34:56", "TIMESTAMP shifted (winter/CST)")
        #expect(r.rows[1][1] == "2026-08-01 12:34:56")
        #expect(r.rows[1][2] == "2026-08-01 12:34:56", "TIMESTAMP shifted (summer/CDT)")
    }

    @Test("rendering does not depend on the machine's timezone")
    func renderingIsDeterministic() async throws {
        let alias = "tz2"
        let engine = try await makeEngine(alias)
        let tz = try await engine.query("SELECT current_setting('TimeZone') AS tz")
        // Whatever the host OS is set to, the engine pins a fixed zone so two
        // people reading the same row see the same instant.
        #expect(tz.rows.first?.first == "UTC", "engine timezone is host-dependent")
    }
}
