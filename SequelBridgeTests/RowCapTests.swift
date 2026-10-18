//
//  RowCapTests.swift
//  SequelBridgeTests
//
//  There is no display row cap: a query returns every row it produces. Large
//  results are streamed in chunks (first chunk paints instantly, the rest follow),
//  but the full result is always available.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("No display row cap", .serialized)
struct RowCapTests {

    @Test("a large result returns every row — nothing is capped")
    func noCapLargeResult() async throws {
        let engine = try QueryEngine()
        let r = try await engine.query("SELECT range AS n FROM range(50000)")
        #expect(r.rows.count == 50000)
        #expect(r.totalRowCount == 50000)
        #expect(!r.isTruncated)
    }

    @Test("a small result is returned whole")
    func smallResult() async throws {
        let engine = try QueryEngine()
        let r = try await engine.query("SELECT range AS n FROM range(42)")
        #expect(r.rows.count == 42)
        #expect(!r.isTruncated)
    }

    @Test("streaming delivers the first chunk immediately, then every remaining row")
    func streamingDeliversAll() async throws {
        let engine = try QueryEngine()
        let (first, stream) = try await engine.openStreamingQuery(
            "SELECT range AS n FROM range(5000)", firstChunk: 1000)
        #expect(first.rows.count >= 1000)       // instant first paint (whole data chunks)
        #expect(stream.hasMore)                  // the total is only known once drained

        var total = first.rows.count
        while let chunk = try await engine.pullMore(stream, size: 2000) {
            total += chunk.rows.count
        }
        #expect(total == 5000)                  // all rows eventually delivered
    }

    @Test("first-chunk larger than the result returns everything and needs no streaming")
    func firstChunkCoversAll() async throws {
        let engine = try QueryEngine()
        let (first, stream) = try await engine.openStreamingQuery(
            "SELECT range AS n FROM range(100)", firstChunk: 1000)
        #expect(first.rows.count == 100)
        #expect(try await engine.pullMore(stream, size: 1000) == nil)  // nothing left
    }

    @Test("two concurrent streams don't clobber each other")
    func concurrentStreamsIndependent() async throws {
        // Opening a second stream used to reset a single shared cursor, truncating the
        // first (and mixing row counts). Each stream now has its own cursor, so both
        // deliver their complete, correct result even while interleaved.
        let engine = try QueryEngine()
        let (a, sa) = try await engine.openStreamingQuery("SELECT range AS n FROM range(5000)", firstChunk: 100)
        let (b, sb) = try await engine.openStreamingQuery("SELECT range AS n FROM range(3000)", firstChunk: 100)
        #expect(sa.hasMore && sb.hasMore)
        var ac = a.rows.count, bc = b.rows.count
        while true {
            let ca = try await engine.pullMore(sa, size: 500)
            let cb = try await engine.pullMore(sb, size: 500)
            ac += ca?.rows.count ?? 0
            bc += cb?.rows.count ?? 0
            if ca == nil && cb == nil { break }
        }
        #expect(ac == 5000)   // first stream complete despite the second opening mid-flight
        #expect(bc == 3000)
    }

    @Test("the content lane runs independently and returns complete results")
    func contentLaneWorks() async throws {
        let engine = try QueryEngine()
        // A Query-lane stream left open…
        let (_, userStream) = try await engine.openStreamingQuery("SELECT range FROM range(4000)", firstChunk: 100)
        // …does not disturb a Content-lane query.
        let content = try await engine.query("SELECT range AS n FROM range(1234)", lane: .content)
        #expect(content.rows.count == 1234)
        await engine.closeStream(userStream)
    }
}
