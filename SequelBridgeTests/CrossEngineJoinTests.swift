//
//  CrossEngineJoinTests.swift
//  SequelBridgeTests
//
//  The streaming cross-server join across ENGINES, against real servers: PostgreSQL ×
//  MySQL with either side big, PostgreSQL × SQLite, and the comma form across
//  engines. Each plan is checked for its shape — the big side first, each side
//  through its own server's passthrough (a SQLite side as a scanner ref) — and for
//  returning exactly the scanner's rows. MariaDB and PostgreSQL hold the same
//  10-tail small_fleet; MariaDB has big_events (200k rows), PostgreSQL big_metrics
//  (100k rows, `tail`). Gated behind SB_XJOIN_VERIFY=1 + SB_PG_VERIFY=1 + SB_PG_PASS.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Cross-engine join (real DBs)", .enabled(if: XJoinPGEnv.enabled), .serialized)
struct CrossEngineJoinTests {
    private let aliases = ["srvA", "srvB", "pg", "lite"]

    private func db(_ alias: String) -> String {
        switch alias {
        case "pg":   return "public"
        case "lite": return "main"
        default:     return XJoinEnv.db
        }
    }
    private func ref(_ alias: String, _ table: String) -> String {
        SQLBuilder.duckTable(alias: alias, database: db(alias), table: table)
    }

    /// MariaDB twice (srvA, srvB), PostgreSQL (pg) and a SQLite fleet of two tails (lite).
    private func makeEngine() async throws -> (engine: QueryEngine, sqlitePath: String) {
        let engine = try await makeTwoServerEngine()
        try await attachPostgres(engine, alias: "pg")
        let path = try await attachSQLiteFleet(engine, alias: "lite", tails: ["N000SB", "N003SB"])
        return (engine, path)
    }

    private func plan(_ engine: QueryEngine, _ sql: String) async throws -> String {
        let cj = try #require(SQLBuilder.detectCrossJoin(sql, aliases: aliases))
        return try #require(try await engine.crossJoinPlan(cj, baseSQL: sql, aliases: aliases, databaseFor: db))
    }

    private func expectSameRows(_ engine: QueryEngine, plan: String, scanner: String,
                                count: Int? = nil) async throws {
        let got = try await engine.query(plan)
        let want = try await engine.query(scanner)
        #expect(got.columns == want.columns)
        #expect(got.rows.count == want.rows.count)
        #expect(got.rows.count > 0)
        if let count { #expect(got.rows.count == count) }
        #expect(sortedRows(got) == sortedRows(want))
    }

    @Test("an unanalyzed PostgreSQL table still has a row estimate, from the stats collector")
    func postgresEstimateWithoutAnalyze() async throws {
        let (engine, path) = try await makeEngine()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // The fixture's small_fleet was never ANALYZEd (reltuples = -1); without the
        // fallback the planner ranked it as the largest side and streamed the 10-row
        // table through a hash table of the 200k-row one.
        #expect(await engine.tableRowEstimate(alias: "pg", database: "public", table: "small_fleet") == 10)
        #expect((await engine.tableRowEstimate(alias: "pg", database: "public", table: "big_metrics") ?? 0) > 50_000)
    }

    @Test("MySQL big side, PostgreSQL probe")
    func mysqlBigPostgresProbe() async throws {
        let (engine, path) = try await makeEngine()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sql = "SELECT e.id, e.tail, s.status FROM srvA.big_events e JOIN pg.small_fleet s ON e.tail = s.tail"
        let p = try await plan(engine, sql)
        #expect(p.hasPrefix("SELECT e.id, e.tail, s.status FROM (SELECT * FROM mysql_query('srvA'"))
        #expect(p.contains("postgres_query('pg'"))
        try await expectSameRows(engine, plan: p,
            scanner: "SELECT e.id, e.tail, s.status FROM \(ref("srvA", "big_events")) e JOIN \(ref("pg", "small_fleet")) s ON e.tail = s.tail",
            count: 4000)
    }

    @Test("PostgreSQL big side, MySQL probe")
    func postgresBigMysqlProbe() async throws {
        let (engine, path) = try await makeEngine()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sql = "SELECT m.id, m.tail, m.score, s.status FROM srvB.small_fleet s JOIN pg.big_metrics m ON s.tail = m.tail"
        let p = try await plan(engine, sql)
        #expect(p.hasPrefix("SELECT m.id, m.tail, m.score, s.status FROM (SELECT * FROM postgres_query('pg'"))
        #expect(p.contains("mysql_query('srvB'"))
        try await expectSameRows(engine, plan: p,
            scanner: "SELECT m.id, m.tail, m.score, s.status FROM \(ref("srvB", "small_fleet")) s JOIN \(ref("pg", "big_metrics")) m ON s.tail = m.tail")
    }

    @Test("PostgreSQL big side, SQLite probe")
    func postgresBigSqliteProbe() async throws {
        let (engine, path) = try await makeEngine()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sql = "SELECT m.id, m.tail, f.tail AS lite_tail FROM pg.big_metrics m JOIN lite.fleet f ON m.tail = f.tail"
        let p = try await plan(engine, sql)
        #expect(p.hasPrefix("SELECT m.id, m.tail, f.tail AS lite_tail FROM (SELECT * FROM postgres_query('pg'"))
        #expect(p.contains("IN ("))                                   // reduced to the SQLite side's keys
        try await expectSameRows(engine, plan: p,
            scanner: "SELECT m.id, m.tail, f.tail AS lite_tail FROM \(ref("pg", "big_metrics")) m JOIN \(ref("lite", "fleet")) f ON m.tail = f.tail")
    }

    @Test("the comma form across engines, with a pushed-down filter")
    func commaAcrossEngines() async throws {
        let (engine, path) = try await makeEngine()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sql = "SELECT e.id, e.tail, s.status FROM srvA.big_events e, pg.small_fleet s WHERE e.tail = s.tail AND e.value > 500"
        let p = try await plan(engine, sql)
        #expect(p.hasPrefix("SELECT e.id, e.tail, s.status FROM (SELECT * FROM mysql_query('srvA'"))
        #expect(p.contains("`value` > 500"))                          // the big side's own filter, on its server
        try await expectSameRows(engine, plan: p,
            scanner: "SELECT e.id, e.tail, s.status FROM \(ref("srvA", "big_events")) e JOIN \(ref("pg", "small_fleet")) s ON e.tail = s.tail WHERE e.value > 500")
    }
}
