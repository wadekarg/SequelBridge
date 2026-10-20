//
//  ContentFilterTests.swift
//  SequelBridgeTests
//
//  The Content tab's filter as in Sequel Ace: a column, an operator and a value, made
//  into the WHERE condition for whichever server reads the page. From the Sequel Ace
//  checklist (guide/SEQUEL-ACE.md), where only a typed WHERE condition existed.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Content filter: a column, an operator, a value")
struct ContentFilterTests {
    typealias F = ContentFilter

    @Test("comparisons quote the value, so MySQL never compares a text column as a number")
    func comparisons() {
        #expect(F.condition(column: "status", op: .equals, value: "paid", dialect: .mysql) == "`status` = 'paid'")
        #expect(F.condition(column: "id", op: .notEquals, value: "5", dialect: .mysql) == "`id` <> '5'")
        #expect(F.condition(column: "total", op: .greaterOrEqual, value: "10", dialect: .standard) == "\"total\" >= '10'")
        #expect(F.condition(column: "total", op: .less, value: "10", dialect: .clickhouse) == "\"total\" < '10'")
    }

    @Test("a quote or a backslash in the value stays part of the value")
    func escaping() {
        #expect(F.condition(column: "name", op: .equals, value: "O'Brien", dialect: .standard) == "\"name\" = 'O''Brien'")
        #expect(F.condition(column: "path", op: .equals, value: #"C:\new"#, dialect: .mysql) == #"`path` = 'C:\\new'"#)
        #expect(F.condition(column: "path", op: .equals, value: #"C:\new"#, dialect: .standard) == #""path" = 'C:\new'"#)
        #expect(F.condition(column: "path", op: .equals, value: #"C:\new"#, dialect: .clickhouse) == #""path" = 'C:\\new'"#)
        #expect(F.condition(column: "we`ird", op: .isNull, value: "", dialect: .mysql) == "`we``ird` IS NULL")
        #expect(F.condition(column: "we\"ird", op: .isNull, value: "", dialect: .standard) == "\"we\"\"ird\" IS NULL")
    }

    @Test("contains, begins with, ends with: a % or _ in the value is matched as itself")
    func like() {
        #expect(F.condition(column: "note", op: .contains, value: "50%", dialect: .mysql) == #"`note` LIKE '%50\\%%'"#)
        #expect(F.condition(column: "note", op: .beginsWith, value: "a_b", dialect: .standard) == #""note" LIKE 'a\_b%' ESCAPE '\'"#)
        #expect(F.condition(column: "note", op: .endsWith, value: "x", dialect: .clickhouse) == "\"note\" LIKE '%x'")
        #expect(F.condition(column: "note", op: .notContains, value: "it's", dialect: .mysql) == "`note` NOT LIKE '%it''s%'")
    }

    @Test("is in takes a comma-separated list; between takes both ends")
    func listsAndRanges() {
        #expect(F.condition(column: "id", op: .isIn, value: " 1, 2 ,3,", dialect: .mysql) == "`id` IN ('1', '2', '3')")
        #expect(F.condition(column: "id", op: .isIn, value: " , ", dialect: .mysql) == nil)
        #expect(F.condition(column: "placed_at", op: .between, value: "2026-01-01", value2: "2026-12-31", dialect: .standard)
                == "\"placed_at\" BETWEEN '2026-01-01' AND '2026-12-31'")
        #expect(F.condition(column: "placed_at", op: .between, value: "2026-01-01", value2: " ", dialect: .standard) == nil)
    }

    @Test("NULL tests take no value; an operator that needs one has none to go on")
    func nulls() {
        #expect(F.condition(column: "note", op: .isNull, value: "ignored", dialect: .mysql) == "`note` IS NULL")
        #expect(F.condition(column: "note", op: .isNotNull, value: "", dialect: .standard) == "\"note\" IS NOT NULL")
        #expect(F.condition(column: "note", op: .equals, value: "", dialect: .mysql) == "`note` = ''")
        #expect(F.condition(column: "note", op: .contains, value: "", dialect: .mysql) == nil)
        #expect(!F.Op.isNull.takesValue && !F.Op.isNotNull.takesValue)
        #expect(F.Op.allCases.filter(\.takesValue).count == F.Op.allCases.count - 2)
    }

    @MainActor @Test("in DuckDB (SQLite files, and MySQL read by the scanner) the rules find awkward values as themselves")
    func duckdb() async throws {
        let e = try QueryEngine()
        _ = try await e.query("CREATE TEMP TABLE cf (id INT, note VARCHAR)")
        _ = try await e.query(#"INSERT INTO cf VALUES (1, '50%'), (2, '50 off'), (3, 'a_b'), (4, 'axb'), (5, 'C:\new'), (6, 'O''Brien'), (7, NULL)"#)
        func ids(_ op: F.Op, _ value: String) async throws -> [String] {
            let condition = try #require(F.condition(column: "note", op: op, value: value, dialect: .standard))
            return try await e.query("SELECT id FROM cf WHERE \(condition) ORDER BY id").rows.map { $0[0] }
        }
        #expect(try await ids(.contains, "50%") == ["1"])
        #expect(try await ids(.beginsWith, "a_") == ["3"])
        #expect(try await ids(.equals, #"C:\new"#) == ["5"])
        #expect(try await ids(.equals, "O'Brien") == ["6"])
        #expect(try await ids(.isNull, "") == ["7"])
        #expect(try await ids(.isIn, "axb, a_b") == ["3", "4"])
    }

    @Test("the server that reads the page decides the dialect")
    func dialect() {
        #expect(F.dialect(engine: .mysql, passthrough: true) == .mysql)
        #expect(F.dialect(engine: .mysql, passthrough: false) == .standard)     // DuckDB reads it
        #expect(F.dialect(engine: .postgres, passthrough: true) == .standard)
        #expect(F.dialect(engine: .sqlite, passthrough: false) == .standard)
        #expect(F.dialect(engine: .clickhouse, passthrough: false) == .clickhouse)
    }
}
