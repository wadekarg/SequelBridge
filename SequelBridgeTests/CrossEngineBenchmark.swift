//
//  CrossEngineBenchmark.swift
//  SequelBridgeTests
//
//  A timing harness (NOT a correctness test) for the headline feature:
//  a single SQL statement that JOINs a MariaDB table against a PostgreSQL
//  table through DuckDB's ATTACH model. Gated behind TEST_RUNNER_SB_BENCH=1
//  so it never runs in the normal suite. Results are written as JSON to
//  TEST_RUNNER_SB_BENCH_OUT so they survive even a teardown crash.
//
//  Run in RELEASE for honest numbers — Debug DuckDB is 20-100x slower.
//  Requires local containers: maria :3309 (root/sbverify123) + pg :5433
//  (sbuser/sbpass123), both with sbtest.big_events / sbtest.big_metrics.
//

import Foundation
import Testing
@testable import SequelBridge

private struct BEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    // Xcode strips the TEST_RUNNER_ prefix before the test process sees these,
    // so on the command line pass TEST_RUNNER_SB_BENCH=1 etc.
    static var enabled: Bool { e["SB_BENCH"] == "1" }
    static var out: String { e["SB_BENCH_OUT"] ?? "/tmp/sb_bench.json" }
    static var iters: Int { Int(e["SB_BENCH_ITERS"] ?? "") ?? 6 }
}

@MainActor
@Suite("Cross-engine benchmark", .enabled(if: BEnv.enabled), .serialized)
struct CrossEngineBenchmark {

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(); let n = s.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
    }

    /// Runs `sql` `iters` times, discards the first (warm-up), returns
    /// (median, min, all timed runs, row count of the last run).
    private func bench(_ engine: QueryEngine, _ sql: String) async throws
        -> (median: Double, min: Double, runs: [Double], rows: Int, total: Int) {
        var runs: [Double] = []
        var rows = 0, total = 0
        for i in 0..<BEnv.iters {
            let t0 = Date()
            let r = try await engine.query(sql)
            let dt = Date().timeIntervalSince(t0)
            rows = r.rows.count
            total = r.totalRowCount
            if i > 0 { runs.append(dt) }   // drop warm-up
        }
        return (median(runs), runs.min() ?? 0, runs, rows, total)
    }

    @Test("maria x postgres cross-engine join timings")
    func run() async throws {
        let engine = try QueryEngine()   // no row cap — the full result materializes

        let maria = Connection(name: "maria10", alias: "maria10", connectionType: .tcpip,
                               host: "127.0.0.1", port: 3309, username: "root",
                               database: "sbtest", engine: .mysql)
        let pg = Connection(name: "pg16", alias: "pg16", connectionType: .tcpip,
                            host: "127.0.0.1", port: 5433, username: "sbuser",
                            database: "sbtest", engine: .postgres)

        let attachT0 = Date()
        try await engine.attach(maria, password: "sbverify123")
        try await engine.attach(pg, password: "sbpass123")
        let attachSecs = Date().timeIntervalSince(attachT0)

        // MySQL: DuckDB maps the database to the catalog *schema* (maria10.sbtest.big_events).
        // Postgres: the scanner exposes tables under their real schema (pg16.public.big_metrics),
        // NOT the connected database — so the middle component differs per engine.
        let ev = SQLBuilder.duckTable(alias: "maria10", database: "sbtest", table: "big_events")
        let me = SQLBuilder.duckTable(alias: "pg16", database: "public", table: "big_metrics")

        // S1 — aggregate cross-engine join: per-tail rollup on each side, joined. 500 rows out.
        let s1 = """
            SELECT e.tail, e.n_events, e.avg_value, m.n_metrics, m.avg_score
            FROM (SELECT tail, COUNT(*) AS n_events, AVG(value) AS avg_value FROM \(ev) GROUP BY tail) e
            JOIN (SELECT tail, COUNT(*) AS n_metrics, AVG(score) AS avg_score FROM \(me) GROUP BY tail) m
              ON e.tail = m.tail
            ORDER BY e.tail
            """

        // S2 — row-level filtered cross-engine join, fully materialized (~105k rows out).
        let s2 = """
            SELECT e.tail, e.event_ts, e.value, m.metric_ts, m.score
            FROM \(ev) e JOIN \(me) m ON e.tail = m.tail
            WHERE e.value > 990 AND m.score > 95
            """

        // S2c — same join, terminated by COUNT(*): pure cross-engine compute, ~no extraction.
        let s2c = """
            SELECT COUNT(*) FROM \(ev) e JOIN \(me) m ON e.tail = m.tail
            WHERE e.value > 990 AND m.score > 95
            """

        let r1 = try await bench(engine, s1)
        writeJSON(attachSecs: attachSecs, s1: r1, s2: nil, s2c: nil)   // flush after each
        let r2 = try await bench(engine, s2)
        writeJSON(attachSecs: attachSecs, s1: r1, s2: r2, s2c: nil)
        let r3 = try await bench(engine, s2c)
        writeJSON(attachSecs: attachSecs, s1: r1, s2: r2, s2c: r3)

        #expect(r1.rows == 500)
    }

    private func writeJSON(attachSecs: Double,
                           s1: (median: Double, min: Double, runs: [Double], rows: Int, total: Int),
                           s2: (median: Double, min: Double, runs: [Double], rows: Int, total: Int)?,
                           s2c: (median: Double, min: Double, runs: [Double], rows: Int, total: Int)?) {
        func block(_ r: (median: Double, min: Double, runs: [Double], rows: Int, total: Int)) -> [String: Any] {
            ["median": r.median, "min": r.min, "runs": r.runs, "rows_out": r.rows, "total_rows": r.total]
        }
        var d: [String: Any] = [
            "tool": "SequelBridge (DuckDB ATTACH, Release)",
            "iters": BEnv.iters,
            "attach_secs": attachSecs,
            "s1_aggregate_join": block(s1),
        ]
        if let s2 { d["s2_rowlevel_join_full"] = block(s2) }
        if let s2c { d["s2_rowlevel_join_count"] = block(s2c) }
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: BEnv.out))
        }
    }
}
