//
//  DestructiveDDLVerifyTests.swift
//  SequelBridgeTests
//
//  End-to-end verification of the new drop-table / truncate-table (sidebar) and
//  server-side ORDER BY (Content) builders, exercised through the real QueryEngine
//  against local MariaDB. Gated behind SB_DDL_VERIFY=1 (pass it as an EXPORTED
//  TEST_RUNNER_SB_DDL_VERIFY=1). Needs a MySQL family server (SB_MYSQL_*; default MariaDB :3309 root/sbverify123), db sbwrite.
//

import Foundation
import Testing
@testable import SequelBridge

private struct DDLVEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_DDL_VERIFY"] == "1" }
    // The MySQL family server under test: MariaDB on the first pass, MySQL 8 on the second.
    static var host: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_MYSQL_PORT"] ?? "") ?? 3309 }
    static var user: String { e["SB_MYSQL_USER"] ?? "root" }
    static var pass: String { e["SB_MYSQL_PASS"] ?? "sbverify123" }
}

@MainActor
@Suite("Destructive DDL + sort end-to-end", .enabled(if: DDLVEnv.enabled), .serialized)
struct DestructiveDDLVerifyTests {

    private let alias = "maria10"
    private let db = "sbwrite"

    private func makeEngine() async throws -> QueryEngine {
        let e = try QueryEngine()
        let c = Connection(name: alias, alias: alias, connectionType: .tcpip,
                           host: DDLVEnv.host, port: DDLVEnv.port, username: DDLVEnv.user,
                           database: db, engine: .mysql)
        try await e.attach(c, password: DDLVEnv.pass)
        return e
    }

    private func mref(_ tbl: String) -> String { SQLBuilder.mysqlTable(database: db, table: tbl) }
    private func dref(_ tbl: String) -> String { SQLBuilder.duckTable(alias: alias, database: db, table: tbl) }

    private func freshTable(_ e: QueryEngine, _ tbl: String) async throws {
        try await e.executeDDL(alias: alias, sql: "DROP TABLE IF EXISTS \(mref(tbl))")
        try await e.executeDDL(alias: alias,
            sql: "CREATE TABLE \(mref(tbl)) (`id` INT NOT NULL, PRIMARY KEY(`id`)) ENGINE=InnoDB")
    }

    @Test("truncateTable builder empties the table through executeDDL")
    func truncate() async throws {
        let e = try await makeEngine()
        let tbl = "_sb_ddl_trunc"
        try await freshTable(e, tbl)
        for i in 1...3 {
            try await e.executeDDL(alias: alias, sql: "INSERT INTO \(mref(tbl)) (`id`) VALUES (\(i))")
        }
        let before = try await e.query("SELECT COUNT(*) FROM \(dref(tbl))")
        #expect(before.rows.first?.first == "3")

        try await e.executeDDL(alias: alias, sql: SQLBuilder.truncateTable(engine: .mysql, database: db, table: tbl))
        let after = try await e.query("SELECT COUNT(*) FROM \(dref(tbl))")
        #expect(after.rows.first?.first == "0")

        try await e.executeDDL(alias: alias, sql: SQLBuilder.dropTable(engine: .mysql, database: db, table: tbl))
    }

    @Test("dropTable builder removes the table (subsequent read fails at the server)")
    func drop() async throws {
        let e = try await makeEngine()
        let tbl = "_sb_ddl_drop"
        try await freshTable(e, tbl)
        _ = try await e.query("SELECT COUNT(*) FROM \(dref(tbl))")   // exists, readable

        try await e.executeDDL(alias: alias, sql: SQLBuilder.dropTable(engine: .mysql, database: db, table: tbl))
        await #expect(throws: (any Error).self) {
            _ = try await e.query("SELECT COUNT(*) FROM \(dref(tbl))")
        }
    }

    private func conn() -> Connection {
        Connection(name: alias, alias: alias, connectionType: .tcpip,
                   host: DDLVEnv.host, port: DDLVEnv.port, username: DDLVEnv.user,
                   database: db, engine: .mysql)
    }

    @Test("detach releases the alias so a reconnect succeeds (was: Connection query failed)")
    func detachAllowsReattach() async throws {
        let e = try QueryEngine()
        try await e.attach(conn(), password: DDLVEnv.pass)
        // Root cause this guards: attach() runs `USE "alias"."db"`, making the alias
        // the active database, and DuckDB refuses to DETACH the default — so before
        // the fix DETACH failed, the alias leaked, and the next connect hit a
        // duplicate ("Connection query failed"). detach() now switches off the
        // default first, so this detach + reconnect both succeed.
        try await e.detach(alias)
        try await e.attach(conn(), password: DDLVEnv.pass)   // reconnect must not throw
        // Prove the engine is alive and the alias is attached & queryable after the
        // reconnect (fetchTables throws if the alias isn't in the catalog).
        let r = try await e.query("SELECT 1 AS one")
        #expect(r.rows.first?.first == "1")
        _ = try await e.fetchTables(alias: alias, database: db)
        try await e.detach(alias)
    }

    @Test("a failed duplicate ATTACH does not poison the connection")
    func failedReattachIsRecoverable() async throws {
        let e = try QueryEngine()
        try await e.attach(conn(), password: DDLVEnv.pass)
        await #expect(throws: (any Error).self) {          // naive re-attach still fails
            try await e.attach(self.conn(), password: DDLVEnv.pass)
        }
        // ...but the engine stays usable: detach + reconnect recover.
        _ = try await e.fetchTables(alias: alias, database: db)
        try await e.detach(alias)
        try await e.attach(conn(), password: DDLVEnv.pass)
        try await e.detach(alias)
    }

    @Test("sqlDump captures the real CREATE TABLE plus NULL-aware, escaped INSERTs")
    func sqlDump() async throws {
        let e = try await makeEngine()
        let tbl = "_sb_ddl_dump"
        try await e.executeDDL(alias: alias, sql: "DROP TABLE IF EXISTS \(mref(tbl))")
        try await e.executeDDL(alias: alias,
            sql: "CREATE TABLE \(mref(tbl)) (`id` INT NOT NULL, `note` VARCHAR(50) DEFAULT NULL, PRIMARY KEY(`id`)) ENGINE=InnoDB")
        try await e.executeDDL(alias: alias, sql: "INSERT INTO \(mref(tbl)) (`id`,`note`) VALUES (1,'a')")
        try await e.executeDDL(alias: alias, sql: "INSERT INTO \(mref(tbl)) (`id`,`note`) VALUES (2,NULL)")
        try await e.executeDDL(alias: alias, sql: "INSERT INTO \(mref(tbl)) (`id`,`note`) VALUES (3,'O''Brien')")

        let dump = try await e.sqlDump(alias: alias, database: db, table: tbl)
        #expect(dump.rowCount == 3)
        #expect(!dump.truncated)
        #expect(dump.text.contains("CREATE TABLE"))          // server-authoritative
        #expect(dump.text.contains("`note`"))
        #expect(dump.text.contains("NULL"))                  // the real-NULL row
        #expect(dump.text.contains("'O''Brien'"))            // escaped apostrophe

        try await e.executeDDL(alias: alias, sql: SQLBuilder.dropTable(engine: .mysql, database: db, table: tbl))
    }

    @Test("server inspection returns process list, variables, and status")
    func serverInspection() async throws {
        let e = try await makeEngine()
        let procs = try await e.serverProcesses(alias: alias)
        #expect(!procs.columns.isEmpty)
        #expect(!procs.rows.isEmpty)                                   // at least our own session
        #expect(procs.rows.contains { Int($0.first ?? "") != nil })    // Id column is numeric
        let vars = try await e.serverVariables(alias: alias)
        #expect(vars.rows.count > 50)                                  // MySQL has hundreds
        let status = try await e.serverStatus(alias: alias)
        #expect(!status.rows.isEmpty)
    }

    @Test("killProcess rejects a non-numeric id (SQL-injection guard)")
    func killGuard() async throws {
        let e = try await makeEngine()
        await #expect(throws: (any Error).self) {
            try await e.killProcess(alias: self.alias, id: "1; DROP TABLE customers")
        }
    }

    @Test("fetchRoutines lists stored procedures with their definitions")
    func routines() async throws {
        let e = try await makeEngine()
        let proc = "_sb_proc_test"
        let ref = SQLBuilder.mysqlTable(database: db, table: proc)
        try await e.executeDDL(alias: alias, sql: "DROP PROCEDURE IF EXISTS \(ref)")
        try await e.executeDDL(alias: alias, sql: "CREATE PROCEDURE \(ref)() BEGIN SELECT 1; END")
        let rows = try await e.fetchRoutines(alias: alias, database: db)
        let mine = rows.first { $0.first == proc } ?? []
        #expect(!mine.isEmpty)
        #expect(mine.count > 1 && mine[1].uppercased() == "PROCEDURE")
        #expect(mine.count > 3 && mine[3].contains("SELECT 1"))   // body captured
        try await e.executeDDL(alias: alias, sql: "DROP PROCEDURE IF EXISTS \(ref)")
    }

    @Test("server-native EXPLAIN returns a plan grid for a single-server query")
    func explainPlan() async throws {
        let e = try await makeEngine()
        let tbl = "_sb_explain"
        try await e.executeDDL(alias: alias, sql: "DROP TABLE IF EXISTS \(mref(tbl))")
        try await e.executeDDL(alias: alias,
            sql: "CREATE TABLE \(mref(tbl)) (`id` INT NOT NULL, PRIMARY KEY(`id`)) ENGINE=InnoDB")
        // serverSQL is what the server sees (no DuckDB alias prefix); it resolves
        // against the connection's default db (sbwrite), where the table was created.
        let plan = try await e.explain(alias: alias, serverSQL: "SELECT * FROM \(tbl)")
        #expect(!plan.columns.isEmpty)
        #expect(!plan.rows.isEmpty)                                   // MySQL EXPLAIN → ≥1 row
        #expect(plan.rows.flatMap { $0 }.contains { $0.contains(tbl) })  // the plan names the table
        try await e.executeDDL(alias: alias, sql: SQLBuilder.dropTable(engine: .mysql, database: db, table: tbl))
    }

    @Test("CSV import parses and inserts rows end-to-end")
    func csvImport() async throws {
        let e = try await makeEngine()
        let tbl = "_sb_csv_import"
        try await e.executeDDL(alias: alias, sql: "DROP TABLE IF EXISTS \(mref(tbl))")
        try await e.executeDDL(alias: alias,
            sql: "CREATE TABLE \(mref(tbl)) (`id` INT NOT NULL, `note` VARCHAR(50) DEFAULT NULL, PRIMARY KEY(`id`)) ENGINE=InnoDB")

        let csv = "id,note\n1,hello\n2,\"a,b\"\n3,"   // row 3's note is empty → NULL
        let parsed = CSVParser.parse(csv)
        let header = parsed[0]
        let dataRows = Array(parsed.dropFirst())
        let n = try await e.importCSV(alias: alias, database: db, table: tbl, columns: header, rows: dataRows)
        #expect(n == 3)

        let count = try await e.query("SELECT COUNT(*) FROM \(dref(tbl))")
        #expect(count.rows.first?.first == "3")
        let comma = try await e.query("SELECT note FROM \(dref(tbl)) WHERE id = 2")
        #expect(comma.rows.first?.first == "a,b")          // quoted comma preserved through import
        let blank = try await e.query("SELECT note FROM \(dref(tbl)) WHERE id = 3")
        #expect(blank.nullMask.first?.first == true)       // empty field imported as NULL

        try await e.executeDDL(alias: alias, sql: SQLBuilder.dropTable(engine: .mysql, database: db, table: tbl))
    }

    @Test("orderBy builder sorts across the whole table, both directions")
    func orderBy() async throws {
        let e = try await makeEngine()
        let tbl = "_sb_ddl_order"
        try await freshTable(e, tbl)
        for i in [5, 1, 3, 2, 4] {
            try await e.executeDDL(alias: alias, sql: "INSERT INTO \(mref(tbl)) (`id`) VALUES (\(i))")
        }
        let desc = try await e.query("SELECT * FROM \(dref(tbl))\(SQLBuilder.orderBy(column: "id", ascending: false)) LIMIT 200")
        #expect(desc.rows.first?.first == "5")
        let asc = try await e.query("SELECT * FROM \(dref(tbl))\(SQLBuilder.orderBy(column: "id", ascending: true)) LIMIT 200")
        #expect(asc.rows.first?.first == "1")

        try await e.executeDDL(alias: alias, sql: SQLBuilder.dropTable(engine: .mysql, database: db, table: tbl))
    }
}
