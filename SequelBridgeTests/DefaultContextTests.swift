//
//  DefaultContextTests.swift
//  SequelBridgeTests
//
//  DuckDB has one default database for the statements the Query tab runs through its
//  catalog; the app remembered one per connection. With two connections open, picking
//  the first again after the second had been used left DuckDB on the second, so an
//  unqualified name read the second server's table of that name (or "does not exist").
//  Test Connection and adding a server move the default too.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("DuckDB's default database follows the connection a statement is for")
struct DefaultContextTests {
    func sqlite(_ name: String, value: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ctx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).sqlite").path
        try await SQLiteTool.run("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('\(value)')", file: file, busyTimeout: 5)
        return file
    }

    @Test("using A after B reads A's table, not B's")
    func aAfterB() async throws {
        let engine = try QueryEngine()
        let a = Connection(name: "A", alias: "ctxa", database: try await sqlite("a", value: "from A"), engine: .sqlite)
        let b = Connection(name: "B", alias: "ctxb", database: try await sqlite("b", value: "from B"), engine: .sqlite)
        try await engine.attach(a, password: "")
        await engine.setDefaultContextAwaited(alias: "ctxa", database: "main")
        #expect(try await engine.query("SELECT v FROM t").rows.first?.first == "from A")
        try await engine.attach(b, password: "")
        await engine.setDefaultContextAwaited(alias: "ctxb", database: "main")
        #expect(try await engine.query("SELECT v FROM t").rows.first?.first == "from B")
        await engine.setDefaultContextAwaited(alias: "ctxa", database: "main")
        #expect(try await engine.query("SELECT v FROM t").rows.first?.first == "from A")
        try await engine.detach("ctxb")
        await engine.setDefaultContextAwaited(alias: "ctxa", database: "main")
        #expect(try await engine.query("SELECT v FROM t").rows.first?.first == "from A")
    }
}
