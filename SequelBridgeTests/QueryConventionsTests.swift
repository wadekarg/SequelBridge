//
//  QueryConventionsTests.swift
//  SequelBridgeTests
//
//  The collapsible note above the editor that says how queries are written here:
//  one server → its own SQL runs there as is; several → alias-prefixed tables, which
//  joins stream server to server, what runs on DuckDB instead. Built from the
//  session's connections, so it names the user's aliases and engines — and kept
//  short: one line per rule.
//

import Testing
@testable import SequelBridge

@Suite("Query conventions note")
struct QueryConventionsTests {
    private func conn(_ alias: String, _ engine: DatabaseEngine) -> Connection {
        Connection(name: alias, alias: alias, engine: engine)
    }

    @Test("one server: its own SQL, run on the server")
    func singleServer() {
        let c = QueryConventions.make(for: [conn("fleet", .mysql)])
        #expect(c.summary == "fleet — plain MySQL, runs on the server as is.")
        #expect(c.lines.count == 2)
        #expect(c.lines[0].contains("fleet") && c.lines[0].contains("MySQL") && c.lines[0].contains("EXPLAIN"))
        #expect(c.lines[1].contains("stream") && c.lines[1].contains("Cancel"))
        #expect(!c.lines.joined().contains("prefix"))
    }

    @Test("a SQLite file is DuckDB SQL, not SQLite's own")
    func singleSQLite() {
        let c = QueryConventions.make(for: [conn("lite", .sqlite)])
        #expect(c.summary == "lite — DuckDB SQL over the SQLite file.")
        #expect(c.lines[0].contains("DuckDB SQL") && c.lines[0].contains("EXPLAIN"))
    }

    @Test("several servers: alias prefixes, streaming joins, and what runs on DuckDB")
    func severalServers() {
        let c = QueryConventions.make(for: [conn("logsrv", .mysql), conn("fleet", .mysql)])
        #expect(c.summary == "Servers logsrv, fleet — prefix tables: logsrv.table • fleet.table")
        let text = c.lines.joined(separator: "\n")
        #expect(c.lines[0].hasPrefix("alias.table") && c.lines[0].contains("alias.db.table"))
        #expect(c.lines[1].contains("logsrv (MySQL); fleet (MySQL)") && c.lines[1].contains("EXPLAIN"))
        #expect(text.contains("JOIN") && text.contains("FROM a, b WHERE a.k = b.k") && text.contains("streamed server to server"))
        #expect(text.contains("=, IN, LIKE"))
        #expect(text.contains("DuckDB SQL") && text.contains("3+ tables"))
        #expect(!text.contains("ClickHouse"))
        #expect(c.lines.last?.contains("Cancel") == true)
        // Honest about what Cancel reaches: the app's work, not a statement a server is
        // already running (pinned by QueryCancelTests.interruptStopsServerStatement, disabled).
        #expect(c.lines.last == "Results stream in, no row cap; Cancel stops the app's work, not a statement already running on a server.")
        // Short: no line runs past a sentence or two.
        #expect(c.lines.allSatisfy { $0.count <= 170 })
    }

    @Test("a ClickHouse connection adds its own rule; SQLite and ClickHouse name where they run")
    func engines() {
        let c = QueryConventions.make(for: [conn("ch", .clickhouse), conn("lite", .sqlite), conn("pg16", .postgres)])
        let text = c.lines.joined(separator: "\n")
        #expect(c.summary.hasPrefix("Servers ch, lite, pg16"))
        #expect(text.contains("ClickHouse side is copied over") && text.contains("smaller side"))
        #expect(text.contains("ClickHouse × ClickHouse"))
        #expect(text.contains("lite (SQLite via DuckDB)") && text.contains("pg16 (PostgreSQL)") && text.contains("ch (ClickHouse, HTTP)"))
    }

    @Test("no connections: nothing to say")
    func none() {
        let c = QueryConventions.make(for: [])
        #expect(c.summary.isEmpty && c.lines.isEmpty)
    }
}
