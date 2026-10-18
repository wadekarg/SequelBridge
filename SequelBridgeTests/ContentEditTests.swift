//
//  ContentEditTests.swift
//  SequelBridgeTests
//
//  A Content-tab cell edit, end to end on every engine that edits in place: the
//  UPDATE the panel builds (SQLBuilder.update), run the way the panel runs it
//  (QueryEngine.executeWrite), then read back. MySQL is covered in PanelWritePathTests
//  and ReadOnlyModeTests; PostgreSQL needs SB_PG_VERIFY=1, SQLite needs nothing.
//

import Foundation
import Testing
@testable import SequelBridge

private enum CEEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var pg: Bool { e["SB_PG_VERIFY"] == "1" }
    static var pgPort: Int { Int(e["SB_PG_PORT"] ?? "") ?? 5433 }
    static var pgUser: String { e["SB_PG_USER"] ?? "sbuser" }
    static var pgPass: String { e["SB_PG_PASS"] ?? "sbpass123" }
    static var pgDB: String { e["SB_PG_DB"] ?? "sbtest" }
}

@MainActor
@Suite("Content-tab cell edits", .serialized)
struct ContentEditTests {

    func read(_ engine: QueryEngine, _ table: String) async throws -> [[String]] {
        try await engine.query("SELECT id, name FROM \(table) ORDER BY id").rows
    }

    @Test("PostgreSQL: a cell edit and a set-to-NULL reach the server", .enabled(if: CEEnv.pg))
    func postgres() async throws {
        let engine = try QueryEngine()
        let c = Connection(name: "pged", alias: "pged", host: "127.0.0.1", port: CEEnv.pgPort,
                           username: CEEnv.pgUser, database: CEEnv.pgDB, engine: .postgres)
        try await engine.attach(c, password: CEEnv.pgPass)
        try await engine.executeDDL(alias: "pged", sql: "DROP TABLE IF EXISTS public.w_content_edit")
        try await engine.executeDDL(alias: "pged", sql: "CREATE TABLE public.w_content_edit (id int PRIMARY KEY, name text)")
        try await engine.executeDDL(alias: "pged", sql: "INSERT INTO public.w_content_edit VALUES (1, 'before'), (2, 'two')")
        let table = SQLBuilder.duckTable(alias: "pged", database: "public", table: "w_content_edit")

        try await engine.executeWrite(SQLBuilder.update(alias: "pged", database: "public", table: "w_content_edit",
                                                        column: "name", newValue: "after",
                                                        primaryKey: [(column: "id", value: "1")]), alias: "pged")
        try await engine.executeWrite(SQLBuilder.update(alias: "pged", database: "public", table: "w_content_edit",
                                                        column: "name", newValue: nil,
                                                        primaryKey: [(column: "id", value: "2")]), alias: "pged")
        let rows = try await read(engine, table)
        #expect(rows.first == ["1", "after"])
        #expect(rows.last?.first == "2")
        let nulls = try await engine.query("SELECT COUNT(*) FROM \(table) WHERE name IS NULL")
        #expect(nulls.rows.first?.first == "1")
        try await engine.executeDDL(alias: "pged", sql: "DROP TABLE public.w_content_edit")
    }

    @Test("SQLite: a cell edit reaches the file")
    func sqlite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sb_content_edit_\(UUID().uuidString).sqlite").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t VALUES (1, 'before');"]
        try p.run(); p.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let engine = try QueryEngine()
        try await engine.attach(Connection(name: "lited", alias: "lited", database: path, engine: .sqlite), password: "")
        try await engine.executeWrite(SQLBuilder.update(alias: "lited", database: "main", table: "t",
                                                        column: "name", newValue: "after",
                                                        primaryKey: [(column: "id", value: "1")]), alias: "lited")
        let rows = try await read(engine, SQLBuilder.duckTable(alias: "lited", database: "main", table: "t"))
        #expect(rows == [["1", "after"]])
        try await engine.detach("lited")
    }
}
