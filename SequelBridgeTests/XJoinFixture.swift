//
//  XJoinFixture.swift
//  SequelBridgeTests
//
//  Shared by the real-DB cross-server suites (CrossJoinReductionTests,
//  FallbackMaterializeDBTests, PushdownDBTests). One MariaDB container is attached
//  under two aliases to stand in for two servers — the planner keys off the aliases,
//  not the host. Needs big_events (200k rows, idx_tail) and small_fleet (10 tails ⊂
//  big_events.tail) in the connected database. Gated behind SB_XJOIN_VERIFY=1 (pass
//  TEST_RUNNER_SB_XJOIN_VERIFY=1; Xcode strips the prefix).
//

import Foundation
@testable import SequelBridge

enum XJoinEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_XJOIN_VERIFY"] == "1" }
    static var host: String { e["SB_XJOIN_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_XJOIN_PORT"] ?? "") ?? 3309 }
    static var user: String { e["SB_XJOIN_USER"] ?? "root" }
    static var pass: String { e["SB_XJOIN_PASS"] ?? "sbverify123" }
    static var db:   String { e["SB_XJOIN_DB"] ?? "sbtest" }
}

/// One engine with the same MariaDB attached twice, as `srvA` and `srvB`.
@MainActor
func makeTwoServerEngine() async throws -> QueryEngine {
    let engine = try QueryEngine()
    for alias in ["srvA", "srvB"] {
        let conn = Connection(name: alias, alias: alias, connectionType: .tcpip,
                              host: XJoinEnv.host, port: XJoinEnv.port, username: XJoinEnv.user,
                              database: XJoinEnv.db, engine: .mysql)
        try await engine.attach(conn, password: XJoinEnv.pass)
    }
    return engine
}

/// The local PostgreSQL container (PostgresTests') as a third server: `small_fleet`
/// holds the same 10 tails as MariaDB's, `big_metrics` 100k rows with a `tail`.
/// Needs SB_PG_VERIFY=1 and SB_PG_PASS on top of the MariaDB gate.
enum XJoinPGEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { XJoinEnv.enabled && e["SB_PG_VERIFY"] == "1" && !pass.isEmpty }
    static var host: String { e["SB_PG_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_PG_PORT"] ?? "") ?? 5433 }
    static var user: String { e["SB_PG_USER"] ?? "sbuser" }
    static var pass: String { e["SB_PG_PASS"] ?? "" }
    static var db:   String { e["SB_PG_DB"] ?? "sbtest" }
}

@MainActor
func attachPostgres(_ engine: QueryEngine, alias: String) async throws {
    let conn = Connection(name: alias, alias: alias, connectionType: .tcpip,
                          host: XJoinPGEnv.host, port: XJoinPGEnv.port, username: XJoinPGEnv.user,
                          database: XJoinPGEnv.db, engine: .postgres)
    try await engine.attach(conn, password: XJoinPGEnv.pass)
}

/// A throwaway SQLite file holding `fleet(tail)` with the given tails, attached as
/// `alias` — a local side with no server passthrough. Returns the path to remove.
@MainActor
func attachSQLiteFleet(_ engine: QueryEngine, alias: String, tails: [String]) async throws -> String {
    let path = NSTemporaryDirectory() + "sb-xjoin-\(UUID().uuidString).sqlite"
    guard FileManager.default.createFile(atPath: path, contents: nil) else {   // an empty file is an empty SQLite database
        throw CocoaError(.fileWriteUnknown)
    }
    try await engine.attach(Connection(name: alias, alias: alias, database: path, engine: .sqlite), password: "")
    _ = try await engine.query("CREATE TABLE \(alias).main.fleet (tail VARCHAR)")
    _ = try await engine.query("INSERT INTO \(alias).main.fleet VALUES " + tails.map { "('\($0)')" }.joined(separator: ", "))
    return path
}

/// Rows in a canonical order, so two results can be compared regardless of row order.
func sortedRows(_ r: QueryResult) -> [[String]] {
    r.rows.sorted { a, b in
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }
}
