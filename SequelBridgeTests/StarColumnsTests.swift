//
//  StarColumnsTests.swift
//  SequelBridgeTests
//
//  The cross-server planner lists the BIG side first in the rebuilt FROM…JOIN (see
//  CrossJoinRewriteTests). Swapping the FROM order would flip the columns of a
//  `SELECT *`, so the star is spelled out as `a.*, b.*` in the user's original table
//  order first. These pin that rewrite.
//

import Testing
@testable import SequelBridge

@Suite("SELECT * spelled out per side")
struct StarColumnsTests {

    @Test("a bare star becomes the two sides' stars in the original order")
    func bareStar() {
        #expect(SQLBuilder.explicitStarColumns("SELECT * FROM a.t x JOIN b.u y ON x.k = y.k", first: "x", second: "y")
                == "SELECT x.*, y.* FROM a.t x JOIN b.u y ON x.k = y.k")
    }

    @Test("DISTINCT, case and line breaks are kept")
    func distinctAndLayout() {
        #expect(SQLBuilder.explicitStarColumns("select distinct *\nfrom a.t x\nJOIN b.u y ON x.k = y.k", first: "x", second: "y")
                == "select distinct x.*, y.*\nfrom a.t x\nJOIN b.u y ON x.k = y.k")
    }

    @Test("a leading comment before SELECT is preserved")
    func leadingComment() {
        #expect(SQLBuilder.explicitStarColumns("-- note\nSELECT * FROM a.t x JOIN b.u y ON x.k = y.k", first: "x", second: "y")
                == "-- note\nSELECT x.*, y.* FROM a.t x JOIN b.u y ON x.k = y.k")
    }

    @Test("an explicit select list is left alone — its order doesn't depend on FROM")
    func explicitList() {
        let sql = "SELECT x.id, y.name FROM a.t x JOIN b.u y ON x.k = y.k"
        #expect(SQLBuilder.explicitStarColumns(sql, first: "x", second: "y") == sql)
        let qualified = "SELECT y.*, x.* FROM a.t x JOIN b.u y ON x.k = y.k"
        #expect(SQLBuilder.explicitStarColumns(qualified, first: "x", second: "y") == qualified)
        let counted = "SELECT COUNT(*) FROM a.t x JOIN b.u y ON x.k = y.k"
        #expect(SQLBuilder.explicitStarColumns(counted, first: "x", second: "y") == counted)
    }
}
