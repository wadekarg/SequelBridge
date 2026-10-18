//
//  StreamExtractionTests.swift
//  SequelBridgeTests
//
//  The streaming reader pulls a materialized DuckDB result in 20k-row pieces. The
//  vendored duckdb-swift located each cell by walking every data chunk from the first
//  one, so reading a result was O(rows² / 2048) per column — a 1M-row, 12-column prod
//  result took minutes to stream while the fetch itself took ten seconds. The lookup is
//  now O(log chunks) via precomputed chunk offsets. These pin two things: every row
//  still comes back intact across chunk boundaries (the patch cannot be off by one),
//  and extraction throughput, printed so a regression shows in the test log.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Streaming extraction", .serialized)
struct StreamExtractionTests {

    /// 1,000,000 rows span ~489 DuckDB chunks of 2048; the last one is partial.
    private let n = 1_000_000

    @Test("every row survives chunk boundaries when pulled in 20k pieces")
    func rowsIntactAcrossChunks() async throws {
        let engine = try QueryEngine()
        let (first, stream) = try await engine.openStreamingQuery(
            "SELECT i, i * 2 AS d FROM range(\(n)) t(i) ORDER BY i", firstChunk: 2_000)
        #expect(first.columns == ["i", "d"])
        #expect(stream.hasMore)
        var cells = first.cells
        while let more = try await engine.pullMore(stream, size: 20_000), more.rowCount > 0 {
            cells.append(more)
        }
        #expect(cells.rowCount == n)
        // Spot-check the seams: the first row, both sides of every 2048-row chunk
        // boundary near the end, and the very last row.
        for k in [0, 2047, 2048, 2049, 20_000, 20_001, 999_423, 999_424, n - 1] {
            #expect(cells.row(k) == [String(k), String(k * 2)], "row \(k)")
        }
        // And the whole thing, cheaply: every row's first cell is its own index.
        var ok = true
        for k in 0..<n where cells.value(k, 0) != String(k) { ok = false; break }
        #expect(ok)
        await engine.closeStream(stream)
    }

    @Test("wide rows with timestamps stream at a sane rate (prints cells/s)")
    func wideThroughput() async throws {
        let engine = try QueryEngine()
        // 12 columns like a real log table: ints, strings, and three timestamps.
        let sql = """
            SELECT i, i * 7 AS a, 'row' || i AS s1, 'AF' AS s2, 'ORD' AS s3, 'LHR' AS s4,
                   TIMESTAMP '2024-01-01' + INTERVAL (i) SECOND AS t1,
                   TIMESTAMP '2024-06-01' + INTERVAL (i) SECOND AS t2,
                   TIMESTAMP '2024-12-31' + INTERVAL (i) SECOND AS t3,
                   i % 5 AS k, 'Airtime' AS p, 'feature' AS f
            FROM range(500000) t(i)
            """
        let start = Date()
        let (first, stream) = try await engine.openStreamingQuery(sql, firstChunk: 2_000)
        var cells = first.cells
        while let more = try await engine.pullMore(stream, size: 20_000), more.rowCount > 0 {
            cells.append(more)
        }
        let secs = Date().timeIntervalSince(start)
        let count = cells.rowCount
        #expect(count == 500_000)
        let lastRow = cells.row(count - 1)
        #expect(lastRow[0] == "499999")
        #expect(lastRow[6] == "2024-01-06 18:53:19")   // 2024-01-01 + 499999s, rendered by our formatter
        let cellCount = Double(count * 12)
        print("STREAM-EXTRACT 500k×12 (3 timestamp cols): \(String(format: "%.2f", secs))s  →  \(Int(cellCount / secs)) cells/s")
        // Before the chunk-sequential reader this took ~49s (per-cell Vector/LogicalType
        // allocation in the library); ~11s now on a Debug build, pulled through DuckDB's
        // streaming execution. A generous bound — the machine may be building at the
        // same time — that still can't let that regression creep back.
        #expect(secs < 20, "500k×12 should stream in seconds; took \(secs)s")
        await engine.closeStream(stream)
    }
}
