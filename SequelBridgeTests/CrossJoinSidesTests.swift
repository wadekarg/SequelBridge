//
//  CrossJoinSidesTests.swift
//  SequelBridgeTests
//
//  Which side of a two-table cross-server join streams through the join (the "big"
//  side) and which is fetched first as the hash-table side (the "probe"). The big
//  side comes from its server through the passthrough, so it MUST be a side that
//  has one: with a local SQLite table on the other side, the MySQL/Postgres side is
//  big whatever the row estimates say. When both sides have a passthrough the row
//  estimates decide, an unknown estimate counting as the largest; neither → no plan.
//

import Testing
@testable import SequelBridge

@Suite("Cross-server join sides")
struct CrossJoinSidesTests {

    @Test("both passthrough: the larger estimate is the big side, a tie makes A the probe")
    func bothPassthrough() {
        #expect(SQLBuilder.crossJoinBigSide(estA: 10, estB: 1_000, canA: true, canB: true) == false)
        #expect(SQLBuilder.crossJoinBigSide(estA: 1_000, estB: 10, canA: true, canB: true) == true)
        #expect(SQLBuilder.crossJoinBigSide(estA: 10, estB: 10, canA: true, canB: true) == false)
    }

    @Test("an unknown estimate counts as the largest")
    func unknownEstimate() {
        #expect(SQLBuilder.crossJoinBigSide(estA: nil, estB: 1_000, canA: true, canB: true) == true)
        #expect(SQLBuilder.crossJoinBigSide(estA: 1_000, estB: nil, canA: true, canB: true) == false)
        #expect(SQLBuilder.crossJoinBigSide(estA: nil, estB: nil, canA: true, canB: true) == false)
    }

    @Test("only one passthrough side: that side is big, whatever the estimates")
    func onePassthrough() {
        #expect(SQLBuilder.crossJoinBigSide(estA: 10, estB: 1_000, canA: true, canB: false) == true)
        #expect(SQLBuilder.crossJoinBigSide(estA: 1_000, estB: 10, canA: false, canB: true) == false)
        #expect(SQLBuilder.crossJoinBigSide(estA: nil, estB: nil, canA: false, canB: true) == false)
    }

    @Test("no passthrough side: no plan")
    func neither() {
        #expect(SQLBuilder.crossJoinBigSide(estA: 10, estB: 1_000, canA: false, canB: false) == nil)
    }
}
