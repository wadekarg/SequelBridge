//
//  QueryEngineDDLTests.swift
//  SequelBridgeTests
//
//  Covers QueryEngine.mysqlExecute — the route DDL must take, because DuckDB
//  cannot parse MySQL DDL and the mysql_query() table function turns it into a
//  fatal error that invalidates the connection.
//  Skipped unless SB_MYSQL_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private struct DEnv {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { ProcessInfo.processInfo.environment["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(ProcessInfo.processInfo.environment["SB_MYSQL_PORT"] ?? "3307") ?? 3307 }
    static var user: String { ProcessInfo.processInfo.environment["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { ProcessInfo.processInfo.environment["SB_MYSQL_PASS"] ?? "" }
    static var db:   String { ProcessInfo.processInfo.environment["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
}

@MainActor
@Suite("QueryEngine.mysqlExecute", .enabled(if: DEnv.enabled), .serialized)
struct QueryEngineDDLTests {

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        let conn = Connection(name: "ddl", alias: alias, connectionType: .tcpip,
                              host: DEnv.host, port: DEnv.port, username: DEnv.user, database: DEnv.db)
        try await engine.attach(conn, password: DEnv.pass)
        return engine
    }

    @Test("runs CREATE TABLE / DROP TABLE against the server")
    func createsAndDropsTable() async throws {
        let alias = "ddl1"
        let engine = try await makeEngine(alias)
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: DEnv.db, table: "d_create"))")
        try await engine.mysqlExecute(alias: alias, sql: """
            CREATE TABLE \(SQLBuilder.mysqlTable(database: DEnv.db, table: "d_create")) \
            (`id` INT NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB
            """)

        let cols = try await engine.fetchColumns(alias: alias, database: DEnv.db, table: "d_create")
        #expect(cols.map(\.name) == ["id"])

        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: DEnv.db, table: "d_create"))")
        // Once dropped, the metadata lookup fails at the server rather than returning rows.
        let after = try? await engine.fetchColumns(alias: alias, database: DEnv.db, table: "d_create")
        #expect(after?.isEmpty ?? true)
    }

    @Test("the engine stays usable after a successful DDL statement")
    func engineSurvivesDDL() async throws {
        let alias = "ddl2"
        let engine = try await makeEngine(alias)
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: DEnv.db, table: "d_survive"))")
        let r = try await engine.query("SELECT 1 AS ok")
        #expect(r.rows.first?.first == "1")
    }

    @Test("a rejected statement throws but leaves the engine usable")
    func engineSurvivesBadDDL() async throws {
        let alias = "ddl3"
        let engine = try await makeEngine(alias)

        await #expect(throws: (any Error).self) {
            try await engine.mysqlExecute(alias: alias, sql: "ALTER TABLE `\(DEnv.db)`.`no_such_table_here` DROP COLUMN `nope`")
        }

        // The critical property: one bad statement must not brick the session.
        let r = try await engine.query("SELECT 2 AS ok")
        #expect(r.rows.first?.first == "2")
    }

    @Test("single quotes inside the statement survive the round trip")
    func quoteEscaping() async throws {
        let alias = "ddl4"
        let engine = try await makeEngine(alias)
        let tbl = SQLBuilder.mysqlTable(database: DEnv.db, table: "d_quote")
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(tbl)")
        try await engine.mysqlExecute(alias: alias, sql: """
            CREATE TABLE \(tbl) (`id` INT NOT NULL, `note` VARCHAR(50) DEFAULT 'it''s fine', PRIMARY KEY (`id`)) ENGINE=InnoDB
            """)
        let cols = try await engine.fetchColumns(alias: alias, database: DEnv.db, table: "d_quote")
        #expect(cols.count == 2)
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(tbl)")
    }
}

@MainActor
@Suite("Whole-database SQL dump (real DB)", .enabled(if: DEnv.enabled), .serialized)
struct DatabaseDumpTests {
    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        let conn = Connection(name: "dump", alias: alias, connectionType: .tcpip,
                              host: DEnv.host, port: DEnv.port, username: DEnv.user, database: DEnv.db)
        try await engine.attach(conn, password: DEnv.pass)
        return engine
    }

    @Test("dumps every table in the database with CREATE + INSERTs")
    func dumpsAllTables() async throws {
        let alias = "dumpdb"
        let engine = try await makeEngine(alias)
        // Ensure at least two tables exist in the write DB.
        for t in ["dump_a", "dump_b"] {
            try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: DEnv.db, table: t))")
            try await engine.mysqlExecute(alias: alias, sql: "CREATE TABLE \(SQLBuilder.mysqlTable(database: DEnv.db, table: t)) (`id` INT NOT NULL, PRIMARY KEY(`id`)) ENGINE=InnoDB")
            try await engine.mysqlExecute(alias: alias, sql: "INSERT INTO \(SQLBuilder.mysqlTable(database: DEnv.db, table: t)) (`id`) VALUES (1),(2)")
        }
        let dump = try await engine.sqlDumpDatabase(alias: alias, database: DEnv.db)
        #expect(dump.text.contains("dump_a"))
        #expect(dump.text.contains("dump_b"))
        #expect(dump.text.uppercased().contains("CREATE TABLE"))
        #expect(dump.text.uppercased().contains("INSERT INTO"))
        #expect(dump.rowCount >= 4)
        for t in ["dump_a", "dump_b"] {
            try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: DEnv.db, table: t))")
        }
    }
}
