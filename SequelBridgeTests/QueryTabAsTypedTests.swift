//
//  QueryTabAsTypedTests.swift
//  SequelBridgeTests
//
//  A Query-tab statement that returns no rows, on one MySQL server, runs there as typed.
//  It used to go through DuckDB, which refused MySQL's own syntax (AUTO_INCREMENT,
//  UNSIGNED, TINYINT(1), backticks, "double-quoted" strings, ON DUPLICATE KEY UPDATE,
//  REPLACE, INSERT IGNORE, MODIFY, AFTER, SET @x, DATE_FORMAT, CREATE INDEX) and
//  changed what it did accept: a VARCHAR(40) column was made TEXT. Runs on MariaDB and
//  on MySQL 8.4 (scripts/run-all-tests.sh); skipped without SB_MYSQL_VERIFY.
//

import Foundation
import Testing
@testable import SequelBridge

private struct AsTypedEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_MYSQL_PORT"] ?? "3309") ?? 3309 }
    static var user: String { e["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { e["SB_MYSQL_PASS"] ?? "" }
    static var writeDB: String { e["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
}

@MainActor
@Suite("Query tab on MySQL: statements run as typed", .enabled(if: AsTypedEnv.enabled), .serialized)
struct QueryTabAsTypedTests {
    func connect(_ alias: String) async throws -> QueryEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-astyped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        let entry: [String: Any] = [
            "id": UUID().uuidString, "name": alias, "alias": alias, "connectionType": "TCP/IP",
            "color": "#3A9AA8", "host": AsTypedEnv.host, "port": AsTypedEnv.port,
            "username": AsTypedEnv.user, "password": AsTypedEnv.pass, "database": AsTypedEnv.writeDB,
            "engine": "mysql", "folder": "", "readOnly": false,
        ]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: fixture)
        let manager = try ConnectionManager(arguments: ["-SBConnectionsFile", fixture.path])
        let conn = try #require(manager.saved.first)
        try await manager.connect([conn])
        return manager.queryEngine
    }

    /// A column's type as the server keeps it.
    func columnType(_ q: QueryEngine, _ alias: String, _ table: String, _ column: String) async throws -> String? {
        try await q.serverPassthroughQuery(alias: alias, serverSQL: """
            SELECT COLUMN_TYPE FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = '\(AsTypedEnv.writeDB)' AND TABLE_NAME = '\(table)' AND COLUMN_NAME = '\(column)'
            """).rows.first?.first
    }

    func value(_ q: QueryEngine, _ alias: String, _ sql: String) async throws -> String? {
        try await q.serverPassthroughQuery(alias: alias, serverSQL: sql).rows.first?.first
    }

    @Test("MySQL's own syntax runs, and a table keeps the types it was given")
    func mysqlSyntax() async throws {
        let q = try await connect("at1")
        _ = try await q.runAsTyped(alias: "at1", sql: "DROP TABLE IF EXISTS `qt_types`")
        _ = try await q.runAsTyped(alias: "at1", sql: """
            CREATE TABLE `qt_types` (id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, note VARCHAR(40),
                                     flag TINYINT(1) NOT NULL DEFAULT 0) ENGINE=InnoDB
            """)
        #expect(try await columnType(q, "at1", "qt_types", "note") == "varchar(40)")
        #expect(try await columnType(q, "at1", "qt_types", "flag") == "tinyint(1)")
        #expect(try await columnType(q, "at1", "qt_types", "id")?.contains("unsigned") == true)

        #expect(try await q.runAsTyped(alias: "at1", sql: "INSERT INTO `qt_types` (`note`) VALUES (\"double\")") == 1)
        #expect(try await q.runAsTyped(alias: "at1",
                                       sql: "INSERT INTO qt_types (id, note) VALUES (1, 'x') ON DUPLICATE KEY UPDATE note = 'dup'") == 2)
        #expect(try await q.runAsTyped(alias: "at1", sql: "INSERT IGNORE INTO qt_types (id, note) VALUES (1, 'ignored')") == 0)
        #expect(try await q.runAsTyped(alias: "at1", sql: "REPLACE INTO qt_types (id, note) VALUES (2, 'replaced')") == 1)
        _ = try await q.runAsTyped(alias: "at1", sql: "ALTER TABLE qt_types MODIFY note VARCHAR(80)")
        _ = try await q.runAsTyped(alias: "at1", sql: "ALTER TABLE qt_types ADD COLUMN extra INT AFTER note")
        _ = try await q.runAsTyped(alias: "at1", sql: "CREATE INDEX qt_note ON qt_types (note)")
        _ = try await q.runAsTyped(alias: "at1", sql: "SET @sb_probe = 1")
        #expect(try await q.runAsTyped(alias: "at1", sql: "UPDATE qt_types SET extra = DATE_FORMAT(NOW(), '%Y') WHERE id = 1") == 1)
        #expect(try await columnType(q, "at1", "qt_types", "note") == "varchar(80)")
        #expect(try await value(q, "at1", "SELECT note FROM qt_types WHERE id = 1") == "dup")
        _ = try await q.runAsTyped(alias: "at1", sql: "DROP TABLE qt_types")
    }

    @Test("the rows a write changed are counted")
    func counts() async throws {
        let q = try await connect("at2")
        _ = try await q.runAsTyped(alias: "at2", sql: "DROP TABLE IF EXISTS qt_count")
        _ = try await q.runAsTyped(alias: "at2", sql: "CREATE TABLE qt_count (id INT PRIMARY KEY, v INT)")
        #expect(try await q.runAsTyped(alias: "at2", sql: "INSERT INTO qt_count VALUES (1,0),(2,0),(3,0),(4,0),(5,0)") == 5)
        #expect(try await q.runAsTyped(alias: "at2", sql: "UPDATE qt_count SET v = 1 WHERE id <= 2") == 2)
        #expect(try await q.runAsTyped(alias: "at2", sql: "DELETE FROM qt_count WHERE id > 99") == 0)
        _ = try await q.runAsTyped(alias: "at2", sql: "DROP TABLE qt_count")
    }

    @Test("inside a transaction begun in the Query tab, a write waits for its COMMIT or ROLLBACK")
    func insideATransaction() async throws {
        let q = try await connect("at3")
        _ = try await q.runAsTyped(alias: "at3", sql: "DROP TABLE IF EXISTS qt_txn")
        _ = try await q.runAsTyped(alias: "at3", sql: "CREATE TABLE qt_txn (id INT PRIMARY KEY, v INT)")
        _ = try await q.runAsTyped(alias: "at3", sql: "INSERT INTO qt_txn VALUES (1, 0)")
        _ = try await q.query("BEGIN TRANSACTION")      // how the Query tab runs BEGIN
        #expect(try await q.runAsTyped(alias: "at3", sql: "UPDATE qt_txn SET v = 9 WHERE id = 1") == 1)
        _ = try await q.query("ROLLBACK")
        #expect(try await value(q, "at3", "SELECT v FROM qt_txn WHERE id = 1") == "0", "ROLLBACK didn't undo the write")

        _ = try await q.query("BEGIN TRANSACTION")
        _ = try await q.runAsTyped(alias: "at3", sql: "UPDATE qt_txn SET v = 7 WHERE id = 1")
        _ = try await q.query("COMMIT")
        #expect(try await value(q, "at3", "SELECT v FROM qt_txn WHERE id = 1") == "7")
        _ = try await q.runAsTyped(alias: "at3", sql: "DROP TABLE qt_txn")
    }

    @Test("a statement the server rejects says the server's reason, and the next one runs")
    func rejected() async throws {
        let q = try await connect("at4")
        do {
            _ = try await q.runAsTyped(alias: "at4", sql: "INSERT INTO qt_no_such_table VALUES (1)")
            Issue.record("an insert into a missing table went through")
        } catch {
            let reason = QueryEngine.extractReason(from: error)
            #expect(reason.contains("qt_no_such_table"), "got: \(reason)")
        }
        _ = try await q.runAsTyped(alias: "at4", sql: "SET @sb_after = 1")
        #expect(try await value(q, "at4", "SELECT 1") == "1")
    }
}
