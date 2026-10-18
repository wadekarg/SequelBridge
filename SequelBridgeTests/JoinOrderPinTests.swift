//
//  JoinOrderPinTests.swift
//  SequelBridgeTests
//
//  DuckDB has no row estimate for a passthrough subquery (a table function reports
//  ~1 row), so its optimizers decide the hash join's build side from guesses: the
//  smaller estimate is built, and between equal estimates the NARROWER table is —
//  whatever the written order. For a cross-server join that put the BIG side on the
//  build side whenever the other side was a real table, or simply had more columns
//  (the prod case): every row had to arrive before the first joined row came out
//  (measured: 15 s of nothing, 700 MB, for a 3M-row side that otherwise streams
//  from 0.15 s). The planner already knows which side is small, so it runs its
//  statement with the join order pinned: the first table in FROM is probed, the
//  second is built. These pin that contract on plain local tables, where DuckDB's
//  own choice is the opposite of the written order.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Pinned join order")
struct JoinOrderPinTests {

    /// The table DuckDB builds the hash table on: the right child of HASH_JOIN in the
    /// physical plan (EXPLAIN in JSON, children in order: probe, build).
    private func buildSide(_ engine: QueryEngine, _ sql: String, pinJoinOrder: Bool) async throws -> String {
        let (plan, stream) = try await engine.openStreamingQuery("EXPLAIN (FORMAT json) " + sql,
                                                                 firstChunk: 10, pinJoinOrder: pinJoinOrder)
        await engine.closeStream(stream)
        let text = try #require(plan.rows.first?.last)
        let roots = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        func find(_ node: [String: Any], named name: String) -> [String: Any]? {
            if node["name"] as? String == name { return node }
            for child in node["children"] as? [[String: Any]] ?? [] {
                if let hit = find(child, named: name) { return hit }
            }
            return nil
        }
        func table(_ node: [String: Any]) -> String? {
            if let t = (node["extra_info"] as? [String: Any])?["Table"] as? String { return t }
            for child in node["children"] as? [[String: Any]] ?? [] {
                if let t = table(child) { return t }
            }
            return nil
        }
        let join = try #require(roots.lazy.compactMap { find($0, named: "HASH_JOIN") }.first)
        let children = try #require(join["children"] as? [[String: Any]])
        return try #require(table(children[1]))
    }

    @Test("pinned: the second table in FROM is the build side even when it is the big one")
    func pinnedKeepsWrittenOrder() async throws {
        let engine = try QueryEngine()
        _ = try await engine.query("CREATE TEMP TABLE small AS SELECT range AS k FROM range(10)")
        _ = try await engine.query("CREATE TEMP TABLE big AS SELECT range % 10 AS k, range AS v FROM range(100000)")
        let sql = "SELECT b.v FROM small s JOIN big b ON s.k = b.k"

        // DuckDB's own choice builds on the small table, whatever the written order.
        #expect(try await buildSide(engine, sql, pinJoinOrder: false).contains("small"))
        // Pinned, the written order stands: big is second, so big is built.
        #expect(try await buildSide(engine, sql, pinJoinOrder: true).contains("big"))
    }

    @Test("equal estimates: DuckDB builds on the narrower table whatever the order; pinned, the second is built")
    func narrowerSideWins() async throws {
        let engine = try QueryEngine()
        let wideCols = (1...30).map { "range AS c\($0)" }.joined(separator: ", ")
        _ = try await engine.query("CREATE TEMP TABLE narrow AS SELECT range AS k FROM range(1000)")
        _ = try await engine.query("CREATE TEMP TABLE wide AS SELECT range AS k, \(wideCols) FROM range(1000)")
        let sql = "SELECT * FROM narrow n JOIN wide w ON n.k = w.k"

        #expect(try await buildSide(engine, sql, pinJoinOrder: false).contains("narrow"))
        #expect(try await buildSide(engine, sql, pinJoinOrder: true).contains("wide"))
    }

    @Test("the pin is per statement: the next query on the lane is optimized as usual")
    func pinDoesNotLeak() async throws {
        let engine = try QueryEngine()
        _ = try await engine.query("CREATE TEMP TABLE small AS SELECT range AS k FROM range(10)")
        _ = try await engine.query("CREATE TEMP TABLE big AS SELECT range % 10 AS k, range AS v FROM range(100000)")
        let sql = "SELECT b.v FROM small s JOIN big b ON s.k = b.k"
        _ = try await buildSide(engine, sql, pinJoinOrder: true)
        #expect(try await buildSide(engine, sql, pinJoinOrder: false).contains("small"))
    }
}
