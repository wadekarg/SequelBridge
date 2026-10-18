//
//  ClickHouseParseTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("ClickHouse TSV parsing")
struct ClickHouseParseTests {

    @Test("names, types and rows come apart correctly")
    func basic() {
        let text = "id\ttail\tvalue\nUInt32\tString\tFloat64\n1\tN001SB\t9.5\n2\tN002SB\t7.25\n"
        let r = ClickHouseClient.parseTSVWithNamesAndTypes(text)
        #expect(r.columns == ["id", "tail", "value"])
        #expect(r.columnTypes == ["UInt32", "String", "Float64"])
        #expect(r.rows == [["1", "N001SB", "9.5"], ["2", "N002SB", "7.25"]])
        #expect(r.totalRowCount == 2)
    }

    @Test("NULL arrives as the app's NULL sentinel")
    func nulls() {
        let text = "a\nNullable(String)\n\\N\nplain\n"
        let r = ClickHouseClient.parseTSVWithNamesAndTypes(text)
        #expect(r.rows == [["NULL"], ["plain"]])
    }

    @Test("escaped tabs, newlines and backslashes survive")
    func escapes() {
        let text = "a\nString\ncol\\tumn\nline\\nbreak\nback\\\\slash\n"
        let r = ClickHouseClient.parseTSVWithNamesAndTypes(text)
        #expect(r.rows == [["col\tumn"], ["line\nbreak"], ["back\\slash"]])
    }

    @Test("empty fields are preserved, not collapsed")
    func emptyFields() {
        let text = "a\tb\tc\nString\tString\tString\n\tmiddle\t\n"
        let r = ClickHouseClient.parseTSVWithNamesAndTypes(text)
        #expect(r.rows == [["", "middle", ""]])
    }

    @Test("a result with no rows still carries columns and types")
    func headerOnly() {
        let text = "n\nUInt64\n"
        let r = ClickHouseClient.parseTSVWithNamesAndTypes(text)
        #expect(r.columns == ["n"])
        #expect(r.rows.isEmpty)
        #expect(!r.isTruncated)
    }

    @Test("ClickHouse numeric types right-align, Nullable included", arguments: [
        "UInt32", "UInt64", "Int8", "Int64", "Float32", "Float64",
        "Decimal(10, 2)", "Nullable(UInt32)", "Nullable(Float64)",
    ])
    func numericTypes(_ t: String) {
        #expect(QueryResult.isNumericType(t))
    }

    @Test("ClickHouse text types stay left", arguments: [
        "String", "Nullable(String)", "DateTime", "Date", "UUID", "Array(UInt32)",
    ])
    func textTypes(_ t: String) {
        #expect(!QueryResult.isNumericType(t))
    }
}
