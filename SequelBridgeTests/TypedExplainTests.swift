//
//  TypedExplainTests.swift
//  SequelBridgeTests
//
//  Typing `EXPLAIN …` in the Query tab ran it through the passthrough and failed on
//  MariaDB ("Failed to fetch return types": mysql_query prepares every statement to
//  learn its result types, and EXPLAIN isn't preparable). The Explain button already
//  runs server-native EXPLAIN on the native client; a typed EXPLAIN now takes that
//  path. This pins the recognizer: the leading EXPLAIN keyword — after comments and
//  whitespace, case-insensitive, as a whole word — and the statement left to explain.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Typed EXPLAIN")
struct TypedExplainTests {

    @Test("the statement after a leading EXPLAIN, whatever the case and spacing")
    func leadingExplain() {
        #expect(SQLBuilder.strippedExplain("EXPLAIN SELECT * FROM t") == "SELECT * FROM t")
        #expect(SQLBuilder.strippedExplain("explain\n   select 1") == "select 1")
        #expect(SQLBuilder.strippedExplain("  EXPLAIN SELECT 1  ") == "SELECT 1")
    }

    @Test("leading comments are skipped like the row-returning check does")
    func comments() {
        #expect(SQLBuilder.strippedExplain("-- plan?\nEXPLAIN SELECT 1") == "SELECT 1")
        #expect(SQLBuilder.strippedExplain("/* x */ EXPLAIN SELECT 1") == "SELECT 1")
    }

    @Test("EXPLAIN modifiers stay with the statement; explain() re-adds the keyword")
    func modifiers() {
        #expect(SQLBuilder.strippedExplain("EXPLAIN FORMAT=JSON SELECT 1") == "FORMAT=JSON SELECT 1")
        #expect(SQLBuilder.strippedExplain("EXPLAIN EXTENDED SELECT 1") == "EXTENDED SELECT 1")
    }

    @Test("anything else is not a typed EXPLAIN")
    func notExplain() {
        #expect(SQLBuilder.strippedExplain("SELECT 1") == nil)
        #expect(SQLBuilder.strippedExplain("EXPLAINS SELECT 1") == nil)
        #expect(SQLBuilder.strippedExplain("EXPLAIN") == nil)        // nothing to explain
        #expect(SQLBuilder.strippedExplain("SELECT 'EXPLAIN SELECT 1'") == nil)
    }
}
