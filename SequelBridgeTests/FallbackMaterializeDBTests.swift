//
//  FallbackMaterializeDBTests.swift
//  SequelBridgeTests
//
//  End-to-end check of the cross-engine scanner fallback's passthrough
//  materialization against a real server. It replicates QueryPanelView's fallback
//  orchestration — SQLBuilder.planFallback picks the remote tables, the engine
//  materializes each via the passthrough into a DuckDB TEMP table, the query is
//  rewritten to read them — and proves the materialized plan returns EXACTLY the
//  same rows as the plain cross-engine scanner. Materialization may only speed a
//  query up, never change its result.
//
//  Like CrossJoinReductionTests it attaches ONE MariaDB container under two aliases
//  (srvA, srvB) to stand in for two servers; the fallback keys off aliases, not
//  hosts. Needs big_events and small_fleet in the connected database. Gated behind
//  SB_XJOIN_VERIFY=1 (pass TEST_RUNNER_SB_XJOIN_VERIFY=1).
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Cross-engine fallback materialization (real DB)", .enabled(if: XJoinEnv.enabled), .serialized)
struct FallbackMaterializeDBTests {

    /// Replicates QueryPanelView's fallback: plan the remote tables, materialize each
    /// via the passthrough, return the rewritten DuckDB SQL plus the temp idents to drop.
    private func buildFallbackSQL(_ engine: QueryEngine, baseSQL: String,
                                  remoteAliases: Set<String>, db: String) async throws
        -> (sql: String, temps: [String]) {
        var seq = 0
        let plan = SQLBuilder.planFallback(baseSQL, remoteAliases: remoteAliases) { _, _ in
            defer { seq += 1 }; return SQLBuilder.duckIdent("__sb_mat_\(seq)")
        }
        var temps: [String] = []
        for m in plan.materializations {
            let ident = try await engine.materializeViaPassthrough(
                alias: m.alias, database: db, table: m.table, tempIdent: m.temp)
            temps.append(ident)
        }
        return (plan.rewrittenSQL, temps)
    }


    @Test("a materialized table holds exactly the server's rows")
    func materializeMatchesServer() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        let ident = try await engine.materializeViaPassthrough(
            alias: "srvB", database: db, table: "small_fleet",
            tempIdent: SQLBuilder.duckIdent("__sb_mat_probe"))

        let temp = try await engine.query("SELECT * FROM \(ident) ORDER BY tail")
        let scanRef = SQLBuilder.duckTable(alias: "srvB", database: db, table: "small_fleet")
        let scan = try await engine.query("SELECT * FROM \(scanRef) ORDER BY tail")

        #expect(temp.columns == scan.columns)
        #expect(temp.rows.count == 10)
        #expect(sortedRows(temp) == sortedRows(scan))
        await engine.dropTempTable(ident)
    }

    @Test("the fallback (non-reducible join) materialized plan equals the scanner, row for row")
    func fallbackEqualsScanner() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        // `ON e.id = 1` is a constant filter, not a key equality, so detectCrossJoin
        // declines it (the exact shape of the user's reported slow query) and the
        // planner reaches the scanner fallback. Both tables are remote, so both are
        // materialized via the passthrough.
        #expect(SQLBuilder.detectCrossJoin(
            "SELECT 1 FROM srvA.big_events e JOIN srvB.small_fleet s ON e.id = 1",
            aliases: ["srvA", "srvB"]) == nil)

        let baseSQL = "SELECT e.id, e.tail, s.tail, s.status FROM srvA.big_events e JOIN srvB.small_fleet s ON e.id = 1"

        let (matSQL, temps) = try await buildFallbackSQL(
            engine, baseSQL: baseSQL, remoteAliases: ["srvA", "srvB"], db: db)
        #expect(matSQL.contains("__sb_mat_0"))
        #expect(matSQL.contains("__sb_mat_1"))
        #expect(!matSQL.contains("srvA.big_events"))   // both remote refs were rewritten
        #expect(!matSQL.contains("srvB.small_fleet"))
        let materialized = try await engine.query(matSQL)

        let aRef = SQLBuilder.duckTable(alias: "srvA", database: db, table: "big_events")
        let bRef = SQLBuilder.duckTable(alias: "srvB", database: db, table: "small_fleet")
        let scannerSQL = "SELECT e.id, e.tail, s.tail, s.status FROM \(aRef) e JOIN \(bRef) s ON e.id = 1"
        let scanner = try await engine.query(scannerSQL)

        #expect(materialized.columns == scanner.columns)
        #expect(materialized.rows.count == scanner.rows.count)
        #expect(materialized.rows.count == 10)         // one big_events row × 10 fleet rows
        #expect(sortedRows(materialized) == sortedRows(scanner))
        print("FALLBACK materialized=\(String(format: "%.3f", materialized.executionTime))s  scanner=\(String(format: "%.3f", scanner.executionTime))s  (rows=\(materialized.rows.count))")

        for t in temps { await engine.dropTempTable(t) }
    }

    @Test("a mixed local-SQLite / remote-MySQL fallback materializes only the remote side")
    func mixedEngineOnlyRemoteMaterialized() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        // Only srvA is in remoteAliases, mimicking a SQLite side the planner leaves to
        // expandAliases. srvB here stands in for that untouched side.
        let baseSQL = "SELECT e.id, s.tail FROM srvA.big_events e JOIN srvB.small_fleet s ON e.id = 1"
        let (matSQL, temps) = try await buildFallbackSQL(
            engine, baseSQL: baseSQL, remoteAliases: ["srvA"], db: db)

        #expect(matSQL.contains("__sb_mat_0"))
        #expect(!matSQL.contains("srvA.big_events"))   // remote side rewritten
        #expect(matSQL.contains("srvB.small_fleet"))   // non-remote side left for expandAliases
        for t in temps { await engine.dropTempTable(t) }
    }
}
