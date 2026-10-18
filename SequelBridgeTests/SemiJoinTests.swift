//
//  SemiJoinTests.swift
//  SequelBridgeTests
//
//  Cross-server semi-join reduction: a `col IN (SELECT … FROM otherServer…)` is
//  detected so the subquery can run on its server and its values be inlined into the
//  outer query, instead of DuckDB's scanner dragging both whole tables to the client.
//  Detection is conservative — anything unclear returns nil and the caller falls back
//  to the scanner, so it can only speed queries up, never change their results.
//

import Testing
@testable import SequelBridge

@Suite("Cross-server semi-join reduction")
struct SemiJoinTests {

    let aliases = ["srvA", "srvB"]

    @Test("a non-correlated cross-server IN-subquery is reduced")
    func reducible() {
        let sql = "SELECT * FROM srvA.events WHERE tail IN (SELECT tail FROM srvB.fleet WHERE status = 'active') AND logtime > '2026-01-01'"
        let sj = SQLBuilder.detectSemiJoin(sql, aliases: aliases)
        #expect(sj != nil)
        #expect(sj?.subAlias == "srvB")
        #expect(sj?.outerAlias == "srvA")
        #expect(sj?.subquery.contains("fleet") == true)
        #expect(sj?.subquery.lowercased().hasPrefix("select") == true)
        #expect(sj?.outerPrefix.hasSuffix("(") == true)
        #expect(sj?.outerSuffix.hasPrefix(")") == true)

        // Composing prefix + values + suffix and stripping the outer alias yields the
        // single-server query to run on the outer server.
        if let sj {
            let outer = SQLBuilder.stripAliasPrefix(sj.outerPrefix + "'N1', 'N2'" + sj.outerSuffix, alias: sj.outerAlias)
            #expect(outer.contains("events"))
            #expect(!outer.contains("srvA."))                 // alias stripped
            #expect(outer.contains("tail IN ('N1', 'N2')"))     // values inlined
            #expect(outer.contains("logtime > '2026-01-01'"))   // rest of the outer WHERE kept
        }
    }

    @Test("a plain value list is not a subquery")
    func valueList() {
        #expect(SQLBuilder.detectSemiJoin("SELECT * FROM srvA.t WHERE x IN (1, 2, 3)", aliases: aliases) == nil)
    }

    @Test("a same-server subquery is left to the scanner")
    func sameServer() {
        #expect(SQLBuilder.detectSemiJoin("SELECT * FROM srvA.a WHERE k IN (SELECT k FROM srvA.b)", aliases: aliases) == nil)
    }

    @Test("a correlated subquery (references the outer server) is not reduced")
    func correlated() {
        let sql = "SELECT * FROM srvA.a WHERE k IN (SELECT k FROM srvB.b WHERE srvB.b.x = srvA.a.y)"
        #expect(SQLBuilder.detectSemiJoin(sql, aliases: aliases) == nil)
    }

    @Test("an outer query spanning two servers is not reduced")
    func multiServerOuter() {
        let sql = "SELECT * FROM srvA.a JOIN srvB.c ON a.k = c.k WHERE k IN (SELECT k FROM srvB.b)"
        #expect(SQLBuilder.detectSemiJoin(sql, aliases: aliases) == nil)
    }

    @Test("no subquery, nothing to reduce")
    func noSubquery() {
        #expect(SQLBuilder.detectSemiJoin("SELECT * FROM srvA.t WHERE x > 1", aliases: aliases) == nil)
    }

    @Test("value list: quotes values, drops NULLs, escapes quotes")
    func inValueList() {
        #expect(SQLBuilder.inValueList(["N1", "N2"], mask: [false, false]) == "'N1', 'N2'")
        #expect(SQLBuilder.inValueList(["N1", "x"], mask: [false, true]) == "'N1'")
        #expect(SQLBuilder.inValueList([], mask: []) == "NULL")
        #expect(SQLBuilder.inValueList(["x"], mask: [true]) == "NULL")
        #expect(SQLBuilder.inValueList(["O'Brien"], mask: [false]) == "'O''Brien'")
    }

    @Test("referencesAlias respects word boundaries and quotes")
    func referencesAlias() {
        #expect(SQLBuilder.referencesAlias("select * from srvA.t", "srvA"))
        #expect(!SQLBuilder.referencesAlias("select * from mysrvA.t", "srvA"))  // preceded by a word char
        #expect(!SQLBuilder.referencesAlias("select 'srvA.t'", "srvA"))         // inside a string literal
        #expect(!SQLBuilder.referencesAlias("select srvA", "srvA"))             // no trailing dot
    }

    // MARK: - Cross-server inner-join detection

    @Test("a two-table cross-server inner join with aliases is detected")
    func crossJoinAliased() {
        let sql = "SELECT x.ip, y.status FROM srvA.events x JOIN srvB.fleet y ON x.tail = y.tail WHERE y.status = 'active'"
        let cj = SQLBuilder.detectCrossJoin(sql, aliases: aliases)
        #expect(cj?.a == .init(server: "srvA", table: "events", tableAlias: "x", key: "tail"))
        #expect(cj?.b == .init(server: "srvB", table: "fleet", tableAlias: "y", key: "tail"))
        #expect(cj?.fromJoinClause.hasPrefix("FROM srvA.events x JOIN srvB.fleet y ON") == true)
    }

    @Test("a JOIN at the start of a line is still the one join of a two-table query")
    func crossJoinOnItsOwnLine() {
        // The join count was taken from " join " with spaces, so a newline before JOIN
        // made the detector give up and the query took the whole-table fallback.
        let sql = "SELECT *\nFROM srvA.events t1\nJOIN srvB.fleet t2 ON t1.tail = t2.tail\nWHERE t1.tail = 'N1'"
        let cj = SQLBuilder.detectCrossJoin(sql, aliases: aliases)
        #expect(cj?.a == .init(server: "srvA", table: "events", tableAlias: "t1", key: "tail"))
        #expect(cj?.b == .init(server: "srvB", table: "fleet", tableAlias: "t2", key: "tail"))
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x\nJOIN srvB.b y ON x.k = y.k\nJOIN srvA.c z ON z.k = x.k", aliases: aliases) == nil)
    }

    @Test("AS aliases and reversed ON order map to the right sides")
    func crossJoinAsReversed() {
        let sql = "SELECT * FROM srvA.big AS a JOIN srvB.small AS b ON b.k2 = a.k1"
        let cj = SQLBuilder.detectCrossJoin(sql, aliases: aliases)
        #expect(cj?.a.key == "k1")   // srvA side
        #expect(cj?.b.key == "k2")   // srvB side
        #expect(cj?.a.tableAlias == "a")
        #expect(cj?.b.tableAlias == "b")
    }

    @Test("no table alias → the table name is used as the alias")
    func crossJoinNoAlias() {
        let sql = "SELECT * FROM srvA.big JOIN srvB.small ON big.tail = small.tail"
        let cj = SQLBuilder.detectCrossJoin(sql, aliases: aliases)
        #expect(cj?.a.tableAlias == "big")
        #expect(cj?.b.tableAlias == "small")
    }

    @Test("same-server join is not a cross-server reduction")
    func crossJoinSameServer() {
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x JOIN srvA.b y ON x.k = y.k", aliases: aliases) == nil)
    }

    @Test("LEFT/RIGHT/FULL/CROSS joins are not reduced")
    func crossJoinOuterRejected() {
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x LEFT JOIN srvB.b y ON x.k = y.k", aliases: aliases) == nil)
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x RIGHT JOIN srvB.b y ON x.k = y.k", aliases: aliases) == nil)
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a LEFT OUTER JOIN srvB.b ON a.k = b.k", aliases: aliases) == nil)
    }

    @Test("unqualified ON key is ambiguous → not reduced")
    func crossJoinUnqualifiedKey() {
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x JOIN srvB.b y ON tail = y.tail", aliases: aliases) == nil)
    }

    // Comma joins — `FROM a x, b y WHERE x.k = y.k` — are the same inner equi-join
    // and just as common; the equality is read from the WHERE's top-level conjuncts.

    @Test("a comma join whose key equality is a WHERE conjunct is detected")
    func commaJoin() {
        let sql = "SELECT *\nFROM srvA.events t1, srvB.fleet t2\nWHERE t1.tail = t2.tail AND t1.tail = 'N1' AND t1.logtime BETWEEN '2026-01-08' AND '2026-01-09'"
        let cj = SQLBuilder.detectCrossJoin(sql, aliases: aliases)
        #expect(cj?.a == .init(server: "srvA", table: "events", tableAlias: "t1", key: "tail"))
        #expect(cj?.b == .init(server: "srvB", table: "fleet", tableAlias: "t2", key: "tail"))
        #expect(cj?.fromJoinClause == "FROM srvA.events t1, srvB.fleet t2")
    }

    @Test("a comma join's reversed equality and AS aliases map to the right sides")
    func commaJoinReversed() {
        let sql = "SELECT * FROM srvA.big AS a, srvB.small AS b WHERE b.k2 = a.k1"
        let cj = SQLBuilder.detectCrossJoin(sql, aliases: aliases)
        #expect(cj?.a.key == "k1")
        #expect(cj?.b.key == "k2")
        #expect(cj?.fromJoinClause == "FROM srvA.big AS a, srvB.small AS b")
    }

    @Test("a comma join needs the equality as a top-level AND conjunct")
    func commaJoinNeedsConjunct() {
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x, srvB.b y WHERE x.k = y.k OR x.z = 1", aliases: aliases) == nil)
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x, srvB.b y WHERE (x.k = y.k OR x.z = 1) AND x.w = 2", aliases: aliases) == nil)
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x, srvB.b y WHERE x.k = 1", aliases: aliases) == nil)
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x, srvB.b y", aliases: aliases) == nil)
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x, srvB.b y WHERE x.k = x.z", aliases: aliases) == nil)
    }

    @Test("three comma tables, or a comma list with a JOIN, are not reduced")
    func commaJoinThreeTables() {
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x, srvB.b y, srvA.c z WHERE x.k = y.k", aliases: aliases) == nil)
        #expect(SQLBuilder.detectCrossJoin("SELECT * FROM srvA.a x, srvB.b y JOIN srvA.c z ON z.k = x.k WHERE x.k = y.k", aliases: aliases) == nil)
    }

    @Test("three-table (two joins) query is not reduced")
    func crossJoinThreeTables() {
        let sql = "SELECT * FROM srvA.a x JOIN srvB.b y ON x.k = y.k JOIN srvA.c z ON z.k = x.k"
        #expect(SQLBuilder.detectCrossJoin(sql, aliases: aliases) == nil)
    }
}
