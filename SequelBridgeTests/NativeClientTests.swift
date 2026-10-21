//
//  NativeClientTests.swift
//  SequelBridgeTests
//
//  The statements the passthrough can't run, on the app's own client for the server. On
//  MySQL, mysql_query prepares every statement, and MySQL can't prepare SHOW CREATE
//  TABLE, SHOW PROCESSLIST, SHOW GRANTS, SHOW WARNINGS, HELP or CHECK TABLE: typed in the
//  Query tab, they failed. On PostgreSQL, postgres_query nests every statement as a
//  subquery, where PostgreSQL takes neither SHOW nor EXPLAIN: the Explain button failed,
//  and so did a typed SHOW. Then PostgreSQL's own client: its logins and SSL.
//

import Foundation
import Testing
@testable import SequelBridge

private enum NativeEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static func value(_ key: String, _ fallback: String) -> String { e[key] ?? fallback }
}

@Suite("Which typed statements go to the app's own client")
struct NativeRoutingTests {
    @Test("on MySQL: SHOW, HELP, CHECK and CHECKSUM", arguments: [
        "SHOW CREATE TABLE t", "show processlist", "  SHOW GRANTS", "HELP 'select'", "CHECK TABLE t",
        "CHECKSUM TABLE t", "-- note\nSHOW WARNINGS",
    ])
    func mysql(_ sql: String) {
        #expect(QueryEffects.runsOnNativeClient(sql, engine: .mysql))
    }

    @Test("on PostgreSQL: SHOW and EXPLAIN", arguments: ["SHOW search_path", "show all", "EXPLAIN SELECT 1"])
    func postgres(_ sql: String) {
        #expect(QueryEffects.runsOnNativeClient(sql, engine: .postgres))
    }

    @Test("everything else keeps its route")
    func others() {
        #expect(!QueryEffects.runsOnNativeClient("SELECT 1", engine: .mysql))
        #expect(!QueryEffects.runsOnNativeClient("DESCRIBE t", engine: .mysql))
        #expect(!QueryEffects.runsOnNativeClient("UPDATE t SET a = 1", engine: .mysql))
        #expect(!QueryEffects.runsOnNativeClient("SELECT 1", engine: .postgres))
        #expect(!QueryEffects.runsOnNativeClient("CHECK TABLE t", engine: .postgres))
        #expect(!QueryEffects.runsOnNativeClient("SHOW TABLES", engine: .sqlite))
        #expect(!QueryEffects.runsOnNativeClient("SHOW TABLES", engine: .clickhouse))
    }
}

@Suite("PostgreSQL's own client: its logins and messages")
struct PostgresLoginTests {
    @Test("MD5: the md5 of the password and user, then of that and the salt")
    func md5() {
        #expect(PostgresClient.md5Password(user: "postgres", password: "secret", salt: Data([1, 2, 3, 4]))
                == "md5bb41a296aab6baccb36ff243a562abff")
    }

    @Test("SCRAM-SHA-256: RFC 7677's own example, and a server that can't prove the password")
    func scram() throws {
        var s = PostgresClient.SCRAM(user: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        #expect(s.clientFirst == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let final = try s.clientFinal("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(final == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try s.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
        #expect(throws: (any Error).self) { try s.verify("v=AAAA") }
        #expect(throws: (any Error).self) { try s.clientFinal("r=someone-else,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096") }
    }

    @Test("a server's error is its message")
    func error() {
        let fields = Data("SERROR\u{0}C42P01\u{0}Mrelation \"nope\" does not exist\u{0}\u{0}".utf8)
        #expect(PostgresClient.errorMessage(fields) == "relation \"nope\" does not exist")
    }
}

@MainActor
@Suite("PostgreSQL's own client (real server)", .enabled(if: NativeEnv.e["SB_PG_VERIFY"] == "1"), .serialized)
struct PostgresNativeTests {
    func engine(_ alias: String, readOnly: Bool = false, port: Int? = nil, ssl: Bool = false,
                socket: String? = nil) async throws -> QueryEngine {
        let e = try QueryEngine()
        var c = Connection(name: "PG \(alias)", alias: alias, connectionType: socket == nil ? .tcpip : .socket,
                           host: NativeEnv.value("SB_PG_HOST", "127.0.0.1"),
                           port: port ?? Int(NativeEnv.value("SB_PG_PORT", "5433")) ?? 5433,
                           username: NativeEnv.value("SB_PG_USER", "sbuser"),
                           database: NativeEnv.value("SB_PG_DB", "sbtest"))
        c.engine = .postgres
        c.readOnly = readOnly
        c.useSSL = ssl
        if let socket { c.socketPath = socket }
        try await e.attach(c, password: NativeEnv.value("SB_PG_PASS", ""))
        return e
    }

    @Test("the Explain button's plan comes back")
    func explain() async throws {
        let e = try await engine("pn1")
        let plan = try await e.explain(alias: "pn1", serverSQL: "SELECT * FROM customers WHERE id = 1")
        #expect(plan.columns == ["QUERY PLAN"])
        #expect(plan.rows.contains { $0.first?.contains("customers") == true }, "\(plan.rows)")
    }

    /// The encrypted link waited 10 seconds for any reply, the connect timeout reused: a
    /// statement that ran longer (EXPLAIN ANALYZE, an UPDATE of many rows) failed.
    @Test("a statement that runs longer than the 10 seconds a connect may take still comes back")
    func longStatement() async throws {
        let e = try await engine("pn9")
        let r = try await e.nativeQuery(alias: "pn9", sql: "SELECT 'slept' FROM pg_sleep(11)", database: nil)
        #expect(r.rows == [["slept"]])
    }

    @Test("Cancel ends a statement on the app's own client at once")
    func cancel() async throws {
        let e = try await engine("pn10")
        let started = Date()
        let run = Task { try await e.nativeQuery(alias: "pn10", sql: "SELECT pg_sleep(30)", database: nil) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        run.cancel()
        let outcome = await run.result
        #expect(Date().timeIntervalSince(started) < 5, "it ran \(Date().timeIntervalSince(started)) s")
        if case .success = outcome { Issue.record("a cancelled statement ran to the end") }
    }

    /// The schema picked was set as the whole search_path, so a function or extension in
    /// public (or Supabase's extensions schema) stopped resolving there.
    @Test("in a schema picked, the role's own search_path still applies after it")
    func searchPathKeepsTheRest() async throws {
        let e = try await engine("pn11")
        try await e.executeDDL(alias: "pn11", sql: "CREATE SCHEMA IF NOT EXISTS sbsp")
        try await e.executeDDL(alias: "pn11", sql: "CREATE OR REPLACE FUNCTION public.sb_pubfn() RETURNS int LANGUAGE sql AS 'SELECT 7'")
        #expect(try await e.nativeQuery(alias: "pn11", sql: "SELECT sb_pubfn()", database: "sbsp").rows == [["7"]])
        // "sbsp", "$user", public: the schema picked first (quoted, as a name is), then the rest.
        let path = try await e.nativeQuery(alias: "pn11", sql: "SHOW search_path", database: "sbsp").rows.first?.first ?? ""
        let first = path.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        #expect(first == "sbsp" && path.contains("public"), "\(path)")
        try await e.executeDDL(alias: "pn11", sql: "DROP SCHEMA sbsp CASCADE")
    }

    /// A role whose own search_path is empty (a hardened setup): the schema picked comes
    /// first all the same (PostgreSQL writes the empty path as "", not as nothing), and a
    /// table in it reads by its bare name.
    @Test("a schema picked works for a role whose own search_path is empty")
    func emptySearchPath() async throws {
        let admin = try await engine("pn14")
        try await admin.executeDDL(alias: "pn14", sql: "DROP ROLE IF EXISTS sb_nopath")
        try await admin.executeDDL(alias: "pn14", sql: "CREATE ROLE sb_nopath LOGIN PASSWORD 'sbnopath123'")
        try await admin.executeDDL(alias: "pn14", sql: "ALTER ROLE sb_nopath SET search_path = ''")
        try await admin.executeDDL(alias: "pn14", sql: "CREATE SCHEMA IF NOT EXISTS sbnp")
        try await admin.executeDDL(alias: "pn14", sql: "GRANT USAGE ON SCHEMA sbnp TO sb_nopath")
        try await admin.executeDDL(alias: "pn14", sql: "CREATE TABLE sbnp.t (i int)")
        try await admin.executeDDL(alias: "pn14", sql: "GRANT SELECT ON sbnp.t TO sb_nopath")
        let e = try QueryEngine()
        var c = Connection(name: "PG pn15", alias: "pn15", host: NativeEnv.value("SB_PG_HOST", "127.0.0.1"),
                           port: Int(NativeEnv.value("SB_PG_PORT", "5433")) ?? 5433, username: "sb_nopath",
                           database: NativeEnv.value("SB_PG_DB", "sbtest"))
        c.engine = .postgres
        try await e.attach(c, password: "sbnopath123")
        let path = try await e.nativeQuery(alias: "pn15", sql: "SHOW search_path", database: "sbnp").rows.first?.first ?? ""
        let first = path.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        #expect(first == "sbnp", "\(path)")
        #expect(try await e.nativeQuery(alias: "pn15", sql: "SELECT count(*) FROM t", database: "sbnp").rows == [["0"]])
        try? await e.detach("pn15")
        try await admin.executeDDL(alias: "pn14", sql: "DROP SCHEMA sbnp CASCADE")
        try await admin.executeDDL(alias: "pn14", sql: "DROP ROLE sb_nopath")
    }

    @Test("an error names no statement number for a single statement")
    func singleStatementError() async throws {
        let e = try await engine("pn12")
        do {
            _ = try await e.nativeQuery(alias: "pn12", sql: "SELEC 1", database: "public")
            Issue.record("a syntax error ran")
        } catch {
            let reason = QueryEngine.extractReason(from: error)
            #expect(reason.contains("syntax") && !reason.contains("Statement"), "\(reason)")
        }
    }

    /// COPY … FROM STDIN waited for data the app never sends: the statement hung until
    /// Cancel. COPY … TO STDOUT said Done and showed nothing.
    @Test("COPY TO STDOUT shows its rows; COPY FROM STDIN fails at once, saying what to use")
    func copy() async throws {
        let e = try await engine("pn13")
        let out = try await e.nativeQuery(alias: "pn13", sql: "COPY (SELECT 1 AS a UNION ALL SELECT 2) TO STDOUT", database: nil)
        #expect(out.rows == [["1"], ["2"]])
        let started = Date()
        let run = Task { try await e.nativeQuery(alias: "pn13", sql: "COPY customers FROM STDIN", database: nil) }
        var finished = false
        Task { _ = await run.result; finished = true }
        for _ in 0..<50 where !finished { try await Task.sleep(nanoseconds: 100_000_000) }
        run.cancel()
        let outcome = await run.result
        #expect(Date().timeIntervalSince(started) < 5, "COPY FROM STDIN hung")
        if case .failure(let error) = outcome {
            #expect(QueryEngine.extractReason(from: error).contains("Import CSV"), "\(QueryEngine.extractReason(from: error))")
        } else { Issue.record("COPY FROM STDIN ran") }
    }

    @Test("a typed SHOW runs, in the schema picked")
    func show() async throws {
        let e = try await engine("pn2")
        #expect(try await e.nativeQuery(alias: "pn2", sql: "SHOW search_path", database: "public").rows.first?.first?.contains("public") == true)
        #expect(try await e.nativeQuery(alias: "pn2", sql: "SHOW server_version", database: nil).rows.count == 1)
    }

    @Test("a server error comes back as PostgreSQL's message")
    func serverError() async throws {
        let e = try await engine("pn3")
        var reason = ""
        do { _ = try await e.nativeQuery(alias: "pn3", sql: "SHOW no_such_setting", database: nil) }
        catch { reason = QueryEngine.extractReason(from: error) }
        #expect(reason.contains("no_such_setting"), "\(reason)")
    }

    @Test("a read-only connection's session is read-only on the server")
    func readOnly() async throws {
        let e = try await engine("pn4", readOnly: true)
        #expect(try await e.nativeQuery(alias: "pn4", sql: "SHOW default_transaction_read_only", database: nil).rows == [["on"]])
    }

    @Test("over a Unix socket", .enabled(if: NativeEnv.e["SB_PG_SOCKET_DIR"] != nil))
    func socket() async throws {
        let e = try await engine("pn5", socket: NativeEnv.e["SB_PG_SOCKET_DIR"])
        #expect(try await e.explain(alias: "pn5", serverSQL: "SELECT 1").rows.isEmpty == false)
    }
}

@MainActor
@Suite("PostgreSQL's own client over SSL (real server)", .enabled(if: NativeEnv.e["SB_PG_SSL_PORT"] != nil), .serialized)
struct PostgresNativeSSLTests {
    var sslPort: Int { Int(NativeEnv.value("SB_PG_SSL_PORT", "5434")) ?? 5434 }
    var plainPort: Int { Int(NativeEnv.value("SB_PG_PORT", "5433")) ?? 5433 }
    let encrypted = "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"

    @Test("Use SSL: the session is encrypted and Explain works")
    func required() async throws {
        let e = try await PostgresNativeTests().engine("ps1", port: sslPort, ssl: true)
        #expect(try await e.nativeQuery(alias: "ps1", sql: encrypted, database: nil).rows == [["t"]])
        #expect(try await e.explain(alias: "ps1", serverSQL: "SELECT 1").rows.isEmpty == false)
    }

    @Test("without Use SSL, TLS is used when the server offers it, as libpq does")
    func preferred() async throws {
        let e = try await PostgresNativeTests().engine("ps2", port: sslPort)
        #expect(try await e.nativeQuery(alias: "ps2", sql: encrypted, database: nil).rows == [["t"]])
    }

    @Test("Use SSL against a server without SSL is refused, and no password is sent")
    func refused() async throws {
        let client = PostgresClient(.init(host: NativeEnv.value("SB_PG_HOST", "127.0.0.1"), port: plainPort,
                                          user: NativeEnv.value("SB_PG_USER", "sbuser"),
                                          password: NativeEnv.value("SB_PG_PASS", ""),
                                          database: NativeEnv.value("SB_PG_DB", "sbtest"), useTLS: true))
        var reason = ""
        do { _ = try await client.query("SELECT 1") } catch { reason = QueryEngine.extractReason(from: error) }
        #expect(reason == PostgresClient.sslMissing, "\(reason)")
    }
}

@MainActor
@Suite("Typed statements MySQL can't prepare, on its own client (real server)",
       .enabled(if: NativeEnv.e["SB_MYSQL_VERIFY"] == "1"), .serialized)
struct MySQLNativeStatementTests {
    func engine(_ alias: String) async throws -> QueryEngine {
        let e = try QueryEngine()
        let c = Connection(name: "MySQL \(alias)", alias: alias, connectionType: .tcpip,
                           host: NativeEnv.value("SB_MYSQL_HOST", "127.0.0.1"),
                           port: Int(NativeEnv.value("SB_MYSQL_PORT", "3307")) ?? 3307,
                           username: NativeEnv.value("SB_MYSQL_USER", "sbuser"),
                           database: NativeEnv.value("SB_MYSQL_DB", "sbtest"), engine: .mysql)
        try await e.attach(c, password: NativeEnv.value("SB_MYSQL_PASS", ""))
        return e
    }

    @Test("SHOW CREATE TABLE, SHOW PROCESSLIST, SHOW GRANTS, SHOW WARNINGS, CHECK and CHECKSUM TABLE return their rows")
    func unpreparable() async throws {
        let e = try await engine("mn1")
        for (sql, column) in [("SHOW CREATE TABLE customers", "Create Table"), ("SHOW FULL PROCESSLIST", "Id"),
                              ("SHOW WARNINGS", "Level"), ("CHECK TABLE customers", "Msg_text"),
                              ("CHECKSUM TABLE customers", "Checksum")] {
            #expect(QueryEffects.runsOnNativeClient(sql, engine: .mysql), "\(sql)")
            let r = try await e.nativeQuery(alias: "mn1", sql: sql, database: nil)
            #expect(r.columns.contains(column), "\(sql): \(r.columns)")
        }
        #expect(try await e.nativeQuery(alias: "mn1", sql: "SHOW GRANTS", database: nil).rows.isEmpty == false)
    }

    @Test("in the database picked at the top of the left panel")
    func pickedDatabase() async throws {
        let e = try await engine("mn2")
        let write = NativeEnv.value("SB_MYSQL_WRITE_DB", "sbwrite")
        #expect(try await e.nativeQuery(alias: "mn2", sql: "SHOW TABLES", database: write).columns == ["Tables_in_\(write)"])
    }
}
