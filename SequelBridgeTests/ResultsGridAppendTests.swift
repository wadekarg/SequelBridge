//
//  ResultsGridAppendTests.swift
//  SequelBridgeTests
//
//  While a large result streams in, every published batch used to reload the whole
//  NSTableView, which discards and rebuilds all visible cells (each with Auto Layout
//  constraints) — ~45% of main-thread time in a profile. An append-only update (same
//  columns, same leading rows, more rows, no client-side sort) only needs the table
//  told its row count grew; existing cells stay. This pins the decision.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Results grid update kind")
struct ResultsGridAppendTests {

    private func result(_ rows: [[String]], columns: [String] = ["a", "b"]) -> QueryResult {
        QueryResult(columns: columns, rows: rows, executionTime: 0)
    }

    @Test("more rows with the same columns and first row is an append")
    func append() {
        let before = result([["1", "x"], ["2", "y"]])
        let after  = result([["1", "x"], ["2", "y"], ["3", "z"]])
        #expect(ResultsTableView.updateKind(from: before, to: after, clientSorted: false) == .append)
    }

    @Test("a different first row is a reload (new result, page change, re-sort)")
    func newResult() {
        let before = result([["1", "x"], ["2", "y"]])
        let after  = result([["9", "q"], ["2", "y"], ["3", "z"]])
        #expect(ResultsTableView.updateKind(from: before, to: after, clientSorted: false) == .reload)
    }

    @Test("fewer or equal rows is a reload")
    func shrinkOrSame() {
        let before = result([["1", "x"], ["2", "y"]])
        #expect(ResultsTableView.updateKind(from: before, to: result([["1", "x"]]), clientSorted: false) == .reload)
        #expect(ResultsTableView.updateKind(from: before, to: result([["1", "x"], ["2", "y"]]), clientSorted: false) == .reload)
    }

    @Test("changed columns is a reload")
    func columnsChanged() {
        let before = result([["1", "x"]])
        let after  = result([["1", "x", "!"], ["2", "y", "!"]], columns: ["a", "b", "c"])
        #expect(ResultsTableView.updateKind(from: before, to: after, clientSorted: false) == .reload)
    }

    @Test("with a client-side sort active, growth must re-sort, so it is a reload")
    func sortedGrowth() {
        let before = result([["1", "x"], ["2", "y"]])
        let after  = result([["1", "x"], ["2", "y"], ["0", "z"]])
        #expect(ResultsTableView.updateKind(from: before, to: after, clientSorted: true) == .reload)
    }

    @Test("from no previous result is a reload")
    func fromNothing() {
        #expect(ResultsTableView.updateKind(from: nil, to: result([["1", "x"]]), clientSorted: false) == .reload)
    }
}
