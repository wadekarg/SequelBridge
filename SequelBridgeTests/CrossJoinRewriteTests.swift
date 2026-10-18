//
//  CrossJoinRewriteTests.swift
//  SequelBridgeTests
//
//  The cross-server planner rebuilds the user's FROM…JOIN…ON with each side replaced
//  by what it fetches (a passthrough subquery, or a scanner ref), BIG SIDE FIRST: the
//  statement runs with its join order pinned, so DuckDB probes with the first table
//  and builds its hash table on the second — the big side streams through a hash
//  table of the small side, and the first joined rows appear as the server sends
//  them. Swapping the FROM order would flip the columns of a `SELECT *`, so the star
//  is spelled out as `a.*, b.*` in the user's original table order when the sides
//  are swapped. These pin that rewrite.
//

import Testing
@testable import SequelBridge

@Suite("Cross-server join rewrite")
struct CrossJoinRewriteTests {
    private let sql = "SELECT * FROM a.t x JOIN b.u y ON x.k = y.k WHERE x.k > 1"
    private var join: SQLBuilder.CrossJoin { SQLBuilder.detectCrossJoin(sql, aliases: ["a", "b"])! }

    @Test("the big side goes first, each side keeping its own alias and key")
    func bigFirst() {
        #expect(SQLBuilder.crossJoinRewrite(sql, join: join, bigIsA: true, bigRef: "(BIG)", probeRef: "(PROBE)")
                == "SELECT * FROM (BIG) x JOIN (PROBE) y ON x.k = y.k WHERE x.k > 1")
    }

    @Test("a big second table moves first and SELECT * is spelled out so columns keep their order")
    func bigSecond() {
        #expect(SQLBuilder.crossJoinRewrite(sql, join: join, bigIsA: false, bigRef: "(BIG)", probeRef: "(PROBE)")
                == "SELECT x.*, y.* FROM (BIG) y JOIN (PROBE) x ON y.k = x.k WHERE x.k > 1")
    }

    @Test("an explicit select list is left alone when the sides swap")
    func explicitList() {
        let s = "SELECT x.id, y.name FROM a.t x JOIN b.u y ON x.k = y.k"
        let cj = SQLBuilder.detectCrossJoin(s, aliases: ["a", "b"])!
        #expect(SQLBuilder.crossJoinRewrite(s, join: cj, bigIsA: false, bigRef: "(BIG)", probeRef: "(PROBE)")
                == "SELECT x.id, y.name FROM (BIG) y JOIN (PROBE) x ON y.k = x.k")
    }
}
