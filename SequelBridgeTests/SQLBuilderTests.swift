//
//  SQLBuilderTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("SQL identifier quoting")
struct SQLQuotingTests {

    @Test("DuckDB identifiers use double quotes")
    func duckIdent() {
        #expect(SQLBuilder.duckIdent("name") == "\"name\"")
    }

    @Test("DuckDB identifiers escape embedded double quotes")
    func duckIdentEscaping() {
        #expect(SQLBuilder.duckIdent("we\"ird") == "\"we\"\"ird\"")
    }

    @Test("MySQL identifiers use backticks")
    func mysqlIdent() {
        #expect(SQLBuilder.mysqlIdent("name") == "`name`")
    }

    @Test("MySQL identifiers escape embedded backticks")
    func mysqlIdentEscaping() {
        #expect(SQLBuilder.mysqlIdent("we`ird") == "`we``ird`")
    }

    @Test("string literals are single quoted with doubled quotes")
    func literals() {
        #expect(SQLBuilder.literal("O'Brien") == "'O''Brien'")
    }

    @Test("stripAliasPrefix removes the alias-dot prefix, case-insensitively, honoring quotes")
    func stripAlias() {
        #expect(SQLBuilder.stripAliasPrefix("SELECT * FROM maria10.customers", alias: "maria10")
                == "SELECT * FROM customers")
        #expect(SQLBuilder.stripAliasPrefix("select MARIA10.a, maria10.b from Maria10.t", alias: "maria10")
                == "select a, b from t")
        #expect(SQLBuilder.stripAliasPrefix("SELECT * FROM pg16.x", alias: "maria10")
                == "SELECT * FROM pg16.x")                                    // other alias untouched
        #expect(SQLBuilder.stripAliasPrefix("SELECT * FROM maria10x.t", alias: "maria10")
                == "SELECT * FROM maria10x.t")                                // not a word boundary
        #expect(SQLBuilder.stripAliasPrefix("SELECT 'maria10.x' FROM maria10.t", alias: "maria10")
                == "SELECT 'maria10.x' FROM t")                               // string literal left alone
    }

    @Test("clickhouseSoleServerSQL turns alias.table into the server's database.table, quotes honored")
    func clickhouseSoleServer() {
        // A statement of a multi-server workspace that names only the ClickHouse server
        // runs on its native client, where the alias means nothing: the alias prefix
        // becomes the database the sidebar has picked for that server.
        #expect(SQLBuilder.clickhouseSoleServerSQL("SELECT day FROM analytics.daily_metrics WHERE event = 'analytics.x'",
                                                   alias: "analytics", database: "analyticsdemo")
                == "SELECT day FROM `analyticsdemo`.daily_metrics WHERE event = 'analytics.x'")
        #expect(SQLBuilder.clickhouseSoleServerSQL("select Analytics.a, analytics.b from ANALYTICS.t", alias: "analytics", database: "d")
                == "select `d`.a, `d`.b from `d`.t")
        #expect(SQLBuilder.clickhouseSoleServerSQL("SELECT * FROM analytics.t", alias: "analytics", database: "")
                == "SELECT * FROM t")                                        // no database known: the server's default
        #expect(SQLBuilder.clickhouseSoleServerSQL("SELECT * FROM shop.t", alias: "analytics", database: "d")
                == "SELECT * FROM shop.t")                                   // other alias untouched
        // The explicit three-part form the note documents, alias.database.table: only the
        // alias goes, the database written by the user stays.
        #expect(SQLBuilder.clickhouseSoleServerSQL("SELECT * FROM analytics.other.t WHERE x = analytics.other.t.x",
                                                   alias: "analytics", database: "d")
                == "SELECT * FROM other.t WHERE x = other.t.x")
        #expect(SQLBuilder.stripAliasPrefix("SELECT * FROM maria10.db.t", alias: "maria10")
                == "SELECT * FROM db.t")                                     // the passthrough form is unchanged
    }

    @Test("orderBy is empty when no column is chosen")
    func orderByNone() {
        #expect(SQLBuilder.orderBy(column: nil, ascending: true) == "")
        #expect(SQLBuilder.orderBy(column: "", ascending: true) == "")
    }

    @Test("orderBy quotes the column and honors direction")
    func orderByDirection() {
        #expect(SQLBuilder.orderBy(column: "created_at", ascending: true) == " ORDER BY \"created_at\" ASC")
        #expect(SQLBuilder.orderBy(column: "created_at", ascending: false) == " ORDER BY \"created_at\" DESC")
    }

    @Test("orderBy escapes an embedded double quote in the column name")
    func orderByEscaping() {
        #expect(SQLBuilder.orderBy(column: "we\"ird", ascending: true) == " ORDER BY \"we\"\"ird\" ASC")
    }

    @Test("dropTable qualifies per engine")
    func dropTablePerEngine() {
        #expect(SQLBuilder.dropTable(engine: .mysql, database: "shop", table: "orders")
                == "DROP TABLE `shop`.`orders`")
        #expect(SQLBuilder.dropTable(engine: .postgres, database: "public", table: "orders")
                == "DROP TABLE \"public\".\"orders\"")
    }

    @Test("truncateTable qualifies per engine")
    func truncateTablePerEngine() {
        #expect(SQLBuilder.truncateTable(engine: .mysql, database: "shop", table: "orders")
                == "TRUNCATE TABLE `shop`.`orders`")
        #expect(SQLBuilder.truncateTable(engine: .postgres, database: "public", table: "orders")
                == "TRUNCATE TABLE \"public\".\"orders\"")
    }

    @Test("dumpInsertStatements uses the null mask, not the literal string")
    func dumpNullMask() {
        let out = SQLBuilder.dumpInsertStatements(
            table: "t", columns: ["id", "note"],
            rows: [["1", "a"], ["2", "NULL"]],           // "NULL" here is a real string value...
            nullMask: [[false, false], [false, true]])   // ...but the mask marks row 2 as SQL NULL
        #expect(out.count == 1)
        #expect(out[0] == "INSERT INTO `t` (`id`, `note`) VALUES\n('1', 'a'),\n('2', NULL);")
    }

    @Test("dumpInsertStatements splits into batches")
    func dumpBatches() {
        let rows = (1...5).map { ["\($0)"] }
        let mask = rows.map { _ in [false] }
        let out = SQLBuilder.dumpInsertStatements(table: "t", columns: ["id"], rows: rows, nullMask: mask, batchSize: 2)
        #expect(out.count == 3)                                   // 2 + 2 + 1
        #expect(out[0] == "INSERT INTO `t` (`id`) VALUES\n('1'),\n('2');")
        #expect(out[2] == "INSERT INTO `t` (`id`) VALUES\n('5');")
    }

    @Test("dumpInsertStatements escapes quotes and is empty for no rows")
    func dumpEscaping() {
        #expect(SQLBuilder.dumpInsertStatements(table: "t", columns: ["c"], rows: [], nullMask: []).isEmpty)
        let out = SQLBuilder.dumpInsertStatements(table: "t", columns: ["c"], rows: [["O'Brien"]], nullMask: [[false]])
        #expect(out[0] == "INSERT INTO `t` (`c`) VALUES\n('O''Brien');")
    }

    @Test("insertRows quotes per engine and maps empty field to NULL")
    func insertRowsPerEngine() {
        let cols = ["id", "note"]
        let my = SQLBuilder.insertRows(engine: .mysql, database: "d", table: "t",
                                       columns: cols, rows: [["1", "a"], ["2", ""]], batchSize: 100)
        #expect(my.count == 1)
        #expect(my[0] == "INSERT INTO `d`.`t` (`id`, `note`) VALUES\n('1', 'a'),\n('2', NULL)")
        let pg = SQLBuilder.insertRows(engine: .postgres, database: "public", table: "t",
                                       columns: cols, rows: [["1", "x"]])
        #expect(pg[0] == "INSERT INTO \"public\".\"t\" (\"id\", \"note\") VALUES\n('1', 'x')")
    }

    @Test("insertRows batches and pads short rows to the column count")
    func insertRowsBatchAndPad() {
        let out = SQLBuilder.insertRows(engine: .mysql, database: "d", table: "t",
                                        columns: ["a", "b"], rows: [["1"], ["2"], ["3"]], batchSize: 2)
        #expect(out.count == 2)                              // 2 + 1
        #expect(out[0] == "INSERT INTO `d`.`t` (`a`, `b`) VALUES\n('1', NULL),\n('2', NULL)")
        #expect(out[1] == "INSERT INTO `d`.`t` (`a`, `b`) VALUES\n('3', NULL)")
    }

    @Test("DuckDB table reference is alias-qualified")
    func duckTable() {
        #expect(SQLBuilder.duckTable(alias: "prod", database: "shop", table: "orders")
                == "\"prod\".\"shop\".\"orders\"")
    }

    @Test("MySQL table reference omits the local connection alias")
    func mysqlTable() {
        // The server has no idea what "prod" is — sending it would be a syntax error.
        #expect(SQLBuilder.mysqlTable(database: "shop", table: "orders") == "`shop`.`orders`")
    }
}

@Suite("Content panel DML")
struct ContentDMLTests {

    @Test("INSERT quotes every identifier the DuckDB way")
    func insertQuoting() {
        let sql = SQLBuilder.insert(alias: "prod", database: "shop", table: "orders",
                                    values: ["id": "1", "name": "alpha"])
        #expect(!sql.contains("`"), "backticks are a DuckDB parser error: \(sql)")
        #expect(sql == #"INSERT INTO "prod"."shop"."orders" ("id", "name") VALUES ('1', 'alpha')"#)
    }

    @Test("INSERT passes NULL and CURRENT_TIMESTAMP through unquoted")
    func insertKeywords() {
        let sql = SQLBuilder.insert(alias: "p", database: "d", table: "t",
                                    values: ["a": "NULL", "b": "CURRENT_TIMESTAMP", "c": "text"])
        #expect(sql.contains("VALUES (NULL, CURRENT_TIMESTAMP, 'text')"))
    }

    @Test("INSERT escapes quotes inside values")
    func insertEscaping() {
        let sql = SQLBuilder.insert(alias: "p", database: "d", table: "t", values: ["a": "O'Brien"])
        #expect(sql.contains("VALUES ('O''Brien')"))
    }

    @Test("UPDATE sets one column and matches on the primary key")
    func updateStatement() {
        let sql = SQLBuilder.update(alias: "prod", database: "shop", table: "orders",
                                    column: "status", newValue: "paid",
                                    primaryKey: [(column: "id", value: "7")])
        #expect(!sql.contains("`"))
        #expect(sql == #"UPDATE "prod"."shop"."orders" SET "status" = 'paid' WHERE "id" = '7'"#)
    }

    @Test("UPDATE stores an empty string for an empty value; NULL only when explicit (nil)")
    func updateEmptyVsNull() {
        let empty = SQLBuilder.update(alias: "p", database: "d", table: "t",
                                      column: "note", newValue: "",
                                      primaryKey: [(column: "id", value: "1")])
        #expect(empty.contains(#"SET "note" = ''"#))   // empty string, not NULL
        let null = SQLBuilder.update(alias: "p", database: "d", table: "t",
                                     column: "note", newValue: nil,
                                     primaryKey: [(column: "id", value: "1")])
        #expect(null.contains(#"SET "note" = NULL"#))  // explicit NULL
    }

    @Test("UPDATE matches composite keys with AND")
    func updateCompositeKey() {
        let sql = SQLBuilder.update(alias: "p", database: "d", table: "t",
                                    column: "qty", newValue: "5",
                                    primaryKey: [(column: "order_id", value: "1"),
                                                 (column: "line_no", value: "2")])
        #expect(sql.contains(#"WHERE "order_id" = '1' AND "line_no" = '2'"#))
    }

    @Test("a nil key is matched with IS NULL; a real \"NULL\" string is matched literally")
    func nullKeyMatching() {
        let isNull = SQLBuilder.delete(alias: "p", database: "d", table: "t",
                                       primaryKey: [(column: "id", value: nil)])
        #expect(isNull.contains(#"WHERE "id" IS NULL"#))
        let literal = SQLBuilder.delete(alias: "p", database: "d", table: "t",
                                        primaryKey: [(column: "id", value: "NULL")])
        #expect(literal.contains(#"WHERE "id" = 'NULL'"#))
    }

    @Test("DELETE targets the row by primary key")
    func deleteStatement() {
        let sql = SQLBuilder.delete(alias: "prod", database: "shop", table: "orders",
                                    primaryKey: [(column: "id", value: "7")])
        #expect(!sql.contains("`"))
        #expect(sql == #"DELETE FROM "prod"."shop"."orders" WHERE "id" = '7'"#)
    }
}

@Suite("Structure panel ALTER generation")
struct AlterStatementTests {

    func column(_ name: String, type: String = "VARCHAR", length: String = "50") -> ColumnInfo {
        ColumnInfo(id: "t.\(name)", name: name,
                   dataType: length.isEmpty ? type.lowercased() : "\(type.lowercased())(\(length))",
                   nullable: true, keyType: "", defaultValue: "", extra: "",
                   encoding: "", collation: "", comment: "")
    }

    func edit(from col: ColumnInfo) -> ColumnEdit { ColumnEdit(from: col) }

    @Test("statements are qualified by database only, never by connection alias")
    func noAliasInDDL() {
        var e = edit(from: column("note"))
        e.originalName = nil                       // new column → ADD COLUMN
        let stmts = SQLBuilder.alterStatements(database: "shop", table: "orders",
                                               columnEdits: [e], originalColumns: [],
                                               deletedColumnNames: [], indexEdits: [],
                                               deletedIndexNames: [])
        #expect(stmts.count == 1)
        let sql = try! #require(stmts.first)
        #expect(sql.contains("`shop`.`orders`"))
        #expect(!sql.contains("prod"))
    }

    @Test("ADD COLUMN for a newly added column")
    func addColumn() {
        var e = edit(from: column("note"))
        e.originalName = nil
        let stmts = SQLBuilder.alterStatements(database: "d", table: "t",
                                               columnEdits: [e], originalColumns: [],
                                               deletedColumnNames: [], indexEdits: [],
                                               deletedIndexNames: [])
        #expect(stmts.first?.hasPrefix("ALTER TABLE `d`.`t` ADD COLUMN `note` VARCHAR(50)") == true)
    }

    @Test("MODIFY COLUMN when the type changed but the name did not")
    func modifyColumn() {
        let orig = column("note", length: "50")
        var e = edit(from: orig)
        e.length = "99"
        let stmts = SQLBuilder.alterStatements(database: "d", table: "t",
                                               columnEdits: [e], originalColumns: [orig],
                                               deletedColumnNames: [], indexEdits: [],
                                               deletedIndexNames: [])
        #expect(stmts.first?.contains("MODIFY COLUMN `note` VARCHAR(99)") == true)
    }

    @Test("CHANGE COLUMN when the column was renamed")
    func renameColumn() {
        let orig = column("old_name")
        var e = edit(from: orig)
        e.name = "new_name"
        let stmts = SQLBuilder.alterStatements(database: "d", table: "t",
                                               columnEdits: [e], originalColumns: [orig],
                                               deletedColumnNames: [], indexEdits: [],
                                               deletedIndexNames: [])
        #expect(stmts.first?.contains("CHANGE `old_name` `new_name`") == true)
    }

    @Test("unchanged columns produce no statement")
    func noopColumn() {
        let orig = column("note")
        let stmts = SQLBuilder.alterStatements(database: "d", table: "t",
                                               columnEdits: [edit(from: orig)], originalColumns: [orig],
                                               deletedColumnNames: [], indexEdits: [],
                                               deletedIndexNames: [])
        #expect(stmts.isEmpty)
    }

    @Test("DROP COLUMN for deleted columns")
    func dropColumn() {
        let stmts = SQLBuilder.alterStatements(database: "d", table: "t",
                                               columnEdits: [], originalColumns: [],
                                               deletedColumnNames: ["gone"], indexEdits: [],
                                               deletedIndexNames: [])
        #expect(stmts == ["ALTER TABLE `d`.`t` DROP COLUMN `gone`"])
    }

    @Test("index creation covers PRIMARY KEY, UNIQUE and plain indexes")
    func addIndexes() {
        let pk  = IndexEdit(originalName: nil, name: "PRIMARY", indexType: "PRIMARY KEY", columns: ["id"])
        let uq  = IndexEdit(originalName: nil, name: "uq_email", indexType: "UNIQUE", columns: ["email"])
        let idx = IndexEdit(originalName: nil, name: "idx_pair", indexType: "INDEX", columns: ["a", "b"])
        let stmts = SQLBuilder.alterStatements(database: "d", table: "t",
                                               columnEdits: [], originalColumns: [],
                                               deletedColumnNames: [], indexEdits: [pk, uq, idx],
                                               deletedIndexNames: [])
        #expect(stmts.contains("ALTER TABLE `d`.`t` ADD PRIMARY KEY (`id`)"))
        #expect(stmts.contains("ALTER TABLE `d`.`t` ADD UNIQUE INDEX `uq_email` (`email`)"))
        #expect(stmts.contains("ALTER TABLE `d`.`t` ADD INDEX `idx_pair` (`a`, `b`)"))
    }

    @Test("dropping the primary key uses DROP PRIMARY KEY, not DROP INDEX")
    func dropPrimaryKey() {
        let stmts = SQLBuilder.alterStatements(database: "d", table: "t",
                                               columnEdits: [], originalColumns: [],
                                               deletedColumnNames: [], indexEdits: [],
                                               deletedIndexNames: ["PRIMARY"])
        #expect(stmts == ["ALTER TABLE `d`.`t` DROP PRIMARY KEY"])
    }

    @Test("dropping a named index")
    func dropIndex() {
        let stmts = SQLBuilder.alterStatements(database: "d", table: "t",
                                               columnEdits: [], originalColumns: [],
                                               deletedColumnNames: [], indexEdits: [],
                                               deletedIndexNames: ["idx_name"])
        #expect(stmts == ["DROP INDEX `idx_name` ON `d`.`t`"])
    }

    @Test("column definition carries nullability, default and extra")
    func columnDefinition() {
        var e = edit(from: column("qty", type: "INT", length: ""))
        e.nullable = false
        e.defaultValue = "0"
        e.extra = "auto_increment"
        let def = SQLBuilder.columnDefinition(e)
        #expect(def.contains("INT"))
        #expect(def.contains("NOT NULL"))
        #expect(def.contains("DEFAULT 0"))
        #expect(def.uppercased().contains("AUTO_INCREMENT"))
    }

    /// A column as `SHOW FULL COLUMNS` actually reports it when there is no
    /// collation and no default: SQL NULL, which reaches ColumnInfo as "NULL".
    func absentMetadataColumn(nullable: Bool) -> ColumnInfo {
        ColumnInfo(id: "t.c", name: "c", dataType: "bigint(20)", nullable: nullable,
                   keyType: "PRI", defaultValue: "NULL", extra: "auto_increment",
                   encoding: "NULL", collation: "NULL", comment: "")
    }

    @Test("a column with no collation gets no CHARACTER SET or COLLATE clause")
    func absentCollationOmitted() {
        let def = SQLBuilder.columnDefinition(ColumnEdit(from: absentMetadataColumn(nullable: false)))
        #expect(!def.uppercased().contains("CHARACTER SET"), "got: \(def)")
        #expect(!def.uppercased().contains("COLLATE"), "got: \(def)")
    }

    @Test("a NOT NULL column with no default gets no DEFAULT clause")
    func notNullWithoutDefault() {
        let def = SQLBuilder.columnDefinition(ColumnEdit(from: absentMetadataColumn(nullable: false)))
        // "NOT NULL DEFAULT NULL" is rejected by the server as an invalid default.
        #expect(!def.uppercased().contains("DEFAULT"), "got: \(def)")
        #expect(def.uppercased().contains("NOT NULL"))
    }

    @Test("a nullable column with no default keeps DEFAULT NULL")
    func nullableWithoutDefault() {
        let def = SQLBuilder.columnDefinition(ColumnEdit(from: absentMetadataColumn(nullable: true)))
        #expect(def.uppercased().contains("DEFAULT NULL"), "got: \(def)")
    }

    @Test("a string default is quoted, a function default is not")
    func defaultQuoting() {
        var text = edit(from: column("a"))
        text.defaultValue = "hello"
        #expect(SQLBuilder.columnDefinition(text).contains("DEFAULT 'hello'"))

        var fn = edit(from: column("b"))
        fn.defaultValue = "CURRENT_TIMESTAMP"
        #expect(fn.defaultValue == "CURRENT_TIMESTAMP")
        #expect(SQLBuilder.columnDefinition(fn).contains("DEFAULT CURRENT_TIMESTAMP"))
    }
}

@Suite("ClickHouse → DuckDB type mapping (bridge)")
struct ClickHouseTypeMappingTests {

    @Test("numeric and temporal types get real DuckDB types; the rest are VARCHAR")
    func mapping() {
        // Signed/unsigned ints that fit in 64-bit signed → BIGINT.
        #expect(SQLBuilder.clickhouseToDuckType("Int32") == "BIGINT")
        #expect(SQLBuilder.clickhouseToDuckType("UInt32") == "BIGINT")
        #expect(SQLBuilder.clickhouseToDuckType("Int64") == "BIGINT")
        // Overflow-prone widths stay text (safe).
        #expect(SQLBuilder.clickhouseToDuckType("UInt64") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("Int256") == "VARCHAR")
        // Floats and bools.
        #expect(SQLBuilder.clickhouseToDuckType("Float64") == "DOUBLE")
        #expect(SQLBuilder.clickhouseToDuckType("Bool") == "BOOLEAN")
        // Temporal (with and without parameters).
        #expect(SQLBuilder.clickhouseToDuckType("Date") == "DATE")
        #expect(SQLBuilder.clickhouseToDuckType("DateTime") == "TIMESTAMP")
        #expect(SQLBuilder.clickhouseToDuckType("DateTime64(3)") == "TIMESTAMP")
        // Everything else → VARCHAR (safe: ClickHouse sends it as text).
        #expect(SQLBuilder.clickhouseToDuckType("String") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("FixedString(8)") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("UUID") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("Decimal(10, 2)") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("IPv4") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("Array(Int32)") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("Enum8('a' = 1)") == "VARCHAR")
    }

    @Test("Nullable() and LowCardinality() wrappers are peeled")
    func wrappers() {
        #expect(SQLBuilder.clickhouseToDuckType("Nullable(DateTime)") == "TIMESTAMP")
        #expect(SQLBuilder.clickhouseToDuckType("Nullable(Int32)") == "BIGINT")
        #expect(SQLBuilder.clickhouseToDuckType("LowCardinality(String)") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("LowCardinality(Nullable(String))") == "VARCHAR")
        #expect(SQLBuilder.clickhouseToDuckType("LowCardinality(Nullable(Int32))") == "BIGINT")
    }
}

@Suite("Read-only classifier (safe mode)")
struct ReadOnlyClassifierTests {

    @Test("reads are classified read-only")
    func reads() {
        #expect(SQLBuilder.isReadOnly("SELECT * FROM t"))
        #expect(SQLBuilder.isReadOnly("  select 1"))
        #expect(SQLBuilder.isReadOnly("WITH x AS (SELECT 1) SELECT * FROM x"))
        #expect(SQLBuilder.isReadOnly("SHOW TABLES"))
        #expect(SQLBuilder.isReadOnly("EXPLAIN SELECT * FROM t"))
        #expect(SQLBuilder.isReadOnly("DESCRIBE t"))
        #expect(SQLBuilder.isReadOnly("-- a comment\nSELECT 1"))
        #expect(SQLBuilder.isReadOnly("/* c */ SELECT 1"))
        #expect(SQLBuilder.isReadOnly("SELECT 1; SELECT 2;"))
    }

    @Test("writes and DDL are not read-only")
    func writes() {
        #expect(!SQLBuilder.isReadOnly("INSERT INTO t VALUES (1)"))
        #expect(!SQLBuilder.isReadOnly("UPDATE t SET x = 1"))
        #expect(!SQLBuilder.isReadOnly("DELETE FROM t WHERE id = 1"))
        #expect(!SQLBuilder.isReadOnly("DROP TABLE t"))
        #expect(!SQLBuilder.isReadOnly("CREATE TABLE t (id INT)"))
        #expect(!SQLBuilder.isReadOnly("ALTER TABLE t ADD c INT"))
        #expect(!SQLBuilder.isReadOnly("TRUNCATE TABLE t"))
        #expect(!SQLBuilder.isReadOnly("REPLACE INTO t VALUES (1)"))
    }

    @Test("a read batch containing one write is not read-only")
    func mixedBatch() {
        #expect(!SQLBuilder.isReadOnly("SELECT 1; DELETE FROM t; SELECT 2"))
    }

    @Test("a data-modifying CTE is a write")
    func modifyingCTE() {
        #expect(!SQLBuilder.isReadOnly("WITH x AS (SELECT id FROM t) DELETE FROM u WHERE u.id IN (SELECT id FROM x)"))
    }

    @Test("a write keyword inside a string literal does not flip a read")
    func keywordInString() {
        #expect(SQLBuilder.isReadOnly("SELECT * FROM t WHERE note = 'please DELETE me'"))
        // even in a CTE, a write verb only inside a literal stays read-only
        #expect(SQLBuilder.isReadOnly("WITH x AS (SELECT 'please update me' AS n) SELECT * FROM x"))
    }
}

@Suite("CSV type inference (create table from CSV)")
struct CSVInferenceTests {
    @Test("all integers → INT, all numeric → DOUBLE, else VARCHAR/TEXT")
    func types() {
        #expect(SQLBuilder.inferCSVColumnType(["1", "2", "30"]).base == "INT")
        #expect(SQLBuilder.inferCSVColumnType(["1", "", "3"]).base == "INT")      // blanks ignored
        #expect(SQLBuilder.inferCSVColumnType(["1.5", "2", "3.0"]).base == "DOUBLE")
        #expect(SQLBuilder.inferCSVColumnType(["a", "b", "1"]).base == "VARCHAR")
        #expect(SQLBuilder.inferCSVColumnType([String(repeating: "x", count: 300)]).base == "TEXT")
        #expect(SQLBuilder.inferCSVColumnType([]).base == "VARCHAR")             // empty column
        #expect(SQLBuilder.inferCSVColumnType(["1", "2"]).length == "")
        // zero-padded codes must stay text, not become INT/DOUBLE (leading zeros lost)
        #expect(SQLBuilder.inferCSVColumnType(["007", "042", "100"]).base == "VARCHAR")
        #expect(SQLBuilder.inferCSVColumnType(["0", "1", "2"]).base == "INT")       // bare zero is fine
        #expect(SQLBuilder.inferCSVColumnType(["0.5", "1.5"]).base == "DOUBLE")     // decimal, not leading-zero int
        #expect(SQLBuilder.inferCSVColumnType(["a"]).length == "255")
    }

    @Test("column names are sanitized to safe identifiers")
    func names() {
        #expect(SQLBuilder.sanitizeColumnName("First Name", fallback: "c1") == "First_Name")
        #expect(SQLBuilder.sanitizeColumnName("price($)", fallback: "c1") == "price___")
        #expect(SQLBuilder.sanitizeColumnName("", fallback: "c1") == "c1")
        #expect(SQLBuilder.sanitizeColumnName("2024total", fallback: "c1") == "c_2024total")
    }
}
