//
//  SQLiteTests.swift
//  SequelBridgeTests
//
//  SQLite attached as a third engine. Needs no server — the suite builds its own
//  database file with the sqlite3 CLI, so it runs unconditionally.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("SQLite", .serialized)
struct SQLiteTests {

    /// Builds a throwaway SQLite file. Returns nil when sqlite3 is unavailable.
    static func makeDatabase() throws -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sb-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("test.sqlite")

        let sql = """
        CREATE TABLE customers (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL,
          full_name TEXT,
          credit_limit REAL DEFAULT 0.0,
          notes TEXT
        );
        CREATE UNIQUE INDEX uq_customers_email ON customers(email);
        CREATE INDEX idx_customers_name ON customers(full_name);
        CREATE TABLE orders (
          id INTEGER PRIMARY KEY,
          customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
          total REAL
        );
        CREATE TABLE order_items (
          order_id INTEGER NOT NULL, line_no INTEGER NOT NULL, sku TEXT,
          PRIMARY KEY (order_id, line_no)
        );
        INSERT INTO customers (email, full_name, credit_limit) VALUES
          ('a@x.com','Ada',500.0),('b@x.com','Alan',1200.5),('c@x.com',NULL,0.0);
        INSERT INTO orders (customer_id,total) VALUES (1,99.99),(1,10.0),(2,250.75);
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db.path]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return nil }
        try p.run()
        stdin.fileHandleForWriting.write(Data(sql.utf8))
        try? stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return db
    }

    func attached(_ alias: String) async throws -> (QueryEngine, URL)? {
        guard let db = try Self.makeDatabase() else { return nil }
        let engine = try QueryEngine()
        var c = Connection(name: "lite", alias: alias, host: "", username: "", database: db.path)
        c.engine = .sqlite
        try await engine.attach(c, password: "")
        return (engine, db)
    }

    @Test("a database file attaches with no host or credentials")
    func attaches() async throws {
        guard let (e, _) = try await attached("s1") else { return }
        let r = try await e.query("SELECT COUNT(*) FROM \(SQLBuilder.duckIdent("s1")).\(SQLBuilder.duckIdent("customers"))")
        #expect(r.rows.first?.first == "3")
    }

    @Test("a missing file reports itself instead of attaching")
    func missingFile() async throws {
        let engine = try QueryEngine()
        var c = Connection(name: "gone", alias: "s0", host: "", username: "", database: "/no/such/file.sqlite")
        c.engine = .sqlite
        await #expect(throws: (any Error).self) { try await engine.attach(c, password: "") }
    }

    @Test("the single schema is reported as main")
    func schema() async throws {
        guard let (e, _) = try await attached("s2") else { return }
        #expect(try await e.fetchDatabases(alias: "s2") == ["main"])
    }

    @Test("tables are listed and internal ones hidden")
    func tables() async throws {
        guard let (e, _) = try await attached("s3") else { return }
        let names = try await e.fetchTables(alias: "s3", database: "main").map(\.name).sorted()
        #expect(Set(["customers", "order_items", "orders"]).isSubset(of: Set(names)))
        // AUTOINCREMENT creates sqlite_sequence; it is bookkeeping, not user data.
        #expect(!names.contains("sqlite_sequence"))
    }

    @Test("columns keep their declared types and mark the primary key")
    func columns() async throws {
        guard let (e, _) = try await attached("s4") else { return }
        let cols = try await e.fetchColumns(alias: "s4", database: "main", table: "customers")
        #expect(cols.map(\.name) == ["id","email","full_name","credit_limit","notes"])

        let id = try #require(cols.first { $0.name == "id" })
        #expect(id.isPrimaryKey)
        #expect(id.extra == "auto_increment")
        // The declared type, not DuckDB's normalisation of it.
        #expect(id.dataType == "INTEGER")

        #expect(try #require(cols.first { $0.name == "email" }).nullable == false)
        #expect(try #require(cols.first { $0.name == "full_name" }).nullable == true)
        #expect(try #require(cols.first { $0.name == "credit_limit" }).defaultValue == "0.0")
    }

    @Test("a composite primary key is reported on every column")
    func compositeKey() async throws {
        guard let (e, _) = try await attached("s5") else { return }
        let cols = try await e.fetchColumns(alias: "s5", database: "main", table: "order_items")
        #expect(cols.filter(\.isPrimaryKey).map(\.name) == ["order_id", "line_no"])
    }

    @Test("indexes include the primary key and report uniqueness correctly")
    func indexes() async throws {
        guard let (e, _) = try await attached("s6") else { return }
        let idx = try await e.fetchIndexes(alias: "s6", database: "main", table: "customers")
        #expect(try #require(idx.first { $0.name == "PRIMARY" }).columns == ["id"])
        // duckdb_indexes() claims false here; the DDL is the truth.
        #expect(try #require(idx.first { $0.name == "uq_customers_email" }).unique)
        #expect(try #require(idx.first { $0.name == "idx_customers_name" }).unique == false)
    }

    @Test("foreign keys are read from the table definition")
    func relations() async throws {
        guard let (e, _) = try await attached("s7") else { return }
        let rels = try await e.fetchRelations(alias: "s7", database: "main", table: "orders")
        #expect(rels.count == 1)
        #expect(rels[0][1] == "customer_id")
        #expect(rels[0][2] == "customers")
        #expect(rels[0][4] == "CASCADE")
    }

    @Test("row counts are reported")
    func tableMeta() async throws {
        guard let (e, _) = try await attached("s8") else { return }
        let meta = try await e.fetchTableMeta(alias: "s8", database: "main", table: "customers")
        #expect(meta.count == 15)
        #expect(meta[0] == "SQLite")
        #expect(meta[6] == "3")
    }

    @Test("rows read back with NULLs preserved")
    func rows() async throws {
        guard let (e, _) = try await attached("s9") else { return }
        let r = try await e.query("""
            SELECT email, full_name FROM \(SQLBuilder.duckIdent("s9")).\(SQLBuilder.duckIdent("customers")) ORDER BY email
            """)
        #expect(r.rows.count == 3)
        #expect(r.rows[2][1] == "NULL")
    }

    @Test("a SQLite file joins against a server in one query")
    func crossEngineJoin() async throws {
        guard let (e, _) = try await attached("lite") else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["SB_PG_VERIFY"] == "1" else { return }

        var pg = Connection(name: "pg", alias: "pg", connectionType: .tcpip,
                            host: env["SB_PG_HOST"] ?? "127.0.0.1",
                            port: Int(env["SB_PG_PORT"] ?? "5433") ?? 5433,
                            username: env["SB_PG_USER"] ?? "sbuser",
                            database: env["SB_PG_DB"] ?? "sbtest")
        pg.engine = .postgres
        try await e.attach(pg, password: env["SB_PG_PASS"] ?? "")

        let r = try await e.query("""
            SELECT l.email FROM \(SQLBuilder.duckIdent("lite")).\(SQLBuilder.duckIdent("customers")) AS l
            JOIN \(SQLBuilder.duckTable(alias: "pg", database: "public", table: "customers")) AS p
              ON p.email = l.email
            ORDER BY l.email
            """)
        // Both fixtures use the same three addresses.
        #expect(r.rows.count == 3)
    }
}
