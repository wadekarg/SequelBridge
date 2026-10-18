//
//  RunClockTests.swift
//  SequelBridgeTests
//
//  The toolbar's elapsed counter and the status bar's query time showed different
//  quantities: the counter was a 1s Timer that ticked for the whole run (planning,
//  materializing, streaming), while the status bar showed the engine's time to the
//  first chunk of the final statement only — 54s on top, 1.412s at the bottom for the
//  same cross-join. Both now derive from one RunClock started when Run is pressed.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Run clock")
struct RunClockTests {

    @Test("elapsed is the wall time since the run started")
    func elapsedSinceStart() {
        let clock = RunClock(now: 100)
        #expect(abs(clock.elapsed(now: 154.3) - 54.3) < 1e-9)
    }

    @Test("the counter shows whole seconds, floored, so it never reads past the final total")
    func tickerFloors() {
        #expect(RunClock.tickerText(54.9) == "54s")
        #expect(RunClock.tickerText(0.4) == "0s")
        #expect(RunClock.tickerText(125) == "125s")
    }

    @Test("the status bar shows milliseconds")
    func statusMilliseconds() {
        #expect(RunClock.statusText(1.4119) == "1.412s")
        #expect(RunClock.statusText(54.3) == "54.300s")
    }

    @Test("counter and status bar agree on the seconds for the same elapsed value")
    func tickerAndStatusAgree() {
        for t in [0.0, 0.999, 1.0, 12.5, 54.9, 3599.4] {
            let ticker = RunClock.tickerText(t).dropLast()                     // "54"
            let status = RunClock.statusText(t).split(separator: ".")[0]       // "54"
            #expect(ticker == status, "at \(t)s")
        }
    }

    @Test("a stamped result carries the run's total time, not the statement's")
    func stampedResultCarriesRunTotal() {
        let clock = RunClock(now: 100)
        let first = QueryResult(columns: ["a"], rows: [["1"]], executionTime: 1.412)
        let stamped = clock.stamped(first, now: 154.3)
        #expect(abs(stamped.executionTime - 54.3) < 1e-9)
        #expect(stamped.rows == first.rows)
        #expect(stamped.columns == first.columns)
    }
}
