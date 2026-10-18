//
//  QueryResultEditTests.swift
//  SequelBridgeTests
//
//  A Query-tab result edit, end to end: the result of a real SELECT, the engine's
//  check of whether it can be edited (QueryEngine.resultEditing), the UPDATE for one
//  cell keyed by that row's primary key, run the way the popup runs it (executeWrite),
//  then read back. SQLite needs nothing; PostgreSQL needs SB_PG_VERIFY=1 and MySQL
//  SB_MYSQL_VERIFY=1 (scripts/run-all-tests.sh sets both).
//

import Foundation
import Testing
@testable import SequelBridge

private enum QEEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var pg: Bool { e["SB_PG_VERIFY"] == "1" }
    static var pgPort: Int { Int(e["SB_PG_PORT"] ?? "") ?? 5433 }
    static var pgUser: String { e["SB_PG_USER"] ?? "sbuser" }
    static var pgPass: String { e["SB_PG_PASS"] ?? "sbpass123" }
    static var pgDB: String { e["SB_PG_DB"] ?? "sbtest" }
    static var my: Bool { e["SB_MYSQL_VERIFY"] == "1" }
    static var myHost: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var myPort: Int { Int(e["SB_MYSQL_PORT"] ?? "") ?? 3307 }
    static var myUser: String { e["SB_MYSQL_USER"] ?? "sbuser" }
    static var myPass: String { e["SB_MYSQL_PASS"] ?? "" }
    static var myDB: String { e["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
}

@MainActor
@Suite("Query-tab result edits", .serialized)
struct QueryResultEditTests {

    /// A SQLite file with items(id INTEGER PRIMARY KEY, name TEXT), rows 1..3.
    private func sqliteFile() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb_query_edit_\(UUID().uuidString).sqlite").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);"
                           + "INSERT INTO items VALUES (1, 'one'), (2, 'two'), (3, 'three');"]
        try p.run(); p.waitUntilExit()
        return path
    }

    @Test("SQLite: a value in a SELECT's result is written back to its row")
    func sqlite() async throws {
        let path = try sqliteFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let engine = try QueryEngine()
        let conn = Connection(name: "lq", alias: "lq", database: path, engine: .sqlite)
        try await engine.attach(conn, password: "")

        // The statement as typed, and its result as the scanner produces it.
        let typed = "SELECT name, id FROM lq.items WHERE id >= 2 ORDER BY id"
        let result = try await engine.query("SELECT name, id FROM lq.main.items WHERE id >= 2 ORDER BY id")
        let check = await engine.resultEditing(sql: typed, resultColumns: result.columns,
                                               connections: [conn]) { _ in "main" }
        #expect(check.reason == nil)
        let target = try #require(check.target)
        let update = try #require(target.update(row: 1, column: 0, value: "renamed", in: result))   // id 3
        try await engine.executeWrite(update, alias: "lq")

        let after = try await engine.query("SELECT id, name FROM lq.main.items ORDER BY id").rows
        #expect(after == [["1", "one"], ["2", "two"], ["3", "renamed"]])
        try await engine.detach("lq")
    }

    @Test("results that can't be traced to a row say why")
    func declined() async throws {
        let path = try sqliteFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let engine = try QueryEngine()
        var conn = Connection(name: "lr", alias: "lr", database: path, engine: .sqlite)
        try await engine.attach(conn, password: "")

        let noKey = await engine.resultEditing(sql: "SELECT name FROM lr.items", resultColumns: ["name"],
                                               connections: [conn]) { _ in "main" }
        #expect(noKey.target == nil)
        #expect(noKey.reason == ResultEditing.missingKey(table: "items", key: ["id"]))

        let grouped = await engine.resultEditing(sql: "SELECT name, COUNT(*) FROM lr.items GROUP BY name",
                                                 resultColumns: ["name", "count_star()"],
                                                 connections: [conn]) { _ in "main" }
        #expect(grouped.reason == ResultEditing.notOneTable)

        conn.readOnly = true
        let readOnly = await engine.resultEditing(sql: "SELECT * FROM lr.items", resultColumns: ["id", "name"],
                                                  connections: [conn]) { _ in "main" }
        #expect(readOnly.target == nil)
        #expect(readOnly.reason == CellEditability.reason(engine: .sqlite, readOnly: true, hasPrimaryKey: true))
        try await engine.detach("lr")
    }

    @Test("PostgreSQL: a value in a SELECT's result is written back to its row", .enabled(if: QEEnv.pg))
    func postgres() async throws {
        let engine = try QueryEngine()
        let conn = Connection(name: "pq", alias: "pq", host: "127.0.0.1", port: QEEnv.pgPort,
                              username: QEEnv.pgUser, database: QEEnv.pgDB, engine: .postgres)
        try await engine.attach(conn, password: QEEnv.pgPass)
        try await engine.executeDDL(alias: "pq", sql: "DROP TABLE IF EXISTS public.w_query_edit")
        try await engine.executeDDL(alias: "pq", sql: "CREATE TABLE public.w_query_edit (id int PRIMARY KEY, name text)")
        try await engine.executeDDL(alias: "pq", sql: "INSERT INTO public.w_query_edit VALUES (1, 'one'), (2, 'two')")

        // One connection: the passthrough runs the statement with the alias stripped.
        let typed = "SELECT * FROM pq.w_query_edit ORDER BY id"
        let result = try await engine.serverPassthroughQuery(alias: "pq", serverSQL: "SELECT * FROM w_query_edit ORDER BY id")
        let check = await engine.resultEditing(sql: typed, resultColumns: result.columns,
                                               connections: [conn]) { _ in "public" }
        let target = try #require(check.target)
        try await engine.executeWrite(try #require(target.update(row: 1, column: 1, value: nil, in: result)), alias: "pq")
        try await engine.executeWrite(try #require(target.update(row: 0, column: 1, value: "uno", in: result)), alias: "pq")

        let after = try await engine.query("SELECT id, name FROM pq.public.w_query_edit ORDER BY id")
        #expect(after.rows.first == ["1", "uno"])
        #expect(after.isNull(1, 1))
        try await engine.executeDDL(alias: "pq", sql: "DROP TABLE public.w_query_edit")
    }

    @Test("MySQL: a value in a SELECT's result is written back to its row", .enabled(if: QEEnv.my))
    func mysql() async throws {
        let engine = try QueryEngine()
        let conn = Connection(name: "mq", alias: "mq", connectionType: .tcpip, host: QEEnv.myHost, port: QEEnv.myPort,
                              username: QEEnv.myUser, database: QEEnv.myDB, engine: .mysql)
        try await engine.attach(conn, password: QEEnv.myPass)
        try await engine.executeDDL(alias: "mq", sql: "DROP TABLE IF EXISTS w_query_edit")
        try await engine.executeDDL(alias: "mq", sql: "CREATE TABLE w_query_edit (id int PRIMARY KEY, name varchar(20))")
        try await engine.executeDDL(alias: "mq", sql: "INSERT INTO w_query_edit VALUES (1, 'one'), (2, 'two')")

        let typed = "SELECT name AS label, id FROM mq.w_query_edit WHERE id = 2"
        let result = try await engine.serverPassthroughQuery(alias: "mq", serverSQL: "SELECT name AS label, id FROM w_query_edit WHERE id = 2")
        let check = await engine.resultEditing(sql: typed, resultColumns: result.columns,
                                               connections: [conn]) { _ in QEEnv.myDB }
        let target = try #require(check.target)
        try await engine.executeWrite(try #require(target.update(row: 0, column: 0, value: "deux", in: result)), alias: "mq")

        let after = try await engine.serverPassthroughQuery(alias: "mq", serverSQL: "SELECT id, name FROM w_query_edit ORDER BY id")
        #expect(after.rows == [["1", "one"], ["2", "deux"]])
        try await engine.executeDDL(alias: "mq", sql: "DROP TABLE w_query_edit")
    }
}
