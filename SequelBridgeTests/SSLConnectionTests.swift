//
//  SSLConnectionTests.swift
//  SequelBridgeTests
//
//  The connection form's "Use SSL". It sent DuckDB's MySQL driver `ssl=1`, a key that
//  driver doesn't know, so every MySQL connection with the box ticked failed with
//  "Connection query failed"; PostgreSQL ignored the box; and the app's own MySQL client
//  started TLS before MySQL's plain-text greeting and then waited forever. Now the box
//  makes MySQL and PostgreSQL require SSL, and that client says it can't use SSL yet.
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

    @Test("EXPLAIN on an SSL connection says the built-in client can't use SSL yet, at once")
    func explainOnSSL() async throws {
        let engine = try QueryEngine()
        try await engine.attach(mysql(SSLEnv.tlsPort), password: SSLEnv.mysqlPass)
        let outcome = try #require(await finishes(within: 10) { try await engine.explain(alias: "s", serverSQL: "SELECT 1") },
                                   "EXPLAIN was still waiting after 10 seconds")
        guard case .failure(let error) = outcome else { Issue.record("EXPLAIN ran without SSL"); return }
        #expect(QueryEngine.extractReason(from: error).contains("SSL"), "got: \(error)")
        try await engine.detach("s")
    }

    @Test("a dump on an SSL connection says its CREATE TABLE was rebuilt without foreign keys")
    func dumpOnSSL() async throws {
        let engine = try QueryEngine()
        try await engine.attach(mysql(SSLEnv.tlsPort), password: SSLEnv.mysqlPass)
        let outcome = try #require(await finishes(within: 30) {
            try await engine.sqlDump(alias: "s", database: "sbtest", table: "orders", rowLimit: 3)
        }, "the dump was still running after 30 seconds")
        let dump = try outcome.get()
        #expect(dump.text.contains("-- The server's own CREATE TABLE"), "got: \(dump.text.prefix(400))")
        #expect(dump.text.contains("CREATE TABLE"))
        #expect(!dump.text.contains("FOREIGN KEY"))
        try await engine.detach("s")
    }
}
