//
//  ResultsGridSortOrderTests.swift
//  SequelBridgeTests
//
//  ResultsGridView sorts rows client-side and reports row indices back to the
//  Content tab, which builds primary-key WHERE clauses from its UNSORTED rows.
//  If a sorted display index leaks out unchanged, an edit/delete hits the wrong
//  database row. sortOrder() is the permutation used to translate a display
//  position back to its original row; these tests pin it.
//

import Testing
@testable import SequelBridge

@Suite("ResultsGrid sort order mapping")
struct ResultsGridSortOrderTests {

    let rows = [["b", "2"], ["a", "3"], ["c", "1"]]

    @Test("no sort column is the identity permutation")
    func identity() {
        #expect(ResultsTableView.sortOrder(rows: rows, column: nil, ascending: true) == [0, 1, 2])
    }

    @Test("lexicographic ascending sort maps display index to original index")
    func lexAscending() {
        // column 0: a(1), b(0), c(2)
        let order = ResultsTableView.sortOrder(rows: rows, column: 0, ascending: true)
        #expect(order == [1, 0, 2])
        // display row 0 is original row 1 (the "a" row) — the value the parent must edit
        #expect(rows[order[0]][0] == "a")
    }

    @Test("descending sort reverses the mapping")
    func lexDescending() {
        #expect(ResultsTableView.sortOrder(rows: rows, column: 0, ascending: false) == [2, 0, 1])
    }

    @Test("numeric columns sort numerically, not lexicographically")
    func numeric() {
        // column 1 values "2","3","1" -> ascending 1,2,3 -> original 2,0,1
        let order = ResultsTableView.sortOrder(rows: rows, column: 1, ascending: true)
        #expect(order == [2, 0, 1])
        #expect(rows[order[0]][1] == "1")
    }

    @Test("sort order is always a permutation of every original index")
    func isPermutation() {
        let big = (0..<50).map { [String($0 * 7 % 13), "x"] }
        let order = ResultsTableView.sortOrder(rows: big, column: 0, ascending: true)
        #expect(Set(order) == Set(0..<big.count))
        #expect(order.count == big.count)
    }
}

/// The grid reloads only when `reloadSignature` changes. A Content-browser page
/// change or a server-side re-sort keeps the columns, row count, total and
/// (placeholder) executionTime identical while the ROW CONTENT changes — so the
/// signature must reflect content, or the grid shows stale rows. This suite pins
/// that: the regression where sorting/paging a table left the old rows on screen.
@Suite("Results grid reload signature")
struct ResultsGridReloadSignatureTests {

    private func page(_ rows: [[String]]) -> QueryResult {
        // Same shape the Content browser builds: fixed columns, executionTime 0,
        // a stable total — only the rows differ between pages / sort orders.
        var r = QueryResult(columns: ["id", "value"], rows: rows, executionTime: 0)
        r.totalRowCount = 100_000
        return r
    }

    @Test("identical results share a signature (no needless reload)")
    func identical() {
        let a = page([["1", "10"], ["2", "20"]])
        let b = page([["1", "10"], ["2", "20"]])
        #expect(ResultsTableView.reloadSignature(for: a) == ResultsTableView.reloadSignature(for: b))
    }

    @Test("a page change with the same shape changes the signature")
    func pageChange() {
        let p1 = page([["1", "10"], ["2", "20"]])
        let p2 = page([["3", "30"], ["4", "40"]])   // next page: same columns/count/total
        #expect(ResultsTableView.reloadSignature(for: p1) != ResultsTableView.reloadSignature(for: p2))
    }

    @Test("a re-sort (same rows, new order) changes the signature")
    func reSort() {
        let unsorted = page([["1", "30"], ["2", "10"], ["3", "20"]])
        let sorted   = page([["2", "10"], ["3", "20"], ["1", "30"]])   // ORDER BY value
        #expect(ResultsTableView.reloadSignature(for: unsorted) != ResultsTableView.reloadSignature(for: sorted))
    }

    @Test("a streamed append (growing row count) changes the signature")
    func streamAppend() {
        let first = page([["1", "10"], ["2", "20"]])
        let more  = page([["1", "10"], ["2", "20"], ["3", "30"]])
        #expect(ResultsTableView.reloadSignature(for: first) != ResultsTableView.reloadSignature(for: more))
    }
}
