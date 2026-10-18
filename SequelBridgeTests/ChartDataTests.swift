//
//  ChartDataTests.swift
//  SequelBridgeTests
//
//  Data extraction behind the inline result chart.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Chart data extraction")
struct ChartDataTests {

    func sample() -> QueryResult {
        var r = QueryResult(columns: ["name", "total"],
                            rows: [["Ada", "10"], ["Alan", "25"], ["Grace", "7.5"]],
                            executionTime: 0)
        r.columnTypes = ["VARCHAR", "DOUBLE"]
        return r
    }

    @Test("numeric columns are detected by type")
    func numericByType() {
        #expect(ChartData.numericColumnIndices(sample()) == [1])
    }

    @Test("numeric columns are sniffed when types are missing")
    func numericBySniff() {
        let r = QueryResult(columns: ["a", "b"], rows: [["x", "1"], ["y", "2"]], executionTime: 0)
        #expect(ChartData.numericColumnIndices(r) == [1])   // b parses as numbers, a doesn't
    }

    @Test("defaults pick a text label and a numeric value")
    func defaults() {
        #expect(ChartData.defaultLabelColumn(sample()) == 0)
        #expect(ChartData.defaultValueColumn(sample()) == 1)
    }

    @Test("points parse values and pair them with labels")
    func points() {
        let pts = ChartData.points(sample(), labelCol: 0, valueCol: 1)
        #expect(pts.map(\.label) == ["Ada", "Alan", "Grace"])
        #expect(pts.map(\.value) == [10, 25, 7.5])
    }

    @Test("NULL and non-numeric values are skipped")
    func skipsBadValues() {
        var r = QueryResult(columns: ["k", "v"], rows: [["a", "1"], ["b", "NULL"], ["c", "n/a"], ["d", "4"]], executionTime: 0)
        r.columnTypes = ["VARCHAR", "VARCHAR"]
        r.nullMask = [[false, false], [false, true], [false, false], [false, false]]
        let pts = ChartData.points(r, labelCol: 0, valueCol: 1)
        #expect(pts.map(\.label) == ["a", "d"])   // NULL and "n/a" dropped
    }

    @Test("the point count is capped")
    func cap() {
        let rows = (0..<500).map { [String($0), String($0)] }
        var r = QueryResult(columns: ["i", "v"], rows: rows, executionTime: 0)
        r.columnTypes = ["INT", "INT"]
        #expect(ChartData.points(r, labelCol: 0, valueCol: 1, cap: 200).count == 200)
    }
}
