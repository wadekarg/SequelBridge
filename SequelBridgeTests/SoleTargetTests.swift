//
//  SoleTargetTests.swift
//  SequelBridgeTests
//
//  Which connection a Query-tab statement runs on. With several connections open, a
//  statement that named no server (SHOW TABLES, SELECT * FROM orders) was refused or
//  ran nowhere useful. It runs on the connection picked at the top of the left panel,
//  as in Sequel Ace, where each window has one connection.
//

import Testing
@testable import SequelBridge

@Suite("Which connection a statement runs on")
struct SoleTargetTests {
    private let a = Connection(name: "A", alias: "litea", host: "", port: 0, username: "", database: "a.sqlite", engine: .sqlite)
    private let b = Connection(name: "B", alias: "liteb", host: "", port: 0, username: "", database: "b.sqlite", engine: .sqlite)

    private func target(_ sql: String, _ conns: [Connection], active: String?) -> String? {
        SQLBuilder.soleTarget(of: sql, connections: conns, active: active)?.alias
    }

    @Test("one connection: every statement runs on it")
    func one() {
        #expect(target("SHOW TABLES", [a], active: nil) == "litea")
        #expect(target("SELECT * FROM alpha_items", [a], active: "litea") == "litea")
    }

    @Test("several: a statement that names no server runs on the active tab's connection")
    func unnamed() {
        #expect(target("SHOW TABLES", [a, b], active: "liteb") == "liteb")
        #expect(target("SELECT * FROM beta_items", [a, b], active: "liteb") == "liteb")
        #expect(target("USE other", [a, b], active: "litea") == "litea")
        #expect(target("SELECT 1", [a, b], active: nil) == nil)
    }

    @Test("a statement that names one server runs there, whichever tab is active")
    func named() {
        #expect(target("SELECT * FROM litea.alpha_items", [a, b], active: "liteb") == "litea")
    }

    @Test("a statement that names two servers has no single connection")
    func both() {
        #expect(target("SELECT * FROM litea.alpha_items x JOIN liteb.beta_items y ON x.id = y.id", [a, b], active: "litea") == nil)
    }
}
