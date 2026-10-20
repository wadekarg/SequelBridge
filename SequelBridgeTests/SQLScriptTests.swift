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
}
