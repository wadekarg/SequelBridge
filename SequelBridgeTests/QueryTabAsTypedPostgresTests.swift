//
//  QueryTabAsTypedPostgresTests.swift
//  SequelBridgeTests
//
//  A Query-tab statement that returns no rows, on one PostgreSQL server, runs there as
//  typed. Through DuckDB it was refused (SERIAL, RETURNING, to_char, ALTER COLUMN …
//  TYPE, COMMENT ON, GRANT, CREATE FUNCTION, DO, VACUUM) or changed (a VARCHAR(40)
//  column lost its length), and DuckDB's / divides integers as floats where
//  PostgreSQL's doesn't. postgres_execute reports no row count. Skipped without
//  SB_PG_VERIFY.
//

import Foundation
import Testing
@testable import SequelBridge

private struct PGTypedEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_PG_VERIFY"] == "1" }
}

@MainActor
@Suite("Query tab on PostgreSQL: statements run as typed", .enabled(if: PGTypedEnv.enabled), .serialized)
struct QueryTabAsTypedPostgresTests {
    func engine(_ alias: String) async throws -> QueryEngine {
        let e = PGTypedEnv.e
        var c = Connection(name: alias, alias: alias, connectionType: .tcpip, host: e["SB_PG_HOST"] ?? "127.0.0.1",
                           port: Int(e["SB_PG_PORT"] ?? "5433") ?? 5433, username: e["SB_PG_USER"] ?? "sbuser",
                           database: e["SB_PG_DB"] ?? "sbtest")
        c.engine = .postgres
        let q = try QueryEngine()
        try await q.attach(c, password: e["SB_PG_PASS"] ?? "")
        return q
    }

    func value(_ q: QueryEngine, _ alias: String, _ sql: String) async throws -> String? {
        try await q.serverPassthroughQuery(alias: alias, serverSQL: sql).rows.first?.first
    }

    @Test("PostgreSQL's own syntax runs, keeps the types given, and divides as PostgreSQL does")
    func postgresSyntax() async throws {
        let q = try await engine("pt1")
        _ = try await q.runAsTyped(alias: "pt1", sql: "DROP TABLE IF EXISTS public.qt_pg")
        #expect(try await q.runAsTyped(alias: "pt1",
                                       sql: "CREATE TABLE public.qt_pg (id SERIAL PRIMARY KEY, note VARCHAR(40), qty INT, half INT, data JSONB)") == nil,
                "PostgreSQL reports no row count")
        #expect(try await value(q, "pt1", "SELECT character_maximum_length FROM information_schema.columns WHERE table_name = 'qt_pg' AND column_name = 'note'") == "40")
        _ = try await q.runAsTyped(alias: "pt1", sql: "COMMENT ON COLUMN public.qt_pg.note IS 'n'")
        _ = try await q.runAsTyped(alias: "pt1", sql: "INSERT INTO public.qt_pg (note, qty) VALUES ('a', 5) RETURNING id")
        _ = try await q.runAsTyped(alias: "pt1", sql: "UPDATE public.qt_pg SET half = qty / 2, note = to_char(5, 'FM9')")
        #expect(try await value(q, "pt1", "SELECT half || ' ' || note FROM public.qt_pg") == "2 5", "integer division, PostgreSQL's to_char")
        _ = try await q.runAsTyped(alias: "pt1", sql: "ALTER TABLE public.qt_pg ALTER COLUMN note TYPE VARCHAR(80)")
        #expect(try await value(q, "pt1", "SELECT character_maximum_length FROM information_schema.columns WHERE table_name = 'qt_pg' AND column_name = 'note'") == "80")
        _ = try await q.runAsTyped(alias: "pt1", sql: "DROP TABLE public.qt_pg")
    }

    @Test("inside a transaction begun in the Query tab, a write waits for its COMMIT or ROLLBACK")
    func insideATransaction() async throws {
        let q = try await engine("pt2")
        _ = try await q.runAsTyped(alias: "pt2", sql: "DROP TABLE IF EXISTS public.qt_pg_txn")
        _ = try await q.runAsTyped(alias: "pt2", sql: "CREATE TABLE public.qt_pg_txn (id INT PRIMARY KEY, v INT)")
        _ = try await q.runAsTyped(alias: "pt2", sql: "INSERT INTO public.qt_pg_txn VALUES (1, 0)")
        _ = try await q.query("BEGIN TRANSACTION")
        _ = try await q.runAsTyped(alias: "pt2", sql: "UPDATE public.qt_pg_txn SET v = 9 WHERE id = 1")
        _ = try await q.query("ROLLBACK")
        #expect(try await value(q, "pt2", "SELECT v FROM public.qt_pg_txn WHERE id = 1") == "0", "ROLLBACK didn't undo the write")
        _ = try await q.runAsTyped(alias: "pt2", sql: "DROP TABLE public.qt_pg_txn")
    }
}
