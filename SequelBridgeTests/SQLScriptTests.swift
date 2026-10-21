//
//  SQLScriptTests.swift
//  SequelBridgeTests
//
//  Several statements in one run. On a MySQL connection `SELECT 1; SELECT 2` failed with
//  a syntax error: a read went to the server as one prepared statement, and MySQL
//  prepares one statement at a time. The Query tab now runs each statement in turn, as
//  Sequel Ace does; this pins how the text splits into statements.
//

import Testing
@testable import SequelBridge

@Suite("Several statements in one run: splitting the script")
struct SQLScriptTests {
    private func split(_ sql: String) -> [String] { SQLScript.statements(sql) }

    @Test("statements split on ; and keep their own text")
    func basic() {
        #expect(split("SELECT 1; SELECT 2") == ["SELECT 1", "SELECT 2"])
        #expect(split("SELECT 1;\n\nSELECT 2;\n") == ["SELECT 1", "SELECT 2"])
        #expect(split("SELECT 1") == ["SELECT 1"])
        #expect(split("  ;; ") == [])
    }

    @Test("a ; inside quotes or comments doesn't end a statement")
    func quotedAndCommented() {
        #expect(split("SELECT 'a;b'; SELECT \"c;d\"; SELECT `e;f`") == ["SELECT 'a;b'", "SELECT \"c;d\"", "SELECT `e;f`"])
        #expect(split("SELECT 'it\\'s; ok'; SELECT 2") == ["SELECT 'it\\'s; ok'", "SELECT 2"])
        #expect(split("SELECT 1 -- one; two\n; SELECT 2") == ["SELECT 1 -- one; two", "SELECT 2"])
        #expect(split("SELECT /* ; */ 1; # x; y\nSELECT 2") == ["SELECT /* ; */ 1", "# x; y\nSELECT 2"])
    }

    @Test("a piece that is only a comment is not a statement")
    func commentOnly() {
        #expect(split("SELECT 1; -- done") == ["SELECT 1"])
        #expect(split("/* header */;\nSELECT 1") == ["SELECT 1"])
    }

    @Test("DELIMITER changes the separator, so a procedure body keeps its semicolons")
    func delimiter() {
        let script = """
        DELIMITER //
        CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//
        DELIMITER ;
        CALL p();
        SELECT 3
        """
        #expect(split(script) == ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "CALL p()", "SELECT 3"])
    }

    @Test("the statement under the cursor: the one the caret is in, else the one just before it")
    func underCursor() {
        let text = "SELECT 1;\nSELECT 2;\n\nSELECT 3"
        #expect(SQLScript.statement(at: 3, in: text) == "SELECT 1")
        #expect(SQLScript.statement(at: 9, in: text) == "SELECT 1")       // just after its ;
        #expect(SQLScript.statement(at: 14, in: text) == "SELECT 2")
        #expect(SQLScript.statement(at: 20, in: text) == "SELECT 2")      // the blank line after it
        #expect(SQLScript.statement(at: 21, in: text) == "SELECT 3")
        #expect(SQLScript.statement(at: 29, in: text) == "SELECT 3")      // the end of the text
        #expect(SQLScript.statement(at: 0, in: "  \n") == nil)
        #expect(SQLScript.statement(at: 2, in: "é; SELECT 2") == "é")     // UTF-16 offsets, as the editor counts
    }

    @Test("MySQL's executable comments (/*! … */, /*M! … */) are statements, as in a mysqldump file")
    func executableComments() {
        #expect(split("/*!40101 SET NAMES utf8mb4 */; SELECT 1") == ["/*!40101 SET NAMES utf8mb4 */", "SELECT 1"])
        #expect(split("/*M!100100 SET @x = 1 */;") == ["/*M!100100 SET @x = 1 */"])
        #expect(split("/* a plain comment */;") == [])
    }

    @Test("a PostgreSQL body in $$ … $$ or $tag$ … $tag$ keeps its semicolons; $1 and a$b are no quotes")
    func dollarQuotes() {
        #expect(split("CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$; SELECT 2") == [
            "CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$", "SELECT 2"])
        #expect(split("SELECT $tag$a;b$tag$; SELECT 2") == ["SELECT $tag$a;b$tag$", "SELECT 2"])
        #expect(split("DO $$ BEGIN PERFORM 1; END $$; SELECT 3") == ["DO $$ BEGIN PERFORM 1; END $$", "SELECT 3"])
        #expect(split("SELECT $1, a$b; SELECT 2") == ["SELECT $1, a$b", "SELECT 2"])
    }

    @Test("# starts a comment on MySQL and ClickHouse; on PostgreSQL it is an operator (#>>)")
    func hashByEngine() {
        #expect(SQLScript.statements("SELECT meta #>> '{a}' FROM t; SELECT 2", engine: .postgres)
                == ["SELECT meta #>> '{a}' FROM t", "SELECT 2"])
        #expect(SQLScript.statements("SELECT 1 # a note; still the note\n; SELECT 2", engine: .mysql)
                == ["SELECT 1 # a note; still the note", "SELECT 2"])
    }

    /// A trigger's or a routine's BEGIN … END body keeps its semicolons without a DELIMITER
    /// line: SQLite's triggers are always written so, and SHOW CREATE PROCEDURE gives none.
    @Test("a trigger or routine body in BEGIN … END is one statement; a transaction's BEGIN still ends at its ;")
    func compoundBodies() {
        #expect(SQLScript.statements("CREATE TRIGGER t AFTER INSERT ON c BEGIN INSERT INTO log VALUES (NEW.id); UPDATE n SET k = k + 1; END; SELECT 1",
                                     engine: .sqlite)
                == ["CREATE TRIGGER t AFTER INSERT ON c BEGIN INSERT INTO log VALUES (NEW.id); UPDATE n SET k = k + 1; END", "SELECT 1"])
        let proc = "CREATE DEFINER=`root`@`%` PROCEDURE p(IN x INT)\nBEGIN\n  DECLARE n INT DEFAULT 0;\n  lbl: LOOP\n    SET n = n + 1;\n    IF n > x THEN LEAVE lbl; END IF;\n  END LOOP lbl;\n  SELECT CASE WHEN n > 1 THEN 'many' ELSE 'one' END AS v;\nEND"
        #expect(SQLScript.statements(proc + ";\nCALL p(2)", engine: .mysql) == [proc, "CALL p(2)"])
        let trigger = "CREATE TRIGGER t BEFORE INSERT ON log FOR EACH ROW BEGIN IF NEW.msg IS NULL THEN SET NEW.msg = 'none'; END IF; END"
        #expect(SQLScript.statements(trigger + "; INSERT INTO log VALUES (NULL)", engine: .mysql) == [trigger, "INSERT INTO log VALUES (NULL)"])
        let atomic = "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END"
        #expect(SQLScript.statements(atomic + "; SELECT f()", engine: .postgres) == [atomic, "SELECT f()"])
        let anonymous = "BEGIN NOT ATOMIC DECLARE x INT DEFAULT 1; SELECT x + 1; END"
        #expect(SQLScript.statements(anonymous + "; SELECT 3", engine: .mysql) == [anonymous, "SELECT 3"])
        // Not a body: a transaction, a one-line trigger, a CASE in a plain SELECT.
        #expect(SQLScript.statements("BEGIN; INSERT INTO t VALUES (1); END; SELECT 1", engine: .postgres)
                == ["BEGIN", "INSERT INTO t VALUES (1)", "END", "SELECT 1"])
        #expect(SQLScript.statements("CREATE TRIGGER t BEFORE INSERT ON log FOR EACH ROW SET NEW.msg = UPPER(NEW.msg); SELECT 2", engine: .mysql)
                == ["CREATE TRIGGER t BEFORE INSERT ON log FOR EACH ROW SET NEW.msg = UPPER(NEW.msg)", "SELECT 2"])
        #expect(SQLScript.statements("SELECT CASE WHEN a THEN 1 END FROM t; SELECT 2", engine: .mysql)
                == ["SELECT CASE WHEN a THEN 1 END FROM t", "SELECT 2"])
        // A column called end, written with its table, is no END.
        let ranges = "CREATE TRIGGER r BEFORE INSERT ON ranges FOR EACH ROW BEGIN SET NEW.end = NEW.start + 1; SET NEW.begin = 0; END"
        #expect(SQLScript.statements(ranges + "; SELECT 3", engine: .mysql) == [ranges, "SELECT 3"])
    }

    /// Workbench's and phpMyAdmin's way: DELIMITER $$, then $$ right after a name or an END,
    /// or after a space. The $ is part of a word, so the delimiter was read as one.
    @Test("DELIMITER $$: a statement ends at $$ written against a name, an END, a quoted name, or after a space")
    func dollarDelimiter() {
        let script = "DELIMITER $$\nDROP PROCEDURE IF EXISTS p$$\nCREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\nEND$$\n"
            + "CREATE PROCEDURE `q`()\nBEGIN\n  SELECT 2;\nEND $$\nDROP PROCEDURE `r`$$\nDELIMITER ;\nCALL p();"
        let expected = ["DROP PROCEDURE IF EXISTS p", "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\nEND",
                        "CREATE PROCEDURE `q`()\nBEGIN\n  SELECT 2;\nEND", "DROP PROCEDURE `r`", "CALL p()"]
        #expect(SQLScript.statements(script, engine: .mysql) == expected)
        #expect(SQLScript.statements(script) == expected)                  // as Import SQL file splits a file
    }

    /// Words that only look like a body's BEGIN or END: a variable (@end), a column called
    /// end, a parameter called begin, END after a CASE however it goes on, and PostgreSQL's
    /// --end comment (no space needed there).
    @Test("a body's BEGIN and END aren't fooled by @end, a column or parameter called end/begin, CASE … END FOR, or --end")
    func compoundBodyLookalikes() {
        let proc = "CREATE PROCEDURE p() BEGIN SET @end = NOW(); SELECT 1; END"
        #expect(SQLScript.statements(proc + "; SELECT 2", engine: .mysql) == [proc, "SELECT 2"])
        let trigger = "CREATE TRIGGER t BEFORE INSERT ON r FOR EACH ROW SET NEW.a = @begin"
        #expect(SQLScript.statements(trigger + "; INSERT INTO r VALUES (1); SELECT 1", engine: .mysql)
                == [trigger, "INSERT INTO r VALUES (1)", "SELECT 1"])
        let ranges = "CREATE PROCEDURE q() BEGIN SELECT start, end FROM ranges; END"
        #expect(SQLScript.statements(ranges + "; SELECT 3", engine: .mysql) == [ranges, "SELECT 3"])
        let param = "CREATE PROCEDURE b(IN begin INT) BEGIN SELECT begin; END"
        #expect(SQLScript.statements(param + "; SELECT 4", engine: .mysql) == [param, "SELECT 4"])
        let caseFor = "CREATE PROCEDURE c() BEGIN SELECT id FROM t ORDER BY CASE WHEN a THEN 1 END FOR UPDATE; END"
        #expect(SQLScript.statements(caseFor + "; SELECT 5", engine: .mysql) == [caseFor, "SELECT 5"])
        let pg = "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; --end\nSELECT 2; END"
        #expect(SQLScript.statements(pg + "; SELECT 6", engine: .postgres) == [pg, "SELECT 6"])
        let event = "ALTER EVENT e ON SCHEDULE EVERY 1 DAY DO BEGIN DELETE FROM log WHERE 0; END"
        #expect(SQLScript.statements(event + "; SELECT 7", engine: .mysql) == [event, "SELECT 7"])
    }

    @Test("Run Current finds the statement under the cursor by the engine's comments: on PostgreSQL #>> isn't one")
    func statementAtByEngine() {
        let text = "SELECT meta #>> '{a}' FROM t;\nSELECT 2"
        #expect(SQLScript.statement(at: text.utf16.count - 2, in: text, engine: .postgres) == "SELECT 2")
        #expect(SQLScript.statement(at: 3, in: text, engine: .postgres) == "SELECT meta #>> '{a}' FROM t")
    }
}
