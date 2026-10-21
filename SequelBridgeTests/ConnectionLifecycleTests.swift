//
//  ConnectionLifecycleTests.swift
//  SequelBridge
//
//  Connections opened and closed the way Home and the workspace open and close them:
//  nothing stays attached (or its SSH tunnel running) once the connect that made it
//  failed or was left.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Connections open and close cleanly")
struct ConnectionLifecycleTests {
    func sqliteFile(_ name: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-life-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).sqlite").path
        try await SQLiteTool.run("CREATE TABLE t (id INTEGER PRIMARY KEY)", file: file, busyTimeout: 5)
        return file
    }

    /// Connect with several selected attached them one by one and recorded none until all
    /// had: when one failed, those before it stayed attached, their tunnels running, until
    /// the app quit.
    @Test("a connect that fails part-way leaves none of its connections attached")
    func failedConnectLeavesNothing() async throws {
        let manager = try ConnectionManager(arguments: ["app"])
        let good = Connection(name: "Good", alias: "lifegood", database: try await sqliteFile("good"), engine: .sqlite)
        let missing = Connection(name: "Missing", alias: "lifemissing", database: "/nonexistent/sb-missing.sqlite", engine: .sqlite)
        await #expect(throws: (any Error).self) { try await manager.connect([good, missing]) }
        #expect(manager.queryEngine.attachedDatabase("lifegood").isEmpty, "the connection before the failure stayed attached")
        #expect(manager.active.isEmpty)
    }

    /// A SQLite file has no password, yet saving one put an empty item in the login
    /// Keychain, left behind for every file ever added.
    @Test("saving a SQLite connection writes nothing to the Keychain")
    func sqliteSavesNoKeychainItem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-life-kc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = try ConnectionManager(arguments: ["app", "-SBSupportDir", dir.path])
        let conn = Connection(name: "Lite K", alias: "litek", database: dir.appendingPathComponent("k.sqlite").path, engine: .sqlite)
        defer { try? manager.deleteSaved(id: conn.id); Keychain.delete(for: conn.id) }
        try manager.addSaved(conn, password: "")
        #expect(Keychain.load(for: conn.id) == nil, "adding it saved a Keychain item")
        try manager.updateSaved(conn, password: "")
        #expect(Keychain.load(for: conn.id) == nil, "saving it again saved a Keychain item")
        #expect(manager.password(for: conn) == "")
        #expect(manager.saved.contains { $0.id == conn.id })
    }

    /// A server added with a workspace's + was attached on its own, outside the manager's
    /// list: the next Connect from Home left it attached, its SSH tunnel running.
    @Test("a server added in the workspace is closed by the next Connect from Home")
    func addedServerClosesWithTheNextConnect() async throws {
        let manager = try ConnectionManager(arguments: ["app"])
        let a = Connection(name: "A", alias: "lifea", database: try await sqliteFile("a"), engine: .sqlite)
        let b = Connection(name: "B", alias: "lifeb", database: try await sqliteFile("b"), engine: .sqlite)
        let c = Connection(name: "C", alias: "lifec", database: try await sqliteFile("c"), engine: .sqlite)
        try await manager.connect([a])
        try await manager.add(b)
        #expect(manager.active.map(\.alias) == ["lifea", "lifeb"])
        try await manager.connect([c])
        #expect(manager.queryEngine.attachedDatabase("lifeb").isEmpty, "the added server stayed attached")
        #expect(manager.active.map(\.alias) == ["lifec"])
    }
}
