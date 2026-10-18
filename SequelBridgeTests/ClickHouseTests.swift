//
//  ClickHouseTests.swift
//  SequelBridgeTests
//
//  ClickHouse over the native HTTP client, against a live server.
//  Skipped unless SB_CH_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private struct CHEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_CH_VERIFY"] == "1" }
    static var host: String { e["SB_CH_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_CH_PORT"] ?? "8123") ?? 8123 }
    static var user: String { e["SB_CH_USER"] ?? "sbuser" }
    static var pass: String { e["SB_CH_PASS"] ?? "sbpass123" }
}

@MainActor
@Suite("ClickHouse native connection", .enabled(if: CHEnv.enabled), .serialized)
struct ClickHouseTests {

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        var c = Connection(name: "ch", alias: alias, connectionType: .tcpip,
                           host: CHEnv.host, port: CHEnv.port, username: CHEnv.user, database: "default")
        c.engine = .clickhouse
        try await engine.attach(c, password: CHEnv.pass)
        return engine
    }

    @Test("attach validates credentials at connect time")
    func attachValidates() async throws {
        _ = try await makeEngine("ch1")

        let engine = try QueryEngine()
        var bad = Connection(name: "ch", alias: "chbad", connectionType: .tcpip,
                             host: CHEnv.host, port: CHEnv.port, username: CHEnv.user, database: "default")
        bad.engine = .clickhouse
        await #expect(throws: (any Error).self) {
            try await engine.attach(bad, password: "wrong-password")
        }
    }

    @Test("databases list excludes system schemas")
    func databases() async throws {
        let e = try await makeEngine("ch2")
        let dbs = try await e.fetchDatabases(alias: "ch2")
        #expect(dbs.contains("default"))
        #expect(!dbs.contains("system"))
    }

    @Test("tables, columns and table meta come from system tables")
    func metadata() async throws {
        let e = try await makeEngine("ch3")
        let tables = try await e.fetchTables(alias: "ch3", database: "default").map(\.name)
        #expect(tables.contains("events"))

        let cols = try await e.fetchColumns(alias: "ch3", database: "default", table: "events")
        #expect(cols.map(\.name) == ["id", "tail", "value"])
        #expect(cols[0].dataType == "UInt32")
        #expect(cols[0].isPrimaryKey)   // ORDER BY id
        #expect(!cols[1].isPrimaryKey)

        let idx = try await e.fetchIndexes(alias: "ch3", database: "default", table: "events")
        #expect(idx.contains { $0.name == "PRIMARY" && $0.columns == ["id"] })

        let meta = try await e.fetchTableMeta(alias: "ch3", database: "default", table: "events")
        #expect(meta[0] == "MergeTree")
        #expect(Int(meta[6]) ?? 0 >= 3)   // total_rows

        #expect(try await e.fetchRelations(alias: "ch3", database: "default", table: "events").isEmpty)
        #expect(try await e.fetchTriggers(alias: "ch3", database: "default", table: "events").isEmpty)
    }

    @Test("queries return typed rows and log to the console hook")
    func queries() async throws {
        let e = try await makeEngine("ch4")
        var logged: [String] = []
        e.onStatement = { sql, _, _, _ in logged.append(sql) }

        let r = try await e.clickhouseQuery(alias: "ch4", sql: "SELECT id, tail, value FROM default.events ORDER BY id")
        #expect(r.columns == ["id", "tail", "value"])
        #expect(r.columnTypes == ["UInt32", "String", "Float64"])
        #expect(r.rows.count == 3)
        #expect(r.rows[0] == ["1", "N001SB", "9.5"])
        #expect(logged.count == 1)
    }

    @Test("DDL, insert and drop run over HTTP; errors surface and do not stick")
    func writePath() async throws {
        let e = try await makeEngine("ch5")
        try await e.executeDDL(alias: "ch5", sql: "DROP TABLE IF EXISTS default.ch_write")
        try await e.executeDDL(alias: "ch5", sql: """
            CREATE TABLE default.ch_write (id UInt32, note Nullable(String)) ENGINE = MergeTree ORDER BY id
            """)
        try await e.executeDDL(alias: "ch5", sql: "INSERT INTO default.ch_write VALUES (1, 'hello'), (2, NULL)")

        let r = try await e.clickhouseQuery(alias: "ch5", sql: "SELECT note FROM default.ch_write ORDER BY id")
        #expect(r.rows == [["hello"], ["NULL"]])

        await #expect(throws: (any Error).self) {
            try await e.executeDDL(alias: "ch5", sql: "SELECT FROM nonsense syntax")
        }
        // The connection is stateless HTTP — still fine after an error.
        let ok = try await e.clickhouseQuery(alias: "ch5", sql: "SELECT COUNT(*) FROM default.ch_write")
        #expect(ok.rows.first?.first == "2")
        try await e.executeDDL(alias: "ch5", sql: "DROP TABLE default.ch_write")
    }

    @Test("native results are not capped — every row is returned")
    func noCapNative() async throws {
        let e = try await makeEngine("ch6")
        let r = try await e.clickhouseQuery(alias: "ch6", sql: "SELECT number FROM system.numbers LIMIT 100")
        #expect(r.rows.count == 100)
        #expect(r.totalRowCount == 100)
        #expect(!r.isTruncated)
    }

    @Test("detach removes the client")
    func detach() async throws {
        let e = try await makeEngine("ch7")
        try await e.detach("ch7")
        await #expect(throws: (any Error).self) {
            _ = try await e.clickhouseQuery(alias: "ch7", sql: "SELECT 1")
        }
    }
}

@MainActor
@Suite("ClickHouse Query Insights (real DB)", .enabled(if: CHEnv.enabled), .serialized)
struct ClickHouseInsightsTests {
    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        var c = Connection(name: "chi", alias: alias, connectionType: .tcpip,
                           host: CHEnv.host, port: CHEnv.port, username: CHEnv.user, database: "default")
        c.engine = .clickhouse
        try await engine.attach(c, password: CHEnv.pass)
        return engine
    }

    @Test("Recent returns the query_log columns")
    func recent() async throws {
        let e = try await makeEngine("chi1")
        let r = try await e.clickhouseQueryInsights(alias: "chi1", kind: .recent)
        #expect(r.columns.contains("event_time"))
        #expect(r.columns.contains("duration_ms"))
        #expect(r.columns.contains("query"))
    }

    @Test("By Type rolls up per query type")
    func byType() async throws {
        let e = try await makeEngine("chi2")
        let r = try await e.clickhouseQueryInsights(alias: "chi2", kind: .byType)
        #expect(r.columns == ["type", "queries", "avg_ms", "p95_ms", "rows_read"])
    }

    @Test("Slow Queries orders by duration")
    func slow() async throws {
        let e = try await makeEngine("chi3")
        let r = try await e.clickhouseQueryInsights(alias: "chi3", kind: .slow)
        #expect(r.columns.contains("duration_ms"))
    }
}
