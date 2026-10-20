//
//  ClickHouseContentTests.swift
//  SequelBridgeTests
//
//  The Content tab on ClickHouse, run the way the panel runs it on the real server: a
//  page sorted and paged, each filter operator (values are always quoted, so a number
//  column compares with '2'), and a %, _ or backslash in the value matching as itself.
//

import Foundation
import Testing
@testable import SequelBridge

private enum CHCEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_CH_VERIFY"] == "1" }
}

@MainActor
@Suite("ClickHouse's Content tab (real server)", .enabled(if: CHCEnv.enabled), .serialized)
struct ClickHouseContentTests {
    func engine() async throws -> QueryEngine {
        let e = try QueryEngine()
        var c = Connection(name: "CH content", alias: "chc", connectionType: .tcpip,
                           host: CHCEnv.e["SB_CH_HOST"] ?? "127.0.0.1", port: Int(CHCEnv.e["SB_CH_PORT"] ?? "8123") ?? 8123,
                           username: CHCEnv.e["SB_CH_USER"] ?? "sbuser", database: "default")
        c.engine = .clickhouse
        try await e.attach(c, password: CHCEnv.e["SB_CH_PASS"] ?? "sbpass123")
        try await e.clickhouseExecute(alias: "chc", sql: "DROP TABLE IF EXISTS default.ch_content")
        try await e.clickhouseExecute(alias: "chc", sql: "CREATE TABLE default.ch_content (id UInt32, note Nullable(String)) ENGINE = MergeTree ORDER BY id")
        try await e.clickhouseExecute(alias: "chc", sql: #"INSERT INTO default.ch_content VALUES (1, '50%'), (2, 'a_b'), (3, 'axb'), (4, 'back\\slash'), (5, NULL)"#)
        return e
    }

    /// The page query Content sends to ClickHouse.
    func ids(_ e: QueryEngine, where filter: String = "", sort: String? = "id", ascending: Bool = true,
             limit: Int = 100, offset: Int = 0) async throws -> [String] {
        var sql = #"SELECT * FROM "default"."ch_content""#
        if !filter.isEmpty { sql += " WHERE \(filter)" }
        sql += SQLBuilder.orderBy(column: sort, ascending: ascending) + " LIMIT \(limit) OFFSET \(offset)"
        return try await e.clickhouseQuery(alias: "chc", sql: sql).rows.map { $0[0] }
    }

    func rule(_ column: String, _ op: ContentFilter.Op, _ value: String = "", _ value2: String = "") throws -> String {
        try #require(ContentFilter.condition(column: column, op: op, value: value, value2: value2,
                                             dialect: ContentFilter.dialect(engine: .clickhouse, passthrough: false)))
    }

    @Test("a page sorted either way, and the next page")
    func pages() async throws {
        let e = try await engine()
        #expect(try await ids(e, sort: "id", ascending: false, limit: 2) == ["5", "4"])
        #expect(try await ids(e, limit: 2, offset: 2) == ["3", "4"])
    }

    @Test("each operator, on a number column with its value quoted")
    func operators() async throws {
        let e = try await engine()
        #expect(try await ids(e, where: rule("id", .equals, "2")) == ["2"])
        #expect(try await ids(e, where: rule("id", .notEquals, "2")) == ["1", "3", "4", "5"])
        #expect(try await ids(e, where: rule("id", .greater, "3")) == ["4", "5"])
        #expect(try await ids(e, where: rule("id", .lessOrEqual, "2")) == ["1", "2"])
        #expect(try await ids(e, where: rule("id", .isIn, "1, 3")) == ["1", "3"])
        #expect(try await ids(e, where: rule("id", .between, "2", "4")) == ["2", "3", "4"])
        #expect(try await ids(e, where: rule("note", .isNull)) == ["5"])
        #expect(try await ids(e, where: rule("note", .isNotNull)) == ["1", "2", "3", "4"])
        #expect(try await ids(e, where: rule("note", .beginsWith, "a")) == ["2", "3"])
        #expect(try await ids(e, where: rule("note", .endsWith, "b")) == ["2", "3"])
    }

    @Test("a %, _ or backslash in the value matches as itself")
    func literalWildcards() async throws {
        let e = try await engine()
        #expect(try await ids(e, where: rule("note", .contains, "%")) == ["1"])
        #expect(try await ids(e, where: rule("note", .contains, "_")) == ["2"], "an underscore matched any character")
        #expect(try await ids(e, where: rule("note", .contains, #"\"#)) == ["4"])
        #expect(try await ids(e, where: rule("note", .notContains, "_")) == ["1", "3", "4"])
        #expect(try await e.clickhouseQuery(alias: "chc", sql: #"SELECT COUNT(*) FROM "default"."ch_content" WHERE "#
                                            + rule("note", .contains, "a")).rows == [["3"]])
        try await e.clickhouseExecute(alias: "chc", sql: "DROP TABLE IF EXISTS default.ch_content")
    }
}
