//
//  PredicatePushdownTests.swift
//  SequelBridgeTests
//
//  A cross-server query that no reducer covers is run by materializing each remote
//  table through the passthrough — the WHOLE table. The user's WHERE was applied only
//  locally afterwards, so `… JOIN … WHERE tail = 'N1'` dragged a huge traps table
//  across the VPN (266s, cancelled) to keep a handful of rows. The analyzer here gives
//  each table the WHERE conjuncts it can take server-side, including an equality
//  carried across the join key, so the fetch is `WHERE tail = 'N1'` on both
//  servers. Results can never change: a pushed predicate is at most a superset filter
//  of what DuckDB evaluates afterwards on the same rows.
//

import Foundation
import Testing
@testable import SequelBridge

private let userSQL = """
    SELECT *
    FROM logsrv.traps t1
    JOIN fleet.aircraft t2 ON t1.tail = tail_no
    where tail = 'N1'
    LIMIT 10000000
    """

private let cols: [String: [String: String]] = [
    "t1": ["tail": "varchar(10)", "logtime": "datetime", "linenum": "int(11)", "airline": "varchar(4)"],
    "t2": ["tail_no": "varchar(10)", "status": "varchar(16)", "updated": "datetime", "alt": "int(11)", "active": "tinyint(1)"],
]

private func bare(_ alias: String, _ column: String) -> String { column }

private func push(_ sql: String, columns: [String: [String: String]] = cols,
                  aliases: [String] = ["logsrv", "fleet"]) -> [String: [String]] {
    guard let shape = SQLBuilder.analyzeSelect(sql, aliases: aliases) else { return [:] }
    return SQLBuilder.pushdownPredicates(shape, columns: columns, render: bare)
}

@Suite("Select shape analysis")
struct SelectShapeTests {

    @Test("tables, their query aliases, the ON and WHERE text of the user's query")
    func userQueryShape() throws {
        let shape = try #require(SQLBuilder.analyzeSelect(userSQL, aliases: ["logsrv", "fleet"]))
        #expect(shape.tables == [
            .init(server: "logsrv", database: nil, table: "traps", queryAlias: "t1"),
            .init(server: "fleet", database: nil, table: "aircraft", queryAlias: "t2"),
        ])
        #expect(shape.onConditions == ["t1.tail = tail_no"])
        #expect(shape.whereClause == "tail = 'N1'")      // LIMIT is not part of it
    }

    @Test("comma joins, AS aliases, alias defaults to the table name, 3-part refs")
    func otherShapes() throws {
        let shape = try #require(SQLBuilder.analyzeSelect(
            "SELECT a.x FROM srvA.orders AS o, srvB.fp.customers WHERE o.cid = customers.id AND o.total > 5 ORDER BY 1",
            aliases: ["srvA", "srvB"]))
        #expect(shape.tables == [
            .init(server: "srvA", database: nil, table: "orders", queryAlias: "o"),
            .init(server: "srvB", database: "fp", table: "customers", queryAlias: "customers"),
        ])
        #expect(shape.onConditions.isEmpty)
        #expect(shape.whereClause == "o.cid = customers.id AND o.total > 5")
    }

    @Test("outer joins, derived tables and UNIONs are not analyzed")
    func unsupported() {
        #expect(SQLBuilder.analyzeSelect("SELECT * FROM a.t x LEFT JOIN b.u y ON x.k = y.k WHERE x.v = 1", aliases: ["a", "b"]) == nil)
        #expect(SQLBuilder.analyzeSelect("SELECT * FROM (SELECT * FROM a.t) x JOIN b.u y ON x.k = y.k", aliases: ["a", "b"]) == nil)
        #expect(SQLBuilder.analyzeSelect("SELECT k FROM a.t WHERE v = 1 UNION SELECT k FROM b.u", aliases: ["a", "b"]) == nil)
    }
}

@Suite("Predicate pushdown")
struct PredicatePushdownTests {

    @Test("the user's filter goes to its table and, through the join key, to the other side")
    func userQuery() {
        #expect(push(userSQL) == ["t1": ["tail = 'N1'"], "t2": ["tail_no = 'N1'"]])
    }

    @Test("qualified conjuncts go to their table; a conjunct spanning both tables stays local")
    func qualified() {
        let r = push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE t1.linenum > 100 AND t2.status IN ('a', 'b') AND t1.logtime < t2.updated")
        #expect(r == ["t1": ["linenum > 100"], "t2": ["status IN ('a', 'b')"]])
    }

    @Test("a top-level OR across tables pushes nothing; a parenthesized one-table group is pushed whole")
    func disjunctions() {
        #expect(push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE t1.linenum = 1 OR t2.alt = 2").isEmpty)
        let r = push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE (t1.linenum = 1 OR t1.airline = 'AF') AND t2.alt = 2")
        #expect(r == ["t1": ["(linenum = 1 OR airline = 'AF')"], "t2": ["alt = 2"]])
    }

    @Test("functions, arithmetic and subqueries are left to DuckDB")
    func notSimple() {
        #expect(push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE DATE(t1.logtime) = '2026-01-01'").isEmpty)
        #expect(push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE t1.linenum + 1 > 5").isEmpty)
        #expect(push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE t1.tail IN (SELECT tail_no FROM fleet.aircraft)").isEmpty)
    }

    @Test("a bare column that is ambiguous or unknown is not pushed")
    func bareResolution() {
        var both = cols
        both["t2"]?["tail"] = "varchar(10)"      // now in both tables → ambiguous
        #expect(push(userSQL, columns: both).isEmpty)
        #expect(push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE nosuch = 1").isEmpty)
    }

    @Test("string columns: only =, IN, LIKE and IS NULL are safe under the server's collation")
    func stringOperators() {
        let base = "SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE "
        #expect(push(base + "t1.airline <> 'AF'").isEmpty)           // ci collation would drop 'af' rows DuckDB keeps
        #expect(push(base + "t1.airline > 'A'").isEmpty)
        #expect(push(base + "t1.airline NOT IN ('AF')").isEmpty)
        #expect(push(base + "NOT t1.airline = 'AF'").isEmpty)
        #expect(push(base + "t1.airline LIKE 'A%' AND t1.tail IS NOT NULL") == ["t1": ["airline LIKE 'A%'", "tail IS NOT NULL"]])
    }

    @Test("ClickHouse Enum columns take = and IN like strings, but never LIKE")
    func enumColumns() {
        // ClickHouse compares an Enum8/Enum16 with string literals, but has no LIKE on
        // it — a pushed LIKE would fail the whole query instead of filtering.
        #expect(ColumnRef.family(ofType: "Enum8('active' = 1, 'inactive' = 2)") == .enumeration)
        #expect(ColumnRef.family(ofType: "Nullable(Enum16('a' = 1))") == .enumeration)
        let c: [String: [String: String]] = ["t1": ["tail": "String", "status": "Enum8('active' = 1, 'inactive' = 2)"],
                                             "t2": ["tail_no": "varchar(10)"]]
        let base = "SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE "
        #expect(push(base + "t1.status = 'active'", columns: c) == ["t1": ["status = 'active'"]])
        #expect(push(base + "t1.status IN ('active', 'inactive')", columns: c) == ["t1": ["status IN ('active', 'inactive')"]])
        #expect(push(base + "t1.status IS NOT NULL", columns: c) == ["t1": ["status IS NOT NULL"]])
        #expect(push(base + "t1.status LIKE 'act%'", columns: c).isEmpty)
        #expect(push(base + "t1.status <> 'active'", columns: c).isEmpty)
    }

    @Test("numeric and temporal columns take ranges, NOT, BETWEEN and ISO literals")
    func numericTemporal() {
        let base = "SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE "
        let r = push(base + "t1.linenum BETWEEN 10 AND 20 AND NOT t2.alt = 0 AND t1.logtime >= '2026-01-01' AND t1.logtime < '2026-02-01 10:30:00'")
        #expect(r == ["t1": ["linenum BETWEEN 10 AND 20", "logtime >= '2026-01-01'", "logtime < '2026-02-01 10:30:00'"],
                      "t2": ["NOT alt = 0"]])
        #expect(push(base + "t1.logtime > 'yesterday'").isEmpty)      // not ISO: the server would read it differently
    }

    @Test("literal must match the column's family; backslashes stay local; '' quotes pass verbatim")
    func literals() {
        let base = "SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no WHERE "
        #expect(push(base + "t1.tail = 123").isEmpty)
        #expect(push(base + "t1.linenum = '5'").isEmpty)
        #expect(push(base + "t1.tail = 'a\\%'").isEmpty)
        #expect(push(base + "t1.tail = 'O''Hare'") == ["t1": ["tail = 'O''Hare'"], "t2": ["tail_no = 'O''Hare'"]])
    }

    @Test("ON conditions: one-table predicates are pushed; the key equality only carries filters between compatible types")
    func onConditions() {
        let r = push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no AND t2.active = 1 WHERE t1.tail IN ('N1', 'N2')")
        #expect(r == ["t1": ["tail IN ('N1', 'N2')"], "t2": ["active = 1", "tail_no IN ('N1', 'N2')"]])
        var mixed = cols
        mixed["t2"]?["tail_no"] = "int(11)"
        #expect(push(userSQL, columns: mixed) == ["t1": ["tail = 'N1'"]])
    }

    @Test("column references are rendered through the caller's quoting")
    func rendering() throws {
        let shape = try #require(SQLBuilder.analyzeSelect(userSQL, aliases: ["logsrv", "fleet"]))
        let r = SQLBuilder.pushdownPredicates(shape, columns: cols) { _, c in "`\(c)`" }
        #expect(r == ["t1": ["`tail` = 'N1'"], "t2": ["`tail_no` = 'N1'"]])
    }

    @Test("no WHERE and no one-table ON predicate → nothing to push")
    func nothing() {
        #expect(push("SELECT * FROM logsrv.traps t1 JOIN fleet.aircraft t2 ON t1.tail = t2.tail_no LIMIT 10").isEmpty)
    }
}
