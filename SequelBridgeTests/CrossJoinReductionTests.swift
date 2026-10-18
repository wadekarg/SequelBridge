//
//  CrossJoinReductionTests.swift
//  SequelBridgeTests
//
//  End-to-end check of the cross-server INNER-join reduction against real servers.
//  It replicates QueryPanelView's orchestration with the shipping engine/SQLBuilder
//  helpers, then proves the reduced plan returns EXACTLY the same rows as the plain
//  cross-engine scanner — the reduction may only speed a query up, never change it.
//
//  MySQL×MySQL is the real target (the headline use case joins two MariaDB servers),
//  so it attaches ONE MariaDB container under two aliases to stand in for two servers:
//  the detector keys off the aliases, not the host. Needs the big_events table and a
//  small_fleet probe table (10 tails ⊂ big_events.tail) in the connected database.
//  Gated behind SB_XJOIN_VERIFY=1 (pass TEST_RUNNER_SB_XJOIN_VERIFY=1).
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Cross-server join reduction (real DB)", .enabled(if: XJoinEnv.enabled), .serialized)
struct CrossJoinReductionTests {

    /// The planner's DuckDB statement for `baseSQL` — what QueryPanelView streams — or
    /// nil when it declines and the scanner would run. `db` resolves every alias.
    private func plan(_ engine: QueryEngine, baseSQL: String, aliases: [String], db: String) async throws -> String? {
        guard let cj = SQLBuilder.detectCrossJoin(baseSQL, aliases: aliases) else { return nil }
        return try await engine.crossJoinPlan(cj, baseSQL: baseSQL, aliases: aliases) { _ in db }
    }

    @Test("a table side as a passthrough subquery carries its pushed-down filter")
    func passthroughTableSide() async throws {
        let engine = try await makeTwoServerEngine()
        let sub = engine.passthroughTable(alias: "srvB", database: XJoinEnv.db, table: "small_fleet", extraWhere: "(`status` = 'active')")
        #expect(sub == "SELECT * FROM mysql_query('srvB', 'SELECT * FROM `\(XJoinEnv.db)`.`small_fleet` WHERE (`status` = ''active'')')")
        let r = try await engine.query("SELECT COUNT(*) FROM (\(sub!)) t")
        #expect(r.rows.first?.first == "10")
    }


    @Test("the detector picks the smaller side as the probe")
    func probeIsSmaller() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        let estBig   = await engine.tableRowEstimate(alias: "srvA", database: db, table: "big_events")
        let estSmall = await engine.tableRowEstimate(alias: "srvB", database: db, table: "small_fleet")
        #expect((estBig ?? 0) > (estSmall ?? Int.max))
        #expect(estSmall == 10)
    }

    @Test("reduced plan equals the scanner plan, row for row")
    func reducedEqualsScanner() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        let aliases = ["srvA", "srvB"]

        // What the user types (alias.table form).
        let baseSQL = "SELECT e.id, e.tail, e.value, s.status FROM srvA.big_events e JOIN srvB.small_fleet s ON e.tail = s.tail"

        // Reduced plan — must actually push the big side through the passthrough.
        let reducedSQL = try #require(try await plan(engine, baseSQL: baseSQL, aliases: aliases, db: db))
        #expect(reducedSQL.contains("mysql_query"))
        #expect(reducedSQL.contains("small_fleet"))     // probe kept as a scanner ref
        let reduced = try await engine.query(reducedSQL)

        // Scanner plan — the 3-part expansion expandAliases would produce.
        let bigRef   = SQLBuilder.duckTable(alias: "srvA", database: db, table: "big_events")
        let smallRef = SQLBuilder.duckTable(alias: "srvB", database: db, table: "small_fleet")
        let scannerSQL = "SELECT e.id, e.tail, e.value, s.status FROM \(bigRef) e JOIN \(smallRef) s ON e.tail = s.tail"
        let scanner = try await engine.query(scannerSQL)

        // Same cardinality, and the exact same set of rows.
        #expect(reduced.rows.count == 4000)
        #expect(scanner.rows.count == 4000)
        #expect(reduced.columns == scanner.columns)
        #expect(sortedRows(reduced) == sortedRows(scanner))

        // The reduction sends only the matching big-side rows (4k) instead of the whole
        // 200k-row table, so it must not be slower than the scanner. (Both timings print
        // to the test log; the gap widens in Release and on larger/less-selective tables.)
        print("XJOIN reduced=\(String(format: "%.3f", reduced.executionTime))s  scanner=\(String(format: "%.3f", scanner.executionTime))s  (rows=\(reduced.rows.count))")
        #expect(reduced.executionTime <= scanner.executionTime)
    }

    @Test("the server's EXPLAIN of a reduced big side parses to a usable row estimate")
    func explainEstimateParses() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        let keys = try await engine.distinctKeys(alias: "srvB", database: db, table: "small_fleet", column: "tail")
        let inList = SQLBuilder.inValueList(keys.rows.map { $0.first ?? "" }, mask: keys.nullMask.map { $0.first ?? false })
        let sql = engine.reducedBigSideServerSQL(alias: "srvA", database: db, table: "big_events",
                                                 keyColumn: "tail", keyList: inList)
        let plan = try await engine.explain(alias: "srvA", serverSQL: sql)
        let est = SQLBuilder.explainEstimatedRows(columns: plan.columns, rows: plan.rows)
        #expect((est ?? 0) > 0, "EXPLAIN gave no row estimate: \(plan.columns) \(plan.rows)")
    }

    @Test("the whole-side plan (non-selective key) equals the scanner, with no temp tables")
    func wholeSidePlanEqualsScanner() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        let baseSQL = "SELECT e.id, e.tail, e.value, s.status FROM srvA.big_events e JOIN srvB.small_fleet s ON e.tail = s.tail"
        let cj = try #require(SQLBuilder.detectCrossJoin(baseSQL, aliases: ["srvA", "srvB"]))

        // What QueryPanelView does when the big side's key isn't selective: both sides
        // whole through the passthrough, big side first, joined as they stream in —
        // nothing is copied into a TEMP table first.
        let bigRef   = "(\(try #require(engine.passthroughTable(alias: "srvA", database: db, table: "big_events"))))"
        let probeRef = "(\(try #require(engine.passthroughTable(alias: "srvB", database: db, table: "small_fleet"))))"
        let sql = SQLBuilder.crossJoinRewrite(baseSQL, join: cj, bigIsA: true, bigRef: bigRef, probeRef: probeRef)
        #expect(!sql.uppercased().contains("TEMP"))
        let whole = try await engine.query(sql)

        let bigScan   = SQLBuilder.duckTable(alias: "srvA", database: db, table: "big_events")
        let smallScan = SQLBuilder.duckTable(alias: "srvB", database: db, table: "small_fleet")
        let scanner = try await engine.query("SELECT e.id, e.tail, e.value, s.status FROM \(bigScan) e JOIN \(smallScan) s ON e.tail = s.tail")

        #expect(whole.columns == scanner.columns)
        #expect(whole.rows.count == 4000)
        #expect(sortedRows(whole) == sortedRows(scanner))
    }

    @Test("a SQLite × MySQL join streams the MySQL side, reduced to the SQLite keys, and equals the scanner")
    func sqliteProbe() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        // A local SQLite file holding two of the fleet's tails stands in for the user's
        // local side: it has no passthrough, so the MySQL side must be the one that streams.
        let path = try await attachSQLiteFleet(engine, alias: "lite", tails: ["N000SB", "N003SB"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let aliases = ["srvA", "srvB", "lite"]
        let baseSQL = "SELECT e.id, e.tail, f.tail AS lite_tail FROM srvA.big_events e JOIN lite.fleet f ON e.tail = f.tail"
        let cj = try #require(SQLBuilder.detectCrossJoin(baseSQL, aliases: aliases))
        let sql = try #require(try await engine.crossJoinPlan(cj, baseSQL: baseSQL, aliases: aliases) { $0 == "lite" ? "main" : db })
        #expect(sql.hasPrefix("SELECT e.id, e.tail, f.tail AS lite_tail FROM (SELECT * FROM mysql_query('srvA'"))  // MySQL side first, through its passthrough
        #expect(sql.contains("IN ("))                                                                    // reduced to the SQLite side's keys
        let streamed = try await engine.query(sql)

        let bigRef  = SQLBuilder.duckTable(alias: "srvA", database: db, table: "big_events")
        let liteRef = SQLBuilder.duckTable(alias: "lite", database: "main", table: "fleet")
        let scanner = try await engine.query("SELECT e.id, e.tail, f.tail AS lite_tail FROM \(bigRef) e JOIN \(liteRef) f ON e.tail = f.tail")
        #expect(streamed.rows.count == 800)
        #expect(streamed.columns == scanner.columns)
        #expect(sortedRows(streamed) == sortedRows(scanner))
    }

    @Test("the big side streams through the join: first rows long before the transfer ends")
    func bigSideStreams() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        // A 400k-row big side (a server-side self-join) on one server and a probe on
        // the other whose keys match every big row: the shape of a whole-side plan,
        // with enough rows for streaming and materializing to look different.
        func passthrough(_ alias: String, _ serverSQL: String) -> String {
            "(SELECT * FROM mysql_query('\(alias)', '\(serverSQL.replacingOccurrences(of: "'", with: "''"))'))"
        }
        let bigRef = passthrough("srvA", "SELECT a.id, a.tail, b.value FROM `\(db)`.`big_events` a JOIN `\(db)`.`big_events` b ON a.tail = b.tail LIMIT 400000")
        let probeRef = passthrough("srvB", "SELECT DISTINCT `tail` FROM `\(db)`.`big_events`")
        let baseSQL = "SELECT x.id, x.value, p.tail AS probe_tail FROM srvA.big_events x JOIN srvB.big_events p ON x.tail = p.tail"
        let cj = try #require(SQLBuilder.detectCrossJoin(baseSQL, aliases: ["srvA", "srvB"]))
        let sql = SQLBuilder.crossJoinRewrite(baseSQL, join: cj, bigIsA: true, bigRef: bigRef, probeRef: probeRef)

        let t0 = Date()
        let (first, stream) = try await engine.openStreamingQuery(sql, firstChunk: 2_000, pinJoinOrder: true)
        let tFirst = Date().timeIntervalSince(t0)
        var rows = first.rowCount
        while let chunk = try await engine.pullMore(stream, size: 50_000) { rows += chunk.rowCount }
        let tTotal = Date().timeIntervalSince(t0)

        #expect(rows == 400_000)
        #expect(tTotal > 1, "the transfer must take long enough to tell streaming from materializing (\(tTotal)s)")
        #expect(tFirst < tTotal / 3, "first rows after \(tFirst)s of \(tTotal)s — the big side was materialized before the join")
    }

    @Test("a WHERE on the probe side still matches the scanner")
    func reducedEqualsScannerWithFilter() async throws {
        let engine = try await makeTwoServerEngine()
        let db = XJoinEnv.db
        let aliases = ["srvA", "srvB"]

        // Probe-side filter: the reduction fetches the unfiltered key superset, so the
        // extra big-side rows it keeps must still be dropped by the WHERE — proving the
        // superset is safe for an inner join.
        let baseSQL = "SELECT e.id, e.tail, e.value FROM srvA.big_events e JOIN srvB.small_fleet s ON e.tail = s.tail WHERE e.value > 500 AND s.tail IN ('N000SB', 'N001SB')"

        let reducedSQL = try #require(try await plan(engine, baseSQL: baseSQL, aliases: aliases, db: db))
        #expect(reducedSQL.contains("mysql_query"))
        let reduced = try await engine.query(reducedSQL)

        let bigRef   = SQLBuilder.duckTable(alias: "srvA", database: db, table: "big_events")
        let smallRef = SQLBuilder.duckTable(alias: "srvB", database: db, table: "small_fleet")
        let scannerSQL = "SELECT e.id, e.tail, e.value FROM \(bigRef) e JOIN \(smallRef) s ON e.tail = s.tail WHERE e.value > 500 AND s.tail IN ('N000SB', 'N001SB')"
        let scanner = try await engine.query(scannerSQL)

        #expect(reduced.rows.count == scanner.rows.count)
        #expect(sortedRows(reduced) == sortedRows(scanner))
        #expect(reduced.rows.count > 0)                 // the filter keeps some rows
    }
}
