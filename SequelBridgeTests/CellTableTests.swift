//
//  CellTableTests.swift
//  SequelBridgeTests
//
//  Result cells used to live in `[[String]]`: one heap array per row and one heap
//  object per value longer than 15 bytes — ~120 bytes a cell, so a 4.7M-row, 14-column
//  result sat at ~6 GB and pushed the machine into swap while scrolling. CellTable
//  keeps each column of a chunk as one UTF-8 buffer with row offsets (plus a null
//  flag per row only where a column has NULLs), in immutable chunks so a streaming
//  append never copies what is already there. These pin the contract the grid, the
//  exporters and the streaming loop rely on: cells read back exactly, NULL is tracked
//  apart from the string "NULL", chunk seams are invisible, and the footprint is a
//  fraction of the old one.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Cell table")
struct CellTableTests {

    /// Three columns, column-major, as extraction produces them; nil is SQL NULL.
    private let colData: [[String?]] = [
        ["1", "2", "3"],
        ["Cold Start", nil, "a long value well over fifteen bytes"],
        [nil, "NULL", ""],
    ]

    @Test("cells read back exactly, with NULL told apart from the string \"NULL\"")
    func roundTrip() {
        let t = CellTable(chunk: .init(columns: colData, rowCount: 3))
        #expect(t.rowCount == 3)
        #expect(t.columnCount == 3)
        #expect(t.value(0, 1) == "Cold Start")
        #expect(t.value(2, 1) == "a long value well over fifteen bytes")
        #expect(t.value(1, 1) == "NULL")          // the display sentinel for a NULL cell
        #expect(t.isNull(1, 1) == true)
        #expect(t.value(1, 2) == "NULL")          // a real string "NULL"
        #expect(t.isNull(1, 2) == false)
        #expect(t.value(2, 2) == "")
        #expect(t.isNull(0, 2) == true)
        #expect(t.row(2) == ["3", "a long value well over fifteen bytes", ""])
    }

    @Test("the row-major materializations equal what the old assembly produced")
    func materializations() {
        let t = CellTable(chunk: .init(columns: colData, rowCount: 3))
        #expect(t.rows == [["1", "Cold Start", "NULL"], ["2", "NULL", "NULL"], ["3", "a long value well over fifteen bytes", ""]])
        #expect(t.nullMask == [[false, false, true], [false, true, false], [false, false, false]])
        #expect(t.column(0) == ["1", "2", "3"])
    }

    @Test("a table built from row-major rows and a mask reads back the same")
    func fromRows() {
        let rows = [["a", "NULL"], ["NULL", "b"]]
        let t = CellTable(rows: rows, nullMask: [[false, true], [false, false]])
        #expect(t.rows == rows)
        #expect(t.isNull(0, 1) == true)
        #expect(t.isNull(1, 0) == false)          // "NULL" the string, mask says so
        let noMask = CellTable(rows: rows, nullMask: [])
        #expect(noMask.isNull(0, 1) == false)     // no mask → nothing is NULL
    }

    @Test("appended chunks are addressed seamlessly across their boundaries")
    func appendAcrossChunks() {
        var t = CellTable(columnCount: 2)
        for k in 0..<5 {
            let base = k * 1000
            t.append(.init(columns: [(0..<1000).map { String(base + $0) },
                                     (0..<1000).map { (base + $0) % 7 == 0 ? nil : "v\(base + $0)" }], rowCount: 1000))
        }
        #expect(t.rowCount == 5000)
        for r in [0, 999, 1000, 1001, 2999, 3000, 4999] {
            #expect(t.value(r, 0) == String(r), "row \(r)")
            #expect(t.isNull(r, 1) == (r % 7 == 0), "row \(r)")
            #expect(t.value(r, 1) == (r % 7 == 0 ? "NULL" : "v\(r)"), "row \(r)")
        }
        #expect(t.row(4999) == ["4999", "v4999"])
        #expect(t.rows.count == 5000)
    }

    @Test("an empty table and out-of-range reads are safe")
    func empty() {
        let t = CellTable(columnCount: 3)
        #expect(t.rowCount == 0)
        #expect(t.rows.isEmpty)
        #expect(t.value(0, 0) == "NULL")
        #expect(t.isNull(0, 0) == false)
        #expect(t.row(5).isEmpty)
        #expect(t.value(0, 7) == "NULL")           // column out of range
    }

    @Test("the footprint is a small multiple of the text, not ~120 bytes a cell")
    func footprint() {
        // 100k rows × 10 columns of ~10-byte values: the old layout cost ≥ 100k×(32+10×16)
        // for the row arrays alone, ~19 MB; this should be near the text itself.
        let n = 100_000
        let cols: [[String?]] = (0..<10).map { c in (0..<n).map { "v\(c)-\($0 % 1000)" } }
        let t = CellTable(chunk: .init(columns: cols, rowCount: n))
        let text = cols.reduce(0) { $0 + $1.reduce(0) { $0 + ($1?.utf8.count ?? 0) } }
        #expect(t.approximateByteCount < text + n * 10 * 5)      // bytes + a 4-byte offset (+ null flags)
        #expect(t.approximateByteCount < n * 10 * 24)
    }

    @Test("an edited cell is replaced in place; NULL and every other cell are kept")
    func setValue() {
        var t = CellTable(columnCount: 2)
        t.append(.init(columns: [["1", "2"], ["a", nil]], rowCount: 2))
        t.append(.init(columns: [["3"], ["c"]], rowCount: 1))
        t.setValue("bee", row: 1, column: 1)       // NULL -> a value, in the first chunk
        t.setValue(nil, row: 2, column: 1)         // a value -> NULL, in the second
        t.setValue("one", row: 0, column: 0)
        #expect(t.rows == [["one", "a"], ["2", "bee"], ["3", "NULL"]])
        #expect(t.nullMask == [[false, false], [false, false], [false, true]])
        #expect(t.chunks.count == 2)
        t.setValue("x", row: 9, column: 0)         // outside the table: ignored
        #expect(t.rowCount == 3)
    }
}
