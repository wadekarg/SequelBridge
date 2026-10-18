//
//  DSNTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("ATTACH DSN construction")
struct DSNTests {

    func conn(_ engine: DatabaseEngine, user: String = "u", db: String = "d") -> Connection {
        var c = Connection(name: "n", alias: "a", connectionType: .tcpip,
                           host: "h", port: 1234, username: user, database: db)
        c.engine = engine
        return c
    }

    @Test("an empty password never emits a dangling password= pair")
    func emptyPasswordOmitted() {
        // mysql_scanner rejects "password=" with nothing after it — which broke
        // every passwordless server (TiDB's default root, dev MySQL boxes).
        let dsn = QueryEngine.buildDSN(for: conn(.mysql), password: "")
        #expect(!dsn.contains("password"), "got: \(dsn)")
    }

    @Test("a real password is included")
    func passwordIncluded() {
        let dsn = QueryEngine.buildDSN(for: conn(.mysql), password: "s3cret")
        #expect(dsn.contains("password=s3cret"))
    }

    @Test("mysql uses database=, postgres uses dbname=")
    func databaseKeyPerEngine() {
        #expect(QueryEngine.buildDSN(for: conn(.mysql), password: "x").contains("database=d"))
        #expect(QueryEngine.buildDSN(for: conn(.postgres), password: "x").contains("dbname=d"))
    }

    @Test("an empty database is omitted for mysql")
    func emptyDatabaseOmitted() {
        let dsn = QueryEngine.buildDSN(for: conn(.mysql, db: ""), password: "x")
        #expect(!dsn.contains("database="))
    }

    @Test("sqlite's DSN is just the file path")
    func sqlitePath() {
        var c = conn(.sqlite)
        c.database = "/tmp/some file.sqlite"
        #expect(QueryEngine.buildDSN(for: c, password: "") == "/tmp/some file.sqlite")
    }

    @Test("Use SSL makes each driver require it: ssl_mode=required for MySQL, sslmode=require for PostgreSQL")
    func sslRequired() {
        var my = conn(.mysql); my.useSSL = true
        let m = QueryEngine.buildDSN(for: my, password: "x")
        #expect(m.contains("ssl_mode=required"), "got: \(m)")
        #expect(!m.contains("ssl=1"), "got: \(m)")          // the old key, which DuckDB refused
        var pg = conn(.postgres); pg.useSSL = true
        let p = QueryEngine.buildDSN(for: pg, password: "x")
        #expect(p.contains("sslmode=require"), "got: \(p)")
    }

    @Test("without Use SSL the drivers keep their default: encrypt when the server offers it")
    func sslDefault() {
        for engine in [DatabaseEngine.mysql, .postgres] {
            let dsn = QueryEngine.buildDSN(for: conn(engine), password: "x")
            #expect(!dsn.contains("ssl"), "got: \(dsn)")
        }
    }
}
