//
//  QueryEffectsTests.swift
//  SequelBridgeTests
//
//  What a Query-tab run changes in the left panel. A tester coming from Sequel Pro and
//  Sequel Ace typed `USE other_db` and the database at the top of the left panel stayed
//  put, and the next statement still ran in the old database. These are Sequel Ace's
//  rules (its SASQLDatabaseContext cases, ported): USE picks that database, DROP
//  DATABASE of the picked one leaves none, DDL re-reads the table list.
//

import Testing
@testable import SequelBridge

@Suite("What a query run changes in the left panel")
struct QueryEffectsTests {
    private func db(after sql: String, current: String? = "old_db", caseSensitive: Bool = true) -> String? {
        QueryEffects.afterRun(sql, database: current, caseSensitive: caseSensitive).database
    }

    @Test("USE picks that database: comments, quoted names, no space before a quote")
    func use() {
        #expect(db(after: "USE new_db") == "new_db")
        #expect(db(after: "use new_db;") == "new_db")
        #expect(db(after: "USE new_db; -- selected\n") == "new_db")
        #expect(db(after: "/* before */ USE `new``db/*literal*/#name` /* after */") == "new`db/*literal*/#name")
        #expect(db(after: "USE hash_db # selected") == "hash_db")
        #expect(db(after: "USE \"new\"\"db\"") == "new\"db")
        #expect(db(after: "USE`quoted_db`") == "quoted_db")
        #expect(db(after: "-- pick one\nUSE target") == "target")
        #expect(db(after: "# pick one\nUSE target") == "target")
        #expect(db(after: "USEFUL db") == "old_db")
        #expect(db(after: "SELECT 'USE x'") == "old_db")
    }

    @Test("DROP DATABASE of the picked database leaves none; any other leaves it")
    func dropDatabase() {
        #expect(db(after: "DROP DATABASE `app_db`", current: "app_db") == nil)
        #expect(db(after: "DROP SCHEMA IF EXISTS app_db; -- rebuild", current: "app_db") == nil)
        #expect(db(after: "DROP DATABASE`app_db`", current: "app_db") == nil)
        #expect(db(after: "DROP DATABASE IF EXISTS`app_db`", current: "app_db") == nil)
        #expect(db(after: "DROP DATABASE reporting", current: "app_db") == "app_db")
        #expect(db(after: "DROP DATABASE app_db_backup", current: "app_db", caseSensitive: false) == "app_db")
        #expect(db(after: "DROP DATABASE app_db", current: "App_DB", caseSensitive: true) == "App_DB")
        #expect(db(after: "DROP DATABASE app_db", current: "App_DB", caseSensitive: false) == nil)
    }

    @Test("a script is followed statement by statement")
    func script() {
        let o = QueryEffects.afterRun(
            "INSERT INTO events VALUES (1); DROP DATABASE app_db; CREATE DATABASE app_db; USE app_db; /* restored */",
            database: "app_db")
        #expect(o.database == "app_db")
        #expect(o.reloadTables)
        #expect(o.reloadDatabases)
        #expect(db(after: "USE a; SELECT 1; USE b") == "b")
        #expect(db(after: "SELECT ';USE x'; SELECT 2") == "old_db")
    }

    @Test("CREATE, ALTER, DROP and RENAME re-read the table list; reads and row changes don't")
    func tableList() {
        for sql in ["CREATE TABLE t (id INT)", "alter table t add c INT", "DROP TABLE t", "RENAME TABLE t TO u",
                    "  -- note\n CREATE VIEW v AS SELECT 1", "create index i on t (id)"] {
            #expect(QueryEffects.afterRun(sql, database: "d").reloadTables, "\(sql)")
        }
        for sql in ["SELECT 1", "INSERT INTO t VALUES (1)", "UPDATE t SET c = 1", "DELETE FROM t",
                    "CREATED", "SHOW TABLES", "USE d"] {
            #expect(!QueryEffects.afterRun(sql, database: "d").reloadTables, "\(sql)")
        }
    }

    @Test("creating or dropping a database, or picking one, re-reads the database list")
    func databaseList() {
        for sql in ["CREATE DATABASE x", "create schema if not exists x", "DROP DATABASE x", "DROP SCHEMA x", "USE x"] {
            #expect(QueryEffects.afterRun(sql, database: "d").reloadDatabases, "\(sql)")
        }
        for sql in ["CREATE TABLE t (id INT)", "DROP TABLE t", "SELECT 1", "USE d"] {
            #expect(!QueryEffects.afterRun(sql, database: "d").reloadDatabases, "\(sql)")
        }
    }
}
