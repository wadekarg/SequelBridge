//
//  QueryResult.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation

nonisolated struct QueryResult {
    var columns: [String]
    var columnTypes: [String] = []
    /// How many rows the query really produced; `cells` holds at most the display cap.
    var totalRowCount: Int = 0
    var isTruncated: Bool { totalRowCount > rowCount }
    /// The cells, compact and chunked (see CellTable). The grid, the streaming loop,
    /// the exporters and the chart read through it; `rows`/`nullMask` below materialize
    /// the whole result and exist for small results (metadata, pages) and tests.
    var cells: CellTable
    var rowCount: Int { cells.rowCount }
    var executionTime: Double   // seconds
    var affectedRows: Int?      // for INSERT/UPDATE/DELETE
    /// For a filtered result: the row of the unfiltered result each row came from, so a
    /// saved edit lands on the right row. nil when the rows are the result's own.
    var sourceRows: [Int]? = nil

    init(columns: [String], cells: CellTable, executionTime: Double) {
        self.columns = columns
        self.cells = cells
        self.executionTime = executionTime
    }

    /// From row-major rows with no nullability (the legacy shape): a "NULL" string
    /// then counts as NULL, as it always did — set `nullMask` to say otherwise.
    init(columns: [String], rows: [[String]], executionTime: Double) {
        self.init(columns: columns, cells: CellTable(rows: rows, nullMask: []), executionTime: executionTime)
    }

    static let empty = QueryResult(columns: [], rows: [], executionTime: 0)

    /// All rows as strings for display ("NULL" shown for SQL NULL). Materializes the
    /// whole result on every read — small results only.
    var rows: [[String]] {
        get { cells.rows }
        set { cells = CellTable(rows: newValue, nullMask: cells.tracksNulls ? cells.nullMask : []) }
    }

    /// Parallel to `rows`: true where the cell is SQL NULL. Empty when the producer
    /// didn't track nullability — `isNull` then falls back to the "NULL" display string,
    /// which is what distinguishes a real string value "NULL" from an actual NULL.
    var nullMask: [[Bool]] {
        get { cells.tracksNulls ? cells.nullMask : [] }
        set { cells = CellTable(rows: cells.rows, nullMask: newValue) }
    }

    /// Whether cell (row, col) is SQL NULL. Uses tracked nullability when available,
    /// otherwise falls back to the legacy "NULL" display sentinel.
    func isNull(_ row: Int, _ col: Int) -> Bool {
        if cells.tracksNulls { return cells.isNull(row, col) }
        return row < rowCount && col < columns.count && cells.value(row, col) == CellTable.nullText
    }

    /// One row's display strings; empty when out of range.
    func row(_ i: Int) -> [String] { cells.row(i) }
}

nonisolated extension QueryResult {
    /// Client-side filter over the already-loaded rows: keeps a row if any non-NULL
    /// cell contains `query` (case-insensitive). No re-query. Returns self when the
    /// query is blank. totalRowCount becomes the match count so the grid/status agree.
    func filteredByText(_ query: String) -> QueryResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return self }
        var keep: [Int] = []
        for ri in 0..<rowCount {
            for ci in 0..<columns.count where !isNull(ri, ci) && cells.value(ri, ci).range(of: q, options: .caseInsensitive) != nil {
                keep.append(ri)
                break
            }
        }
        var r = self
        r.cells = cells.selecting(rows: keep)
        r.totalRowCount = keep.count
        r.sourceRows = sourceRows.map { origin in keep.map { origin[$0] } } ?? keep
        return r
    }

    /// Numbers read right-aligned — magnitudes line up and scanning a column of
    /// totals works the way it does on paper. Everything else stays left.
    static func isNumericType(_ type: String) -> Bool {
        var t = type.uppercased()
        // ClickHouse wraps nullability into the type: Nullable(UInt32).
        if t.hasPrefix("NULLABLE(") && t.hasSuffix(")") {
            t = String(t.dropFirst("NULLABLE(".count).dropLast())
        }
        switch t {
        case "INT", "BIGINT", "SMALLINT", "TINYINT", "HUGEINT",
             "UINT", "UBIGINT", "USMALLINT", "UTINYINT",
             "FLOAT", "DOUBLE", "DECIMAL":
            return true
        default:
            // ClickHouse spells width into the name: UInt32, Int64, Float64,
            // Decimal(10, 2). Containers like Array(UInt32) stay left-aligned.
            if t.hasPrefix("DECIMAL") { return true }
            if t.hasPrefix("FLOAT"), t.dropFirst(5).allSatisfy(\.isNumber) { return true }
            if t.hasPrefix("UINT"), t.dropFirst(4).allSatisfy(\.isNumber) { return true }
            if t.hasPrefix("INT"), t.dropFirst(3).allSatisfy(\.isNumber) { return true }
            return false
        }
    }
}
