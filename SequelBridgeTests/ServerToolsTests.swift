//
//  ServerToolsTests.swift
//  SequelBridgeTests
//
//  Test Connection on the form, Kill on the Server tab, views listed apart from tables.
//  Items from the Sequel Ace checklist (guide/SEQUEL-ACE.md) that worked with no test.
//  Skipped unless SB_MYSQL_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private struct TEnv {
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
@Suite("Server tools on a live server", .enabled(if: TEnv.enabled), .serialized)
struct ServerToolsTests {

    func conn(_ alias: String) -> Connection {
        Connection(name: alias, alias: alias, host: TEnv.host, port: TEnv.port, username: TEnv.user, database: TEnv.db)
    }

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        try await engine.attach(conn(alias), password: TEnv.pass)
        return engine
    }

    @Test("Test Connection passes for the right password and gives the server's reason for a wrong one")
    func testConnection() async throws {
        let manager = try ConnectionManager(arguments: [])
        #expect(await manager.testConnection(conn("tc1"), password: TEnv.pass) == nil)
        let refused = try #require(await manager.testConnection(conn("tc2"), password: "not-the-password"))
        #expect(refused.contains("Access denied"), "got: \(refused)")
        #expect(!refused.contains("not-the-password"))
    }

    @Test("Kill on the Server tab ends a statement that is running")
    func kill() async throws {
        let sleeper = try await makeEngine("k1")
        let admin = try await makeEngine("k2")
        let running = Task { @MainActor in
            try await sleeper.serverPassthroughQuery(alias: "k1", serverSQL: "SELECT SLEEP(30) AS sb_kill_probe")
        }
        // Find it in the process list, as the Server tab shows it.
        var id: String?
        for _ in 0..<40 where id == nil {
            try await Task.sleep(nanoseconds: 250_000_000)
            let list = try await admin.serverProcesses(alias: "k2")
            let info = list.columns.firstIndex { $0.lowercased() == "info" } ?? 7
            id = list.rows.first { $0.count > info && $0[info].contains("sb_kill_probe") && !$0[info].contains("PROCESSLIST") }?[0]
        }
        let pid = try #require(id, "the sleeping statement never showed in the process list")
        let started = Date()
        try await admin.killProcess(alias: "k2", id: pid)
        _ = await running.result
        #expect(Date().timeIntervalSince(started) < 10, "the statement kept running after Kill")
    }

    @Test("a view is listed as a view, apart from the tables")
    func views() async throws {
        let e = try await makeEngine("v1")
        let v = SQLBuilder.mysqlTable(database: TEnv.writeDB, table: "st_view_probe")
        try await e.mysqlExecute(alias: "v1", sql: "CREATE OR REPLACE VIEW \(v) AS SELECT 1 AS one")
        let listed = try await e.fetchTables(alias: "v1", database: TEnv.writeDB)
        try await e.mysqlExecute(alias: "v1", sql: "DROP VIEW \(v)")
        #expect(listed.first { $0.name == "st_view_probe" }?.type == .view)
        #expect(listed.contains { $0.type == .table })
    }
}
