//
//  ColumnAlignmentTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Column alignment")
struct ColumnAlignmentTests {

    @Test("numeric types right-align", arguments: [
        "INT", "BIGINT", "SMALLINT", "TINYINT", "HUGEINT",
        "UINT", "UBIGINT", "USMALLINT", "UTINYINT",
        "FLOAT", "DOUBLE", "DECIMAL",
    ])
    func numericTypes(_ type: String) {
        #expect(QueryResult.isNumericType(type))
    }

    @Test("text and temporal types keep left alignment", arguments: [
        "VARCHAR", "TEXT", "BLOB", "DATE", "DATETIME", "TIME",
        "BOOLEAN", "UUID", "ENUM", "",
    ])
    func nonNumericTypes(_ type: String) {
        #expect(!QueryResult.isNumericType(type))
    }

    @Test("case does not matter")
    func caseInsensitive() {
        #expect(QueryResult.isNumericType("bigint"))
        #expect(QueryResult.isNumericType("Decimal"))
    }
}
