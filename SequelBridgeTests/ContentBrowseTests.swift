//
//  ContentBrowseTests.swift
//  SequelBridgeTests
//
//  The Content tab on a live server, the way the panel runs it: a page at a time, a
//  typed filter, Set to NULL. Items from the Sequel Ace checklist (guide/SEQUEL-ACE.md)
//  that worked with no test. Skipped unless SB_MYSQL_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private struct CEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_MYSQL_PORT"] ?? "3309") ?? 3309 }
    static var user: String { e["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { e["SB_MYSQL_PASS"] ?? "" }
    static var db: String { e["SB_MYSQL_DB"] ?? "sbtest" }
    static var writeDB: String { e["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
}

@MainActor
@Suite("Content tab on a live server", .enabled(if: CEnv.enabled), .serialized)
struct ContentBrowseTests {

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        try await engine.attach(Connection(name: alias, alias: alias, host: CEnv.host, port: CEnv.port,
                                           username: CEnv.user, database: CEnv.db), password: CEnv.pass)
        return engine
    }

    /// One page of seed10 (n = 0…9), as the panel asks for it.
    func page(_ e: QueryEngine, _ alias: String, filter: String = "", ascending: Bool = true,
              size: Int = 3, number: Int) async throws -> [String] {
        try await e.serverContentPage(alias: alias, database: CEnv.db, table: "seed10", filter: filter,
                                      sortColumn: "n", sortAscending: ascending, limit: size, offset: number * size)
            .rows.map { $0[0] }
    }

    @Test("pages follow one another in order, a page at a time")
    func pages() async throws {
        let e = try await makeEngine("cb1")
        #expect(try await page(e, "cb1", number: 0) == ["0", "1", "2"])
        #expect(try await page(e, "cb1", number: 1) == ["3", "4", "5"])
        #expect(try await page(e, "cb1", number: 3) == ["9"])
        #expect(try await page(e, "cb1", number: 4).isEmpty)
    }

    @Test("a typed filter narrows the rows; one the server can't read says why")
    func filter() async throws {
        let e = try await makeEngine("cb2")
        #expect(try await page(e, "cb2", filter: "n >= 7", ascending: false, size: 200, number: 0) == ["9", "8", "7"])
        var reason = ""
        do { _ = try await page(e, "cb2", filter: "no_such_column = 1", number: 0) }
        catch { reason = QueryEngine.extractReason(from: error) }
        #expect(reason.contains("no_such_column"), "got: \(reason)")
    }

    /// Legacy dates, as an old server or a lax sql_mode keeps them: DuckDB's MySQL driver
    /// read a zero date (0000-00-00) as NULL, and a zero month or day failed the whole page.
    @Test("a page shows zero dates as the server keeps them, and a zero month or day doesn't fail it")
    func zeroDates() async throws {
        let e = try QueryEngine()
        try await e.attach(Connection(name: "cb9", alias: "cb9", host: CEnv.host, port: CEnv.port,
                                      username: CEnv.user, database: CEnv.writeDB), password: CEnv.pass)
        _ = try await e.nativeScript(alias: "cb9", statements: [
            "SET SESSION sql_mode = ''", "DROP TABLE IF EXISTS cb_legacy",
            "CREATE TABLE cb_legacy (id INT PRIMARY KEY, d DATE NOT NULL, dt DATETIME NULL, ts TIMESTAMP NULL DEFAULT NULL, note VARCHAR(10))",
            "INSERT INTO cb_legacy VALUES (1, '0000-00-00', '2026-00-15 10:00:00', '0000-00-00 00:00:00', 'a'), (2, '2026-10-20', NULL, NULL, 'b')",
        ], database: CEnv.writeDB)
        let columns = try await e.fetchColumns(alias: "cb9", database: CEnv.writeDB, table: "cb_legacy")
        let page = try await e.serverContentPage(alias: "cb9", database: CEnv.writeDB, table: "cb_legacy", filter: "",
                                                 sortColumn: "d", sortAscending: true, limit: 10, offset: 0, columns: columns)
        #expect(page.columns == ["id", "d", "dt", "ts", "note"])
        #expect(page.rows == [["1", "0000-00-00", "2026-00-15 10:00:00", "0000-00-00 00:00:00", "a"],
                              ["2", "2026-10-20", "NULL", "NULL", "b"]])
        #expect(page.isNull(1, 2) && !page.isNull(0, 1))
        #expect(Array(page.columnTypes.prefix(4)) == ["INT", "DATE", "DATETIME", "DATETIME"])
        try await e.mysqlExecute(alias: "cb9", sql: "DROP TABLE cb_legacy")
    }

    @Test("a column-operator-value filter finds awkward values as themselves on the server")
    func filterRules() async throws {
        let e = try QueryEngine()
        try await e.attach(Connection(name: "cb4", alias: "cb4", host: CEnv.host, port: CEnv.port,
                                      username: CEnv.user, database: CEnv.writeDB), password: CEnv.pass)
        let t = SQLBuilder.mysqlTable(database: CEnv.writeDB, table: "cb_rules")
        try await e.mysqlExecute(alias: "cb4", sql: "DROP TABLE IF EXISTS \(t)")
        try await e.mysqlExecute(alias: "cb4", sql: "CREATE TABLE \(t) (id INT PRIMARY KEY, note VARCHAR(20)) ENGINE=InnoDB")
        try await e.mysqlExecute(alias: "cb4", sql: #"INSERT INTO \#(t) VALUES (1, '50%'), (2, '50 off'), (3, 'a_b'), (4, 'axb'), (5, 'C:\\new'), (6, 'O''Brien'), (7, NULL)"#)
        func ids(_ op: ContentFilter.Op, _ value: String) async throws -> [String] {
            let condition = try #require(ContentFilter.condition(column: "note", op: op, value: value, dialect: .mysql))
            return try await e.serverContentPage(alias: "cb4", database: CEnv.writeDB, table: "cb_rules", filter: condition,
                                                 sortColumn: "id", sortAscending: true, limit: 100, offset: 0).rows.map { $0[0] }
        }
        #expect(try await ids(.contains, "50%") == ["1"])
        #expect(try await ids(.beginsWith, "a_") == ["3"])
        #expect(try await ids(.equals, #"C:\new"#) == ["5"])
        #expect(try await ids(.equals, "O'Brien") == ["6"])
        #expect(try await ids(.isNull, "") == ["7"])
        #expect(try await ids(.isIn, "axb, a_b") == ["3", "4"])
        try await e.mysqlExecute(alias: "cb4", sql: "DROP TABLE \(t)")
    }

    @Test("Set to NULL stores NULL, not an empty string")
    func setNull() async throws {
        let e = try await makeEngine("cb3")
        let t = SQLBuilder.mysqlTable(database: CEnv.writeDB, table: "cb_null")
        try await e.mysqlExecute(alias: "cb3", sql: "DROP TABLE IF EXISTS \(t)")
        try await e.mysqlExecute(alias: "cb3", sql: "CREATE TABLE \(t) (id INT PRIMARY KEY, note VARCHAR(20)) ENGINE=InnoDB")
        try await e.mysqlExecute(alias: "cb3", sql: "INSERT INTO \(t) VALUES (1, 'x')")
        // The cell's right-click Set to NULL saves nil through the panel's write path.
        try await e.executeWrite(SQLBuilder.update(alias: "cb3", database: CEnv.writeDB, table: "cb_null", column: "note",
                                                   newValue: nil, primaryKey: [(column: "id", value: "1")]), alias: "cb3")
        let r = try await e.serverPassthroughQuery(alias: "cb3", serverSQL: "SELECT note IS NULL FROM \(t) WHERE id = 1")
        try await e.mysqlExecute(alias: "cb3", sql: "DROP TABLE \(t)")
        #expect(r.rows.first?.first == "1")
    }
}
