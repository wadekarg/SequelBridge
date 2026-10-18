//
//  TemporalFormatTests.swift
//  SequelBridgeTests
//
//  TIME / TIMETZ / INTERVAL columns used to render as Swift debug text
//  ("Time(microseconds: …)") and TIMESTAMP dropped fractional seconds. These
//  pin the human-readable formatting (the DuckDB-typed wrappers delegate to
//  these pure Int-based helpers).
//

import Testing
@testable import SequelBridge

@MainActor
@Suite("Temporal formatting")
struct TemporalFormatTests {

    @Test("clock formats HH:MM:SS with a trimmed fraction only when present")
    func clock() {
        #expect(QueryEngine.clock(hour: 9, minute: 5, second: 3, microsecond: 0) == "09:05:03")
        #expect(QueryEngine.clock(hour: 23, minute: 59, second: 59, microsecond: 500000) == "23:59:59.5")
        #expect(QueryEngine.clock(hour: 0, minute: 0, second: 0, microsecond: 123456) == "00:00:00.123456")
        #expect(QueryEngine.clock(hour: 1, minute: 2, second: 3, microsecond: 120000) == "01:02:03.12")
    }

    @Test("zone offset renders sign, hours and optional minutes")
    func offset() {
        #expect(QueryEngine.zoneOffset(seconds: 0) == "+00")
        #expect(QueryEngine.zoneOffset(seconds: 3600) == "+01")
        #expect(QueryEngine.zoneOffset(seconds: 19800) == "+05:30")
        #expect(QueryEngine.zoneOffset(seconds: -28800) == "-08")
    }

    @Test("interval renders calendar and time parts, not debug text")
    func interval() {
        // 1 year 2 months
        #expect(QueryEngine.intervalString(months: 14, days: 0, microseconds: 0) == "1 year 2 months")
        // days + time
        #expect(QueryEngine.intervalString(months: 0, days: 3, microseconds: 14706000000) == "3 days 04:05:06")
        // pure time with fraction
        #expect(QueryEngine.intervalString(months: 0, days: 0, microseconds: 90000000) == "00:01:30")
        #expect(QueryEngine.intervalString(months: 0, days: 0, microseconds: 1500000) == "00:00:01.5")
        // zero interval
        #expect(QueryEngine.intervalString(months: 0, days: 0, microseconds: 0) == "00:00:00")
        // singular units
        #expect(QueryEngine.intervalString(months: 1, days: 1, microseconds: 0) == "1 month 1 day")
        // negative time
        #expect(QueryEngine.intervalString(months: 0, days: 0, microseconds: -3600000000) == "-01:00:00")
    }
}
