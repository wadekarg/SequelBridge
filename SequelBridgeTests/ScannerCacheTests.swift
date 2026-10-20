//
//  ScannerCacheTests.swift
//  SequelBridgeTests
//
//  DuckDB's scanners keep a copy of the server's tables, and a Content edit runs through
//  DuckDB. Found by the PostgreSQL click-through test: a table made in the Query tab
//  couldn't be edited ("Catalog Error: Table … does not exist") until a reconnect. After
//  a statement on MySQL the app drops that copy; on PostgreSQL it didn't, and on either a
//  table made by another tool stayed unknown to DuckDB however often the list refreshed.
//

import Foundation
import Testing
@testable import SequelBridge

private enum CacheEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static func value(_ key: String, _ fallback: String) -> String { e[key] ?? fallback }
}

@MainActor
@Suite("Scanner cache: PostgreSQL (real server)", .enabled(if: CacheEnv.e["SB_PG_VERIFY"] == "1"), .serialized)
struct PostgresScannerCacheTests {
    func engine(_ alias: String) async throws -> QueryEngine {
        let e = try QueryEngine()
        var c = Connection(name: "PG \(alias)", alias: alias, connectionType: .tcpip,
                           host: CacheEnv.value("SB_PG_HOST", "127.0.0.1"),
                           port: Int(CacheEnv.value("SB_PG_PORT", "5433")) ?? 5433,
                           username: CacheEnv.value("SB_PG_USER", "sbuser"),
                           database: CacheEnv.value("SB_PG_DB", "sbtest"))
        c.engine = .postgres
        try await e.attach(c, password: CacheEnv.value("SB_PG_PASS", ""))
        return e
    }

    func note(_ e: QueryEngine, _ alias: String, _ table: String) async throws -> [[String]] {
        try await e.query("SELECT * FROM postgres_query('\(alias)', 'SELECT note FROM sbcache.\(table) WHERE id = 1')").rows
    }

    @Test("a table made in the app is edited at once")
    func madeInTheApp() async throws {
        let e = try await engine("pc1")
        _ = try await e.query(#"SELECT count(*) FROM "pc1"."public"."customers""#)   // DuckDB has read the catalog
        for sql in ["DROP SCHEMA IF EXISTS sbcache CASCADE", "CREATE SCHEMA sbcache",
                    "CREATE TABLE sbcache.made_here (id int PRIMARY KEY, note text)", "INSERT INTO sbcache.made_here VALUES (1, 'before')"] {
            try await e.executeDDL(alias: "pc1", sql: sql)
        }
        try await e.executeWrite(SQLBuilder.update(alias: "pc1", database: "sbcache", table: "made_here", column: "note",
                                                   newValue: "after", primaryKey: [(column: "id", value: "1")]), alias: "pc1")
        #expect(try await note(e, "pc1", "made_here") == [["after"]])
        try await e.executeDDL(alias: "pc1", sql: "DROP SCHEMA sbcache CASCADE")
    }

    @Test("a table another tool made is edited once the app lists it")
    func madeElsewhere() async throws {
        let e = try await engine("pc2")
        try await e.executeDDL(alias: "pc2", sql: "DROP SCHEMA IF EXISTS sbcache CASCADE")
        try await e.executeDDL(alias: "pc2", sql: "CREATE SCHEMA sbcache")
        try await e.executeDDL(alias: "pc2", sql: "CREATE TABLE sbcache.first (id int PRIMARY KEY)")
        _ = try await e.query(#"SELECT count(*) FROM "pc2"."sbcache"."first""#)      // DuckDB has read sbcache's tables
        let other = try await engine("pc2other")
        try await other.executeDDL(alias: "pc2other", sql: "CREATE TABLE sbcache.made_elsewhere (id int PRIMARY KEY, note text)")
        try await other.executeDDL(alias: "pc2other", sql: "INSERT INTO sbcache.made_elsewhere VALUES (1, 'before')")
        #expect(try await e.fetchTables(alias: "pc2", database: "sbcache").map(\.name).contains("made_elsewhere"))
        try await e.executeWrite(SQLBuilder.update(alias: "pc2", database: "sbcache", table: "made_elsewhere", column: "note",
                                                   newValue: "after", primaryKey: [(column: "id", value: "1")]), alias: "pc2")
        #expect(try await note(e, "pc2", "made_elsewhere") == [["after"]])
        try await e.executeDDL(alias: "pc2", sql: "DROP SCHEMA sbcache CASCADE")
    }
}

@MainActor
@Suite("Scanner cache: MySQL (real server)", .enabled(if: CacheEnv.e["SB_MYSQL_VERIFY"] == "1"), .serialized)
struct MySQLScannerCacheTests {
    var db: String { CacheEnv.value("SB_MYSQL_WRITE_DB", "sbwrite") }

    func engine(_ alias: String) async throws -> QueryEngine {
        let e = try QueryEngine()
        let c = Connection(name: "MySQL \(alias)", alias: alias, connectionType: .tcpip,
                           host: CacheEnv.value("SB_MYSQL_HOST", "127.0.0.1"),
                           port: Int(CacheEnv.value("SB_MYSQL_PORT", "3307")) ?? 3307,
                           username: CacheEnv.value("SB_MYSQL_USER", "sbuser"), database: db, engine: .mysql)
        try await e.attach(c, password: CacheEnv.value("SB_MYSQL_PASS", ""))
        return e
    }

    @Test("a table another tool made is edited once the app lists it")
    func madeElsewhere() async throws {
        let e = try await engine("mc1")
        let t = SQLBuilder.mysqlTable(database: db, table: "cache_elsewhere")
        try await e.mysqlExecute(alias: "mc1", sql: "DROP TABLE IF EXISTS \(t)")
        try await e.mysqlExecute(alias: "mc1", sql: "CREATE TABLE IF NOT EXISTS \(SQLBuilder.mysqlTable(database: db, table: "cache_first")) (id INT PRIMARY KEY)")
        _ = try await e.query(#"SELECT count(*) FROM "mc1"."\#(db)"."cache_first""#)   // DuckDB has read the database's tables
        let other = try await engine("mc1other")
        try await other.mysqlExecute(alias: "mc1other", sql: "CREATE TABLE \(t) (id INT PRIMARY KEY, note VARCHAR(20))")
        try await other.mysqlExecute(alias: "mc1other", sql: "INSERT INTO \(t) VALUES (1, 'before')")
        #expect(try await e.fetchTables(alias: "mc1", database: db).map(\.name).contains("cache_elsewhere"))
        try await e.executeWrite(SQLBuilder.update(alias: "mc1", database: db, table: "cache_elsewhere", column: "note",
                                                   newValue: "after", primaryKey: [(column: "id", value: "1")]), alias: "mc1")
        #expect(try await e.nativeMySQLQuery(alias: "mc1", sql: "SELECT note FROM \(t) WHERE id = 1").rows == [["after"]])
        try await e.mysqlExecute(alias: "mc1", sql: "DROP TABLE IF EXISTS \(t)")
    }
}
