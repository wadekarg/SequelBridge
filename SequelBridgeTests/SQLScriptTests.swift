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
}
