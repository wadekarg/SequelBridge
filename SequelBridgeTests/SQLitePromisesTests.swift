//
//  SQLitePromisesTests.swift
//  SequelBridgeTests
//
//  What guide/FEATURES.md promises for a SQLite file, run against one: Create Table,
//  Structure's add/rename/drop column and add/drop index, Content's pages, filter, sort,
//  insert and delete, Export database as SQL, and triggers. Checking found that Create
//  Table sent MySQL's DDL (backticks, ENGINE=), Structure refused every save, and that
//  DuckDB, writing a SQLite file's schema itself, turns DATE into VARCHAR and an INTEGER
//  key into BIGINT, which no longer numbers rows. So the app's DDL on a SQLite file runs
//  in SQLite itself, in SQLite's own SQL.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("SQLite file: what the guide promises", .serialized)
struct SQLitePromisesTests {
    struct File { let url: URL; let alias: String; let engine: QueryEngine }

    /// A new SQLite file made with `setup`, attached under `alias`.
    func open(_ setup: String, alias: String) async throws -> File {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-lite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(alias).sqlite")
        _ = sqlite(url, setup)
        var c = Connection(name: alias, alias: alias, host: "", port: 0, username: "", database: url.path)
        c.engine = .sqlite
        let q = try QueryEngine()
        try await q.attach(c, password: "")
        return File(url: url, alias: alias, engine: q)
    }

    /// What sqlite3 itself prints for `sql` against the file.
    @discardableResult
    func sqlite(_ url: URL, _ sql: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [url.path, sql]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func column(_ name: String, _ type: String, length: String = "") -> NewColumnDef {
        var c = NewColumnDef()
        c.name = name; c.baseType = type; c.length = length
        return c
    }

    @Test("Create Table makes the table in the file: the key numbers new rows, and the types are the ones picked")
    func createTable() async throws {
        let f = try await open("CREATE TABLE seed (id INTEGER PRIMARY KEY);", alias: "lc1")
        var id = column("id", "INT"); id.isPrimaryKey = true; id.autoIncrement = true; id.nullable = false
        var note = column("note", "VARCHAR", length: "40"); note.defaultValue = "x"
        let body = column("body", "MEDIUMTEXT")
        let kind = column("kind", "ENUM")
        let day = column("day", "DATE")
        let sql = SQLBuilder.createTableSQL(engine: .sqlite, database: "main", table: "made",
                                            columns: [id, note, body, kind, day], storageEngine: "InnoDB", charset: "utf8mb4")
        try await f.engine.executeDDL(alias: "lc1", sql: sql)
        // MySQL's own types (MEDIUMTEXT, ENUM) become SQLite's TEXT; the rest stay as picked.
        #expect(sqlite(f.url, "SELECT group_concat(name || ' ' || type, ', ') FROM pragma_table_info('made')")
                == "id INTEGER, note VARCHAR(40), body TEXT, kind TEXT, day DATE")
        _ = try await f.engine.query(#"INSERT INTO "lc1"."main"."made" (body) VALUES ('b')"#)
        #expect(sqlite(f.url, "SELECT id || ':' || note || ':' || body FROM made") == "1:x:b", "the key wasn't numbered or the default not kept")
        let shown = try await f.engine.fetchColumns(alias: "lc1", database: "main", table: "made")
        #expect(shown.map(\.dataType) == ["INTEGER", "VARCHAR(40)", "TEXT", "TEXT", "DATE"], "Structure shows \(shown.map(\.dataType))")
    }

    @Test("Structure adds, renames and drops a column, and adds and drops an index, in the file")
    func structure() async throws {
        let f = try await open("CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT); INSERT INTO t VALUES (1, 'a');", alias: "lc2")
        let original = try await f.engine.fetchColumns(alias: "lc2", database: "main", table: "t")
        var renamed = ColumnEdit(from: try #require(original.first { $0.name == "note" })); renamed.name = "memo"
        var added = ColumnEdit(); added.name = "extra"; added.baseType = "VARCHAR"; added.length = "12"
        let plan = SQLBuilder.sqliteAlterStatements(table: "t", columnEdits: [renamed, added],
                                                    originalColumns: original, deletedColumnNames: [],
                                                    indexEdits: [IndexEdit(originalName: nil, name: "t_memo", indexType: "INDEX", columns: ["memo"])],
                                                    deletedIndexNames: [])
        #expect(plan.refusal == nil, "\(plan.refusal ?? "")")
        for sql in plan.statements { try await f.engine.executeDDL(alias: "lc2", sql: sql) }
        #expect(sqlite(f.url, "SELECT group_concat(name || ' ' || type, ', ') FROM pragma_table_info('t')")
                == "id INTEGER, memo TEXT, extra VARCHAR(12)")
        #expect(sqlite(f.url, "SELECT memo FROM t") == "a", "the rename lost the value")
        #expect(sqlite(f.url, "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 't_memo'") == "t_memo")

        let now = try await f.engine.fetchColumns(alias: "lc2", database: "main", table: "t")
        let drop = SQLBuilder.sqliteAlterStatements(table: "t", columnEdits: now.map(ColumnEdit.init(from:)),
                                                    originalColumns: now, deletedColumnNames: ["extra"],
                                                    indexEdits: [], deletedIndexNames: ["t_memo"])
        #expect(drop.refusal == nil, "\(drop.refusal ?? "")")
        // The index goes first: SQLite won't drop a column an index still uses.
        for sql in drop.statements { try await f.engine.executeDDL(alias: "lc2", sql: sql) }
        #expect(sqlite(f.url, "SELECT group_concat(name) FROM pragma_table_info('t')") == "id,memo")
        #expect(sqlite(f.url, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 't_memo'") == "0")
    }

    @Test("a type, NULL or default change is refused, saying why: SQLite would need the table rebuilt")
    func structureRefusal() {
        let note = ColumnInfo(id: "t.note", name: "note", dataType: "TEXT", nullable: true, isPrimaryKey: false)
        var retyped = ColumnEdit(from: note); retyped.baseType = "INTEGER"
        let plan = SQLBuilder.sqliteAlterStatements(table: "t", columnEdits: [retyped], originalColumns: [note],
                                                    deletedColumnNames: [], indexEdits: [], deletedIndexNames: [])
        #expect(plan.statements.isEmpty)
        #expect(plan.refusal?.contains("note") == true && plan.refusal?.contains("SQLite") == true, "\(plan.refusal ?? "nil")")
    }

    @Test("Content reads a page, filtered and sorted, and inserts and deletes rows in the file")
    func content() async throws {
        let f = try await open("CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT); INSERT INTO t VALUES (1,'50%'),(2,'a_b'),(3,'axb'),(4,NULL);",
                               alias: "lc3")
        let underscore = try #require(ContentFilter.condition(column: "note", op: .contains, value: "_", dialect: .standard))
        let page = try await f.engine.query(#"SELECT * FROM "lc3"."main"."t" WHERE \#(underscore) ORDER BY "id" DESC LIMIT 2 OFFSET 0"#,
                                            lane: .content)
        #expect(page.rows.map { $0[0] } == ["2"], "an underscore matched as a wildcard")
        try await f.engine.executeWrite(SQLBuilder.insert(alias: "lc3", database: "main", table: "t", values: ["id": "5", "note": "new"]),
                                        alias: "lc3")
        try await f.engine.executeWrite(SQLBuilder.delete(alias: "lc3", database: "main", table: "t", primaryKey: [(column: "id", value: "1")]),
                                        alias: "lc3")
        #expect(sqlite(f.url, "SELECT group_concat(id) FROM t") == "2,3,4,5")
    }

    @Test("Content: a foreign key's cell leads to the row it points at")
    func followForeignKey() async throws {
        let f = try await open("""
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers (id));
            INSERT INTO customers VALUES (1, 'Ada'), (2, 'Alan'); INSERT INTO orders VALUES (10, 2);
            """, alias: "lc7")
        let targets = ForeignKeyFollow.targets(try await f.engine.fetchRelations(alias: "lc7", database: "main", table: "orders"))
        let target = try #require(targets["customer_id"], "\(targets)")
        #expect(target.table == "customers")
        let condition = try #require(ForeignKeyFollow.condition(target, values: ["customer_id": "2"],
                                                                dialect: ContentFilter.dialect(engine: .sqlite, passthrough: false)))
        let rows = try await f.engine.query(#"SELECT name FROM "lc7"."main"."customers" WHERE \#(condition)"#, lane: .content).rows
        #expect(rows == [["Alan"]], "\(condition) → \(rows)")
    }

    @Test("Export database as SQL dumps the file's tables and rows")
    func export() async throws {
        let f = try await open("CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT); INSERT INTO t VALUES (1, 'it''s');", alias: "lc4")
        let dump = try await f.engine.sqlDumpDatabase(alias: "lc4", database: "main")
        #expect(dump.text.contains("CREATE TABLE"), "\(dump.text.prefix(300))")
        #expect(dump.text.contains("'it''s'") || dump.text.contains(#"'it\'s'"#), "\(dump.text.prefix(500))")
    }

    @Test("a trigger is added, fires, is listed and is dropped, in SQLite's own SQL")
    func triggers() async throws {
        let f = try await open("CREATE TABLE t (id INTEGER PRIMARY KEY); CREATE TABLE log (msg TEXT);", alias: "lc5")
        // The sheet's body may be one statement, or a BEGIN … END block as typed.
        let single = SQLBuilder.createTrigger(engine: .sqlite, database: "main", table: "t", name: "t_ins",
                                              timing: "AFTER", event: "INSERT", body: "INSERT INTO log VALUES ('added ' || NEW.id)")
        let block = SQLBuilder.createTrigger(engine: .sqlite, database: "main", table: "t", name: "t_del",
                                             timing: "BEFORE", event: "DELETE", body: "BEGIN\n  INSERT INTO log VALUES ('gone ' || OLD.id);\nEND")
        try await f.engine.executeDDL(alias: "lc5", sql: single)
        try await f.engine.executeDDL(alias: "lc5", sql: block)
        let rows = try await f.engine.fetchTriggers(alias: "lc5", database: "main", table: "t")
        #expect(Set(rows.compactMap(\.first)) == ["t_ins", "t_del"], "\(rows)")
        // Name, timing, event, as the Triggers tab reads them; t_del's body has an INSERT.
        #expect(rows.first { $0.first == "t_ins" }.map { Array($0.prefix(3)) } == ["t_ins", "AFTER", "INSERT"], "\(rows)")
        #expect(rows.first { $0.first == "t_del" }.map { Array($0.prefix(3)) } == ["t_del", "BEFORE", "DELETE"], "\(rows)")
        _ = try await f.engine.query(#"INSERT INTO "lc5"."main"."t" (id) VALUES (7)"#)
        _ = try await f.engine.query(#"DELETE FROM "lc5"."main"."t" WHERE id = 7"#)
        #expect(sqlite(f.url, "SELECT group_concat(msg, ', ') FROM log") == "added 7, gone 7")
        try await f.engine.executeDDL(alias: "lc5", sql: SQLBuilder.dropTrigger(engine: .sqlite, database: "main", table: "t", name: "t_ins"))
        #expect(sqlite(f.url, "SELECT group_concat(name) FROM sqlite_master WHERE type = 'trigger'") == "t_del")

        #expect(TriggerEditing.canCreate(on: .sqlite) && TriggerEditing.canDrop(on: .sqlite))
        #expect(!TriggerEditing.canCreate(on: .postgres) && TriggerEditing.canDrop(on: .postgres))
        #expect(TriggerEditing.reason(.postgres)?.contains("trigger function") == true)
        #expect(!TriggerEditing.canCreate(on: .clickhouse) && !TriggerEditing.canDrop(on: .clickhouse))
    }

    @Test("a change while a Query-tab transaction holds the file says the file is busy, and what to do")
    func busy() async throws {
        let f = try await open("CREATE TABLE t (id INTEGER PRIMARY KEY);", alias: "lc6")
        f.engine.sqliteBusyTimeout = 0.3
        _ = try await f.engine.query("BEGIN TRANSACTION")
        _ = try await f.engine.query(#"INSERT INTO "lc6"."main"."t" VALUES (1)"#)
        var reason = ""
        do { try await f.engine.executeDDL(alias: "lc6", sql: #"ALTER TABLE "t" ADD COLUMN "c" TEXT"#) }
        catch { reason = QueryEngine.extractReason(from: error) }
        _ = try await f.engine.query("ROLLBACK")
        #expect(reason.contains("busy") && reason.contains("COMMIT"), "\(reason)")
        try await f.engine.executeDDL(alias: "lc6", sql: #"ALTER TABLE "t" ADD COLUMN "c" TEXT"#)
        #expect(sqlite(f.url, "SELECT group_concat(name) FROM pragma_table_info('t')") == "id,c")
    }
}
