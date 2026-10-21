//
//  CellFormattingPerfTests.swift
//  SequelBridgeTests
//
//  Streaming a wide prod result was CPU-bound in cell extraction. A profile put a
//  quarter of the DB thread in formatTimestamp → clock → Foundation's String(format:),
//  which validates and parses the format string on every call — per cell, per
//  timestamp column. The formatters now zero-pad with a pure-Swift helper. These pin
//  (1) the helper and (2) the exact rendered strings the grid shows, end to end through
//  DuckDB, so the rewrite cannot change a single character of output.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Zero-padded number rendering")
struct ZeroPaddedTests {

    @Test("pads to the requested width")
    func pads() {
        #expect(QueryEngine.zeroPadded(7, width: 2) == "07")
        #expect(QueryEngine.zeroPadded(0, width: 2) == "00")
        #expect(QueryEngine.zeroPadded(42, width: 2) == "42")
        #expect(QueryEngine.zeroPadded(5, width: 6) == "000005")
        #expect(QueryEngine.zeroPadded(123456, width: 6) == "123456")
    }

    @Test("never truncates a value wider than the field")
    func noTruncation() {
        #expect(QueryEngine.zeroPadded(2024, width: 2) == "2024")
        #expect(QueryEngine.zeroPadded(100, width: 2) == "100")
    }
}

@MainActor
@Suite("Temporal rendering end to end (in-process DuckDB)")
struct TemporalRenderingTests {

    @Test("timestamp, date, time, timetz and interval render exactly as before")
    func rendersExactly() async throws {
        let engine = try QueryEngine()
        let r = try await engine.query("""
            SELECT TIMESTAMP '2024-03-05 07:08:09.5'   AS ts,
                   TIMESTAMP '1999-12-31 23:59:59'     AS ts_whole,
                   TIMESTAMP '2024-01-02 03:04:05.123456' AS ts_us,
                   DATE '2024-03-05'                   AS d,
                   DATE '0987-01-09'                   AS d_old,
                   TIME '07:08:09'                     AS t,
                   TIME '00:00:00.120000'              AS t_frac,
                   TIMETZ '07:08:09+05:30'             AS ttz,
                   INTERVAL '1 year 2 months 3 days 04:05:06.5' AS iv
            """)
        #expect(r.rows.count == 1)
        #expect(r.rows[0] == [
            "2024-03-05 07:08:09.5",
            "1999-12-31 23:59:59",
            "2024-01-02 03:04:05.123456",
            "2024-03-05",
            "0987-01-09",
            "07:08:09",
            "00:00:00.12",
            "07:08:09+05:30",
            "1 year 2 months 3 days 04:05:06.5",
        ])
    }

    @Test("a DECIMAL shows the digits its column keeps: 12345678.90, not 12345678.9")
    func decimalScale() async throws {
        let engine = try QueryEngine()
        let r = try await engine.query("""
            SELECT 12345678.90::DECIMAL(10,2) AS money, 10.5::DECIMAL(10,2) AS half, 0::DECIMAL(5,2) AS zero,
                   -1.5::DECIMAL(10,3) AS neg, 7::DECIMAL(4,0) AS whole,
                   12345678901234567890.0123456789::DECIMAL(30,10) AS wide
            """)
        #expect(r.rows[0] == ["12345678.90", "10.50", "0.00", "-1.500", "7", "12345678901234567890.0123456789"])
    }

    @Test("an infinite timestamp or date (PostgreSQL's 'infinity') shows as infinity; formatting one aborted the app")
    func infinity() async throws {
        let engine = try QueryEngine()
        let r = try await engine.query("""
            SELECT 'infinity'::TIMESTAMP, '-infinity'::TIMESTAMP, 'infinity'::DATE, '-infinity'::DATE,
                   'infinity'::TIMESTAMPTZ
            """)
        #expect(r.rows[0] == ["infinity", "-infinity", "infinity", "-infinity", "infinity"])
    }

    @Test("a blob renders as lowercase hex")
    func blobHex() async throws {
        let engine = try QueryEngine()
        let r = try await engine.query("SELECT '\\x00\\xAB\\xff'::BLOB AS b")
        #expect(r.rows[0] == ["00abff"])
    }
}
