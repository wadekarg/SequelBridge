//
//  StreamingResultTests.swift
//  SequelBridgeTests
//
//  DuckDB used to materialize a whole query result before we saw its first row —
//  a 4.7M-row fetch sat behind "Running…" for 77s, and that copy lived next to our
//  own cells until the stream closed. StreamingResult (vendor/DuckDB, a local patch)
//  executes a prepared statement as a streaming result and hands out one data chunk
//  at a time through `duckdb_fetch_chunk`. These pin what the engine relies on: the
//  first chunk arrives long before the query has produced everything, chunks read
//  through the same bulk readers as a materialized result, and a stream can be
//  abandoned early.
//

import DuckDB
import Foundation
import Testing
@testable import SequelBridge

@Suite("Streaming result", .serialized)
struct StreamingResultTests {

    private func connection() throws -> DuckDB.Connection {
        try Database(store: .inMemory).connect()
    }

    @Test("the first chunk arrives before the query has produced everything")
    func lazy() throws {
        let conn = try connection()
        // 300M rows take many seconds to generate; the first 2048 must not wait for them.
        let prepared = try PreparedStatement(connection: conn, query: "SELECT range AS n, range * 2 AS d FROM range(300000000)")
        let start = Date()
        let stream = try StreamingResult(prepared: prepared)
        let first = try #require(try stream.nextChunk())
        let firstAt = Date().timeIntervalSince(start)
        #expect(first.rowCount > 0)
        #expect(firstAt < 1.0, "first chunk after \(firstAt)s")
        // Read a little more, then abandon the stream: nothing hangs or leaks a cursor.
        var seen = first.rowCount
        for _ in 0..<8 { guard let c = try stream.nextChunk() else { break }; seen += c.rowCount }
        #expect(seen > 2048)
    }

    @Test("chunks expose columns, types and cells like a materialized result")
    func values() throws {
        let conn = try connection()
        let prepared = try PreparedStatement(connection: conn,
            query: "SELECT * FROM (VALUES (1, 'x', TIMESTAMP '2024-01-02 03:04:05'), (2, NULL, NULL)) t(a, b, c) ORDER BY a")
        let stream = try StreamingResult(prepared: prepared)
        #expect(stream.columnCount == 3)
        #expect((0..<3).map { stream.columnName(at: DBInt($0)) } == ["a", "b", "c"])
        #expect(stream.columnDataType(at: 1) == .varchar)
        let chunk = try #require(try stream.nextChunk())
        #expect(chunk.rowCount == 2)
        #expect(chunk.columnDataType(at: 1) == .varchar)
        #expect(chunk.bulk(Int32.self, column: 0, rows: 0..<2) == [1, 2])
        #expect(chunk.bulk(String.self, column: 1, rows: 0..<2) == ["x", nil])
        let ts = chunk.bulk(Timestamp.self, column: 2, rows: 0..<2)
        #expect(ts[1] == nil)
        #expect(ts[0].map { QueryEngine.formatTimestamp($0) } == "2024-01-02 03:04:05")
        #expect(try stream.nextChunk() == nil)          // exhausted
        #expect(try stream.nextChunk() == nil)          // and stays so
    }

    @Test("a failing statement reports its error at execution, not silently as an empty stream")
    func errors() throws {
        let conn = try connection()
        #expect(throws: (any Error).self) {
            _ = try PreparedStatement(connection: conn, query: "SELECT * FROM no_such_table")
        }
        // A per-row failure (not a constant the optimizer could fold away) surfaces when
        // the chunk that hits it is fetched — or at execution; never as an empty stream.
        #expect(throws: (any Error).self) {
            let prepared = try PreparedStatement(connection: conn,
                query: "SELECT CAST(CASE WHEN range > 5 THEN 'abc' ELSE '1' END AS INTEGER) FROM range(10)")
            let stream = try StreamingResult(prepared: prepared)
            while try stream.nextChunk() != nil {}
        }
    }
}
