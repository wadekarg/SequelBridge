//
//  MySQLIntegrationTests.swift
//  SequelBridgeTests
//
//  Live-MySQL integration tests. Skipped unless SB_MYSQL_VERIFY=1 is set, so
//  normal test runs (and CI) stay hermetic.
//
//  To run against a throwaway server:
//    docker run -d --name sb-verify-mysql -e MYSQL_ROOT_PASSWORD=... \
//      -e MYSQL_DATABASE=sbtest -p 3307:3306 mysql:8
//    SB_MYSQL_VERIFY=1 SB_MYSQL_HOST=127.0.0.1 SB_MYSQL_PORT=3307 \
//    SB_MYSQL_USER=sbuser SB_MYSQL_PASS=... xcodebuild ... test
//

import Foundation
import Testing
@testable import SequelBridge

private struct Env {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { ProcessInfo.processInfo.environment["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(ProcessInfo.processInfo.environment["SB_MYSQL_PORT"] ?? "3307") ?? 3307 }
    static var user: String { ProcessInfo.processInfo.environment["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { ProcessInfo.processInfo.environment["SB_MYSQL_PASS"] ?? "" }
    static var db:   String { ProcessInfo.processInfo.environment["SB_MYSQL_DB"] ?? "sbtest" }
}

@MainActor
@Suite("MySQL live integration", .enabled(if: Env.enabled))
struct MySQLIntegrationTests {

    static let alias = "sbv"

    /// Fresh engine attached to the test server.
    func makeEngine() async throws -> QueryEngine {
        let engine = try QueryEngine()
        let conn = Connection(
            name: "verify", alias: Self.alias,
            connectionType: .tcpip,
            host: Env.host, port: Env.port,
            username: Env.user, database: Env.db
        )
        try await engine.attach(conn, password: Env.pass)
        return engine
    }

    // MARK: - Connection

    @Test("ATTACH succeeds against a live MySQL server")
    func attachWorks() async throws {
        let engine = try await makeEngine()
        let r = try await engine.query("SELECT 1 AS one")
        #expect(r.rows.first?.first == "1")
    }

    // MARK: - Sidebar / discovery

    @Test("fetchDatabases returns user DBs and filters system schemas")
    func databases() async throws {
        let engine = try await makeEngine()
        let dbs = try await engine.fetchDatabases(alias: Self.alias)
        #expect(dbs.contains(Env.db))
        #expect(!dbs.contains("information_schema"))
        #expect(!dbs.contains("performance_schema"))
        #expect(!dbs.contains("mysql"))
        #expect(!dbs.contains("sys"))
    }

    @Test("fetchTables lists all base tables")
    func tables() async throws {
        let engine = try await makeEngine()
        let names = try await engine.fetchTables(alias: Self.alias, database: Env.db).map(\.name).sorted()
        #expect(Set(["customers", "order_items", "orders"]).isSubset(of: Set(names)))
    }

    @Test("connection's saved default database is applied as the active context on attach")
    func defaultDatabaseAppliedOnConnect() async throws {
        // makeEngine() attaches with `database: Env.db` set and performs no sidebar
        // selection afterwards. The sidebar's initial auto-select only updates UI
        // state and never calls setDefaultContext, so before the fix the engine's
        // active context stayed unset after connect. It must now equal the saved
        // default database. (Unqualified-name resolution alone can't detect this:
        // DuckDB already honours the DSN's database= for that, so we assert the
        // engine's context directly.)
        let engine = try await makeEngine()
        #expect(engine.activeDatabase(for: Self.alias) == Env.db)
        // and unqualified names must still resolve against it
        let r = try await engine.query("SELECT COUNT(*) AS n FROM customers")
        #expect(r.rows.first?.first != nil)
    }

    // MARK: - Structure panel

    @Test("fetchColumns returns MySQL types, nullability, PK and auto_increment")
    func columns() async throws {
        let engine = try await makeEngine()
        let cols = try await engine.fetchColumns(alias: Self.alias, database: Env.db, table: "customers")
        #expect(cols.count == 9)

        let id = try #require(cols.first { $0.name == "id" })
        #expect(id.isPrimaryKey)
        #expect(id.extra.lowercased().contains("auto_increment"))
        #expect(!id.nullable)

        let email = try #require(cols.first { $0.name == "email" })
        #expect(!email.nullable)
        #expect(email.dataType.lowercased() == "varchar(255)")
        #expect(email.keyType.uppercased() == "UNI")

        let credit = try #require(cols.first { $0.name == "credit_limit" })
        #expect(credit.dataType.lowercased() == "decimal(10,2)")

        let notes = try #require(cols.first { $0.name == "notes" })
        #expect(notes.nullable)
        #expect(notes.dataType.lowercased() == "text")
    }

    @Test("fetchColumns marks EVERY column of a composite primary key as PRI")
    func compositePrimaryKey() async throws {
        let engine = try await makeEngine()
        let cols = try await engine.fetchColumns(alias: Self.alias, database: Env.db, table: "order_items")
        let pks = cols.filter(\.isPrimaryKey).map(\.name).sorted()
        #expect(pks == ["line_no", "order_id"])
    }

    @Test("fetchIndexes groups columns per index in key order with uniqueness")
    func indexes() async throws {
        let engine = try await makeEngine()
        let idx = try await engine.fetchIndexes(alias: Self.alias, database: Env.db, table: "customers")

        let primary = try #require(idx.first { $0.name == "PRIMARY" })
        #expect(primary.unique)
        #expect(primary.columns == ["id"])

        let uq = try #require(idx.first { $0.name == "uq_customers_email" })
        #expect(uq.unique)
        #expect(uq.columns == ["email"])

        let composite = try #require(idx.first { $0.name == "idx_customers_name_date" })
        #expect(!composite.unique)
        #expect(composite.columns == ["full_name", "signup_date"])   // Seq_in_index order
        #expect(composite.indexType.uppercased() == "BTREE")
    }

    // MARK: - Relations panel

    @Test("fetchRelations parses FK name, columns, target and referential actions")
    func relations() async throws {
        let engine = try await makeEngine()
        let rels = try await engine.fetchRelations(alias: Self.alias, database: Env.db, table: "orders")
        #expect(rels.count == 1)
        let fk = try #require(rels.first)
        // [name, cols, refTable, refCols, onDelete, onUpdate]
        #expect(fk[0] == "fk_orders_customer")
        #expect(fk[1] == "customer_id")
        #expect(fk[2] == "customers")
        #expect(fk[3] == "id")
        #expect(fk[4] == "CASCADE")
        #expect(Self.serverDefaultRules.contains(fk[5]))
    }

    /// What a server reports for an omitted ON UPDATE / ON DELETE: MariaDB says RESTRICT,
    /// MySQL 8 says NO ACTION. InnoDB treats the two the same; the panel shows the server's word.
    static let serverDefaultRules: Set<String> = ["RESTRICT", "NO ACTION"]

    @Test("fetchRelations shows the server's default for an omitted action (RESTRICT, or NO ACTION on MySQL 8)")
    func relationsDefaultActions() async throws {
        let engine = try await makeEngine()
        let rels = try await engine.fetchRelations(alias: Self.alias, database: Env.db, table: "order_items")
        let fk = try #require(rels.first { $0[0] == "fk_items_order" })
        #expect(fk[4] == "CASCADE")    // explicit ON DELETE CASCADE
        #expect(Self.serverDefaultRules.contains(fk[5]))   // ON UPDATE not specified → the server's default
    }

    @Test("Table Info shows the server's own CREATE TABLE, foreign keys and options included")
    func serverCreateTable() async throws {
        let engine = try await makeEngine()
        let create = try await engine.fetchCreateTable(alias: Self.alias, database: Env.db, table: "orders")
        #expect(!create.rebuilt, "rebuilt: \(create.reason ?? "")")
        #expect(create.statement.hasPrefix("CREATE TABLE `orders`"), "got: \(create.statement.prefix(80))")
        #expect(create.statement.contains("CONSTRAINT `fk_orders_customer` FOREIGN KEY"))
        #expect(create.statement.contains("ENGINE=InnoDB"))
    }

    @Test("Import SQL file runs a dump's statements in order: executable comments, a ; inside a string")
    func importDump() async throws {
        let engine = try await makeEngine()
        let dump = """
        /*!40101 SET NAMES utf8mb4 */;
        DROP TABLE IF EXISTS `sbwrite`.`imp_probe`;
        CREATE TABLE `sbwrite`.`imp_probe` (`id` int NOT NULL, `name` varchar(20), PRIMARY KEY (`id`));
        LOCK TABLES `sbwrite`.`imp_probe` WRITE;
        INSERT INTO `sbwrite`.`imp_probe` VALUES (1,'a'),(2,'b;c');
        UNLOCK TABLES;
        """
        let statements = SQLFile.importStatements(dump)
        var done: [Int] = []
        try await engine.runScript(alias: Self.alias, statements: statements) { done.append($0) }
        #expect(statements.count == 4)   // LOCK TABLES and UNLOCK TABLES are skipped
        #expect(done == (0..<statements.count).map { $0 + 1 })
        let r = try await engine.serverPassthroughQuery(alias: Self.alias, serverSQL: "SELECT name FROM `sbwrite`.`imp_probe` ORDER BY id")
        #expect(r.rows.map { $0[0] } == ["a", "b;c"])
    }

    @Test("Import SQL file stops at the first statement that fails, and says which")
    func importStops() async throws {
        let engine = try await makeEngine()
        try await engine.mysqlExecute(alias: Self.alias, sql: "DROP TABLE IF EXISTS `sbwrite`.`imp_stop`")
        try await engine.mysqlExecute(alias: Self.alias, sql: "CREATE TABLE `sbwrite`.`imp_stop` (`id` int PRIMARY KEY)")
        let statements = ["INSERT INTO `sbwrite`.`imp_stop` VALUES (1)", "INSERT INTO `sbwrite`.`no_such_table_x` VALUES (1)",
                          "INSERT INTO `sbwrite`.`imp_stop` VALUES (2)"]
        do {
            try await engine.runScript(alias: Self.alias, statements: statements) { _ in }
            Issue.record("the failing statement didn't stop the import")
        } catch let failure as SQLScriptFailure {
            #expect(failure.index == 2 && failure.total == 3)
            #expect(failure.reason.contains("no_such_table_x"), "got: \(failure.reason)")
        }
        let r = try await engine.serverPassthroughQuery(alias: Self.alias, serverSQL: "SELECT id FROM `sbwrite`.`imp_stop` ORDER BY id")
        #expect(r.rows.map { $0[0] } == ["1"])
        try await engine.mysqlExecute(alias: Self.alias, sql: "DROP TABLE `sbwrite`.`imp_stop`")
    }

    // MARK: - Triggers panel

    @Test("fetchTriggers returns name, timing, event and statement")
    func triggers() async throws {
        let engine = try await makeEngine()
        let trigs = try await engine.fetchTriggers(alias: Self.alias, database: Env.db, table: "orders")
        #expect(trigs.count == 1)
        let t = try #require(trigs.first)
        // [trigger, timing, event, definer, statement, created]
        #expect(t[0] == "trg_orders_before_insert")
        #expect(t[1].uppercased() == "BEFORE")
        #expect(t[2].uppercased() == "INSERT")
        #expect(t[4].uppercased().contains("SET"))
    }

    @Test("fetchTriggers returns empty for a table with no triggers")
    func triggersEmpty() async throws {
        let engine = try await makeEngine()
        let trigs = try await engine.fetchTriggers(alias: Self.alias, database: Env.db, table: "customers")
        #expect(trigs.isEmpty)
    }

    // MARK: - Table Info panel

    @Test("fetchTableMeta returns engine, collation and row count")
    func tableMeta() async throws {
        let engine = try await makeEngine()
        let meta = try await engine.fetchTableMeta(alias: Self.alias, database: Env.db, table: "customers")
        #expect(meta.count == 15)
        #expect(meta[0] == "InnoDB")                       // engine
        #expect(meta[3].hasPrefix("utf8mb4"))              // collation
        #expect((Int(meta[6]) ?? -1) >= 0)                 // rows
    }

    // MARK: - Content panel reads

    @Test("query returns rows with NULLs preserved and column types populated")
    func contentRead() async throws {
        let engine = try await makeEngine()
        await engine.setDefaultContextAwaited(alias: Self.alias, database: Env.db)
        let r = try await engine.query("""
            SELECT id, email, full_name, credit_limit
            FROM \(Self.alias).\(Env.db).customers ORDER BY id
        """)
        #expect(r.columns == ["id", "email", "full_name", "credit_limit"])
        #expect(r.rows.count == 3)
        #expect(r.columnTypes.count == 4)
        #expect(!r.columnTypes[0].isEmpty)
        // customer 3 has a NULL full_name
        #expect(r.rows[2][2] == "NULL")
        #expect(r.executionTime > 0)
    }
}
