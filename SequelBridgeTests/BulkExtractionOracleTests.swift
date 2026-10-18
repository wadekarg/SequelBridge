//
//  BulkExtractionOracleTests.swift
//  SequelBridgeTests
//
//  The streaming reader now pulls cells through the vendored package's chunk-sequential
//  bulk readers, which touch DuckDB's vectors directly (validity bitmaps, inline vs
//  pointer strings, per-chunk offsets). This checks that path against an oracle that
//  does not share any of it: DuckDB's own `::VARCHAR` rendering of the same values.
//  For every type whose text form we render the same way DuckDB does, each cell of a
//  300k-row result (147 chunks, NULLs sprinkled through every column) must match the
//  oracle exactly. Types we deliberately render differently (floats, decimals, blobs)
//  are pinned in TemporalRenderingTests / CellFormattingPerfTests instead.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Bulk extraction vs DuckDB oracle", .serialized)
struct BulkExtractionOracleTests {

    private let n = 300_000

    /// (column expression, display name). Each is NULL on every 7th row (offset per
    /// column) so validity bits are exercised everywhere, including chunk edges.
    private let columns: [(String, String)] = [
        ("CASE WHEN i % 7 = 0 THEN NULL ELSE i END",                                  "big"),
        ("CASE WHEN i % 7 = 1 THEN NULL ELSE ((i % 200) - 100)::TINYINT END",          "tiny"),
        ("CASE WHEN i % 7 = 2 THEN NULL ELSE (i % 60000)::USMALLINT END",              "usmall"),
        ("CASE WHEN i % 7 = 3 THEN NULL ELSE i % 2 = 0 END",                           "flag"),
        // short (inline, ≤12 bytes) and long (pointer) strings, plus empty strings
        ("CASE WHEN i % 7 = 4 THEN NULL WHEN i % 3 = 0 THEN '' ELSE 'r' || i END",   "short"),
        ("CASE WHEN i % 7 = 5 THEN NULL ELSE repeat('x', 13 + (i % 40)) || i END",     "long"),
        ("CASE WHEN i % 7 = 6 THEN NULL ELSE (i * 1234567890123)::HUGEINT * 1000 END", "huge"),
        ("CASE WHEN i % 7 = 0 THEN NULL ELSE DATE '2000-01-01' + INTERVAL (i) DAY END", "d"),
        ("CASE WHEN i % 7 = 1 THEN NULL ELSE TIMESTAMP '2000-01-01' + INTERVAL (i * 977) SECOND + INTERVAL (i % 1000) MILLISECOND END", "ts"),
        ("CASE WHEN i % 7 = 2 THEN NULL ELSE TIME '00:00:00' + INTERVAL ((i * 7) % 86400) SECOND END", "t"),
        // Deterministic UUID from i (uuid() would differ between the typed column and
        // its ::VARCHAR twin). The app renders UUIDs uppercase; compared case-insensitively.
        ("CASE WHEN i % 7 = 3 THEN NULL ELSE ('6ba7b810-9dad-41d1-80b4-' || lpad(i::VARCHAR, 12, '0'))::UUID END", "u"),
        ("CASE WHEN i % 7 = 4 THEN NULL ELSE INTERVAL (i % 50) DAY + INTERVAL (i % 3600) SECOND END", "iv"),
    ]

    @Test("every cell of every supported type matches DuckDB's own text rendering")
    func matchesOracle() async throws {
        let engine = try QueryEngine()
        // One query produces both the typed columns (our path) and their ::VARCHAR
        // twins (the oracle), so uuid()/row values are identical for both sides.
        let typed  = columns.map { "\($0.0) AS \($0.1)" }
        let oracle = columns.map { "(\($0.0))::VARCHAR AS o_\($0.1)" }
        let sql = "SELECT " + (typed + oracle).joined(separator: ", ") + " FROM range(\(n)) t(i) ORDER BY i"
        let (first, stream) = try await engine.openStreamingQuery(sql, firstChunk: 2_000)
        var rows = first.rows
        var mask = first.nullMask
        while let more = try await engine.pullMore(stream, size: 20_000), !more.rows.isEmpty {
            rows.append(contentsOf: more.rows)
            mask.append(contentsOf: more.mask)
        }
        await engine.closeStream(stream)
        #expect(rows.count == n)
        let k = columns.count
        var mismatches: [String] = []
        for (r, row) in rows.enumerated() {
            for c in 0..<k {
                let ours = row[c], theirs = row[k + c]
                let ourNull = mask[r][c], theirNull = mask[r][k + c]
                let same = columns[c].1 == "u" ? ours.lowercased() == theirs.lowercased() : ours == theirs
                if ourNull != theirNull || (!ourNull && !same) {
                    mismatches.append("row \(r) \(columns[c].1): ours=\(ourNull ? "NULL" : ours) oracle=\(theirNull ? "NULL" : theirs)")
                    if mismatches.count > 12 { break }
                }
            }
            if mismatches.count > 12 { break }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    }
}
