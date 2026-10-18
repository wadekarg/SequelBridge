//
//  DatabaseEngineTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Database engines")
struct DatabaseEngineTests {

    @Test("each engine names its own DuckDB scanner")
    func extensionNames() {
        #expect(DatabaseEngine.mysql.extensionName == "mysql_scanner")
        #expect(DatabaseEngine.postgres.extensionName == "postgres_scanner")
    }

    @Test("ATTACH type matches the scanner")
    func attachTypes() {
        #expect(DatabaseEngine.mysql.attachType == "mysql_scanner")
        #expect(DatabaseEngine.postgres.attachType == "postgres_scanner")
    }

    @Test("the DSN key for the initial database differs between engines")
    func dsnKeys() {
        // Passing MySQL's key to Postgres is a connection error, not a warning.
        #expect(DatabaseEngine.mysql.databaseDSNKey == "database")
        #expect(DatabaseEngine.postgres.databaseDSNKey == "dbname")
    }

    @Test("default ports")
    func ports() {
        #expect(DatabaseEngine.mysql.defaultPort == 3306)
        #expect(DatabaseEngine.postgres.defaultPort == 5432)
    }

    @Test("MySQL quotes identifiers with backticks, Postgres with double quotes")
    func quoting() {
        #expect(DatabaseEngine.mysql.identifier("tbl") == "`tbl`")
        #expect(DatabaseEngine.postgres.identifier("tbl") == "\"tbl\"")
    }

    @Test("identifier quoting escapes the quote character")
    func quoteEscaping() {
        #expect(DatabaseEngine.mysql.identifier("we`ird") == "`we``ird`")
        #expect(DatabaseEngine.postgres.identifier("we\"ird") == "\"we\"\"ird\"")
    }

    @Test("engines have display names")
    func displayNames() {
        #expect(DatabaseEngine.mysql.displayName == "MySQL")
        #expect(DatabaseEngine.postgres.displayName == "PostgreSQL")
    }

    @Test("every engine is offered in the UI")
    func allCases() {
        #expect(DatabaseEngine.allCases == [.mysql, .postgres, .sqlite, .clickhouse])
    }

    @Test("SQLite is a file, the others are servers")
    func fileBased() {
        #expect(DatabaseEngine.sqlite.isFileBased)
        #expect(!DatabaseEngine.mysql.isFileBased)
        #expect(!DatabaseEngine.postgres.isFileBased)
    }

    @Test("SQLite names its scanner and double-quotes identifiers")
    func sqliteBasics() {
        #expect(DatabaseEngine.sqlite.extensionName == "sqlite_scanner")
        #expect(DatabaseEngine.sqlite.displayName == "SQLite")
        #expect(DatabaseEngine.sqlite.identifier("tbl") == "\"tbl\"")
    }
}

@Suite("Connection engine field")
struct ConnectionEngineTests {

    @Test("a connection saved before engines existed loads as MySQL")
    func legacyDecodesAsMySQL() throws {
        // Exactly what ConnectionStore wrote before this field was added.
        let legacy = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"old","alias":"old",
         "connectionType":"TCP/IP","color":"#4A90D9","host":"h","port":3306,
         "username":"u","database":"d"}
        """
        let c = try JSONDecoder().decode(Connection.self, from: Data(legacy.utf8))
        #expect(c.engine == .mysql)
        #expect(c.alias == "old")
    }

    @Test("the engine survives a round trip")
    func roundTrips() throws {
        var c = Connection(name: "pg", alias: "pg", host: "h", username: "u")
        c.engine = .postgres
        let decoded = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(c))
        #expect(decoded.engine == .postgres)
    }

    @Test("new connections default to MySQL")
    func defaultsToMySQL() {
        #expect(Connection(name: "n", alias: "a").engine == .mysql)
    }
}
