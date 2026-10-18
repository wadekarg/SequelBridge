//
//  ClickHouseBridgeTests.swift
//  SequelBridgeTests
//
//  The app-side ClickHouse bridge: ClickHouse is native-HTTP and can't be ATTACH'd
//  into DuckDB, so its side of a two-table join is copied into a DuckDB TEMP table
//  and the join runs on DuckDB — planned like every other cross-server join (see
//  QueryEngine.clickHouseJoinPlan): when the ClickHouse side is the smaller one it
//  is copied whole (with its own pushed-down WHERE) and the other side streams from
//  its server reduced to the ClickHouse keys; when it is the bigger one it is copied
//  reduced to the other side's keys. This exercises the real engine plan against a
//  live ClickHouse container and a live MariaDB, and checks every result against an
//  oracle: the whole ClickHouse table copied over, joined by DuckDB's own scanner.
//
//  Needs SB_CHBRIDGE_VERIFY=1 (pass TEST_RUNNER_SB_CHBRIDGE_VERIFY=1), a MariaDB with
//  sbtest.big_events (500 tails × 400 rows) and small_fleet (10 tails), and a
//  ClickHouse with sbtest.fleet_meta (10 typed rows, tails N000SB..N009SB ⊂
//  big_events.tail, `status` active/inactive alternating).
//

import Foundation
import Testing
@testable import SequelBridge

private struct CEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_CHBRIDGE_VERIFY"] == "1" }
    // MariaDB (ATTACH'd side)
    static var myHost: String { e["SB_CHB_MY_HOST"] ?? "127.0.0.1" }
    static var myPort: Int { Int(e["SB_CHB_MY_PORT"] ?? "") ?? 3309 }
    static var myUser: String { e["SB_CHB_MY_USER"] ?? "root" }
    static var myPass: String { e["SB_CHB_MY_PASS"] ?? "sbverify123" }
    // ClickHouse (bridged side, over the HTTP interface)
    static var chHost: String { e["SB_CHB_CH_HOST"] ?? "127.0.0.1" }
    static var chPort: Int { Int(e["SB_CHB_CH_PORT"] ?? "") ?? 8123 }
    static var chUser: String { e["SB_CHB_CH_USER"] ?? "sbuser" }
    static var chPass: String { e["SB_CHB_CH_PASS"] ?? "sbpass123" }
    static var db: String { e["SB_CHB_DB"] ?? "sbtest" }
}

@MainActor
@Suite("ClickHouse bridge (real DB)", .enabled(if: CEnv.enabled), .serialized)
struct ClickHouseBridgeTests {
    private let aliases = ["maria", "ch"]

    private func makeEngine() async throws -> QueryEngine {
        let engine = try QueryEngine()
        let maria = Connection(name: "maria", alias: "maria", connectionType: .tcpip,
                               host: CEnv.myHost, port: CEnv.myPort, username: CEnv.myUser,
                               database: CEnv.db, engine: .mysql)
        try await engine.attach(maria, password: CEnv.myPass)
        let ch = Connection(name: "ch", alias: "ch", connectionType: .tcpip,
                            host: CEnv.chHost, port: CEnv.chPort, username: CEnv.chUser,
                            database: CEnv.db, engine: .clickhouse)
        try await engine.attach(ch, password: CEnv.chPass)
        return engine
    }

    /// The rows the join must produce: the whole ClickHouse table copied over, joined
    /// by DuckDB's own scanner of the MariaDB side. Computed before the plan, which
    /// replaces the same temp table.
    private func oracle(_ engine: QueryEngine, select: String, mariaTable: String, mariaAlias: String,
                        chAlias: String, on: String, where: String? = nil) async throws -> QueryResult {
        let whole = try await engine.materializeClickHouse(alias: "ch", database: CEnv.db, table: "fleet_meta",
                                                           keyColumn: nil, keyValues: nil)
        let maria = SQLBuilder.duckTable(alias: "maria", database: CEnv.db, table: mariaTable)
        var sql = "SELECT \(select) FROM \(maria) \(mariaAlias) JOIN \(whole) \(chAlias) ON \(on)"
        if let `where` { sql += " WHERE \(`where`)" }
        return try await engine.query(sql)
    }

    private func plan(_ engine: QueryEngine, _ sql: String) async throws -> (sql: String, temp: String) {
        let cj = try #require(SQLBuilder.detectCrossJoin(sql, aliases: aliases))
        return try await engine.clickHouseJoinPlan(cj, baseSQL: sql, aliases: aliases) { _ in CEnv.db }
    }

    @Test("attach records the connection's database, so `ch.table` resolves without a sidebar pick")
    func attachRecordsDatabase() async throws {
        // The workspace resolves an alias's database from the sidebar selection, else
        // from what attach recorded; ClickHouse recorded nothing, so a bridged join
        // was sent to ClickHouse as ``.`table` and failed.
        let engine = try await makeEngine()
        #expect(engine.attachedDatabase("ch") == CEnv.db)
    }

    @Test("materialize maps ClickHouse types to DuckDB-compatible columns")
    func typeMapping() async throws {
        let engine = try await makeEngine()
        let temp = try await engine.materializeClickHouse(
            alias: "ch", database: CEnv.db, table: "fleet_meta", keyColumn: nil, keyValues: nil)
        defer { Task { await engine.dropTempTable(temp) } }

        let desc = try await engine.query("DESCRIBE SELECT * FROM \(temp)")
        var types: [String: String] = [:]
        for row in desc.rows where row.count >= 2 { types[row[0]] = row[1].uppercased() }
        #expect(types["tail"] == "VARCHAR")
        #expect(types["reg_ts"] == "TIMESTAMP")       // DateTime64 → TIMESTAMP
        #expect(types["maybe_dt"] == "TIMESTAMP")      // Nullable(DateTime) → TIMESTAMP
        #expect(types["ip"] == "VARCHAR")              // IPv4 → VARCHAR (lossy but safe)
        #expect(types["big_num"] == "VARCHAR")         // Int256 → VARCHAR
        #expect(types["status"] == "VARCHAR")          // Enum8 → VARCHAR
        // 10 rows copied, NULLs preserved (odd tails have maybe_dt NULL).
        let n = try await engine.query("SELECT COUNT(*), COUNT(maybe_dt) FROM \(temp)")
        #expect(n.rows.first?[0] == "10")
        #expect(n.rows.first?[1] == "5")               // half are NULL
    }

    @Test("the key reduction is lossless (subset of keys → exactly those rows)")
    func reductionLossless() async throws {
        let engine = try await makeEngine()
        let temp = try await engine.materializeClickHouse(
            alias: "ch", database: CEnv.db, table: "fleet_meta",
            keyColumn: "tail", keyValues: ["N000SB", "N001SB"])
        defer { Task { await engine.dropTempTable(temp) } }
        let rows = try await engine.query("SELECT tail FROM \(temp) ORDER BY tail")
        #expect(rows.rows.map { $0.first } == ["N000SB", "N001SB"])
    }

    @Test("a pushed-down WHERE is applied inside ClickHouse before the copy")
    func materializeWithWhere() async throws {
        let engine = try await makeEngine()
        let temp = try await engine.materializeClickHouse(
            alias: "ch", database: CEnv.db, table: "fleet_meta",
            keyColumn: nil, keyValues: nil, extraWhere: "(\"status\" = 'active')")
        defer { Task { await engine.dropTempTable(temp) } }
        let rows = try await engine.query("SELECT tail, status FROM \(temp) ORDER BY tail")
        #expect(rows.rows.count == 5)
        #expect(rows.rows.allSatisfy { $0[1] == "active" })
    }

    @Test("ClickHouse as the small side: the MySQL side streams, reduced to the ClickHouse keys")
    func clickHouseProbe() async throws {
        let engine = try await makeEngine()
        let want = try await oracle(engine, select: "e.id, e.tail, f.status", mariaTable: "big_events",
                                    mariaAlias: "e", chAlias: "f", on: "e.tail = f.tail")
        let sql = "SELECT e.id, e.tail, f.status FROM maria.big_events e JOIN ch.fleet_meta f ON e.tail = f.tail"
        let p = try await plan(engine, sql)
        defer { Task { await engine.dropTempTable(p.temp) } }
        // The 200k-row MySQL side comes through its passthrough, reduced to the 10
        // fleet tails, and goes first; the copied ClickHouse side is the hash-table side.
        #expect(p.sql.hasPrefix("SELECT e.id, e.tail, f.status FROM (SELECT * FROM mysql_query('maria', 'SELECT * FROM `\(CEnv.db)`.`big_events` WHERE `tail` IN ("))
        #expect(p.sql.contains(") e JOIN \(p.temp) f ON e.tail = f.tail"))
        let got = try await engine.query(p.sql)
        #expect(got.rows.count == 4000)
        #expect(got.columns == want.columns)
        #expect(sortedRows(got) == sortedRows(want))
    }

    @Test("ClickHouse as the big side: copied reduced to the MySQL side's keys, listed first")
    func clickHouseBig() async throws {
        let engine = try await makeEngine()
        let want = try await oracle(engine, select: "s.*, f.*", mariaTable: "small_fleet",
                                    mariaAlias: "s", chAlias: "f", on: "s.tail = f.tail")
        // Equal row estimates (10 and 10): a tie makes the first table the probe, so
        // the ClickHouse side listed second is the big side here.
        let sql = "SELECT * FROM maria.small_fleet s JOIN ch.fleet_meta f ON s.tail = f.tail"
        let p = try await plan(engine, sql)
        defer { Task { await engine.dropTempTable(p.temp) } }
        #expect(p.sql.hasPrefix("SELECT s.*, f.* FROM \(p.temp) f JOIN (SELECT * FROM mysql_query('maria'"))
        let copied = try await engine.query("SELECT COUNT(*) FROM \(p.temp)")
        #expect(copied.rows.first?.first == "10")      // reduced to small_fleet's 10 tails — all of them
        let got = try await engine.query(p.sql)
        #expect(got.rows.count == 10)
        #expect(got.columns == want.columns)
        #expect(sortedRows(got) == sortedRows(want))
    }

    @Test("the user's WHERE on the ClickHouse side runs in ClickHouse; the comma form is the same join")
    func commaWithClickHouseFilter() async throws {
        let engine = try await makeEngine()
        let want = try await oracle(engine, select: "e.id, e.tail, f.status", mariaTable: "big_events",
                                    mariaAlias: "e", chAlias: "f", on: "e.tail = f.tail", where: "f.status = 'active'")
        let sql = "SELECT e.id, e.tail, f.status FROM maria.big_events e, ch.fleet_meta f WHERE e.tail = f.tail AND f.status = 'active'"
        let p = try await plan(engine, sql)
        defer { Task { await engine.dropTempTable(p.temp) } }
        let copied = try await engine.query("SELECT COUNT(*) FROM \(p.temp)")
        #expect(copied.rows.first?.first == "5")       // only the active tails crossed the wire
        #expect(p.sql.contains("`tail` IN ("))         // and the MySQL side is reduced to those 5
        let got = try await engine.query(p.sql)
        #expect(got.rows.count == 2000)
        #expect(got.columns == want.columns)
        #expect(sortedRows(got) == sortedRows(want))
    }
}
