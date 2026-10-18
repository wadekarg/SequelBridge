//
//  ResultsStreamingPerfTests.swift
//  SequelBridgeTests
//
//  Large results stream in 20k-row chunks. Pushing every chunk through the published
//  QueryTab re-copied the growing rows array and re-rendered the whole workspace per
//  chunk — super-linear in rows × columns (1M wide rows took minutes to finish painting
//  while the fetch itself took 10s). These pin the two pure pieces of the fix:
//  • StreamBatcher: chunks are buffered and flushed to the UI on a size/time cadence,
//    so a million rows cost a handful of publishes instead of fifty.
//  • ResultsTableView.displayOrder: the identity order is represented as an EMPTY
//    permutation, so an unsorted grid never materializes an O(rows) index array on
//    every refresh.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Streaming flush batcher")
struct StreamBatcherTests {

    @Test("below both thresholds nothing flushes")
    func belowThresholds() {
        var b = StreamBatcher(maxPendingRows: 200_000, maxInterval: 0.4, now: 0)
        #expect(b.add(20_000, now: 0.05) == false)
        #expect(b.pendingRows == 20_000)
    }

    @Test("reaching the row threshold flushes and resets the pending count")
    func rowThreshold() {
        var b = StreamBatcher(maxPendingRows: 50_000, maxInterval: 60, now: 0)
        #expect(b.add(20_000, now: 0.01) == false)
        #expect(b.add(20_000, now: 0.02) == false)
        #expect(b.add(20_000, now: 0.03) == true)     // 60k ≥ 50k
        #expect(b.pendingRows == 0)
    }

    @Test("exceeding the interval flushes even a small batch, so progress stays visible")
    func timeThreshold() {
        var b = StreamBatcher(maxPendingRows: 1_000_000, maxInterval: 0.4, now: 10.0)
        #expect(b.add(100, now: 10.1) == false)
        #expect(b.add(100, now: 10.45) == true)       // 0.45s since the last flush
        #expect(b.lastFlush == 10.45)
    }

    @Test("a million rows in 20k chunks every 60ms costs a handful of flushes, not fifty")
    func millionRowScenario() {
        var b = StreamBatcher(maxPendingRows: 200_000, maxInterval: 0.4, now: 0)
        var flushes = 0
        for i in 1...50 { if b.add(20_000, now: Double(i) * 0.06) { flushes += 1 } }
        // Time (every 7 chunks: 0.42s) wins over rows (every 10): flushes at chunks
        // 7, 14, 21, 28, 35, 42, 49 — seven publishes for a million rows.
        #expect(flushes == 7)
        #expect(b.pendingRows == 20_000)              // the caller flushes the tail itself
    }
}

@Suite("Results grid display order")
struct ResultsGridDisplayOrderTests {

    let rows = [["b", "2"], ["a", "3"], ["c", "1"]]

    @Test("no local sort yields the empty (identity) order — nothing O(rows) is built")
    func identityIsEmpty() {
        #expect(ResultsTableView.displayOrder(rows: rows, column: nil, ascending: true, isServerSort: false).isEmpty)
    }

    @Test("a server-side sort also yields the identity order (the page is already ordered)")
    func serverSortIsIdentity() {
        #expect(ResultsTableView.displayOrder(rows: rows, column: 0, ascending: true, isServerSort: true).isEmpty)
    }

    @Test("a client-side sort yields the same permutation as sortOrder")
    func clientSortPermutes() {
        let order = ResultsTableView.displayOrder(rows: rows, column: 0, ascending: true, isServerSort: false)
        #expect(order == ResultsTableView.sortOrder(rows: rows, column: 0, ascending: true))
        #expect(order == [1, 0, 2])
    }
}
