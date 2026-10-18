//
//  QueryCancelTests.swift
//  SequelBridgeTests
//
//  Cancelling a query must actually stop the engine, not just the UI. Before
//  this, cancel abandoned the Swift task while DuckDB kept computing and every
//  later query queued behind it.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Query cancellation", .serialized)
struct QueryCancelTests {

    /// A query that takes tens of seconds of local compute — no server needed.
    static let slowSQL = "SELECT COUNT(*) FROM range(200000000) t1, range(50) t2"

    @Test("interrupt aborts a running query promptly")
    func interruptAborts() async throws {
        let engine = try QueryEngine()

        let started = Date()
        let task = Task {
            try await engine.query(Self.slowSQL)
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        engine.interruptUserQuery()

        // The abandoned query must come back as an error, quickly.
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 10, "interrupt took too long")
    }

    @Test("the connection answers immediately after an interrupt")
    func usableAfterInterrupt() async throws {
        let engine = try QueryEngine()
        let task = Task { try? await engine.query(Self.slowSQL) }
        try await Task.sleep(nanoseconds: 500_000_000)
        engine.interruptUserQuery()
        _ = await task.value

        let t0 = Date()
        let r = try await engine.query("SELECT 42 AS ok")
        #expect(r.rows.first?.first == "42")
        #expect(Date().timeIntervalSince(t0) < 5, "connection still blocked after interrupt")
    }

    @Test("interrupt with nothing running is harmless")
    func interruptIdle() async throws {
        let engine = try QueryEngine()
        engine.interruptUserQuery()
        let r = try await engine.query("SELECT 1 AS ok")
        #expect(r.rows.first?.first == "1")
    }

    /// What Cancel would need to do to stop the server as well: a statement that keeps
    /// the MariaDB container busy for ~20 s (SLEEP per row, 1,000 rows) should leave
    /// the server's process list within seconds of the interrupt — not run on to its
    /// end — while a second connection watches. It does not today (measured 2026-10-13:
    /// the statement stayed for the full 10 s window and finished on its own), so the
    /// note and the guide say so, and this test waits for the feature.
    @Test("interrupt stops the statement on the MySQL server as well",
          .disabled("the interrupt stops DuckDB, not the server: the statement finishes there on its own (known gap)"),
          .enabled(if: XJoinEnv.enabled))
    func interruptStopsServerStatement() async throws {
        let engine = try await makeTwoServerEngine()
        let marker = "SLEEP(0.02)"
        let slow = "SELECT \(marker), a.tail FROM sbtest.small_fleet a, sbtest.small_fleet b, sbtest.small_fleet c"
        let task = Task {
            try await engine.openServerStreamingQuery(alias: "srvA", serverSQL: slow, firstChunk: 10)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        engine.interruptUserQuery()

        // Watch the server from another connection (the metadata lane): the statement
        // must be gone well before it would finish on its own.
        let watch = "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%\(marker)%' AND INFO NOT LIKE '%PROCESSLIST%'"
        var stillRunning = true
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 10 {
            let pl = try await engine.serverPassthroughQuery(alias: "srvB", serverSQL: watch, lane: .content)
            if pl.rows.isEmpty { stillRunning = false; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(!stillRunning, "the server kept running the cancelled statement for 10 s after the interrupt")
        _ = try? await task.value
    }
}
