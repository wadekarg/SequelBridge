//
//  ConnectionTests.swift
//  SequelBridgeTests
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Connection Tests")
struct ConnectionTests {

    @Test func connectionRoundTrips() throws {
        let conn = Connection(
            id: UUID(),
            name: "Test DB",
            alias: "testdb",
            color: "#FF0000",
            host: "192.168.1.1",
            port: 3306,
            username: "user",
            database: "mydb"
        )
        let data = try JSONEncoder().encode(conn)
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        #expect(decoded.id == conn.id)
        #expect(decoded.alias == "testdb")
        #expect(decoded.host == "192.168.1.1")
        #expect(decoded.color == "#FF0000")
    }

    @Test func defaultPort() {
        let conn = Connection(name: "DB", alias: "db", host: "localhost", username: "u", database: "d")
        #expect(conn.port == 3306)
    }

    @Test func defaultColor() {
        let conn = Connection(name: "DB", alias: "db", host: "localhost", username: "u", database: "d")
        #expect(conn.color == "#4A90D9")
    }
}