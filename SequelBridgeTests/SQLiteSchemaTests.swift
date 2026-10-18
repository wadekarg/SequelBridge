//
//  SQLiteSchemaTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("SQLite DDL parsing")
struct SQLiteSchemaTests {

    // MARK: - Columns

    @Test("columns, types, nullability and the primary key")
    func basicColumns() {
        let ddl = """
        CREATE TABLE customers (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL,
          full_name TEXT,
          credit_limit REAL DEFAULT 0.0,
          is_active INTEGER NOT NULL DEFAULT 1,
          notes TEXT
        )
        """
        let cols = SQLiteSchema.parseColumns(fromCreateTable: ddl)
        #expect(cols.map(\.name) == ["id","email","full_name","credit_limit","is_active","notes"])
        #expect(cols[0].isPrimaryKey)
        #expect(cols[0].type == "INTEGER")
        #expect(cols[1].notNull)
        #expect(!cols[2].notNull)
        #expect(cols[3].defaultValue == "0.0")
        #expect(cols[4].defaultValue == "1")
        #expect(cols[5].defaultValue.isEmpty)
    }

    @Test("a table-level PRIMARY KEY marks every column it names")
    func compositePrimaryKey() {
        let ddl = """
        CREATE TABLE order_items (
          order_id INTEGER NOT NULL,
          line_no INTEGER NOT NULL,
          sku TEXT,
          PRIMARY KEY (order_id, line_no)
        )
        """
        let cols = SQLiteSchema.parseColumns(fromCreateTable: ddl)
        #expect(cols.map(\.name) == ["order_id","line_no","sku"])
        #expect(cols[0].isPrimaryKey)
        #expect(cols[1].isPrimaryKey)
        #expect(!cols[2].isPrimaryKey)
    }

    @Test("a comma inside a type is not a definition boundary")
    func commaInsideType() {
        let ddl = "CREATE TABLE t (a NUMERIC(10,2), b TEXT)"
        let cols = SQLiteSchema.parseColumns(fromCreateTable: ddl)
        #expect(cols.map(\.name) == ["a","b"])
        #expect(cols[0].type == "NUMERIC(10,2)")
    }

    @Test("quoted and bracketed identifiers are unwrapped")
    func quotedNames() {
        let ddl = #"CREATE TABLE t ("odd name" TEXT, [bracketed] INTEGER, `backticked` REAL)"#
        #expect(SQLiteSchema.parseColumns(fromCreateTable: ddl).map(\.name)
                == ["odd name","bracketed","backticked"])
    }

    @Test("a quoted string default keeps its text without the quotes")
    func stringDefault() {
        let ddl = "CREATE TABLE t (a TEXT DEFAULT 'hello' NOT NULL, b TEXT)"
        let cols = SQLiteSchema.parseColumns(fromCreateTable: ddl)
        #expect(cols[0].defaultValue == "hello")
        #expect(cols[0].notNull)
    }

    @Test("table-level constraints are not mistaken for columns")
    func constraintsSkipped() {
        let ddl = """
        CREATE TABLE t (
          a INTEGER,
          b INTEGER,
          UNIQUE (a),
          CHECK (b > 0),
          CONSTRAINT fk_x FOREIGN KEY (b) REFERENCES other(id)
        )
        """
        #expect(SQLiteSchema.parseColumns(fromCreateTable: ddl).map(\.name) == ["a","b"])
    }

    // MARK: - Indexes

    @Test("a unique index reports its columns in order")
    func uniqueIndex() {
        let idx = SQLiteSchema.parseIndex(fromCreateIndex: "CREATE UNIQUE INDEX uq_email ON customers(email)")
        let i = try! #require(idx)
        #expect(i.name == "uq_email")
        #expect(i.table == "customers")
        #expect(i.unique)
        #expect(i.columns == ["email"])
    }

    @Test("a plain multi-column index")
    func plainIndex() {
        let i = try! #require(SQLiteSchema.parseIndex(
            fromCreateIndex: "CREATE INDEX idx_name_date ON customers (full_name, signup_date)"))
        #expect(!i.unique)
        #expect(i.columns == ["full_name","signup_date"])
    }

    @Test("sort direction and collation are stripped from index columns")
    func indexColumnModifiers() {
        let i = try! #require(SQLiteSchema.parseIndex(
            fromCreateIndex: "CREATE INDEX i ON t (a DESC, b COLLATE NOCASE ASC)"))
        #expect(i.columns == ["a","b"])
    }

    @Test("a non-index statement yields nothing")
    func notAnIndex() {
        #expect(SQLiteSchema.parseIndex(fromCreateIndex: "CREATE TABLE t (a INT)") == nil)
    }

    // MARK: - Foreign keys

    @Test("a column-level REFERENCES clause with ON DELETE")
    func columnLevelFK() {
        let ddl = """
        CREATE TABLE orders (
          id INTEGER PRIMARY KEY,
          customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
          total REAL
        )
        """
        let fks = SQLiteSchema.parseForeignKeys(fromCreateTable: ddl)
        #expect(fks.count == 1)
        #expect(fks[0][1] == "customer_id")
        #expect(fks[0][2] == "customers")
        #expect(fks[0][3] == "id")
        #expect(fks[0][4] == "CASCADE")
    }

    @Test("a named table-level FOREIGN KEY with both actions")
    func tableLevelFK() {
        let ddl = """
        CREATE TABLE t (
          a INTEGER,
          CONSTRAINT fk_a FOREIGN KEY (a) REFERENCES other (id) ON DELETE SET NULL ON UPDATE CASCADE
        )
        """
        let fks = SQLiteSchema.parseForeignKeys(fromCreateTable: ddl)
        #expect(fks.count == 1)
        #expect(fks[0][0] == "fk_a")
        #expect(fks[0][2] == "other")
        #expect(fks[0][4] == "SET NULL")
        #expect(fks[0][5] == "CASCADE")
    }

    @Test("a table with no foreign keys returns none")
    func noFKs() {
        #expect(SQLiteSchema.parseForeignKeys(fromCreateTable: "CREATE TABLE t (a INT, b TEXT)").isEmpty)
    }

    @Test("omitted referential actions default to NO ACTION")
    func defaultActions() {
        let ddl = "CREATE TABLE t (a INTEGER REFERENCES other(id))"
        let fks = SQLiteSchema.parseForeignKeys(fromCreateTable: ddl)
        #expect(fks[0][4] == "NO ACTION")
        #expect(fks[0][5] == "NO ACTION")
    }
}
