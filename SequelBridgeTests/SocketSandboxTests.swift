//
//  SocketSandboxTests.swift
//  SequelBridgeTests
//
//  The App Sandbox refuses a Unix socket even in a folder the user granted, and even with
//  Apple's file exceptions (spike, 2026-10-23): the App Store build offers TCP/IP and SSH,
//  and says why when a socket connection reaches it. The DMG build offers sockets as before.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Sockets: the DMG build only", .serialized)
struct SocketSandboxTests {
    @Test("the App Store build's connection form offers no socket; the DMG build's does")
    func offered() {
        for engine in [DatabaseEngine.mysql, .postgres] {
            #expect(engine.connectionTypes(in: .direct) == [.tcpip, .ssh, .socket])
            #expect(engine.connectionTypes(in: .appStore) == [.tcpip, .ssh])
        }
        #expect(DatabaseEngine.clickhouse.connectionTypes(in: .appStore) == [.tcpip, .ssh])
        #expect(DatabaseEngine.mysql.connectionTypes == [.tcpip, .ssh, .socket])
    }

    @Test("a socket connection reaching the App Store build is refused, saying to use TCP/IP to 127.0.0.1")
    func refused() async throws {
        QueryEngine.socketsAllowed = false
        defer { QueryEngine.socketsAllowed = Distribution.current.offersSockets }
        let c = Connection(name: "s", alias: "s", connectionType: .socket, username: "root", socketPath: "/tmp/mysql.sock")
        let engine = try QueryEngine()
        do {
            try await engine.attach(c, password: "x")
            Issue.record("attached")
        } catch {
            #expect(error.localizedDescription == QueryEngine.noSockets, "\(error)")
        }
    }
}
