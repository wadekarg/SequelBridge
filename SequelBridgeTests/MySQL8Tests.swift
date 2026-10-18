//
//  MySQL8Tests.swift
//  SequelBridgeTests
//
//  MySQL 8 announces caching_sha2_password at login. The app's own MySQL client, which
//  runs EXPLAIN and the dumps' SHOW CREATE TABLE, spoke only mysql_native_password, so
//  on MySQL 8 EXPLAIN failed, table dumps fell back to a CREATE TABLE without foreign
//  keys, and the join planner lost the server's row estimates. These run against a real
//  MySQL 8.4 (scripts/run-all-tests.sh starts one on port 3311 with SB_MYSQL8_VERIFY=1);
//  every other MySQL suite also runs a second time against it.
//

import Foundation
import Testing
@testable import SequelBridge

private enum M8Env {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_MYSQL8_VERIFY"] == "1" }
    static var host: String { e["SB_MYSQL8_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_MYSQL8_PORT"] ?? "") ?? 3311 }
    static var pass: String { e["SB_MYSQL8_PASS"] ?? "sbverify123" }
    /// An account kept on mysql_native_password, on a server whose default is caching_sha2_password.
    static var nativeUser: String { e["SB_MYSQL8_NATIVE_USER"] ?? "sbnative" }
    static var nativePass: String { e["SB_MYSQL8_NATIVE_PASS"] ?? "sbnative123" }
}

@MainActor
@Suite("MySQL 8: the app's own client logs in, EXPLAIN and dumps work", .enabled(if: M8Env.enabled), .serialized)
struct MySQL8Tests {

    private func client(user: String = "root", password: String = M8Env.pass, database: String = "sbtest") -> MySQLClient {
        MySQLClient(.init(host: M8Env.host, port: M8Env.port, user: user, password: password,
                          database: database, useTLS: false))
    }

    @Test("caching_sha2_password: the full exchange (RSA over plain TCP), then the cached fast path")
    func cachingSha2() async throws {
        // Empty the server's login cache, so the next login must do the full exchange.
        _ = try await client().query("FLUSH PRIVILEGES")
        let first = client()
        let rows = try await first.query("SELECT 1 + 1")
        #expect(rows.rows.first?.first == "2")
        #expect(first.authPath == .cachingSha2Full)
        let second = client()
        _ = try await second.query("SELECT 1")
        #expect(second.authPath == .cachingSha2Fast)
    }

    @Test("an account on mysql_native_password: the server switches the client to it")
    func authSwitch() async throws {
        let c = client(user: M8Env.nativeUser, password: M8Env.nativePass)
        let rows = try await c.query("SELECT CURRENT_USER()")
        #expect((rows.rows.first?.first ?? nil)?.hasPrefix(M8Env.nativeUser) == true)
        #expect(c.authPath == .nativePassword)
        #expect(c.switchedPlugin)
    }

    @Test("a wrong password is refused with the server's message")
    func wrongPassword() async throws {
        await #expect(throws: MySQLClient.MySQLClientError.self) {
            _ = try await client(password: "not-the-password").query("SELECT 1")
        }
    }

    private func attached() async throws -> QueryEngine {
        let engine = try QueryEngine()
        let c = Connection(name: "m8", alias: "m8", host: M8Env.host, port: M8Env.port,
                           username: "root", database: "sbtest", engine: .mysql)
        try await engine.attach(c, password: M8Env.pass)
        return engine
    }

    @Test("EXPLAIN returns the server's own plan")
    func explain() async throws {
        let engine = try await attached()
        let plan = try await engine.explain(alias: "m8", serverSQL: "SELECT * FROM seed10 WHERE n < 5")
        #expect(plan.columns.contains("select_type"))
        #expect(plan.rowCount >= 1)
        try await engine.detach("m8")
    }

    @Test("a table dump carries the server's CREATE TABLE, foreign keys included")
    func dumpKeepsForeignKeys() async throws {
        let engine = try await attached()
        let dump = try await engine.sqlDump(alias: "m8", database: "sbtest", table: "orders", rowLimit: 5)
        #expect(dump.text.contains("CONSTRAINT `fk_orders_customer` FOREIGN KEY"))
        try await engine.detach("m8")
    }
}
