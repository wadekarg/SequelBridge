//
//  ConnectionStoreTests.swift
//  SequelBridgeTests
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import Testing
import Foundation
@testable import SequelBridge

@Suite("ConnectionStore Tests")
struct ConnectionStoreTests {

    private func makeStore() -> ConnectionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_connections_\(UUID().uuidString).json")
        return ConnectionStore(fileURL: url)
    }

    @Test func saveAndLoad() throws {
        let store = makeStore()
        let conn = Connection(name: "Test", alias: "t", host: "localhost", username: "u", database: "db")
        try store.save([conn])
        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].alias == "t")
    }

    @Test func loadEmptyWhenNoFile() throws {
        let store = makeStore()
        let loaded = try store.load()
        #expect(loaded.isEmpty)
    }

    @Test func overwrite() throws {
        let store = makeStore()
        let c1 = Connection(name: "A", alias: "a", host: "h1", username: "u", database: "db")
        let c2 = Connection(name: "B", alias: "b", host: "h2", username: "u", database: "db")
        try store.save([c1])
        try store.save([c1, c2])
        let loaded = try store.load()
        #expect(loaded.count == 2)
    }

    @Test func roundTripsAllFields() throws {
        let store = makeStore()
        let conn = Connection(
            id: UUID(),
            name: "Full Test",
            alias: "full",
            color: "#FF5500",
            host: "192.168.1.1",
            port: 5432,
            username: "admin",
            database: "mydb"
        )
        try store.save([conn])
        let loaded = try store.load()
        #expect(loaded[0].id == conn.id)
        #expect(loaded[0].port == 5432)
        #expect(loaded[0].color == "#FF5500")
    }

    // MARK: - Fixture files (-SBConnectionsFile)

    private func writeFixture(_ json: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture_\(UUID().uuidString).json")
        try! json.data(using: .utf8)!.write(to: url)
        return url
    }

    @Test("a fixture file's inline passwords are read, keyed by connection id")
    func inlinePasswordsRead() throws {
        let id = UUID()
        let url = writeFixture("""
        [{"id":"\(id.uuidString)","name":"Shop","alias":"shop","connectionType":"TCP/IP","color":"#D97A0B",
          "host":"127.0.0.1","port":3309,"username":"root","database":"shopdemo","engine":"mysql","password":"sbverify123"}]
        """)
        let store = ConnectionStore(fileURL: url, fixture: true)
        let loaded = try store.load()
        #expect(loaded.map(\.alias) == ["shop"])
        #expect(store.inlinePasswords[id] == "sbverify123")
    }

    @Test("a fixture connection without a password has no inline password")
    func inlinePasswordMissingFallsBack() throws {
        let id = UUID()
        let url = writeFixture("""
        [{"id":"\(id.uuidString)","name":"Ref","alias":"ref","connectionType":"TCP/IP","color":"#3A9AA8",
          "host":"","port":0,"username":"","database":"/tmp/ref.sqlite","engine":"sqlite"}]
        """)
        let store = ConnectionStore(fileURL: url, fixture: true)
        _ = try store.load()
        #expect(store.inlinePasswords[id] == nil)
    }

    @Test("a normal store never reads inline passwords")
    func normalStoreIgnoresPasswords() throws {
        let id = UUID()
        let url = writeFixture("""
        [{"id":"\(id.uuidString)","name":"X","alias":"x","connectionType":"TCP/IP","color":"#4A90D9",
          "host":"h","port":1,"username":"u","database":"d","engine":"mysql","password":"secret"}]
        """)
        let store = ConnectionStore(fileURL: url)
        _ = try store.load()
        #expect(store.inlinePasswords.isEmpty)
    }

    @Test("a fixture store never writes its file")
    func fixtureStoreNeverWrites() throws {
        let url = writeFixture("[]")
        let before = try Data(contentsOf: url)
        let store = ConnectionStore(fileURL: url, fixture: true)
        try store.save([Connection(name: "A", alias: "a", host: "h", username: "u", database: "d")])
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("a missing fixture file loads as an empty list")
    func missingFixtureFileGivesEmptyList() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope_\(UUID().uuidString).json")
        let store = ConnectionStore(fileURL: url, fixture: true)
        #expect(try store.load().isEmpty)
    }

    @Test("the launch argument names the fixture file")
    func fixtureURLFromArguments() {
        #expect(ConnectionStore.fixtureURL(from: ["app", "-SBConnectionsFile", "/tmp/demo.json"])?.path == "/tmp/demo.json")
        #expect(ConnectionStore.fixtureURL(from: ["app"]) == nil)
        #expect(ConnectionStore.fixtureURL(from: ["app", "-SBConnectionsFile"]) == nil)   // no value
    }
}