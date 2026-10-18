//
//  StatementShapeTests.swift
//  SequelBridgeTests
//
//  With several servers connected, only statements that actually touch tables
//  need an alias prefix. `SELECT 1` must run, not lecture about aliases.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Statement shape")
struct StatementShapeTests {

    @Test("constant queries reference no tables", arguments: [
        "SELECT 1",
        "SELECT 1 + 1 AS two",
        "SELECT NOW()",
        "select current_timestamp",
    ])
    func constants(_ sql: String) {
        #expect(!SQLBuilder.referencesTables(sql))
    }

    @Test("table-touching statements do", arguments: [
        "SELECT * FROM customers",
        "select id from t where x = 1",
        "INSERT INTO t (a) VALUES (1)",
        "UPDATE t SET a = 1",
        "DELETE FROM t",
        "SELECT a FROM x JOIN y ON y.id = x.id",
        "WITH c AS (SELECT 1) SELECT * FROM c",
    ])
    func tables(_ sql: String) {
        #expect(SQLBuilder.referencesTables(sql))
    }

    @Test("FROM inside a string literal does not count")
    func literalFrom() {
        #expect(!SQLBuilder.referencesTables("SELECT 'greetings from mars'"))
    }

    // MARK: - Row-returning classification (gates the server passthrough)

    @Test("row-returning statements are recognised", arguments: [
        "SELECT * FROM t",
        "select 1",
        "  \n SELECT 1",                       // leading whitespace
        "(SELECT * FROM t)",                    // wrapped in parens
        "WITH c AS (SELECT 1) SELECT * FROM c",
        "SHOW TABLES",
        "DESCRIBE t",
        "DESC t",
        "EXPLAIN SELECT * FROM t",
        "VALUES (1), (2)",
        "TABLE t",
        "PRAGMA table_info(t)",
        "-- a comment\nSELECT 1",              // leading line comment
        "/* block */ SELECT 1",                // leading block comment
        "select".uppercased() + " * from t",   // case-insensitive
    ])
    func rowReturning(_ sql: String) {
        #expect(SQLBuilder.isRowReturning(sql))
    }

    @Test("writes and DDL are not row-returning", arguments: [
        "INSERT INTO t (a) VALUES (1)",
        "UPDATE t SET a = 1",
        "DELETE FROM t",
        "CREATE TABLE t (id INT)",
        "ALTER TABLE t ADD COLUMN c INT",
        "DROP TABLE t",
        "TRUNCATE TABLE t",
        "REPLACE INTO t VALUES (1)",
        "SET autocommit = 1",
        "USE otherdb",
        "GRANT SELECT ON t TO u",
        "",
    ])
    func notRowReturning(_ sql: String) {
        #expect(!SQLBuilder.isRowReturning(sql))
    }

    // MARK: - Server-dialect identifier quoting (used by the passthrough)

    @Test("MySQL identifiers use backticks, others use double quotes")
    func serverIdent() {
        #expect(SQLBuilder.serverIdent(.mysql, "col") == "`col`")
        #expect(SQLBuilder.serverIdent(.postgres, "col") == "\"col\"")
        // Embedded quote chars are escaped by doubling.
        #expect(SQLBuilder.serverIdent(.mysql, "a`b") == "`a``b`")
        #expect(SQLBuilder.serverIdent(.postgres, "a\"b") == "\"a\"\"b\"")
    }

    @Test("server table references qualify db.table per dialect")
    func serverTable() {
        #expect(SQLBuilder.serverTable(.mysql, database: "d", table: "t") == "`d`.`t`")
        #expect(SQLBuilder.serverTable(.postgres, database: "s", table: "t") == "\"s\".\"t\"")
    }
}
