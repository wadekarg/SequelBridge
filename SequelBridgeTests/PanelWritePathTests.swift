//
//  PanelWritePathTests.swift
//  SequelBridgeTests
//
//  End-to-end coverage of the write paths behind the workspace panels: the SQL
//  that SQLBuilder generates, executed against a live server by the same route
//  the panels use. Skipped unless SB_MYSQL_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private struct WEnv {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { ProcessInfo.processInfo.environment["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(ProcessInfo.processInfo.environment["SB_MYSQL_PORT"] ?? "3307") ?? 3307 }
    static var user: String { ProcessInfo.processInfo.environment["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { ProcessInfo.processInfo.environment["SB_MYSQL_PASS"] ?? "" }
    static var db:   String { ProcessInfo.processInfo.environment["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
}

@MainActor
@Suite("Panel write paths", .enabled(if: WEnv.enabled), .serialized)
struct PanelWritePathTests {

    func makeEngine(_ alias: String) async throws -> QueryEngine {
        let engine = try QueryEngine()
        let conn = Connection(name: "w", alias: alias, connectionType: .tcpip,
                              host: WEnv.host, port: WEnv.port, username: WEnv.user, database: WEnv.db)
        try await engine.attach(conn, password: WEnv.pass)
        return engine
    }

    func fixture(_ engine: QueryEngine, _ alias: String, _ table: String, _ body: String) async throws {
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: WEnv.db, table: table))")
        try await engine.mysqlExecute(alias: alias, sql: "CREATE TABLE \(SQLBuilder.mysqlTable(database: WEnv.db, table: table)) (\(body)) ENGINE=InnoDB")
    }

    func columnNames(_ engine: QueryEngine, _ alias: String, _ table: String) async throws -> [String] {
        try await engine.fetchColumns(alias: alias, database: WEnv.db, table: table).map(\.name)
    }

    // MARK: - ContentPanel

    @Test("insert, edit and delete a row end to end")
    func contentPanelDML() async throws {
        let alias = "w1"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_dml", "`id` INT NOT NULL, `name` VARCHAR(50), PRIMARY KEY (`id`)")

        // ContentPanel.insertRow
        _ = try await engine.query(SQLBuilder.insert(alias: alias, database: WEnv.db, table: "w_dml",
                                                     values: ["id": "1", "name": "alpha"]))
        var r = try await engine.query("SELECT name FROM \(SQLBuilder.duckTable(alias: alias, database: WEnv.db, table: "w_dml"))")
        #expect(r.rows.first?.first == "alpha")

        // ContentPanel.handleCellEdit
        _ = try await engine.query(SQLBuilder.update(alias: alias, database: WEnv.db, table: "w_dml",
                                                     column: "name", newValue: "beta",
                                                     primaryKey: [(column: "id", value: "1")]))
        r = try await engine.query("SELECT name FROM \(SQLBuilder.duckTable(alias: alias, database: WEnv.db, table: "w_dml"))")
        #expect(r.rows.first?.first == "beta")

        // Clearing a cell to empty stores an empty string, NOT NULL
        _ = try await engine.query(SQLBuilder.update(alias: alias, database: WEnv.db, table: "w_dml",
                                                     column: "name", newValue: "",
                                                     primaryKey: [(column: "id", value: "1")]))
        r = try await engine.query("SELECT name FROM \(SQLBuilder.duckTable(alias: alias, database: WEnv.db, table: "w_dml"))")
        #expect(r.rows.first?.first == "")

        // Explicit NULL (the "Set to NULL" action) writes a real NULL
        _ = try await engine.query(SQLBuilder.update(alias: alias, database: WEnv.db, table: "w_dml",
                                                     column: "name", newValue: nil,
                                                     primaryKey: [(column: "id", value: "1")]))
        r = try await engine.query("SELECT name FROM \(SQLBuilder.duckTable(alias: alias, database: WEnv.db, table: "w_dml"))")
        #expect(r.rows.first?.first == "NULL")

        // ContentPanel.deleteSelectedRows
        _ = try await engine.query(SQLBuilder.delete(alias: alias, database: WEnv.db, table: "w_dml",
                                                     primaryKey: [(column: "id", value: "1")]))
        r = try await engine.query("SELECT COUNT(*) FROM \(SQLBuilder.duckTable(alias: alias, database: WEnv.db, table: "w_dml"))")
        #expect(r.rows.first?.first == "0")
    }

    @Test("values containing quotes survive an insert")
    func contentPanelQuoting() async throws {
        let alias = "w2"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_quote", "`id` INT NOT NULL, `name` VARCHAR(50), PRIMARY KEY (`id`)")

        _ = try await engine.query(SQLBuilder.insert(alias: alias, database: WEnv.db, table: "w_quote",
                                                     values: ["id": "1", "name": "O'Brien"]))
        let r = try await engine.query("SELECT name FROM \(SQLBuilder.duckTable(alias: alias, database: WEnv.db, table: "w_quote"))")
        #expect(r.rows.first?.first == "O'Brien")
    }

    @Test("a composite primary key identifies the right row")
    func contentPanelCompositeKey() async throws {
        let alias = "w3"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_comp",
                          "`order_id` INT NOT NULL, `line_no` INT NOT NULL, `qty` INT, PRIMARY KEY (`order_id`, `line_no`)")

        for line in ["1", "2"] {
            _ = try await engine.query(SQLBuilder.insert(alias: alias, database: WEnv.db, table: "w_comp",
                                                         values: ["order_id": "1", "line_no": line, "qty": "10"]))
        }
        _ = try await engine.query(SQLBuilder.update(alias: alias, database: WEnv.db, table: "w_comp",
                                                     column: "qty", newValue: "99",
                                                     primaryKey: [(column: "order_id", value: "1"),
                                                                  (column: "line_no", value: "2")]))
        let r = try await engine.query("""
            SELECT line_no, qty FROM \(SQLBuilder.duckTable(alias: alias, database: WEnv.db, table: "w_comp")) ORDER BY line_no
            """)
        #expect(r.rows.count == 2)
        #expect(r.rows[0][1] == "10")   // line 1 untouched
        #expect(r.rows[1][1] == "99")   // line 2 updated
    }

    // MARK: - StructurePanel

    @Test("every ALTER shape StructurePanel generates is accepted by the server")
    func structurePanelAlters() async throws {
        let alias = "w4"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_alter",
                          "`id` INT NOT NULL, `note` varchar(10) NULL, `gone` varchar(10) NULL, PRIMARY KEY (`id`)")

        let original = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_alter")
        let noteCol = try #require(original.first { $0.name == "note" })

        // Widen `note`, rename nothing, add one column, drop one column, add an index.
        var widened = ColumnEdit(from: noteCol)
        widened.length = "99"
        var added = ColumnEdit(from: noteCol)
        added.originalName = nil
        added.name = "added"
        let newIndex = IndexEdit(originalName: nil, name: "idx_note", indexType: "INDEX", columns: ["note"])

        let stmts = SQLBuilder.alterStatements(
            database: WEnv.db, table: "w_alter",
            columnEdits: [widened, added], originalColumns: original,
            deletedColumnNames: ["gone"], indexEdits: [newIndex], deletedIndexNames: []
        )
        #expect(stmts.count == 4)
        for sql in stmts {
            try await engine.mysqlExecute(alias: alias, sql: sql)
        }

        let names = try await columnNames(engine, alias, "w_alter")
        #expect(names.contains("added"))
        #expect(!names.contains("gone"))
        let idx = try await engine.fetchIndexes(alias: alias, database: WEnv.db, table: "w_alter")
        #expect(idx.map(\.name).contains("idx_note"))
    }

    @Test("renaming a column applies as CHANGE")
    func structurePanelRename() async throws {
        let alias = "w5"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_ren", "`id` INT NOT NULL, `old_name` varchar(10) NULL, PRIMARY KEY (`id`)")

        let original = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_ren")
        var renamed = ColumnEdit(from: try #require(original.first { $0.name == "old_name" }))
        renamed.name = "new_name"

        for sql in SQLBuilder.alterStatements(database: WEnv.db, table: "w_ren",
                                              columnEdits: [renamed], originalColumns: original,
                                              deletedColumnNames: [], indexEdits: [], deletedIndexNames: []) {
            try await engine.mysqlExecute(alias: alias, sql: sql)
        }

        let names = try await columnNames(engine, alias, "w_ren")
        #expect(names.contains("new_name"))
        #expect(!names.contains("old_name"))
    }

    @Test("dropping an index")
    func structurePanelDropIndex() async throws {
        let alias = "w6"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_dropidx",
                          "`id` INT NOT NULL, `name` varchar(20) NULL, PRIMARY KEY (`id`), KEY `idx_name` (`name`)")

        for sql in SQLBuilder.alterStatements(database: WEnv.db, table: "w_dropidx",
                                              columnEdits: [], originalColumns: [],
                                              deletedColumnNames: [], indexEdits: [],
                                              deletedIndexNames: ["idx_name"]) {
            try await engine.mysqlExecute(alias: alias, sql: sql)
        }
        let idx = try await engine.fetchIndexes(alias: alias, database: WEnv.db, table: "w_dropidx")
        #expect(!idx.map(\.name).contains("idx_name"))
    }

    @Test("schema changes are visible to the metadata connection right after a save")
    func alterIsVisibleToMetadataConnection() async throws {
        let alias = "w11"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_visible", "`id` INT NOT NULL, `note` varchar(10) NULL, PRIMARY KEY (`id`)")

        // Reading first opens a transaction on the metadata connection. The panels
        // always do this — the Structure panel loads before you can edit anything.
        let before = try await columnNames(engine, alias, "w_visible")
        #expect(before.sorted() == ["id", "note"])

        // DDL goes out on the user connection, exactly as saveChanges() does.
        try await engine.mysqlExecute(alias: alias,
            sql: "ALTER TABLE \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_visible")) ADD COLUMN `added` varchar(10) NULL")

        // …and StructurePanel.saveChanges() immediately calls loadAll().
        let after = try await columnNames(engine, alias, "w_visible")
        #expect(after.sorted() == ["added", "id", "note"])
    }

    @Test("editing a NOT NULL column that has no default")
    func alterNotNullColumnWithoutDefault() async throws {
        let alias = "w12"
        let engine = try await makeEngine(alias)
        // Shape taken from a real production table: NOT NULL, no DEFAULT clause.
        // SHOW FULL COLUMNS reports Default as SQL NULL for these, which reaches
        // ColumnInfo as the string "NULL" — it must not become "DEFAULT NULL".
        try await fixture(engine, alias, "w_notnull",
                          "`id` int(11) NOT NULL AUTO_INCREMENT, `IATA` varchar(3) NOT NULL, PRIMARY KEY (`id`)")

        let original = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_notnull")
        let iata = try #require(original.first { $0.name == "IATA" })
        #expect(!iata.nullable)
        #expect(iata.defaultValue == "NULL", "precondition: no default surfaces as the string NULL")

        var widened = ColumnEdit(from: iata)
        widened.length = "4"

        let stmts = SQLBuilder.alterStatements(database: WEnv.db, table: "w_notnull",
                                               columnEdits: [widened], originalColumns: original,
                                               deletedColumnNames: [], indexEdits: [], deletedIndexNames: [])
        #expect(stmts.count == 1)
        for sql in stmts {
            try await engine.mysqlExecute(alias: alias, sql: sql)
        }

        let after = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_notnull")
        let updated = try #require(after.first { $0.name == "IATA" })
        #expect(updated.dataType.lowercased() == "varchar(4)")
    }

    @Test("an AUTO_INCREMENT column keeps its extra and stays valid")
    func alterAutoIncrementColumn() async throws {
        let alias = "w13"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_autoinc",
                          "`id` int(11) NOT NULL AUTO_INCREMENT, `label` varchar(10) NULL, PRIMARY KEY (`id`)")

        let original = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_autoinc")
        let id = try #require(original.first { $0.name == "id" })
        #expect(id.extra.lowercased().contains("auto_increment"))

        var widened = ColumnEdit(from: id)
        widened.baseType = "BIGINT"
        widened.length = "20"

        for sql in SQLBuilder.alterStatements(database: WEnv.db, table: "w_autoinc",
                                              columnEdits: [widened], originalColumns: original,
                                              deletedColumnNames: [], indexEdits: [], deletedIndexNames: []) {
            try await engine.mysqlExecute(alias: alias, sql: sql)
        }

        let after = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_autoinc")
        let updated = try #require(after.first { $0.name == "id" })
        #expect(updated.dataType.lowercased().hasPrefix("bigint"))
        #expect(updated.extra.lowercased().contains("auto_increment"))
    }

    // MySQL 8 reports a DEFAULT CURRENT_TIMESTAMP column's Extra as DEFAULT_GENERATED and
    // MariaDB 10.2+ its default as current_timestamp(): server metadata, not DDL. Copied
    // into the ALTER, Structure's save failed on every created_at-style column.
    @Test("a timestamp column with CURRENT_TIMESTAMP and ON UPDATE keeps both through a Structure save")
    func alterTimestampDefaults() async throws {
        let alias = "w16"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_stamps", """
            `id` int NOT NULL, `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (`id`)
            """)
        let original = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_stamps")
        var edits: [ColumnEdit] = []
        for name in ["created", "updated"] {
            var edit = ColumnEdit(from: try #require(original.first { $0.name == name }))
            edit.comment = "\(name) note"
            edits.append(edit)
        }
        for sql in SQLBuilder.alterStatements(database: WEnv.db, table: "w_stamps", columnEdits: edits,
                                              originalColumns: original, deletedColumnNames: [],
                                              indexEdits: [], deletedIndexNames: []) {
            try await engine.mysqlExecute(alias: alias, sql: sql)
        }
        let after = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_stamps")
        let created = try #require(after.first { $0.name == "created" })
        let updated = try #require(after.first { $0.name == "updated" })
        #expect(created.comment == "created note" && updated.comment == "updated note")
        #expect(created.defaultValue.lowercased().hasPrefix("current_timestamp"), "\(created.defaultValue)")
        #expect(updated.extra.lowercased().contains("on update current_timestamp"), "\(updated.extra)")
    }

    // MARK: - RelationsPanel

    @Test("add and drop a foreign key")
    func relationsPanelLifecycle() async throws {
        let alias = "w7"
        let engine = try await makeEngine(alias)
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_child"))")
        try await fixture(engine, alias, "w_parent", "`id` INT NOT NULL, PRIMARY KEY (`id`)")
        try await fixture(engine, alias, "w_child",
                          "`id` INT NOT NULL, `parent_id` INT NOT NULL, PRIMARY KEY (`id`), KEY (`parent_id`)")

        let name = "fk_w_child_parent_id"
        let addSQL = """
            ALTER TABLE \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_child")) \
            ADD CONSTRAINT \(SQLBuilder.mysqlIdent(name)) FOREIGN KEY (\(SQLBuilder.mysqlIdent("parent_id"))) \
            REFERENCES \(SQLBuilder.mysqlIdent("w_parent")) (\(SQLBuilder.mysqlIdent("id"))) \
            ON DELETE CASCADE ON UPDATE RESTRICT
            """
        try await engine.mysqlExecute(alias: alias, sql: addSQL)

        var rels = try await engine.fetchRelations(alias: alias, database: WEnv.db, table: "w_child")
        #expect(rels.contains { $0[0] == name })

        try await engine.mysqlExecute(alias: alias, sql: "ALTER TABLE \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_child")) DROP FOREIGN KEY \(SQLBuilder.mysqlIdent(name))")
        rels = try await engine.fetchRelations(alias: alias, database: WEnv.db, table: "w_child")
        #expect(!rels.contains { $0[0] == name })

        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_child"))")
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_parent"))")
    }

    // MARK: - TriggersPanel

    @Test("create and drop a trigger")
    func triggersPanelLifecycle() async throws {
        let alias = "w8"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_trig", "`id` INT NOT NULL, `total` INT, PRIMARY KEY (`id`)")

        // What CreateTriggerSheet.generatedSQL produces, database-qualified.
        let create = "CREATE TRIGGER \(SQLBuilder.mysqlIdent("trg_w")) BEFORE INSERT "
            + "ON \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_trig")) "
            + "FOR EACH ROW SET NEW.total = IFNULL(NEW.total, 0)"
        try await engine.mysqlExecute(alias: alias, sql: create)

        var trigs = try await engine.fetchTriggers(alias: alias, database: WEnv.db, table: "w_trig")
        #expect(trigs.contains { $0[0] == "trg_w" })

        try await engine.mysqlExecute(alias: alias, sql: "DROP TRIGGER IF EXISTS \(SQLBuilder.mysqlTable(database: WEnv.db, table: "trg_w"))")
        trigs = try await engine.fetchTriggers(alias: alias, database: WEnv.db, table: "w_trig")
        #expect(!trigs.contains { $0[0] == "trg_w" })
    }

    // MARK: - CreateTableSheet

    @Test("create a table from the sheet's generated DDL")
    func createTableSheet() async throws {
        let alias = "w9"
        let engine = try await makeEngine(alias)
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_created"))")

        let ddl = """
            CREATE TABLE \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_created")) (
              `id` INT NOT NULL AUTO_INCREMENT,
              `label` VARCHAR(255) NULL DEFAULT 'it''s fine',
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        try await engine.mysqlExecute(alias: alias, sql: ddl)

        #expect(try await columnNames(engine, alias, "w_created").sorted() == ["id", "label"])
        try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_created"))")
    }

    // MARK: - Regression guard

    @Test("mysql_query() must never be used for DDL — it is fatal to the connection")
    func mysqlQueryOnDDLIsFatal() async throws {
        let alias = "w10"
        let engine = try await makeEngine(alias)

        // Documents why mysqlExecute exists. mysql_query() is a table function that must
        // learn its result types up front; a DDL statement returns no columns, so the
        // scanner rejects it. On DuckDB 1.5.x this is a clean error (no longer the old
        // FATAL that invalidated the handle) — the engine stays usable afterward.
        await #expect(throws: (any Error).self) {
            _ = try await engine.schemaQuery("SELECT * FROM mysql_query('\(alias)', 'DROP TABLE IF EXISTS `\(WEnv.db)`.`w_never`')")
        }
        // The engine survives the error — ordinary queries still work.
        let r = try await engine.query("SELECT 1 AS ok")
        #expect(r.rows.first?.first == "1")
    }

    @Test("rename and duplicate a table, with and without its rows")
    func renameAndDuplicate() async throws {
        let alias = "w9"
        let engine = try await makeEngine(alias)
        try await fixture(engine, alias, "w_rd", "`id` INT NOT NULL, `name` VARCHAR(20), PRIMARY KEY (`id`)")
        for t in ["w_rd_renamed", "w_rd_full", "w_rd_empty"] {
            try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: WEnv.db, table: t))")
        }
        try await engine.mysqlExecute(alias: alias, sql: "INSERT INTO \(SQLBuilder.mysqlTable(database: WEnv.db, table: "w_rd")) VALUES (1, 'a'), (2, 'b')")

        try await engine.executeDDL(alias: alias, sql: SQLBuilder.renameTable(engine: .mysql, database: WEnv.db, from: "w_rd", to: "w_rd_renamed"))
        for sql in SQLBuilder.duplicateTable(engine: .mysql, database: WEnv.db, from: "w_rd_renamed", to: "w_rd_full", withRows: true) {
            try await engine.executeDDL(alias: alias, sql: sql)
        }
        for sql in SQLBuilder.duplicateTable(engine: .mysql, database: WEnv.db, from: "w_rd_renamed", to: "w_rd_empty", withRows: false) {
            try await engine.executeDDL(alias: alias, sql: sql)
        }
        let names = try await engine.fetchTables(alias: alias, database: WEnv.db).map(\.name)
        #expect(names.contains("w_rd_renamed") && !names.contains("w_rd"))
        func count(_ t: String) async throws -> String? {
            try await engine.serverPassthroughQuery(alias: alias, serverSQL: "SELECT COUNT(*) FROM \(SQLBuilder.mysqlTable(database: WEnv.db, table: t))").rows.first?.first
        }
        #expect(try await count("w_rd_full") == "2")
        #expect(try await count("w_rd_empty") == "0")
        #expect(try await columnNames(engine, alias, "w_rd_empty") == ["id", "name"])
        let pk = try await engine.fetchColumns(alias: alias, database: WEnv.db, table: "w_rd_empty").filter(\.isPrimaryKey).map(\.name)
        #expect(pk == ["id"])
        for t in ["w_rd_renamed", "w_rd_full", "w_rd_empty"] {
            try await engine.mysqlExecute(alias: alias, sql: "DROP TABLE \(SQLBuilder.mysqlTable(database: WEnv.db, table: t))")
        }
    }
}
