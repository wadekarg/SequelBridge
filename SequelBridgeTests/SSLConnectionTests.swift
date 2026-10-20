//
//  SSLConnectionTests.swift
//  SequelBridgeTests
//
//  The connection form's "Use SSL". It sent DuckDB's MySQL driver `ssl=1`, a key that
//  driver doesn't know, so every MySQL connection with the box ticked failed with
//  "Connection query failed"; PostgreSQL ignored the box; and the app's own MySQL client
//  started TLS before MySQL's plain-text greeting and then waited forever. Now the box
//  makes MySQL and PostgreSQL require SSL, and that client switches to TLS after the
//  greeting, as MySQL asks: EXPLAIN, the server's CREATE TABLE and Table Maintenance
//  work on an SSL connection.
//  Runs against MySQL 8.4 (offers TLS), MariaDB 10.0 and PostgreSQL 16 (neither does);
//  scripts/run-all-tests.sh sets SB_SSL_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private enum SSLEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_SSL_VERIFY"] == "1" }
    static var tlsPort: Int { Int(e["SB_SSL_TLS_PORT"] ?? "") ?? 3311 }       // MySQL 8.4
    static var plainPort: Int { Int(e["SB_SSL_PLAIN_PORT"] ?? "") ?? 3309 }   // MariaDB 10.0, no TLS
    static var mysqlPass: String { e["SB_MYSQL_PASS"] ?? "sbverify123" }
    static var pgPort: Int { Int(e["SB_PG_PORT"] ?? "") ?? 5433 }
    static var pgUser: String { e["SB_PG_USER"] ?? "sbuser" }
    static var pgPass: String { e["SB_PG_PASS"] ?? "sbpass123" }
    static var pgDB: String { e["SB_PG_DB"] ?? "sbtest" }
}

@MainActor
@Suite("Use SSL", .enabled(if: SSLEnv.enabled), .serialized)
struct SSLConnectionTests {

    private func mysql(_ port: Int) -> Connection {
        Connection(name: "s", alias: "s", host: "127.0.0.1", port: port, username: "root",
                   database: "sbtest", useSSL: true, engine: .mysql)
    }

    @Test("MySQL with Use SSL connects, and the session is encrypted")
    func mysqlEncrypted() async throws {
        let engine = try QueryEngine()
        try await engine.attach(mysql(SSLEnv.tlsPort), password: SSLEnv.mysqlPass)
        let r = try await engine.serverPassthroughQuery(alias: "s", serverSQL: "SHOW SESSION STATUS LIKE 'Ssl_cipher'")
        let cipher = r.rows.first?.last ?? ""
        #expect(cipher.hasPrefix("TLS"), "Ssl_cipher: \(r.rows)")
        try await engine.detach("s")
    }

    @Test("MySQL with Use SSL on a server without SSL is refused, and says so")
    func mysqlWithoutTLS() async throws {
        let engine = try QueryEngine()
        do {
            try await engine.attach(mysql(SSLEnv.plainPort), password: SSLEnv.mysqlPass)
            Issue.record("it connected without SSL")
        } catch {
            let reason = QueryEngine.extractReason(from: error)
            #expect(reason.localizedCaseInsensitiveContains("SSL"), "got: \(reason)")
            #expect(!reason.contains(SSLEnv.mysqlPass), "the password is in the message")
        }
    }

    @Test("PostgreSQL with Use SSL on a server without SSL is refused, and says so")
    func postgresWithoutTLS() async throws {
        let engine = try QueryEngine()
        let c = Connection(name: "p", alias: "p", host: "127.0.0.1", port: SSLEnv.pgPort, username: SSLEnv.pgUser,
                           database: SSLEnv.pgDB, useSSL: true, engine: .postgres)
        do {
            try await engine.attach(c, password: SSLEnv.pgPass)
            Issue.record("it connected without SSL")
        } catch {
            let reason = QueryEngine.extractReason(from: error)
            #expect(reason.localizedCaseInsensitiveContains("SSL"), "got: \(reason)")
            #expect(!reason.contains(SSLEnv.pgPass), "the password is in the message")
        }
    }

    @Test("EXPLAIN on an SSL connection runs, over SSL")
    func explainOnSSL() async throws {
        let engine = try QueryEngine()
        try await engine.attach(mysql(SSLEnv.tlsPort), password: SSLEnv.mysqlPass)
        let outcome = try #require(await finishes(within: 20) {
            try await engine.explain(alias: "s", serverSQL: "SELECT * FROM orders WHERE id = 1")
        }, "EXPLAIN was still waiting after 20 seconds")
        let plan = try outcome.get()
        #expect(plan.columns.contains("select_type"), "got: \(plan.columns)")
        try await engine.detach("s")
    }

    @Test("the app's own MySQL client encrypts its session on an SSL connection")
    func nativeClientEncrypted() async throws {
        let client = MySQLClient(.init(host: "127.0.0.1", port: SSLEnv.tlsPort, user: "root",
                                       password: SSLEnv.mysqlPass, database: "sbtest", useTLS: true))
        let r = try await client.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
        let cipher = r.rows.first?.last ?? nil
        #expect(cipher?.hasPrefix("TLS") == true, "Ssl_cipher: \(r.rows)")
    }

    @Test("the app's own MySQL client refuses a server without SSL, and says so")
    func nativeClientWithoutTLS() async throws {
        let client = MySQLClient(.init(host: "127.0.0.1", port: SSLEnv.plainPort, user: "root",
                                       password: SSLEnv.mysqlPass, database: "sbtest", useTLS: true))
        do {
            _ = try await client.query("SELECT 1")
            Issue.record("it ran without SSL")
        } catch {
            let reason = "\(error)"
            #expect(reason.localizedCaseInsensitiveContains("SSL"), "got: \(reason)")
            #expect(!reason.contains(SSLEnv.mysqlPass), "the password is in the message")
        }
    }

    @Test("a dump on an SSL connection carries the server's own CREATE TABLE, foreign keys included")
    func dumpOnSSL() async throws {
        let engine = try QueryEngine()
        try await engine.attach(mysql(SSLEnv.tlsPort), password: SSLEnv.mysqlPass)
        let outcome = try #require(await finishes(within: 30) {
            try await engine.sqlDump(alias: "s", database: "sbtest", table: "orders", rowLimit: 3)
        }, "the dump was still running after 30 seconds")
        let dump = try outcome.get()
        #expect(dump.text.contains("CONSTRAINT `fk_orders_customer` FOREIGN KEY"), "got: \(dump.text.prefix(600))")
        #expect(!dump.text.contains("rebuilt"), "got: \(dump.text.prefix(400))")
        try await engine.detach("s")
    }

    @Test("Table Maintenance on an SSL connection reads the server's answer")
    func maintenanceOnSSL() async throws {
        let engine = try QueryEngine()
        try await engine.attach(mysql(SSLEnv.tlsPort), password: SSLEnv.mysqlPass)
        let outcome = try #require(await finishes(within: 20) {
            try await engine.tableMaintenance(.check, alias: "s", database: "sbtest", table: "orders")
        }, "CHECK TABLE was still waiting after 20 seconds")
        #expect(try outcome.get() == "status: OK")
        try await engine.detach("s")
    }
}
