//
//  QueryResultFilterTests.swift
//  SequelBridgeTests
//
//  The instant client-side result filter (⌘-style filter over loaded rows, no re-query).
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Result text filter")
struct QueryResultFilterTests {

    func sample() -> QueryResult {
        var r = QueryResult(columns: ["id", "name"],
                            rows: [["1", "Ada"], ["2", "Alan"], ["3", "Grace"]],
                            executionTime: 0)
        r.columnTypes = ["INT", "VARCHAR"]
        return r
    }

    @Test("a blank filter returns the result unchanged")
    func blank() {
        #expect(sample().filteredByText("").rowCount == 3)
        #expect(sample().filteredByText("   ").rowCount == 3)
    }

    @Test("matches any cell, case-insensitively")
    func matches() {
        #expect(sample().filteredByText("al").rows.map { $0[1] } == ["Alan"])
        #expect(sample().filteredByText("a").rowCount == 3)   // case-insensitive: Ada, Alan, Grace all contain 'a'
        #expect(sample().filteredByText("ada").rows.map { $0[1] } == ["Ada"])
        #expect(sample().filteredByText("3").rows.first?.first == "3")  // matches id column
    }

    @Test("no match yields zero rows and a zeroed total")
    func noMatch() {
        let f = sample().filteredByText("zzz")
        #expect(f.rowCount == 0)
        #expect(f.totalRowCount == 0)
    }

    @Test("a NULL cell does not match (the mask distinguishes it from the string)")
    func nullNotMatched() {
        var r = QueryResult(columns: ["note"], rows: [["NULL"], ["hello"]], executionTime: 0)
        r.columnTypes = ["VARCHAR"]
        r.nullMask = [[true], [false]]
        // Searching "null" must not match the actual SQL NULL row.
        #expect(r.filteredByText("null").rowCount == 0)
    }

    @Test("the null mask stays aligned with the filtered rows")
    func maskAligned() {
        var r = QueryResult(columns: ["a", "b"], rows: [["x", "NULL"], ["keep", "NULL"], ["y", "v"]], executionTime: 0)
        r.columnTypes = ["VARCHAR", "VARCHAR"]
        r.nullMask = [[false, true], [false, true], [false, false]]
        let f = r.filteredByText("keep")
        #expect(f.rowCount == 1)
        #expect(f.isNull(0, 1))          // the kept row's b is still NULL
        #expect(!f.isNull(0, 0))
    }

    @Test("a filtered result remembers which rows it kept, so an edit finds its row")
    func sourceRows() {
        #expect(sample().filteredByText("al").sourceRows == [1])     // only "Alan"
        #expect(sample().filteredByText("").sourceRows == nil)       // unfiltered: rows are their own
    }
}
