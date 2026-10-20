//
//  ReadOnlyEnforcementTests.swift
//  SequelBridgeTests
//
//  Read-only mode tried on every path a write can take below the interface: a statement
//  through DuckDB, the passthrough's execute, a SELECT that writes, the native MySQL
//  client, EXPLAIN ANALYZE, Kill, ClickHouse's HTTP. Checking found that only the app's
//  own write functions refused: a statement through DuckDB still wrote to a read-only
//  connection, and so did the native client, EXPLAIN ANALYZE of a DELETE, Kill on
//  PostgreSQL and any statement sent to ClickHouse.
//

import Foundation
import Testing
@testable import SequelBridge

private enum ROEnvironment {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static func value(_ key: String, _ fallback: String) -> String { e[key] ?? fallback }
}

@Suite("Read-only statements: EXPLAIN ANALYZE runs what it explains")
struct ReadOnlyStatementTests {
    @Test("EXPLAIN ANALYZE of a write is a write", arguments: [
        "EXPLAIN ANALYZE DELETE FROM t",
        "explain analyse update t set a = 1",
        "EXPLAIN (ANALYZE) INSERT INTO t VALUES (1)",
        "EXPLAIN (FORMAT JSON, ANALYZE true) DELETE FROM t",
        "EXPLAIN ANALYZE VERBOSE DELETE FROM t",
        "EXPLAIN ANALYZE FORMAT=TREE DELETE FROM t",
        "DESCRIBE ANALYZE DELETE FROM t",
        "EXPLAIN ANALYZE WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d",
    ])
    func analyzedWrites(_ sql: String) {
        #expect(!SQLBuilder.isReadOnly(sql))
    }

    @Test("an EXPLAIN that runs nothing, or runs a read, stays a read", arguments: [
        "EXPLAIN DELETE FROM t",
        "EXPLAIN ANALYZE SELECT * FROM t",
        "EXPLAIN (ANALYZE false) DELETE FROM t",
        "EXPLAIN FORMAT=JSON SELECT 1",
        "EXPLAIN QUERY PLAN SELECT 1",
        "DESC t",
    ])
    func reads(_ sql: String) {
        #expect(SQLBuilder.isReadOnly(sql))
    }
}

@MainActor
@Suite("Read-only mode on a SQLite file", .serialized)
struct ReadOnlySQLiteTests {
    @Test("a write reaching DuckDB, the app's write paths or SQLite itself is refused; reads still work")
    func everyPath() async throws {
        let lite = SQLitePromisesTests()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ro.sqlite")
        lite.sqlite(url, "CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT); INSERT INTO t VALUES (1, 'a');")
        var c = Connection(name: "Prod file", alias: "lro", host: "", port: 0, username: "", database: url.path)
        c.engine = .sqlite
        c.readOnly = true
        let e = try QueryEngine()
        try await e.attach(c, password: "")

        await #expect(throws: (any Error).self, "a statement through DuckDB") {
            _ = try await e.query(#"DELETE FROM "lro"."main"."t""#)
        }
        await #expect(throws: (any Error).self, "a typed statement") {
            try await StatementSource.$typedByYou.withValue(true) {
                _ = try await e.query(#"UPDATE "lro"."main"."t" SET note = 'b'"#)
            }
        }
        await #expect(throws: (any Error).self, "a Content edit") {
            try await e.executeWrite(#"UPDATE "lro"."main"."t" SET note = 'c'"#, alias: "lro")
        }
        await #expect(throws: (any Error).self, "Structure, run in SQLite itself") {
            try await e.executeDDL(alias: "lro", sql: #"ALTER TABLE "t" ADD COLUMN "x" TEXT"#)
        }
        #expect(lite.sqlite(url, "SELECT group_concat(id || ':' || note) FROM t") == "1:a")
        #expect(lite.sqlite(url, "SELECT group_concat(name) FROM pragma_table_info('t')") == "id,note")

        #expect(try await e.fetchTables(alias: "lro", database: "main").map(\.name) == ["t"])
        #expect(try await e.query(#"SELECT note FROM "lro"."main"."t""#, lane: .content).rows == [["a"]])
        #expect(try await e.sqlDumpDatabase(alias: "lro", database: "main").text.contains("CREATE TABLE"))
    }
}

@MainActor
@Suite("Read-only mode on PostgreSQL (real server)", .enabled(if: ROEnvironment.e["SB_PG_VERIFY"] == "1"), .serialized)
struct ReadOnlyPostgresTests {
    func engine(_ alias: String, readOnly: Bool) async throws -> QueryEngine {
        let e = try QueryEngine()
        var c = Connection(name: "PG \(alias)", alias: alias, connectionType: .tcpip,
                           host: ROEnvironment.value("SB_PG_HOST", "127.0.0.1"),
                           port: Int(ROEnvironment.value("SB_PG_PORT", "5433")) ?? 5433,
                           username: ROEnvironment.value("SB_PG_USER", "sbuser"),
                           database: ROEnvironment.value("SB_PG_DB", "sbtest"))
        c.engine = .postgres
        c.readOnly = readOnly
        try await e.attach(c, password: ROEnvironment.value("SB_PG_PASS", ""))
        return e
    }

    func count(_ e: QueryEngine, _ alias: String) async throws -> [[String]] {
        try await e.query("SELECT * FROM postgres_query('\(alias)', 'SELECT count(*) FROM sbro.ro_t')").rows
    }

    @Test("a write through DuckDB, a write a SELECT hides, EXPLAIN ANALYZE and Kill are refused; reads work")
    func everyPath() async throws {
        let w = try await engine("pgw", readOnly: false)
        for sql in ["CREATE SCHEMA IF NOT EXISTS sbro", "DROP TABLE IF EXISTS sbro.ro_t", "DROP SEQUENCE IF EXISTS sbro.ro_seq",
                    "CREATE TABLE sbro.ro_t (id int PRIMARY KEY)", "INSERT INTO sbro.ro_t VALUES (1), (2), (3)",
                    "CREATE SEQUENCE sbro.ro_seq"] {
            try await w.executeDDL(alias: "pgw", sql: sql)
        }
        let r = try await engine("pgro", readOnly: true)

        await #expect(throws: (any Error).self, "a statement through DuckDB") {
            _ = try await r.query(#"DELETE FROM "pgro"."sbro"."ro_t""#)
        }
        await #expect(throws: (any Error).self, "a write a SELECT hides") {
            _ = try await r.query("SELECT * FROM postgres_query('pgro', 'SELECT nextval(''sbro.ro_seq'')')")
        }
        await #expect(throws: (any Error).self, "EXPLAIN ANALYZE runs the DELETE it explains") {
            _ = try await r.explain(alias: "pgro", serverSQL: "ANALYZE DELETE FROM sbro.ro_t")
        }
        await #expect(throws: (any Error).self, "Kill") {
            try await r.killProcess(alias: "pgro", id: "999999")
        }
        #expect(try await count(w, "pgw") == [["3"]])
        #expect(try await w.query("SELECT * FROM postgres_query('pgw', 'SELECT nextval(''sbro.ro_seq'')')").rows == [["1"]],
                "the sequence moved")

        #expect(try await r.fetchTables(alias: "pgro", database: "sbro").map(\.name).contains("ro_t"))
        #expect(try await count(r, "pgro") == [["3"]])
    }
}

@MainActor
@Suite("Read-only mode on MySQL (real server)", .enabled(if: ROEnvironment.e["SB_MYSQL_VERIFY"] == "1"), .serialized)
struct ReadOnlyMySQLTests {
    var db: String { ROEnvironment.value("SB_MYSQL_WRITE_DB", "sbwrite") }

    func engine(_ alias: String, readOnly: Bool) async throws -> QueryEngine {
        let e = try QueryEngine()
        var c = Connection(name: "MySQL \(alias)", alias: alias, connectionType: .tcpip,
                           host: ROEnvironment.value("SB_MYSQL_HOST", "127.0.0.1"),
                           port: Int(ROEnvironment.value("SB_MYSQL_PORT", "3307")) ?? 3307,
                           username: ROEnvironment.value("SB_MYSQL_USER", "sbuser"),
                           database: db, engine: .mysql)
        c.readOnly = readOnly
        try await e.attach(c, password: ROEnvironment.value("SB_MYSQL_PASS", ""))
        return e
    }

    @Test("a write through DuckDB, mysql_execute, the native client and EXPLAIN ANALYZE are refused; reads work")
    func everyPath() async throws {
        let w = try await engine("myw", readOnly: false)
        let t = SQLBuilder.mysqlTable(database: db, table: "ro_enforce")
        try await w.mysqlExecute(alias: "myw", sql: "DROP TABLE IF EXISTS \(t)")
        try await w.mysqlExecute(alias: "myw", sql: "CREATE TABLE \(t) (id INT PRIMARY KEY) ENGINE=InnoDB")
        try await w.mysqlExecute(alias: "myw", sql: "INSERT INTO \(t) VALUES (1), (2), (3)")
        let r = try await engine("myro", readOnly: true)

        await #expect(throws: (any Error).self, "a statement through DuckDB") {
            _ = try await r.query(#"DELETE FROM "myro"."\#(db)"."ro_enforce""#)
        }
        await #expect(throws: (any Error).self, "the passthrough's execute") {
            _ = try await r.query("CALL mysql_execute('myro', 'DELETE FROM \(db).ro_enforce')")
        }
        await #expect(throws: (any Error).self, "the native client") {
            _ = try await r.nativeMySQLQuery(alias: "myro", sql: "DELETE FROM \(t)")
        }
        await #expect(throws: (any Error).self, "EXPLAIN ANALYZE runs the DELETE it explains (MySQL 8)") {
            _ = try await r.explain(alias: "myro", serverSQL: "ANALYZE DELETE FROM \(t)")
        }
        #expect(try await w.nativeMySQLQuery(alias: "myw", sql: "SELECT COUNT(*) FROM \(t)").rows == [["3"]])

        #expect(try await r.fetchTables(alias: "myro", database: db).map(\.name).contains("ro_enforce"))
        #expect(try await r.nativeMySQLQuery(alias: "myro", sql: "SELECT COUNT(*) FROM \(t)").rows == [["3"]])
        #expect(try await r.query("SELECT * FROM mysql_query('myro', 'SELECT COUNT(*) FROM \(db).ro_enforce')").rows == [["3"]])
        #expect(try await r.explain(alias: "myro", serverSQL: "SELECT * FROM \(t)").rows.isEmpty == false)
        try await w.mysqlExecute(alias: "myw", sql: "DROP TABLE IF EXISTS \(t)")
    }
}

extension ReadOnlyMySQLTests {
    @Test("a write hidden in a SELECT, a stored function that inserts, is refused by the server on both paths")
    func hiddenWrite() async throws {
        let w = try await engine("myw2", readOnly: false)
        let fn = "\(db).sb_ro_write", t = "\(db).ro_fn"
        for sql in ["DROP FUNCTION IF EXISTS \(fn)", "DROP TABLE IF EXISTS \(t)", "CREATE TABLE \(t) (id INT)",
                    "CREATE FUNCTION \(fn)() RETURNS INT DETERMINISTIC MODIFIES SQL DATA BEGIN INSERT INTO \(t) VALUES (99); RETURN 1; END"] {
            try await w.mysqlExecute(alias: "myw2", sql: sql)
        }
        let r = try await engine("myro2", readOnly: true)
        await #expect(throws: (any Error).self, "the native client") {
            _ = try await r.nativeMySQLQuery(alias: "myro2", sql: "SELECT \(fn)()")
        }
        await #expect(throws: (any Error).self, "the passthrough") {
            _ = try await r.query("SELECT * FROM mysql_query('myro2', 'SELECT \(fn)() AS v')")
        }
        #expect(try await w.nativeMySQLQuery(alias: "myw2", sql: "SELECT COUNT(*) FROM \(t)").rows == [["0"]])
        try await w.mysqlExecute(alias: "myw2", sql: "DROP FUNCTION IF EXISTS \(fn)")
        try await w.mysqlExecute(alias: "myw2", sql: "DROP TABLE IF EXISTS \(t)")
    }
}

@MainActor
@Suite("Read-only mode on ClickHouse (real server)", .enabled(if: ROEnvironment.e["SB_CH_VERIFY"] == "1"), .serialized)
struct ReadOnlyClickHouseTests {
    func engine(_ alias: String, readOnly: Bool, user: String? = nil, password: String? = nil) async throws -> QueryEngine {
        let e = try QueryEngine()
        var c = Connection(name: "CH \(alias)", alias: alias, connectionType: .tcpip,
                           host: ROEnvironment.value("SB_CH_HOST", "127.0.0.1"),
                           port: Int(ROEnvironment.value("SB_CH_PORT", "8123")) ?? 8123,
                           username: user ?? ROEnvironment.value("SB_CH_USER", "sbuser"), database: "default")
        c.engine = .clickhouse
        c.readOnly = readOnly
        try await e.attach(c, password: password ?? ROEnvironment.value("SB_CH_PASS", "sbpass123"))
        return e
    }

    @Test("a statement that writes is refused by the server itself; reads work")
    func everyPath() async throws {
        let w = try await engine("chw", readOnly: false)
        try await w.clickhouseExecute(alias: "chw", sql: "DROP TABLE IF EXISTS default.ro_enforce")
        try await w.clickhouseExecute(alias: "chw", sql: "CREATE TABLE default.ro_enforce (id UInt32) ENGINE = MergeTree ORDER BY id")
        try await w.clickhouseExecute(alias: "chw", sql: "INSERT INTO default.ro_enforce VALUES (1), (2), (3)")
        let r = try await engine("chro", readOnly: true)

        await #expect(throws: (any Error).self, "an INSERT sent as a statement") {
            _ = try await r.clickhouseQuery(alias: "chro", sql: "INSERT INTO default.ro_enforce VALUES (9)")
        }
        await #expect(throws: (any Error).self, "DDL sent as a statement") {
            _ = try await r.clickhouseQuery(alias: "chro", sql: "DROP TABLE default.ro_enforce")
        }
        await #expect(throws: (any Error).self, "the app's write path") {
            try await r.clickhouseExecute(alias: "chro", sql: "TRUNCATE TABLE default.ro_enforce")
        }
        #expect(try await w.clickhouseQuery(alias: "chw", sql: "SELECT count() FROM default.ro_enforce").rows == [["3"]])

        #expect(try await r.clickhouseQuery(alias: "chro", sql: "SELECT count() FROM default.ro_enforce").rows == [["3"]])
        #expect(try await r.fetchTables(alias: "chro", database: "default").map(\.name).contains("ro_enforce"))
        try await w.clickhouseExecute(alias: "chw", sql: "DROP TABLE IF EXISTS default.ro_enforce")
    }

    @Test("an account the server already holds read-only still connects and reads")
    func readOnlyAccount() async throws {
        let w = try await engine("chw2", readOnly: false)
        try await w.clickhouseExecute(alias: "chw2", sql: "DROP USER IF EXISTS sb_ro_account")
        try await w.clickhouseExecute(alias: "chw2", sql: "CREATE USER sb_ro_account IDENTIFIED BY 'ro-pass-1' SETTINGS readonly = 1")
        try await w.clickhouseExecute(alias: "chw2", sql: "GRANT SELECT ON default.* TO sb_ro_account")
        do {
            let r = try await engine("chro2", readOnly: true, user: "sb_ro_account", password: "ro-pass-1")
            #expect(try await r.clickhouseQuery(alias: "chro2", sql: "SELECT 1").rows == [["1"]])
            _ = try await r.fetchTables(alias: "chro2", database: "default")
        } catch {
            Issue.record("a read-only account couldn't read: \(QueryEngine.extractReason(from: error))")
        }
        try await w.clickhouseExecute(alias: "chw2", sql: "DROP USER IF EXISTS sb_ro_account")
    }
}
