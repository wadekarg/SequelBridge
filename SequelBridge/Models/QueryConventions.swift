//
//  QueryConventions.swift
//  SequelBridge
//
//  What the note above the editor says about how queries are written here, built
//  from the session's connections so it names the user's own aliases and engines.
//  `summary` is the collapsed one-liner; `lines` the expanded explanation, one point
//  per line. The rules it states are the planner's (see QueryPanelView.runQuery and
//  QueryEngine.crossJoinPlan): a single-server statement goes to that server as is,
//  a two-table join across servers streams server to server, everything else across
//  servers runs on DuckDB.
//

import Foundation

struct QueryConventions: Equatable {
    let summary: String
    let lines: [String]

    static let streamingNote = "Results stream in, no row cap; Cancel stops the app's work, not a statement already running on a server."

    static func make(for connections: [Connection]) -> QueryConventions {
        guard let first = connections.first else { return QueryConventions(summary: "", lines: []) }
        if connections.count == 1 {
            return QueryConventions(summary: singleSummary(first), lines: [singleLine(first), streamingNote])
        }
        let aliases = connections.map(\.alias)
        var lines = [
            "No server named (SHOW TABLES, SELECT * FROM t) → runs on the server picked at the top of the left panel.",
            "alias.table — the database is filled in (sidebar pick, else the connection's); alias.db.table to be explicit.",
            "One server named → runs there in its own SQL, EXPLAIN included: " + connections.map(runsAs).joined(separator: "; ") + ".",
            "Two tables on one key (JOIN … ON, or FROM a, b WHERE a.k = b.k) → streamed server to server; simple WHERE filters (=, IN, LIKE, number/date ranges) run on the servers.",
            "Anything else across servers (3+ tables, outer joins, UNION, subqueries) → DuckDB SQL; remote tables are fetched whole.",
        ]
        if connections.contains(where: { $0.engine == .clickhouse }) {
            lines.append("ClickHouse side is copied over — keep it the smaller side; ClickHouse × ClickHouse isn't supported.")
        }
        lines.append(streamingNote)
        return QueryConventions(
            summary: "Servers \(aliases.joined(separator: ", ")) — no prefix runs on the server picked in the left panel; name another: \(aliases[0]).table",
            lines: lines)
    }

    private static func singleSummary(_ c: Connection) -> String {
        switch c.engine {
        case .sqlite: return "\(c.alias) — SQLite's own SQL, run in SQLite."
        default:      return "\(c.alias) — plain \(c.engine.displayName), runs on the server as is."
        }
    }

    private static func singleLine(_ c: Connection) -> String {
        switch c.engine {
        case .sqlite:
            return "SQLite's own SQL, run in SQLite: its functions, PRAGMA, INSERT OR REPLACE, RETURNING; EXPLAIN QUERY PLAN shows its plan."
        default:
            return "Write \(c.engine.displayName) as in its own client — runs on \(c.alias) unchanged, EXPLAIN included."
        }
    }

    /// `alias (engine)` with where its statements run, for the several-servers note.
    private static func runsAs(_ c: Connection) -> String {
        switch c.engine {
        case .sqlite:     return "\(c.alias) (SQLite)"
        case .clickhouse: return "\(c.alias) (ClickHouse, HTTP)"
        default:          return "\(c.alias) (\(c.engine.displayName))"
        }
    }
}
