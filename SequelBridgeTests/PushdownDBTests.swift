//
//  PushdownDBTests.swift
//  SequelBridgeTests
//
//  Real-server check of predicate pushdown in the cross-engine fallback: the user's
//  WHERE reaches the servers' SELECTs (its own conjuncts, and the one carried across
//  the join key), the rows that come back join to EXACTLY what the plain scanner
//  returns, and a query with a misspelled column fails on the shape-only temps
//  before any rows are fetched. Attaches one MariaDB container under two aliases to
//  stand in for two servers (the planner keys off the aliases, not the host). Needs
//  big_events (200k rows, idx_tail) and small_fleet in the connected database.
//  Gated behind SB_XJOIN_VERIFY=1 (pass TEST_RUNNER_SB_XJOIN_VERIFY=1).
//

import Foundation
import Testing
@testable import SequelBridge

private final class StatementLog: @unchecked Sendable {
    var lines: [String] = []
}

@MainActor
@Suite("Predicate pushdown (real DB)", .enabled(if: XJoinEnv.enabled), .serialized)
struct PushdownDBTests {

    private func makeEngine(_ log: StatementLog) async throws -> QueryEngine {
        let engine = try await makeTwoServerEngine()
        engine.onStatement = { sql, _, _, _ in log.lines.append(sql) }
        return engine
    }


    private let baseSQL = "SELECT e.id, e.tail, e.value, s.status FROM srvA.big_events e JOIN srvB.small_fleet s ON e.tail = s.tail WHERE e.tail = 'N003SB' AND s.status = 'active'"

    @Test("each table's server SELECT carries its filter, incl. the one carried across the join key")
    func pushedWhereText() async throws {
        let log = StatementLog()
        let engine = try await makeEngine(log)
        let pushed = await engine.pushdownWhere(baseSQL: baseSQL, aliases: ["srvA", "srvB"]) { _ in XJoinEnv.db }
        #expect(pushed[QueryEngine.pushdownKey(alias: "srvA", table: "big_events")] == "(`tail` = 'N003SB')")
        #expect(pushed[QueryEngine.pushdownKey(alias: "srvB", table: "small_fleet")] == "(`status` = 'active') AND (`tail` = 'N003SB')")
    }

    @Test("materialized with pushdown == plain scanner, and only the matching rows were fetched")
    func pushedRowsEqualScanner() async throws {
        let log = StatementLog()
        let engine = try await makeEngine(log)
        let db = XJoinEnv.db
        let pushed = await engine.pushdownWhere(baseSQL: baseSQL, aliases: ["srvA", "srvB"]) { _ in db }
        var seq = 0
        let plan = SQLBuilder.planFallback(baseSQL, remoteAliases: ["srvA", "srvB"]) { _, _ in
            defer { seq += 1 }; return SQLBuilder.duckIdent("__sb_pd_\(seq)")
        }
        var temps: [String] = []
        for m in plan.materializations {
            temps.append(try await engine.materializeViaPassthrough(
                alias: m.alias, database: db, table: m.table, tempIdent: m.temp,
                extraWhere: pushed[QueryEngine.pushdownKey(alias: m.alias, table: m.table)]))
        }
        defer { let t = temps; Task { for x in t { await engine.dropTempTable(x) } } }
        // The big side came back reduced to the one tail — not the 200k-row table.
        let bigTemp = try #require(plan.materializations.first(where: { $0.table == "big_events" })?.temp)
        let n = try await engine.query("SELECT COUNT(*) FROM \(bigTemp)")
        #expect(n.rows.first?.first == "400")
        #expect(log.lines.contains { $0.contains("`big_events` WHERE (`tail` = 'N003SB')") })
        #expect(log.lines.contains { $0.contains("`small_fleet` WHERE (`status` = 'active') AND (`tail` = 'N003SB')") })

        let materialized = try await engine.query(plan.rewrittenSQL)
        let aRef = SQLBuilder.duckTable(alias: "srvA", database: db, table: "big_events")
        let bRef = SQLBuilder.duckTable(alias: "srvB", database: db, table: "small_fleet")
        let scanner = try await engine.query(
            "SELECT e.id, e.tail, e.value, s.status FROM \(aRef) e JOIN \(bRef) s ON e.tail = s.tail WHERE e.tail = 'N003SB' AND s.status = 'active'")
        #expect(materialized.rows.count == 400)
        #expect(sortedRows(materialized) == sortedRows(scanner))
    }

    @Test("a misspelled column fails on the shape-only temps, before any rows are fetched")
    func bindFailsBeforeFetch() async throws {
        let log = StatementLog()
        let engine = try await makeEngine(log)
        let db = XJoinEnv.db
        let bad = "SELECT e.nosuch FROM srvA.big_events e JOIN srvB.small_fleet s ON e.tail = s.tail"
        var seq = 0
        let plan = SQLBuilder.planFallback(bad, remoteAliases: ["srvA", "srvB"]) { _, _ in
            defer { seq += 1 }; return SQLBuilder.duckIdent("__sb_pdb_\(seq)")
        }
        var temps: [String] = []
        for m in plan.materializations {
            temps.append(try await engine.materializeViaPassthrough(
                alias: m.alias, database: db, table: m.table, tempIdent: m.temp, shapeOnly: true))
        }
        defer { let t = temps; Task { for x in t { await engine.dropTempTable(x) } } }
        // Shape-only temps have the columns and no rows.
        let n = try await engine.query("SELECT COUNT(*) FROM \(temps[0])")
        #expect(n.rows.first?.first == "0")
        #expect(log.lines.allSatisfy { !$0.contains("big_events") || $0.contains("LIMIT 0") })
        // Binding the rewritten query names the problem; nothing was fetched for it.
        var reason = ""
        do { try await engine.bindCheck(plan.rewrittenSQL) } catch { reason = QueryEngine.extractReason(from: error) }
        #expect(reason.lowercased().contains("nosuch"), "got: \(reason)")
        // And a correct query binds fine on the same temps.
        let good = SQLBuilder.planFallback("SELECT e.id FROM srvA.big_events e JOIN srvB.small_fleet s ON e.tail = s.tail",
                                           remoteAliases: ["srvA", "srvB"]) { a, t in
            plan.materializations.first { $0.alias == a && $0.table == t }!.temp
        }
        try await engine.bindCheck(good.rewrittenSQL)
    }
}
