//
//  SQLBuilderDDLTests.swift
//  SequelBridgeTests
//
//  The DDL statements the panels used to build inline.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("DDL statement generation")
struct SQLBuilderDDLTests {

    func col(_ name: String, type: String = "VARCHAR", length: String = "255",
             nullable: Bool = true, auto: Bool = false, pk: Bool = false,
             def: String = "") -> NewColumnDef {
        var c = NewColumnDef()
        c.name = name; c.baseType = type; c.length = length
        c.nullable = nullable; c.autoIncrement = auto; c.isPrimaryKey = pk
        c.defaultValue = def
        return c
    }

    // MARK: - CREATE TABLE

    @Test("CREATE TABLE is database-qualified with engine and charset")
    func createTable() {
        let sql = SQLBuilder.createTable(database: "shop", table: "widgets",
                                         columns: [col("id", type: "INT", length: "", nullable: false, auto: true, pk: true)],
                                         engine: "InnoDB", charset: "utf8mb4")
        #expect(sql.contains("CREATE TABLE `shop`.`widgets`"))
        #expect(sql.contains("`id` INT NOT NULL AUTO_INCREMENT"))
        #expect(sql.contains("PRIMARY KEY (`id`)"))
        #expect(sql.contains("ENGINE=InnoDB"))
        #expect(sql.contains("DEFAULT CHARSET=utf8mb4"))
    }

    @Test("CREATE TABLE combines every primary key column into one clause")
    func createTableCompositePK() {
        let sql = SQLBuilder.createTable(database: "d", table: "t",
                                         columns: [col("a", type: "INT", length: "", nullable: false, pk: true),
                                                   col("b", type: "INT", length: "", nullable: false, pk: true)],
                                         engine: "InnoDB", charset: "utf8mb4")
        #expect(sql.contains("PRIMARY KEY (`a`, `b`)"))
    }

    @Test("CREATE TABLE omits the primary key clause when no column is marked")
    func createTableNoPK() {
        let sql = SQLBuilder.createTable(database: "d", table: "t", columns: [col("a")],
                                         engine: "InnoDB", charset: "utf8mb4")
        #expect(!sql.uppercased().contains("PRIMARY KEY"))
    }

    @Test("CREATE TABLE escapes quotes in a default value")
    func createTableEscapesDefault() {
        let sql = SQLBuilder.createTable(database: "d", table: "t",
                                         columns: [col("label", def: "it's")],
                                         engine: "InnoDB", charset: "utf8mb4")
        #expect(sql.contains("DEFAULT 'it''s'"), "got: \(sql)")
    }

    @Test("CREATE TABLE passes keyword defaults through unquoted")
    func createTableKeywordDefault() {
        let sql = SQLBuilder.createTable(database: "d", table: "t",
                                         columns: [col("at", type: "DATETIME", length: "", def: "CURRENT_TIMESTAMP")],
                                         engine: "InnoDB", charset: "utf8mb4")
        #expect(sql.contains("DEFAULT CURRENT_TIMESTAMP"))
        #expect(!sql.contains("'CURRENT_TIMESTAMP'"))
    }

    // MARK: - Foreign keys

    @Test("ADD CONSTRAINT names the constraint and both sides")
    func addForeignKey() {
        let sql = SQLBuilder.addForeignKey(database: "shop", table: "orders", name: "fk_o_c",
                                           column: "customer_id", referencedTable: "customers",
                                           referencedColumn: "id", onDelete: "CASCADE", onUpdate: "RESTRICT")
        #expect(sql == "ALTER TABLE `shop`.`orders` ADD CONSTRAINT `fk_o_c` FOREIGN KEY (`customer_id`) "
                     + "REFERENCES `customers` (`id`) ON DELETE CASCADE ON UPDATE RESTRICT")
    }

    @Test("DROP FOREIGN KEY targets the named constraint")
    func dropForeignKey() {
        #expect(SQLBuilder.dropForeignKey(database: "shop", table: "orders", name: "fk_o_c")
                == "ALTER TABLE `shop`.`orders` DROP FOREIGN KEY `fk_o_c`")
    }

    // MARK: - Triggers

    @Test("CREATE TRIGGER qualifies the table with its database")
    func createTrigger() {
        // The server session's default schema is not necessarily the selected one.
        let sql = SQLBuilder.createTrigger(database: "shop", table: "orders", name: "trg_x",
                                           timing: "BEFORE", event: "INSERT",
                                           body: "SET NEW.total = 0")
        #expect(sql == "CREATE TRIGGER `trg_x` BEFORE INSERT ON `shop`.`orders` FOR EACH ROW SET NEW.total = 0")
    }

    @Test("DROP TRIGGER is qualified by database and tolerates absence")
    func dropTrigger() {
        #expect(SQLBuilder.dropTrigger(database: "shop", name: "trg_x")
                == "DROP TRIGGER IF EXISTS `shop`.`trg_x`")
    }
}

@Suite("CREATE TABLE reconstruction")
struct ShowCreateTableTests {

    func column(_ name: String, type: String, nullable: Bool = true,
                def: String = "", extra: String = "", comment: String = "") -> ColumnInfo {
        ColumnInfo(id: "t.\(name)", name: name, dataType: type, nullable: nullable,
                   keyType: "", defaultValue: def, extra: extra,
                   encoding: "", collation: "", comment: comment)
    }

    @Test("renders columns with types, nullability and extras")
    func columnLines() {
        let sql = SQLBuilder.showCreateTable(
            table: "widgets",
            columns: [column("id", type: "int(11)", nullable: false, extra: "auto_increment"),
                      column("label", type: "varchar(50)")],
            indexes: [], engine: "InnoDB", collation: "utf8mb4_general_ci",
            autoIncrement: "42", comment: "")
        #expect(sql.contains("CREATE TABLE `widgets`"))
        #expect(sql.contains("`id` int(11) NOT NULL AUTO_INCREMENT"))
        #expect(sql.contains("`label` varchar(50)"))
        #expect(sql.contains("ENGINE=InnoDB"))
        #expect(sql.contains("AUTO_INCREMENT=42"))
        #expect(sql.contains("DEFAULT CHARSET=utf8mb4"))
        #expect(sql.contains("COLLATE=utf8mb4_general_ci"))
    }

    @Test("renders primary, unique and plain indexes")
    func indexLines() {
        let sql = SQLBuilder.showCreateTable(
            table: "t",
            columns: [column("id", type: "int(11)", nullable: false)],
            indexes: [IndexInfo(id: "t.PRIMARY", name: "PRIMARY", columns: ["id"], unique: true, indexType: "BTREE"),
                      IndexInfo(id: "t.uq", name: "uq_a", columns: ["a"], unique: true, indexType: "BTREE"),
                      IndexInfo(id: "t.k", name: "k_b", columns: ["b", "c"], unique: false, indexType: "BTREE")],
            engine: "InnoDB", collation: "", autoIncrement: "", comment: "")
        #expect(sql.contains("PRIMARY KEY (`id`)"))
        #expect(sql.contains("UNIQUE KEY `uq_a` (`a`)"))
        #expect(sql.contains("KEY `k_b` (`b`, `c`)"))
    }

    @Test("escapes quotes by doubling them, not with backslashes")
    func escaping() {
        let sql = SQLBuilder.showCreateTable(
            table: "t",
            columns: [column("label", type: "varchar(10)", def: "it's", comment: "Bob's column")],
            indexes: [], engine: "", collation: "", autoIncrement: "", comment: "Ann's table")
        // Backslash escaping breaks under NO_BACKSLASH_ESCAPES; doubling is portable.
        #expect(!sql.contains("\\'"), "got: \(sql)")
        #expect(sql.contains("DEFAULT 'it''s'"))
        #expect(sql.contains("COMMENT 'Bob''s column'"))
        #expect(sql.contains("COMMENT='Ann''s table'"))
    }

    @Test("skips placeholder dashes coming from an empty metadata row")
    func placeholders() {
        let sql = SQLBuilder.showCreateTable(
            table: "t", columns: [], indexes: [],
            engine: "—", collation: "—", autoIncrement: "", comment: "—")
        #expect(!sql.contains("—"), "got: \(sql)")
    }
}

@Suite("Copy row as SQL INSERT")
struct InsertStatementTests {

    @Test("renders a portable INSERT for the copied row")
    func basic() {
        let sql = SQLBuilder.insertStatement(table: "orders",
                                             columns: ["id", "label"], row: ["1", "alpha"])
        #expect(sql == "INSERT INTO `orders` (`id`, `label`) VALUES ('1', 'alpha');")
    }

    @Test("NULL cells stay unquoted keywords")
    func nulls() {
        let sql = SQLBuilder.insertStatement(table: "t", columns: ["a", "b"], row: ["NULL", "x"])
        #expect(sql.contains("VALUES (NULL, 'x')"))
    }

    @Test("quotes inside a value are escaped")
    func escaping() {
        let sql = SQLBuilder.insertStatement(table: "t", columns: ["a"], row: ["O'Brien"])
        #expect(sql.contains("VALUES ('O''Brien')"))
    }

    @Test("a short row does not produce a mismatched column list")
    func shortRow() {
        // Defensive: the grid can hand over fewer cells than columns.
        let sql = SQLBuilder.insertStatement(table: "t", columns: ["a", "b", "c"], row: ["1"])
        #expect(sql.contains("(`a`)"))
        #expect(sql.contains("VALUES ('1')"))
    }
}
