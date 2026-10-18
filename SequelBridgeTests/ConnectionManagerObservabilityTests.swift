//
//  ConnectionManagerObservabilityTests.swift
//  SequelBridgeTests
//
//  ConnectionManager declares a custom `objectWillChange` (required by Swift 6.3
//  isolation rules). A custom publisher silently disables @Published's automatic
//  notifications, so mutating `saved`/`active` stopped refreshing SwiftUI — a new
//  connection did not appear in the Home list until relaunch. These tests pin the
//  contract: every observable mutation must fire objectWillChange.
//

import Combine
import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("ConnectionManager observability")
struct ConnectionManagerObservabilityTests {

    @Test("setting saved notifies observers so the Home list refreshes")
    func savedFiresObjectWillChange() throws {
        let mgr = try ConnectionManager()
        var fired = 0
        let c = mgr.objectWillChange.sink { fired += 1 }
        defer { c.cancel() }
        mgr.saved = Array(mgr.saved)                 // any set must notify SwiftUI
        #expect(fired >= 1)
    }

    @Test("setting active notifies observers")
    func activeFiresObjectWillChange() throws {
        let mgr = try ConnectionManager()
        var fired = 0
        let c = mgr.objectWillChange.sink { fired += 1 }
        defer { c.cancel() }
        mgr.active = Array(mgr.active)
        #expect(fired >= 1)
    }

    @Test("setting connectionError notifies observers")
    func errorFiresObjectWillChange() throws {
        let mgr = try ConnectionManager()
        var fired = 0
        let c = mgr.objectWillChange.sink { fired += 1 }
        defer { c.cancel() }
        mgr.connectionError = "x"
        #expect(fired >= 1)
    }

    @Test("a fixture store's inline password wins over the Keychain")
    func fixturePasswordWins() throws {
        let id = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr_fixture_\(UUID().uuidString).json")
        try """
        [{"id":"\(id.uuidString)","name":"Shop","alias":"shop","connectionType":"TCP/IP","color":"#D97A0B",
          "host":"127.0.0.1","port":3309,"username":"root","database":"shopdemo","engine":"mysql","password":"inline-pw"}]
        """.data(using: .utf8)!.write(to: url)
        let manager = try ConnectionManager(arguments: ["app", "-SBConnectionsFile", url.path])
        let shop = try #require(manager.saved.first)
        #expect(manager.saved.map(\.alias) == ["shop"])
        #expect(manager.password(for: shop) == "inline-pw")
        #expect(manager.isFixtureBacked)
    }

    @Test("a SQLite file needs no password: nothing stored means an empty one, not a refusal")
    func sqliteNeedsNoPassword() throws {
        let manager = try ConnectionManager(arguments: ["app"])
        let lite = Connection(name: "Ref", alias: "ref", database: "/tmp/ref.sqlite", engine: .sqlite)  // fresh id: nothing in the Keychain
        #expect(manager.password(for: lite) == "")
        let mysql = Connection(name: "Shop", alias: "shop", host: "127.0.0.1", username: "root", database: "shopdemo", engine: .mysql)
        #expect(manager.password(for: mysql) == nil)                                                   // servers still need one
    }
}
