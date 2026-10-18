//
//  MultiServerTests.swift
//  SequelBridgeTests
//
//  Several servers attached to one workspace at once, including cross-server
//  JOINs — the thing DuckDB's ATTACH model exists to make possible.
//  Needs SB_MYSQL_VERIFY=1 plus a second server in SB_MYSQL_PORT2 (and
//  optionally a third in SB_MYSQL_PORT3).
//

import Foundation
import Testing
@testable import SequelBridge

private struct MEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_MYSQL_VERIFY"] == "1" && e["SB_MYSQL_PORT2"] != nil }
    static var host: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var user: String { e["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { e["SB_MYSQL_PASS"] ?? "" }
    static var db:   String { e["SB_MYSQL_DB"] ?? "sbtest" }
    static var ports: [Int] {
        ["SB_MYSQL_PORT", "SB_MYSQL_PORT2", "SB_MYSQL_PORT3"].compactMap { e[$0].flatMap(Int.init) }
    }
}

@MainActor
@Suite("Multiple servers in one workspace", .enabled(if: MEnv.enabled), .serialized)
struct MultiServerTests {

    /// One engine with every available server attached under its own alias.
    func makeMultiEngine() async throws -> (QueryEngine, [String]) {
        let engine = try QueryEngine()
        var aliases: [String] = []
        for (i, port) in MEnv.ports.enumerated() {
            let alias = "srv\(i + 1)"
            let conn = Connection(name: alias, alias: alias, connectionType: .tcpip,
                                  host: MEnv.host, port: port, username: MEnv.user, database: MEnv.db)
            try await engine.attach(conn, password: MEnv.pass)
            aliases.append(alias)
        }
        return (engine, aliases)
    }

    @Test("several servers attach to one engine simultaneously")
    func multipleAttach() async throws {
        let (engine, aliases) = try await makeMultiEngine()
        #expect(aliases.count >= 2)
        for alias in aliases {
            let tables = try await engine.fetchTables(alias: alias, database: MEnv.db).map(\.name).sorted()
            // Containment, not equality: other suites stage volume-test tables
            // in the same database.
            #expect(Set(["customers", "order_items", "orders"]).isSubset(of: Set(tables)),
                    "alias \(alias) saw \(tables)")
        }
    }

    @Test("each attached server keeps its own catalog")
    func independentCatalogs() async throws {
        let (engine, aliases) = try await makeMultiEngine()
        for alias in aliases {
            let cols = try await engine.fetchColumns(alias: alias, database: MEnv.db, table: "customers")
            #expect(cols.contains { $0.name == "email" })
        }
    }

    @Test("a single query JOINs tables living on different servers")
    func crossServerJoin() async throws {
        let (engine, aliases) = try await makeMultiEngine()
        let a = try #require(aliases.first)
        let b = try #require(aliases.dropFirst().first)

        let left  = SQLBuilder.duckTable(alias: a, database: MEnv.db, table: "customers")
        let right = SQLBuilder.duckTable(alias: b, database: MEnv.db, table: "orders")

        let r = try await engine.query("""
            SELECT c.email, COUNT(o.id) AS order_count
            FROM \(left) AS c
            JOIN \(right) AS o ON o.customer_id = c.id
            GROUP BY c.email
            ORDER BY c.email
            """)
        // Customer 1 has two orders on the other server, customer 2 has one.
        #expect(r.columns == ["email", "order_count"])
        #expect(r.rows.count == 2)
        #expect(r.rows[0][0] == "a@x.com")
        #expect(r.rows[0][1] == "2")
        #expect(r.rows[1][0] == "b@x.com")
        #expect(r.rows[1][1] == "1")
    }

    @Test("a cross-server UNION reads both servers in one pass")
    func crossServerUnion() async throws {
        let (engine, aliases) = try await makeMultiEngine()
        let parts = aliases.map { alias in
            "SELECT '\(alias)' AS src, COUNT(*) AS n FROM \(SQLBuilder.duckTable(alias: alias, database: MEnv.db, table: "customers"))"
        }
        let r = try await engine.query(parts.joined(separator: " UNION ALL ") + " ORDER BY src")
        #expect(r.rows.count == aliases.count)
        for row in r.rows { #expect(row[1] == "3") }
    }

    @Test("detaching one server leaves the others working")
    func detachIsolation() async throws {
        let (engine, aliases) = try await makeMultiEngine()
        let victim = try #require(aliases.last)
        let survivor = try #require(aliases.first)

        try await engine.detach(victim)

        let tables = try await engine.fetchTables(alias: survivor, database: MEnv.db).map(\.name)
        #expect(tables.contains("customers"))

        // The detached alias is gone from the catalog.
        await #expect(throws: (any Error).self) {
            _ = try await engine.query("SELECT COUNT(*) FROM \(SQLBuilder.duckTable(alias: victim, database: MEnv.db, table: "customers"))")
        }
    }
}
