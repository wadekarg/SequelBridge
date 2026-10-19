//
//  MySQLRelationsTests.swift
//  SequelBridgeTests
//
//  The Relations tab's foreign-key lookup. It joined information_schema's
//  REFERENTIAL_CONSTRAINTS to KEY_COLUMN_USAGE on their schema and table columns, and
//  MariaDB (like MySQL before 8) answers that join by opening every table in every
//  database on the server: seconds to minutes on a big one. The Structure tab waits on
//  the same connection, so it sat on "loading" behind it. Skipped unless SB_MYSQL_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private struct RelEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_MYSQL_PORT"] ?? "3309") ?? 3309 }
    static var user: String { e["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { e["SB_MYSQL_PASS"] ?? "" }
    static var db: String { e["SB_MYSQL_DB"] ?? "sbtest" }
    static var writeDB: String { e["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
    static var otherDB: String { e["SB_MYSQL_REAL_DB"] ?? "sbreal" }
}

@MainActor
@Suite("Relations tab: foreign keys", .enabled(if: RelEnv.enabled), .serialized)
struct MySQLRelationsTests {

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        let conn = Connection(name: "rel", alias: alias, connectionType: .tcpip,
                              host: RelEnv.host, port: RelEnv.port, username: RelEnv.user, database: RelEnv.db)
        try await engine.attach(conn, password: RelEnv.pass)
        return engine
    }

    /// rel_child has two foreign keys: fk_rel_pair over (py, px), declared out of
    /// alphabetical order, and fk_rel_other over oid.
    func makeTables(_ engine: QueryEngine, _ alias: String, in db: String, pairOnDelete: String) async throws {
        try await dropTables(engine, alias, in: db)
        let parent = SQLBuilder.mysqlTable(database: db, table: "rel_parent")
        let other = SQLBuilder.mysqlTable(database: db, table: "rel_other")
        try await engine.mysqlExecute(alias: alias, sql:
            "CREATE TABLE \(parent) (x INT NOT NULL, y INT NOT NULL, PRIMARY KEY (y, x)) ENGINE=InnoDB")
        try await engine.mysqlExecute(alias: alias, sql:
            "CREATE TABLE \(other) (id INT NOT NULL PRIMARY KEY) ENGINE=InnoDB")
        try await engine.mysqlExecute(alias: alias, sql:
            "CREATE TABLE \(SQLBuilder.mysqlTable(database: db, table: "rel_child")) ("
            + "id INT NOT NULL PRIMARY KEY, px INT NULL, py INT NULL, oid INT NULL, "
            + "CONSTRAINT fk_rel_pair FOREIGN KEY (py, px) REFERENCES \(parent) (y, x) ON DELETE \(pairOnDelete), "
            + "CONSTRAINT fk_rel_other FOREIGN KEY (oid) REFERENCES \(other) (id) ON UPDATE CASCADE"
            + ") ENGINE=InnoDB")
    }

    func dropTables(_ engine: QueryEngine, _ alias: String, in db: String) async throws {
        for t in ["rel_child", "rel_parent", "rel_other"] {
            try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: db, table: t))")
        }
    }

    @Test("the lookup asks the server about this one table, not every table it has")
    func onlyThisTable() async throws {
        let engine = try await makeEngine("rl1")
        let plan = try await engine.explain(alias: "rl1",
                                            serverSQL: QueryEngine.mysqlRelationsSQL(database: RelEnv.db, table: "orders"))
        let lines = plan.rows.map { $0.joined(separator: " | ") }
        #expect(!lines.isEmpty)
        #expect(!lines.contains { $0.contains("Scanned all databases") }, "plan:\n\(lines.joined(separator: "\n"))")
    }

    @Test("two foreign keys, one over two columns: each listed once, columns in key order, with its own rules")
    func compositeAndSeveral() async throws {
        let engine = try await makeEngine("rl2")
        try await makeTables(engine, "rl2", in: RelEnv.writeDB, pairOnDelete: "CASCADE")
        let rels = try await engine.fetchRelations(alias: "rl2", database: RelEnv.writeDB, table: "rel_child")
        try await dropTables(engine, "rl2", in: RelEnv.writeDB)

        // [name, cols, refTable, refCols, onDelete, onUpdate], ordered by name
        #expect(rels.map { $0[0] } == ["fk_rel_other", "fk_rel_pair"])
        let other = try #require(rels.first)
        #expect(Array(other[1...3]) == ["oid", "rel_other", "id"])
        #expect(MySQLIntegrationTests.serverDefaultRules.contains(other[4]))
        #expect(other[5] == "CASCADE")
        let pair = try #require(rels.last)
        #expect(Array(pair[1...3]) == ["py, px", "rel_parent", "y, x"])
        #expect(pair[4] == "CASCADE")
        #expect(MySQLIntegrationTests.serverDefaultRules.contains(pair[5]))
    }

    @Test("the same table and key names in another database stay out of the list")
    func otherDatabase() async throws {
        let engine = try await makeEngine("rl3")
        try await makeTables(engine, "rl3", in: RelEnv.writeDB, pairOnDelete: "CASCADE")
        try await makeTables(engine, "rl3", in: RelEnv.otherDB, pairOnDelete: "SET NULL")
        let here = try await engine.fetchRelations(alias: "rl3", database: RelEnv.writeDB, table: "rel_child")
        let there = try await engine.fetchRelations(alias: "rl3", database: RelEnv.otherDB, table: "rel_child")
        try await dropTables(engine, "rl3", in: RelEnv.writeDB)
        try await dropTables(engine, "rl3", in: RelEnv.otherDB)

        #expect(here.count == 2)
        #expect(here.first { $0[0] == "fk_rel_pair" }.map { [$0[1], $0[4]] } == ["py, px", "CASCADE"])
        #expect(there.count == 2)
        #expect(there.first { $0[0] == "fk_rel_pair" }.map { [$0[1], $0[4]] } == ["py, px", "SET NULL"])
    }
}
