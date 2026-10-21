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
        #expect(db(after: "/*!40101 USE versioned_db */") == "versioned_db")   // an executable comment runs
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

@Suite("Query tab on MySQL: what runs on the server as typed")
struct AsTypedRoutingTests {
    @Test("a statement that returns no rows runs as typed, MySQL's own syntax included")
    func asTyped() {
        for sql in ["CREATE TABLE t (id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY) ENGINE=InnoDB",
                    "INSERT INTO `t` (`a`) VALUES (\"x\") ON DUPLICATE KEY UPDATE a = 'y'",
                    "UPDATE t SET a = DATE_FORMAT(NOW(), '%Y')", "REPLACE INTO t VALUES (1)", "SET @x = 1",
                    "OPTIMIZE TABLE t", "ALTER TABLE t MODIFY a INT", "/*!40101 SET NAMES utf8mb4 */",
                    "# a note\nDELETE FROM t"] {
            #expect(QueryEffects.runsAsTyped(sql), "\(sql)")
        }
    }

    @Test("reads, USE and transaction control don't: a transaction is DuckDB's, so the statements in it share one server connection")
    func notAsTyped() {
        for sql in ["SELECT 1", "  (SELECT 1)", "# a note\nSELECT 1", "SHOW TABLES", "EXPLAIN SELECT 1",
                    "WITH x AS (SELECT 1) SELECT * FROM x", "USE sbtest",
                    "BEGIN", "begin work", "START TRANSACTION", "COMMIT", "ROLLBACK", "END"] {
            #expect(!QueryEffects.runsAsTyped(sql), "\(sql)")
        }
    }

    @Test("on PostgreSQL too, but SET and RESET stay DuckDB's: on the server they'd change a connection the app reuses")
    func postgres() {
        #expect(QueryEffects.runsAsTyped("CREATE TABLE t (id SERIAL PRIMARY KEY, note VARCHAR(40))", engine: .postgres))
        #expect(QueryEffects.runsAsTyped("COMMENT ON COLUMN t.note IS 'n'", engine: .postgres))
        #expect(QueryEffects.runsAsTyped("UPDATE t SET half = qty / 2", engine: .postgres))
        #expect(!QueryEffects.runsAsTyped("SET search_path TO other", engine: .postgres))
        #expect(!QueryEffects.runsAsTyped("reset all", engine: .postgres))
        #expect(!QueryEffects.runsAsTyped("BEGIN", engine: .postgres))
        #expect(!QueryEffects.runsAsTyped("SELECT 1", engine: .postgres))
        #expect(QueryEffects.runsAsTyped("SET @x = 1", engine: .mysql), "MySQL's SET stays as typed")
        #expect(!QueryEffects.runsAsTyped("CREATE TABLE t (id INT)", engine: .sqlite), "SQLite files are DuckDB's own")
    }

    @Test("which statements begin and end a transaction in the Query tab")
    func transactionChange() {
        for sql in ["BEGIN", "begin work", "START TRANSACTION", "BEGIN TRANSACTION"] { #expect(QueryEffects.transactionChange(sql) == true, "\(sql)") }
        for sql in ["COMMIT", "rollback", "END", "COMMIT WORK"] { #expect(QueryEffects.transactionChange(sql) == false, "\(sql)") }
        for sql in ["SELECT 1", "UPDATE t SET a = 1", "CREATE TRIGGER x BEFORE INSERT ON t FOR EACH ROW BEGIN END"] {
            #expect(QueryEffects.transactionChange(sql) == nil, "\(sql)")
        }
    }

    @Test("LOCK TABLES, UNLOCK TABLES and SET autocommit are refused, saying why: they'd stay on a connection the app reuses")
    func locks() {
        let reason = QueryEffects.refusal("LOCK TABLES t WRITE")
        #expect(reason?.contains("lock") == true, "got: \(reason ?? "nil")")
        #expect(QueryEffects.refusal("unlock tables") != nil)
        #expect(QueryEffects.refusal("LOCK TABLE t READ") != nil)
        #expect(QueryEffects.refusal("SET autocommit = 0") != nil)
        #expect(QueryEffects.refusal("set @@session.autocommit=0") != nil)
        #expect(QueryEffects.refusal("SET @autocommit_note = 1") == nil)
        #expect(QueryEffects.refusal("SELECT 'LOCK TABLES'") == nil)
        #expect(QueryEffects.refusal("UPDATE t SET a = 1") == nil)
    }

    @Test("a script shares one connection when a statement sets what a later one reads, not for an @ in a string or a name")
    func oneSession() {
        #expect(QueryEffects.needsOneSession(["SET @d = '2026-01-01'", "SELECT COUNT(*) FROM t WHERE d > @d"], engine: .mysql))
        #expect(QueryEffects.needsOneSession(["CREATE TEMPORARY TABLE x (id INT)", "SELECT * FROM x"], engine: .mysql))
        #expect(QueryEffects.needsOneSession(["PREPARE q AS SELECT 1", "EXECUTE q"], engine: .postgres))
        #expect(QueryEffects.needsOneSession(["SELECT 1", "SELECT 2"], engine: .sqlite))          // a SQLite script runs in one go
        #expect(!QueryEffects.needsOneSession(["SELECT 1", "SELECT 2"], engine: .mysql))
        #expect(!QueryEffects.needsOneSession(["SELECT * FROM t WHERE email LIKE '%@example.com'", "SELECT 2"], engine: .mysql))
        #expect(!QueryEffects.needsOneSession(["SELECT * FROM t WHERE email LIKE \"%@example.com\"", "SELECT 2"], engine: .mysql))
        #expect(!QueryEffects.needsOneSession(["SELECT `@odd` FROM t", "SELECT 2"], engine: .mysql))
        #expect(!QueryEffects.needsOneSession(["SELECT @@version", "SELECT 2"], engine: .mysql))   // a server variable
        #expect(!QueryEffects.needsOneSession(["SET @x = 1"], engine: .mysql))                      // one statement
    }

    /// mysqldump --no-autocommit writes SET autocommit = 0 … COMMIT: refused at its first
    /// statement once any autocommit kept a script off one connection. ROLLBACK TO a
    /// savepoint was taken for the transaction's end, so a script leaving it open ran on a
    /// connection that closed, rolling it back, the grid saying Done.
    @Test("a script's transaction: autocommit = 0 opens one that COMMIT ends; ROLLBACK TO and RELEASE end none; AND CHAIN opens the next")
    func transactionShape() {
        #expect(QueryEffects.needsOneSession(["SET autocommit = 0", "INSERT INTO t VALUES (1)", "COMMIT"], engine: .mysql))
        #expect(!QueryEffects.needsOneSession(["SET autocommit = 0", "INSERT INTO t VALUES (1)"], engine: .mysql))
        #expect(!QueryEffects.needsOneSession(["SET autocommit = 0", "INSERT INTO t VALUES (1)", "COMMIT", "INSERT INTO t VALUES (2)"], engine: .mysql))
        #expect(!QueryEffects.needsOneSession(["BEGIN", "UPDATE t SET a = 1", "SAVEPOINT s", "DELETE FROM t", "ROLLBACK TO SAVEPOINT s"], engine: .mysql))
        #expect(QueryEffects.needsOneSession(["BEGIN", "SAVEPOINT s", "ROLLBACK TO s", "COMMIT"], engine: .postgres))
        #expect(!QueryEffects.needsOneSession(["BEGIN", "UPDATE t SET a = 1", "COMMIT AND CHAIN"], engine: .mysql))
        #expect(QueryEffects.transactionChange("ROLLBACK TO SAVEPOINT s") == nil)
        #expect(QueryEffects.transactionChange("rollback work to s") == nil)
        #expect(QueryEffects.transactionChange("RELEASE SAVEPOINT s") == nil)
        #expect(QueryEffects.transactionChange("COMMIT AND CHAIN") == true)
        #expect(QueryEffects.transactionChange("COMMIT AND NO CHAIN") == false)
        #expect(QueryEffects.transactionChange("ABORT") == false)                                   // PostgreSQL's ROLLBACK
        #expect(QueryEffects.transactionChange("ROLLBACK") == false)
    }
}
