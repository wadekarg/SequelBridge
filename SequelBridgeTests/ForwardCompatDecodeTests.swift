//
//  ForwardCompatDecodeTests.swift
//  SequelBridgeTests
//
//  connections.json is written by whatever version last ran. A newer build can
//  add engines/connection types an older build doesn't know, and a single
//  unknown enum value used to make the WHOLE list fail to decode — the user saw
//  "all my connections are gone". These tests pin forward/robust decoding:
//  unknown enum values fall back to a safe default, and one corrupt entry never
//  discards the rest.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Forward-compatible decoding")
struct ForwardCompatDecodeTests {

    @Test("unknown DatabaseEngine decodes to a safe default instead of throwing")
    func unknownEngine() throws {
        let e = try JSONDecoder().decode(DatabaseEngine.self, from: Data("\"oracle\"".utf8))
        #expect(e == .mysql)
    }

    @Test("known DatabaseEngine values still decode correctly")
    func knownEngines() throws {
        let cases: [(String, DatabaseEngine)] =
            [("mysql", .mysql), ("postgres", .postgres), ("sqlite", .sqlite), ("clickhouse", .clickhouse)]
        for (raw, expected) in cases {
            let e = try JSONDecoder().decode(DatabaseEngine.self, from: Data("\"\(raw)\"".utf8))
            #expect(e == expected)
        }
    }

    @Test("DatabaseEngine still encodes as its raw value")
    func engineRoundTrip() throws {
        let data = try JSONEncoder().encode(DatabaseEngine.clickhouse)
        #expect(String(data: data, encoding: .utf8) == "\"clickhouse\"")
        #expect(try JSONDecoder().decode(DatabaseEngine.self, from: data) == .clickhouse)
    }

    @Test("folder round-trips and is absent-safe (old connections decode to ungrouped)")
    func folderForwardCompat() throws {
        // Round-trip: a connection with a folder keeps it.
        let c = Connection(name: "Prod", alias: "p", folder: "AWS")
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Connection.self, from: data).folder == "AWS")
        // Forward-compat: JSON saved before `folder` existed decodes to "".
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old","alias":"o","connectionType":"TCP/IP",
         "color":"#4A90D9","host":"h","port":3306,"username":"u","database":""}
        """
        let old = try JSONDecoder().decode(Connection.self, from: Data(legacy.utf8))
        #expect(old.folder == "")
    }

    @Test("unknown ConnectionType decodes to .tcpip instead of throwing")
    func unknownConnectionType() throws {
        let t = try JSONDecoder().decode(ConnectionType.self, from: Data("\"Carrier Pigeon\"".utf8))
        #expect(t == .tcpip)
    }

    @Test("ConnectionType still encodes as its raw value")
    func connectionTypeRoundTrip() throws {
        let data = try JSONEncoder().encode(ConnectionType.ssh)
        #expect(String(data: data, encoding: .utf8) == "\"SSH\"")
        #expect(try JSONDecoder().decode(ConnectionType.self, from: data) == .ssh)
    }

    @Test("a connection with an unknown engine still loads — no data loss")
    func unknownEngineDoesNotWipeList() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc_\(UUID().uuidString).json")
        let json = """
        [
          {"id":"\(UUID().uuidString)","name":"A","alias":"a","connectionType":"TCP/IP","engine":"mysql","color":"#4A90D9","host":"h1","port":3306,"username":"u","database":""},
          {"id":"\(UUID().uuidString)","name":"B","alias":"b","connectionType":"TCP/IP","engine":"cockroach","color":"#4A90D9","host":"h2","port":3306,"username":"u","database":""}
        ]
        """
        try Data(json.utf8).write(to: url)
        let loaded = try ConnectionStore(fileURL: url).load()
        #expect(loaded.count == 2)                                   // before fix: throws -> caller gets [] -> all lost
        #expect(loaded.first { $0.alias == "b" }?.engine == .mysql)  // unknown engine -> safe default
    }

    @Test("one corrupt entry is skipped, not fatal to the whole list")
    func corruptEntrySkipped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc_\(UUID().uuidString).json")
        // The middle entry is missing the required `id` field.
        let json = """
        [
          {"id":"\(UUID().uuidString)","name":"A","alias":"a","connectionType":"TCP/IP","engine":"mysql","color":"#4A90D9","host":"h1","port":3306,"username":"u","database":""},
          {"name":"broken","alias":"x","connectionType":"TCP/IP","color":"#4A90D9","host":"h","port":3306,"username":"u","database":""},
          {"id":"\(UUID().uuidString)","name":"C","alias":"c","connectionType":"TCP/IP","engine":"mysql","color":"#4A90D9","host":"h3","port":3306,"username":"u","database":""}
        ]
        """
        try Data(json.utf8).write(to: url)
        let loaded = try ConnectionStore(fileURL: url).load()
        #expect(loaded.map(\.alias).sorted() == ["a", "c"])          // before fix: whole decode throws -> []
    }
}
