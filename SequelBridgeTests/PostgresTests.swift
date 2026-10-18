//
//  PostgresTests.swift
//  SequelBridgeTests
//
//  PostgreSQL attached through the same engine as MySQL.
//  Needs SB_PG_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private struct PEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_PG_VERIFY"] == "1" }
    static var host: String { e["SB_PG_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_PG_PORT"] ?? "5433") ?? 5433 }
    static var user: String { e["SB_PG_USER"] ?? "sbuser" }
    static var pass: String { e["SB_PG_PASS"] ?? "" }
    static var db:   String { e["SB_PG_DB"] ?? "sbtest" }
}

@MainActor
@Suite("PostgreSQL", .enabled(if: PEnv.enabled), .serialized)
struct PostgresTests {

    func connection(_ alias: String) -> Connection {
        var c = Connection(name: "pg", alias: alias, connectionType: .tcpip,
                           host: PEnv.host, port: PEnv.port, username: PEnv.user, database: PEnv.db)
        c.engine = .postgres
        return c
    }

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        try await engine.attach(connection(alias), password: PEnv.pass)
        return engine
    }

    @Test("ATTACH succeeds against a live PostgreSQL server")
    func attaches() async throws {
        let engine = try await makeEngine("pg1")
        let r = try await engine.query("SELECT 1 AS ok")
        #expect(r.rows.first?.first == "1")
    }

    @Test("rows read back with NULLs preserved")
    func readsRows() async throws {
        let engine = try await makeEngine("pg2")
        let r = try await engine.query("""
            SELECT email, full_name FROM \(SQLBuilder.duckTable(alias: "pg2", database: "public", table: "customers"))
            ORDER BY email
            """)
        #expect(r.rows.count == 3)
        #expect(r.rows[0][0] == "a@x.com")
        #expect(r.rows[2][1] == "NULL", "a SQL NULL should render as NULL")
    }

    @Test("tables in a non-public schema are reachable")
    func otherSchema() async throws {
        let engine = try await makeEngine("pg3")
        let r = try await engine.query("""
            SELECT COUNT(*) FROM \(SQLBuilder.duckTable(alias: "pg3", database: "reporting", table: "daily_totals"))
            """)
        #expect(r.rows.first?.first == "1")
    }

    @Test("a MySQL and a PostgreSQL server join in one query")
    func crossEngineJoin() async throws {
        let mysqlPort = Int(ProcessInfo.processInfo.environment["SB_MYSQL_PORT"] ?? "") ?? 3309
        let engine = try QueryEngine()
        try await engine.attach(connection("pg"), password: PEnv.pass)

        var my = Connection(name: "my", alias: "my", connectionType: .tcpip,
                            host: "127.0.0.1", port: mysqlPort,
                            username: ProcessInfo.processInfo.environment["SB_MYSQL_USER"] ?? "sbuser",
                            database: "sbtest")
        my.engine = .mysql
        try await engine.attach(my, password: ProcessInfo.processInfo.environment["SB_MYSQL_PASS"] ?? "")

        // The whole point of the ATTACH architecture: one statement, two products.
        let r = try await engine.query("""
            SELECT p.email, COUNT(m.id) AS n
            FROM \(SQLBuilder.duckTable(alias: "pg", database: "public", table: "customers")) AS p
            JOIN \(SQLBuilder.duckTable(alias: "my", database: "sbtest", table: "orders")) AS m
              ON m.customer_id = p.id
            GROUP BY p.email ORDER BY p.email
            """)
        #expect(r.rows.count == 2)
        #expect(r.rows[0][0] == "a@x.com")
        #expect(r.rows[0][1] == "2")
    }

    @Test("the engine reports the connection failure rather than hanging")
    func badCredentials() async throws {
        let engine = try QueryEngine()
        var c = connection("bad")
        c.username = "nosuchuser"
        await #expect(throws: (any Error).self) {
            try await engine.attach(c, password: "wrong")
        }
    }
}

@MainActor
@Suite("PostgreSQL metadata", .enabled(if: PEnv.enabled), .serialized)
struct PostgresMetadataTests {

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        var c = Connection(name: "pg", alias: alias, connectionType: .tcpip,
                           host: PEnv.host, port: PEnv.port, username: PEnv.user, database: PEnv.db)
        c.engine = .postgres
        try await engine.attach(c, password: PEnv.pass)
        return engine
    }

    @Test("schemas are listed where the app expects databases")
    func schemasAsDatabases() async throws {
        let e = try await makeEngine("m1")
        let dbs = try await e.fetchDatabases(alias: "m1")
        #expect(dbs.contains("public"))
        #expect(dbs.contains("reporting"))
        #expect(!dbs.contains("pg_catalog"), "system schemas must be filtered")
    }

    @Test("tables are listed per schema")
    func tables() async throws {
        let e = try await makeEngine("m2")
        let publicTables = try await e.fetchTables(alias: "m2", database: "public").map(\.name)
        #expect(Set(["customers", "order_items", "orders"]).isSubset(of: Set(publicTables)))
        #expect(try await e.fetchTables(alias: "m2", database: "reporting").map(\.name) == ["daily_totals"])
    }

    @Test("columns carry type, nullability, primary key and defaults")
    func columns() async throws {
        let e = try await makeEngine("m3")
        let cols = try await e.fetchColumns(alias: "m3", database: "public", table: "customers")
        #expect(cols.map(\.name) == ["id","email","full_name","credit_limit","is_active",
                                     "signup_date","created_at","notes","avatar"])

        let id = try #require(cols.first { $0.name == "id" })
        #expect(id.isPrimaryKey)
        #expect(!id.nullable)
        // A serial's identity belongs in extra, where the panels look — not as a
        // literal nextval() default.
        #expect(id.extra == "auto_increment")
        #expect(id.defaultValue.isEmpty)

        let email = try #require(cols.first { $0.name == "email" })
        #expect(email.dataType == "character varying(255)")
        #expect(!email.nullable)

        let name = try #require(cols.first { $0.name == "full_name" })
        #expect(name.nullable)

        let limit = try #require(cols.first { $0.name == "credit_limit" })
        #expect(limit.dataType == "numeric(10,2)")
    }

    @Test("indexes group columns in order and report the primary key as PRIMARY")
    func indexes() async throws {
        let e = try await makeEngine("m4")
        let idx = try await e.fetchIndexes(alias: "m4", database: "public", table: "customers")
        let pk = try #require(idx.first { $0.name == "PRIMARY" })
        #expect(pk.columns == ["id"])
        #expect(pk.unique)

        let composite = try #require(idx.first { $0.name == "idx_customers_name_date" })
        #expect(composite.columns == ["full_name", "signup_date"])
        #expect(!composite.unique)

        #expect(idx.first { $0.name == "uq_customers_email" }?.unique == true)
    }

    @Test("foreign keys report both sides and the referential actions")
    func relations() async throws {
        let e = try await makeEngine("m5")
        let rels = try await e.fetchRelations(alias: "m5", database: "public", table: "orders")
        let fk = try #require(rels.first { $0[0] == "fk_orders_customer" })
        #expect(fk[1] == "customer_id")
        #expect(fk[2] == "customers")
        #expect(fk[3] == "id")
        #expect(fk[4] == "CASCADE")
        #expect(fk[5] == "RESTRICT")
    }

    @Test("table meta reports size and does not surface an unanalyzed row count")
    func tableMeta() async throws {
        let e = try await makeEngine("m6")
        let meta = try await e.fetchTableMeta(alias: "m6", database: "public", table: "customers")
        #expect(meta.count == 15)
        #expect(meta[0] == "heap")
        // reltuples is -1 until ANALYZE runs; that must never reach the UI.
        #expect(meta[6] != "-1")
        #expect(Int(meta[8]) ?? 0 > 0, "total size should be reported")
    }

    @Test("a table with no triggers returns none")
    func triggers() async throws {
        let e = try await makeEngine("m7")
        #expect(try await e.fetchTriggers(alias: "m7", database: "public", table: "customers").isEmpty)
    }
}

@MainActor
@Suite("PostgreSQL DDL", .enabled(if: PEnv.enabled), .serialized)
struct PostgresDDLTests {

    /// Its own schema, so creating tables here cannot disturb what the metadata
    /// suite expects to find in public.
    static let schema = "sbddl"

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        var c = Connection(name: "pg", alias: alias, connectionType: .tcpip,
                           host: PEnv.host, port: PEnv.port, username: PEnv.user, database: PEnv.db)
        c.engine = .postgres
        try await engine.attach(c, password: PEnv.pass)
        try await engine.executeDDL(alias: alias, sql: "CREATE SCHEMA IF NOT EXISTS \(SQLBuilder.duckIdent(Self.schema))")
        return engine
    }

    func fixture(_ e: QueryEngine, _ alias: String, _ table: String, _ body: String) async throws {
        let t = SQLBuilder.pgTable(schema: Self.schema, table: table)
        try await e.executeDDL(alias: alias, sql: "DROP TABLE IF EXISTS \(t) CASCADE")
        try await e.executeDDL(alias: alias, sql: "CREATE TABLE \(t) (\(body))")
    }

    func columns(_ e: QueryEngine, _ alias: String, _ table: String) async throws -> [ColumnInfo] {
        try await e.fetchColumns(alias: alias, database: Self.schema, table: table)
    }

    @Test("CREATE TABLE with a serial primary key")
    func createTable() async throws {
        let e = try await makeEngine("d1")
        try await e.executeDDL(alias: "d1", sql: "DROP TABLE IF EXISTS \(SQLBuilder.pgTable(schema: Self.schema, table: "d_create")) CASCADE")

        var id = NewColumnDef(); id.name = "id"; id.baseType = "INT"; id.length = ""
        id.nullable = false; id.autoIncrement = true; id.isPrimaryKey = true
        var label = NewColumnDef(); label.name = "label"; label.baseType = "VARCHAR"; label.length = "50"
        label.defaultValue = "it's"

        let sql = SQLBuilder.pgCreateTable(schema: Self.schema, table: "d_create", columns: [id, label])
        #expect(sql.contains("SERIAL"))
        #expect(!sql.uppercased().contains("ENGINE="))
        try await e.executeDDL(alias: "d1", sql: sql)

        let cols = try await columns(e, "d1", "d_create")
        #expect(cols.map(\.name) == ["id", "label"])
        #expect(try #require(cols.first { $0.name == "id" }).extra == "auto_increment")
        #expect(try #require(cols.first { $0.name == "label" }).dataType == "character varying(50)")
    }

    @Test("add, retype, rename and drop columns")
    func columnLifecycle() async throws {
        let e = try await makeEngine("d2")
        try await fixture(e, "d2", "d_cols",
                          "\"id\" INTEGER NOT NULL PRIMARY KEY, \"note\" VARCHAR(10), \"gone\" VARCHAR(5)")

        let original = try await columns(e, "d2", "d_cols")

        var widened = ColumnEdit(from: try #require(original.first { $0.name == "note" }))
        widened.baseType = "VARCHAR"; widened.length = "99"
        var added = ColumnEdit(from: try #require(original.first { $0.name == "note" }))
        added.originalName = nil; added.name = "added"; added.baseType = "INT"; added.length = ""

        let stmts = SQLBuilder.pgAlterStatements(
            schema: Self.schema, table: "d_cols",
            columnEdits: [widened, added], originalColumns: original,
            deletedColumnNames: ["gone"], indexEdits: [], deletedIndexNames: [])
        for sql in stmts { try await e.executeDDL(alias: "d2", sql: sql) }

        var names = try await columns(e, "d2", "d_cols").map(\.name)
        #expect(names.contains("added"))
        #expect(!names.contains("gone"))
        #expect(try #require(try await columns(e, "d2", "d_cols").first { $0.name == "note" })
                .dataType == "character varying(99)")

        // Rename, which Postgres spells RENAME COLUMN rather than CHANGE.
        let beforeRename = try await columns(e, "d2", "d_cols")
        var renamed = ColumnEdit(from: try #require(beforeRename.first { $0.name == "note" }))
        renamed.name = "note2"
        for sql in SQLBuilder.pgAlterStatements(schema: Self.schema, table: "d_cols",
                                                columnEdits: [renamed], originalColumns: beforeRename,
                                                deletedColumnNames: [], indexEdits: [], deletedIndexNames: []) {
            try await e.executeDDL(alias: "d2", sql: sql)
        }
        names = try await columns(e, "d2", "d_cols").map(\.name)
        #expect(names.contains("note2"))
        #expect(!names.contains("note"))
    }

    @Test("nullability and defaults change independently")
    func nullabilityAndDefaults() async throws {
        let e = try await makeEngine("d3")
        try await fixture(e, "d3", "d_null", "\"id\" INTEGER NOT NULL PRIMARY KEY, \"note\" VARCHAR(10)")

        let original = try await columns(e, "d3", "d_null")
        var edit = ColumnEdit(from: try #require(original.first { $0.name == "note" }))
        edit.nullable = false
        edit.defaultValue = "n/a"

        let stmts = SQLBuilder.pgAlterStatements(schema: Self.schema, table: "d_null",
                                                 columnEdits: [edit], originalColumns: original,
                                                 deletedColumnNames: [], indexEdits: [], deletedIndexNames: [])
        // One MySQL MODIFY becomes a SET NOT NULL and a SET DEFAULT here.
        #expect(stmts.count == 2, "got: \(stmts)")
        for sql in stmts { try await e.executeDDL(alias: "d3", sql: sql) }

        let after = try #require(try await columns(e, "d3", "d_null").first { $0.name == "note" })
        #expect(!after.nullable)
        #expect(after.defaultValue.contains("n/a"))
    }

    @Test("indexes are created and dropped as their own statements")
    func indexLifecycle() async throws {
        let e = try await makeEngine("d4")
        try await fixture(e, "d4", "d_idx",
                          "\"id\" INTEGER NOT NULL PRIMARY KEY, \"a\" VARCHAR(10), \"b\" VARCHAR(10)")

        let plain = IndexEdit(originalName: nil, name: "d_idx_ab", indexType: "INDEX", columns: ["a", "b"])
        let uniq  = IndexEdit(originalName: nil, name: "d_idx_uq", indexType: "UNIQUE", columns: ["a"])
        for sql in SQLBuilder.pgAlterStatements(schema: Self.schema, table: "d_idx",
                                                columnEdits: [], originalColumns: [],
                                                deletedColumnNames: [], indexEdits: [plain, uniq],
                                                deletedIndexNames: []) {
            #expect(sql.hasPrefix("CREATE"), "indexes are not ALTER clauses in Postgres: \(sql)")
            try await e.executeDDL(alias: "d4", sql: sql)
        }

        var idx = try await e.fetchIndexes(alias: "d4", database: Self.schema, table: "d_idx")
        #expect(idx.contains { $0.name == "d_idx_ab" && $0.columns == ["a", "b"] })
        #expect(idx.contains { $0.name == "d_idx_uq" && $0.unique })

        for sql in SQLBuilder.pgAlterStatements(schema: Self.schema, table: "d_idx",
                                                columnEdits: [], originalColumns: [],
                                                deletedColumnNames: [], indexEdits: [],
                                                deletedIndexNames: ["d_idx_ab"]) {
            try await e.executeDDL(alias: "d4", sql: sql)
        }
        idx = try await e.fetchIndexes(alias: "d4", database: Self.schema, table: "d_idx")
        #expect(!idx.contains { $0.name == "d_idx_ab" })
    }

    @Test("dropping the primary key targets the constraint, not an index")
    func dropPrimaryKey() async throws {
        let e = try await makeEngine("d5")
        try await fixture(e, "d5", "d_pk", "\"id\" INTEGER NOT NULL PRIMARY KEY, \"x\" INTEGER")

        let stmts = SQLBuilder.pgAlterStatements(schema: Self.schema, table: "d_pk",
                                                 columnEdits: [], originalColumns: [],
                                                 deletedColumnNames: [], indexEdits: [],
                                                 deletedIndexNames: ["PRIMARY"])
        #expect(stmts == ["ALTER TABLE \"sbddl\".\"d_pk\" DROP CONSTRAINT \"d_pk_pkey\""])
        for sql in stmts { try await e.executeDDL(alias: "d5", sql: sql) }

        let idx = try await e.fetchIndexes(alias: "d5", database: Self.schema, table: "d_pk")
        #expect(!idx.contains { $0.name == "PRIMARY" })
    }

    @Test("add and drop a foreign key")
    func foreignKeyLifecycle() async throws {
        let e = try await makeEngine("d6")
        try await e.executeDDL(alias: "d6", sql: "DROP TABLE IF EXISTS \(SQLBuilder.pgTable(schema: Self.schema, table: "d_child")) CASCADE")
        try await fixture(e, "d6", "d_parent", "\"id\" INTEGER NOT NULL PRIMARY KEY")
        try await fixture(e, "d6", "d_child", "\"id\" INTEGER NOT NULL PRIMARY KEY, \"parent_id\" INTEGER NOT NULL")

        let add = SQLBuilder.pgAddForeignKey(schema: Self.schema, table: "d_child", name: "fk_d_child",
                                             column: "parent_id", referencedTable: "d_parent",
                                             referencedColumn: "id", onDelete: "CASCADE", onUpdate: "RESTRICT")
        try await e.executeDDL(alias: "d6", sql: add)

        var rels = try await e.fetchRelations(alias: "d6", database: Self.schema, table: "d_child")
        let fk = try #require(rels.first { $0[0] == "fk_d_child" })
        #expect(fk[4] == "CASCADE")

        try await e.executeDDL(alias: "d6", sql: SQLBuilder.pgDropForeignKey(schema: Self.schema, table: "d_child", name: "fk_d_child"))
        rels = try await e.fetchRelations(alias: "d6", database: Self.schema, table: "d_child")
        #expect(rels.isEmpty)
    }

    @Test("a rejected statement throws and leaves the engine usable")
    func survivesBadDDL() async throws {
        let e = try await makeEngine("d7")
        await #expect(throws: (any Error).self) {
            try await e.executeDDL(alias: "d7", sql: "ALTER TABLE \"sbddl\".\"no_such_table\" DROP COLUMN \"nope\"")
        }
        #expect(try await e.query("SELECT 7 AS ok").rows.first?.first == "7")
    }
}

@MainActor
@Suite("PostgreSQL row editing", .enabled(if: PEnv.enabled), .serialized)
struct PostgresDMLTests {

    static let schema = "sbddl"

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        var c = Connection(name: "pg", alias: alias, connectionType: .tcpip,
                           host: PEnv.host, port: PEnv.port, username: PEnv.user, database: PEnv.db)
        c.engine = .postgres
        try await engine.attach(c, password: PEnv.pass)
        try await engine.executeDDL(alias: alias, sql: "CREATE SCHEMA IF NOT EXISTS \(SQLBuilder.duckIdent(Self.schema))")
        return engine
    }

    func fixture(_ e: QueryEngine, _ alias: String, _ table: String, _ body: String) async throws {
        let t = SQLBuilder.pgTable(schema: Self.schema, table: table)
        try await e.executeDDL(alias: alias, sql: "DROP TABLE IF EXISTS \(t) CASCADE")
        try await e.executeDDL(alias: alias, sql: "CREATE TABLE \(t) (\(body))")
    }

    /// The DML the Content panel builds is dialect-free — DuckDB executes it against
    /// the attached tables itself, so the same builder serves both engines.
    @Test("insert, edit and delete a row end to end")
    func rowLifecycle() async throws {
        let alias = "x1"
        let e = try await makeEngine(alias)
        try await fixture(e, alias, "x_dml", "\"id\" INTEGER NOT NULL PRIMARY KEY, \"name\" VARCHAR(50)")
        let tbl = SQLBuilder.duckTable(alias: alias, database: Self.schema, table: "x_dml")

        _ = try await e.query(SQLBuilder.insert(alias: alias, database: Self.schema, table: "x_dml",
                                                values: ["id": "1", "name": "alpha"]))
        #expect(try await e.query("SELECT name FROM \(tbl)").rows.first?.first == "alpha")

        _ = try await e.query(SQLBuilder.update(alias: alias, database: Self.schema, table: "x_dml",
                                                column: "name", newValue: "beta",
                                                primaryKey: [(column: "id", value: "1")]))
        #expect(try await e.query("SELECT name FROM \(tbl)").rows.first?.first == "beta")

        // Empty value stores an empty string, not NULL
        _ = try await e.query(SQLBuilder.update(alias: alias, database: Self.schema, table: "x_dml",
                                                column: "name", newValue: "",
                                                primaryKey: [(column: "id", value: "1")]))
        #expect(try await e.query("SELECT name FROM \(tbl)").rows.first?.first == "")

        // Explicit nil writes a real NULL
        _ = try await e.query(SQLBuilder.update(alias: alias, database: Self.schema, table: "x_dml",
                                                column: "name", newValue: nil,
                                                primaryKey: [(column: "id", value: "1")]))
        #expect(try await e.query("SELECT name FROM \(tbl)").rows.first?.first == "NULL")

        _ = try await e.query(SQLBuilder.delete(alias: alias, database: Self.schema, table: "x_dml",
                                                primaryKey: [(column: "id", value: "1")]))
        #expect(try await e.query("SELECT COUNT(*) FROM \(tbl)").rows.first?.first == "0")
    }

    @Test("values containing quotes survive an insert")
    func quoting() async throws {
        let alias = "x2"
        let e = try await makeEngine(alias)
        try await fixture(e, alias, "x_quote", "\"id\" INTEGER NOT NULL PRIMARY KEY, \"name\" VARCHAR(50)")
        _ = try await e.query(SQLBuilder.insert(alias: alias, database: Self.schema, table: "x_quote",
                                                values: ["id": "1", "name": "O'Brien"]))
        let r = try await e.query("SELECT name FROM \(SQLBuilder.duckTable(alias: alias, database: Self.schema, table: "x_quote"))")
        #expect(r.rows.first?.first == "O'Brien")
    }

    @Test("a composite primary key identifies the right row")
    func compositeKey() async throws {
        let alias = "x3"
        let e = try await makeEngine(alias)
        try await fixture(e, alias, "x_comp",
                          "\"order_id\" INTEGER NOT NULL, \"line_no\" INTEGER NOT NULL, \"qty\" INTEGER, PRIMARY KEY (\"order_id\",\"line_no\")")
        for line in ["1", "2"] {
            _ = try await e.query(SQLBuilder.insert(alias: alias, database: Self.schema, table: "x_comp",
                                                    values: ["order_id": "1", "line_no": line, "qty": "10"]))
        }
        _ = try await e.query(SQLBuilder.update(alias: alias, database: Self.schema, table: "x_comp",
                                                column: "qty", newValue: "99",
                                                primaryKey: [(column: "order_id", value: "1"),
                                                             (column: "line_no", value: "2")]))
        let r = try await e.query("""
            SELECT line_no, qty FROM \(SQLBuilder.duckTable(alias: alias, database: Self.schema, table: "x_comp")) ORDER BY line_no
            """)
        #expect(r.rows[0][1] == "10")
        #expect(r.rows[1][1] == "99")
    }
}
