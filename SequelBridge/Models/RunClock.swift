//
//  RunClock.swift
//  SequelBridge
//
//  One clock per query run, started when Run is pressed. The toolbar's elapsed
//  counter and the status bar's query time both read from it, so they can't drift
//  apart. Before, the counter was a 1s Timer counting the whole run (planning,
//  materializing, streaming) while the status bar showed the engine's time to the
//  first chunk of the final statement only — 54s on top, 1.412s at the bottom for
//  the same cross-join. Per-statement timings still go to the Console.
//  Pure and clock-agnostic like StreamBatcher: callers may pass a monotonic `now`.
//

import Foundation

nonisolated struct RunClock {
    let startedAt: TimeInterval

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        startedAt = now
    }

    /// Seconds since the run started.
    func elapsed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        now - startedAt
    }

    /// The counter's label: whole seconds, floored, so it never reads past the total
    /// the status bar shows once the run completes.
    static func tickerText(_ seconds: TimeInterval) -> String {
        "\(Int(seconds.rounded(.down)))s"
    }

    /// The status bar's label, to the millisecond.
    static func statusText(_ seconds: TimeInterval) -> String {
        String(format: "%.3fs", seconds)
    }

    /// `result` with its executionTime replaced by this run's total so far.
    func stamped(_ result: QueryResult, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> QueryResult {
        var r = result
        r.executionTime = elapsed(now: now)
        return r
    }
}
