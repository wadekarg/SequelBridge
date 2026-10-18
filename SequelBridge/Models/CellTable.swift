//
//  CellTable.swift
//  SequelBridge
//
//  Compact storage for a result's cells. `[[String]]` cost ~120 bytes a cell — a heap
//  array per row plus a heap object for every value over 15 bytes — so a 4.7M-row,
//  14-column result sat at ~6 GB and pushed the machine into swap while scrolling.
//  Here each column of a chunk is one UTF-8 buffer with a row-end offset per value
//  (and a null flag per row only where the column has NULLs): the text itself plus
//  ~4 bytes a cell. Chunks are immutable and appended as a stream arrives, so growing
//  a result never copies what is already there, and a cell is found by a binary
//  search over the chunk starts. Values are decoded to String on access; the grid
//  only ever asks for the cells on screen.
//

import Foundation

nonisolated struct CellTable: Sendable {

    /// The rows of one extraction batch, column-major.
    struct Chunk: Sendable {
        struct Column: Sendable {
            var bytes: [UInt8]      // every value's UTF-8, back to back
            var ends: [UInt32]      // end offset of each row's value; it starts at the previous end
            var nulls: [Bool]?      // true where the cell is SQL NULL; nil when the column has none

            init(values: [String?], rowCount: Int) {
                var size = 0
                for v in values { size += v?.utf8.count ?? 0 }
                bytes = []
                bytes.reserveCapacity(size)
                ends = []
                ends.reserveCapacity(rowCount)
                nulls = nil
                for (i, v) in values.prefix(rowCount).enumerated() {
                    if var s = v {
                        s.withUTF8 { bytes.append(contentsOf: $0) }
                    } else {
                        if nulls == nil { nulls = [Bool](repeating: false, count: rowCount) }
                        nulls![i] = true
                    }
                    ends.append(UInt32(bytes.count))
                }
                while ends.count < rowCount { ends.append(UInt32(bytes.count)) }
            }

            func value(_ row: Int) -> String {
                let end = Int(ends[row])
                let start = row == 0 ? 0 : Int(ends[row - 1])
                return bytes.withUnsafeBufferPointer { buf in
                    String(decoding: UnsafeBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
                }
            }

            func isNull(_ row: Int) -> Bool { nulls?[row] ?? false }
        }

        let rowCount: Int
        let columns: [Column]

        /// From column-major values as extraction produces them; nil is SQL NULL.
        init(columns colData: [[String?]], rowCount: Int) {
            self.rowCount = rowCount
            self.columns = colData.map { Column(values: $0, rowCount: rowCount) }
        }

        /// From row-major rows and a parallel null mask (empty mask: nothing is NULL).
        init(rows: [[String]], nullMask: [[Bool]], columnCount: Int) {
            let n = rows.count
            var colData: [[String?]] = Array(repeating: [], count: columnCount)
            for c in 0..<columnCount {
                colData[c].reserveCapacity(n)
                for r in 0..<n {
                    let isNull = r < nullMask.count && c < nullMask[r].count && nullMask[r][c]
                    colData[c].append(isNull ? nil : (c < rows[r].count ? rows[r][c] : ""))
                }
            }
            self.init(columns: colData, rowCount: n)
        }

        private init(rowCount: Int, builtColumns: [Column]) {
            self.rowCount = rowCount
            self.columns = builtColumns
        }

        /// This chunk with one cell replaced.
        func replacing(row: Int, column c: Int, with value: String?) -> Chunk {
            let old = columns[c]
            var values: [String?] = (0..<rowCount).map { old.isNull($0) ? nil : old.value($0) }
            values[row] = value
            var cols = columns
            cols[c] = Column(values: values, rowCount: rowCount)
            return Chunk(rowCount: rowCount, builtColumns: cols)
        }

        /// Row-major materializations, for tests and small results.
        var rows: [[String]] { (0..<rowCount).map { r in columns.map { $0.isNull(r) ? "NULL" : $0.value(r) } } }
        var mask: [[Bool]] { (0..<rowCount).map { r in columns.map { $0.isNull(r) } } }
    }

    /// Display sentinel for a NULL cell (and for a read outside the table).
    static let nullText = "NULL"

    private(set) var chunks: [Chunk] = []
    private var starts: [Int] = []      // first row index of each chunk
    let columnCount: Int
    private(set) var rowCount = 0
    /// False only for a table built from rows without a mask — the legacy producers
    /// that never tracked nullability; `QueryResult.isNull` then falls back to the
    /// "NULL" display sentinel as it always did.
    let tracksNulls: Bool

    init(columnCount: Int) {
        self.columnCount = columnCount
        self.tracksNulls = true
    }

    init(chunk: Chunk) {
        self.init(columnCount: chunk.columns.count)
        append(chunk)
    }

    /// From row-major rows (the legacy shape); `nullMask` may be empty.
    init(rows: [[String]], nullMask: [[Bool]]) {
        let columnCount = rows.first?.count ?? 0
        self.columnCount = columnCount
        self.tracksNulls = !nullMask.isEmpty
        if !rows.isEmpty { append(Chunk(rows: rows, nullMask: nullMask, columnCount: columnCount)) }
    }

    mutating func append(_ chunk: Chunk) {
        guard chunk.rowCount > 0 else { return }
        chunks.append(chunk)
        starts.append(rowCount)
        rowCount += chunk.rowCount
    }

    /// The chunk holding `row` and the row's offset within it; nil when out of range.
    private func locate(_ row: Int) -> (chunk: Int, offset: Int)? {
        guard row >= 0, row < rowCount else { return nil }
        var lo = 0, hi = chunks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return (lo, row - starts[lo])
    }

    /// The cell's text; `nullText` for a NULL cell or a read outside the table.
    func value(_ row: Int, _ col: Int) -> String {
        guard col >= 0, col < columnCount, let at = locate(row) else { return Self.nullText }
        let column = chunks[at.chunk].columns[col]
        return column.isNull(at.offset) ? Self.nullText : column.value(at.offset)
    }

    func isNull(_ row: Int, _ col: Int) -> Bool {
        guard col >= 0, col < columnCount, let at = locate(row) else { return false }
        return chunks[at.chunk].columns[col].isNull(at.offset)
    }

    /// One row, materialized; empty when out of range.
    func row(_ i: Int) -> [String] {
        guard let at = locate(i) else { return [] }
        return chunks[at.chunk].columns.map { $0.isNull(at.offset) ? Self.nullText : $0.value(at.offset) }
    }

    /// One column, materialized (NULL as the sentinel) — what a client-side sort keys on.
    func column(_ c: Int) -> [String] {
        guard c >= 0, c < columnCount else { return [] }
        var out: [String] = []
        out.reserveCapacity(rowCount)
        for chunk in chunks {
            let column = chunk.columns[c]
            for r in 0..<chunk.rowCount { out.append(column.isNull(r) ? Self.nullText : column.value(r)) }
        }
        return out
    }

    /// Replaces one cell (a saved edit); nil is SQL NULL. Only that column of the
    /// cell's chunk is rebuilt. A cell outside the table is ignored.
    mutating func setValue(_ value: String?, row: Int, column: Int) {
        guard column >= 0, column < columnCount, let at = locate(row) else { return }
        chunks[at.chunk] = chunks[at.chunk].replacing(row: at.offset, column: column, with: value)
    }

    /// Only the given rows (original indices, in the given order), as one chunk.
    func selecting(rows keep: [Int]) -> CellTable {
        var out = CellTable(columnCount: columnCount)
        guard !keep.isEmpty else { return out }
        let colData: [[String?]] = (0..<columnCount).map { c in
            keep.map { isNull($0, c) ? nil : value($0, c) }
        }
        out.append(Chunk(columns: colData, rowCount: keep.count))
        return out
    }

    /// Row-major materializations of the whole table — for small results and tests;
    /// never on a hot path with a large result.
    var rows: [[String]] { chunks.flatMap(\.rows) }
    var nullMask: [[Bool]] { chunks.flatMap(\.mask) }

    /// Bytes held by the cell buffers (text, offsets, null flags), ignoring array headers.
    var approximateByteCount: Int {
        chunks.reduce(0) { acc, chunk in
            acc + chunk.columns.reduce(0) { $0 + $1.bytes.count + $1.ends.count * 4 + ($1.nulls?.count ?? 0) }
        }
    }
}
