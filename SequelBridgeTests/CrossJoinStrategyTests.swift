//
//  CrossJoinStrategyTests.swift
//  SequelBridgeTests
//
//  The cross-server inner-join reduction pushes `WHERE key IN (probe keys)` to the big
//  side. Measured against a real server: that key list matched nearly every row of a 2.6M-row table
//  (the join column had a handful of distinct values, '' among them), and even with an
//  index on the column the server took 300s to return the same rows a plain whole-table
//  fetch returned in 30s. Index presence is not the signal — SELECTIVITY is, and the
//  server's own optimizer estimates it instantly via EXPLAIN. These pin the decision and
//  the parsing of MySQL/MariaDB EXPLAIN output into an estimated matched-row count.
//

import Testing
@testable import SequelBridge

@Suite("Cross-server join strategy")
struct CrossJoinStrategyTests {

    @Test("a selective key list keeps the IN-list reduction")
    func selective() {
        #expect(SQLBuilder.crossJoinStrategy(estimatedMatchedRows: 4_000, bigRowEstimate: 2_600_000) == .reduce)
    }

    @Test("a key list matching most of the table fetches the whole table instead")
    func nonSelective() {
        #expect(SQLBuilder.crossJoinStrategy(estimatedMatchedRows: 2_500_000, bigRowEstimate: 2_600_000) == .fetchWhole)
        // 40% is the line: a whole-table sequential fetch beats pulling that much by index.
        #expect(SQLBuilder.crossJoinStrategy(estimatedMatchedRows: 1_040_000, bigRowEstimate: 2_600_000) == .fetchWhole)
        #expect(SQLBuilder.crossJoinStrategy(estimatedMatchedRows: 1_000_000, bigRowEstimate: 2_600_000) == .reduce)
    }

    @Test("no estimate (EXPLAIN unavailable or unparseable) keeps the reduction")
    func unknown() {
        #expect(SQLBuilder.crossJoinStrategy(estimatedMatchedRows: nil, bigRowEstimate: 2_600_000) == .reduce)
        #expect(SQLBuilder.crossJoinStrategy(estimatedMatchedRows: 100, bigRowEstimate: nil) == .reduce)
        #expect(SQLBuilder.crossJoinStrategy(estimatedMatchedRows: 100, bigRowEstimate: 0) == .reduce)
    }
}

@Suite("MySQL EXPLAIN row estimate parsing")
struct ExplainEstimateTests {

    // MariaDB/MySQL EXPLAIN column layout.
    let cols = ["id", "select_type", "table", "type", "possible_keys", "key", "key_len", "ref", "rows", "filtered", "Extra"]

    @Test("a range scan's rows estimate is taken as-is when filtered is 100")
    func rangeScan() {
        let rows = [["1", "SIMPLE", "orders", "range", "PRIMARY", "PRIMARY", "22", "NULL", "2600000", "100.00", "Using index condition"]]
        #expect(SQLBuilder.explainEstimatedRows(columns: cols, rows: rows) == 2_600_000)
    }

    @Test("a full scan applies the filtered percentage")
    func fullScanFiltered() {
        let rows = [["1", "SIMPLE", "big_events", "ALL", "NULL", "NULL", "NULL", "NULL", "200000", "2.00", "Using where"]]
        #expect(SQLBuilder.explainEstimatedRows(columns: cols, rows: rows) == 4_000)
    }

    @Test("without a filtered column the rows estimate is used")
    func noFilteredColumn() {
        let c = ["id", "select_type", "table", "type", "possible_keys", "key", "key_len", "ref", "rows", "Extra"]
        let rows = [["1", "SIMPLE", "t", "ref", "k", "k", "4", "const", "12", "Using where"]]
        #expect(SQLBuilder.explainEstimatedRows(columns: c, rows: rows) == 12)
    }

    @Test("multiple plan rows sum; missing or NULL rows give no estimate")
    func sumsAndNulls() {
        let two = [["1", "SIMPLE", "a", "ALL", "NULL", "NULL", "NULL", "NULL", "10", "100.00", ""],
                   ["1", "SIMPLE", "b", "ref", "k", "k", "4", "a.x", "5", "100.00", ""]]
        #expect(SQLBuilder.explainEstimatedRows(columns: cols, rows: two) == 15)
        let nullRows = [["1", "SIMPLE", "t", "ALL", "NULL", "NULL", "NULL", "NULL", "NULL", "100.00", ""]]
        #expect(SQLBuilder.explainEstimatedRows(columns: cols, rows: nullRows) == nil)
        #expect(SQLBuilder.explainEstimatedRows(columns: ["id", "select_type"], rows: [["1", "SIMPLE"]]) == nil)
    }
}
