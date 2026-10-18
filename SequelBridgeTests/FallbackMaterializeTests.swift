//
//  FallbackMaterializeTests.swift
//  SequelBridgeTests
//
//  Pure-function tests for the cross-engine scanner fallback planner. When a query
//  spans servers but matches none of the fast reductions, DuckDB's raw ATTACH
//  scanner drags each remote table across the wire row by row (~130x slower than
//  the mysql_query/postgres_query passthrough over a VPN). SQLBuilder.planFallback
//  finds the remote (MySQL/Postgres) `alias.table` references so the caller can
//  materialize each through the fast passthrough into a DuckDB TEMP table, and
//  returns the query rewritten to read those temp tables. SQLite references are
//  left untouched for the caller's expandAliases pass.
//
//  No database is touched — this is all string analysis — so these run every build.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Cross-engine fallback materialization planner")
struct FallbackMaterializeTests {

    /// Deterministic temp namer for assertions: `"m_<alias>_<table>"`, DuckDB-quoted.
    private let namer: (String, String) -> String = { a, t in "\"m_\(a)_\(t)\"" }

    @Test("a single remote table is planned and rewritten; local refs and literals untouched")
    func singleRemote() {
        let sql = "SELECT c.name, ac.tail FROM lite.customers c JOIN srv.fleet_state ac ON ac.tail = 'N1'"
        let plan = SQLBuilder.planFallback(sql, remoteAliases: ["srv"], tempName: namer)

        #expect(plan.materializations == [
            .init(alias: "srv", table: "fleet_state", temp: "\"m_srv_fleet_state\"")
        ])
        // srv.fleet_state → temp; lite.customers, the trailing `ac`, and the
        // 'N1' literal are all preserved verbatim.
        #expect(plan.rewrittenSQL ==
            "SELECT c.name, ac.tail FROM lite.customers c JOIN \"m_srv_fleet_state\" ac ON ac.tail = 'N1'")
    }

    @Test("no remote references means nothing to materialize and the SQL is unchanged")
    func noRemote() {
        let sql = "SELECT * FROM lite.customers c JOIN lite.orders o ON c.id = o.cid"
        let plan = SQLBuilder.planFallback(sql, remoteAliases: ["srv", "pg"], tempName: namer)

        #expect(plan.materializations.isEmpty)
        #expect(plan.rewrittenSQL == sql)
    }

    @Test("two distinct remote tables are each materialized and rewritten")
    func twoRemote() {
        let sql = "SELECT * FROM a.orders o JOIN b.customers c ON o.cid = c.id"
        let plan = SQLBuilder.planFallback(sql, remoteAliases: ["a", "b"], tempName: namer)

        #expect(plan.materializations == [
            .init(alias: "a", table: "orders", temp: "\"m_a_orders\""),
            .init(alias: "b", table: "customers", temp: "\"m_b_customers\"")
        ])
        #expect(plan.rewrittenSQL ==
            "SELECT * FROM \"m_a_orders\" o JOIN \"m_b_customers\" c ON o.cid = c.id")
    }

    @Test("the same remote table referenced twice is materialized once and rewritten everywhere")
    func sameTableTwice() {
        var calls = 0
        let counting: (String, String) -> String = { a, t in calls += 1; return "\"m_\(a)_\(t)\"" }
        let sql = "SELECT * FROM srv.t x JOIN srv.t y ON x.id = y.pid"
        let plan = SQLBuilder.planFallback(sql, remoteAliases: ["srv"], tempName: counting)

        #expect(plan.materializations == [.init(alias: "srv", table: "t", temp: "\"m_srv_t\"")])
        #expect(calls == 1)   // the namer is asked once per distinct (alias, table)
        #expect(plan.rewrittenSQL ==
            "SELECT * FROM \"m_srv_t\" x JOIN \"m_srv_t\" y ON x.id = y.pid")
    }

    @Test("an alias inside a string literal or quoted identifier is never matched")
    func quotedSpansIgnored() {
        let sql = "SELECT 'srv.secret' AS note, \"srv.col\" FROM srv.real r"
        let plan = SQLBuilder.planFallback(sql, remoteAliases: ["srv"], tempName: namer)

        #expect(plan.materializations == [.init(alias: "srv", table: "real", temp: "\"m_srv_real\"")])
        #expect(plan.rewrittenSQL ==
            "SELECT 'srv.secret' AS note, \"srv.col\" FROM \"m_srv_real\" r")
    }

    @Test("alias matching is case-insensitive but reports the canonical alias")
    func caseInsensitiveAlias() {
        let sql = "SELECT * FROM SRV.FleetState"
        let plan = SQLBuilder.planFallback(sql, remoteAliases: ["srv"], tempName: namer)

        #expect(plan.materializations == [
            .init(alias: "srv", table: "FleetState", temp: "\"m_srv_FleetState\"")
        ])
        #expect(plan.rewrittenSQL == "SELECT * FROM \"m_srv_FleetState\"")
    }

    @Test("an already 3-part reference is left for expandAliases, not materialized")
    func threePartLeftAlone() {
        let sql = "SELECT * FROM srv.db.tbl"
        let plan = SQLBuilder.planFallback(sql, remoteAliases: ["srv"], tempName: namer)

        #expect(plan.materializations.isEmpty)
        #expect(plan.rewrittenSQL == sql)
    }

    @Test("a non-word-boundary prefix like srvx.t is not mistaken for the srv alias")
    func wordBoundary() {
        let sql = "SELECT * FROM srvx.t"
        let plan = SQLBuilder.planFallback(sql, remoteAliases: ["srv"], tempName: namer)

        #expect(plan.materializations.isEmpty)
        #expect(plan.rewrittenSQL == sql)
    }
}
