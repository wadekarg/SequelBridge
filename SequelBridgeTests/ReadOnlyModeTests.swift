//
//  ReadOnlyModeTests.swift
//  SequelBridgeTests
//
//  Safe mode end-to-end: a connection attached with readOnly = true must refuse
//  every write path (mysqlExecute / executeDDL) while still serving reads.
//  Gated behind SB_MYSQL_VERIFY=1 (pass TEST_RUNNER_SB_MYSQL_VERIFY=1); uses the
//  write DB so a stray write would be caught, but none should ever reach the server.
//

import Foundation
import Testing
@testable import SequelBridge

private struct ROEnv {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { ProcessInfo.processInfo.environment["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(ProcessInfo.processInfo.environment["SB_MYSQL_PORT"] ?? "3307") ?? 3307 }
    static var user: String { ProcessInfo.processInfo.environment["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { ProcessInfo.processInfo.environment["SB_MYSQL_PASS"] ?? "" }
    static var db:   String { ProcessInfo.processInfo.environment["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
}

@MainActor
@Suite("Read-only / safe mode (real DB)", .enabled(if: ROEnv.enabled), .serialized)
struct ReadOnlyModeTests {

    private func makeEngine(_ alias: String, readOnly: Bool) async throws -> QueryEngine {
        let engine = try QueryEngine()
        var c = Connection(name: "ro", alias: alias, connectionType: .tcpip,
                           host: ROEnv.host, port: ROEnv.port, username: ROEnv.user,
                           database: ROEnv.db, engine: .mysql)
        c.readOnly = readOnly
        try await engine.attach(c, password: ROEnv.pass)
        return engine
    }

    @Test("a read-only connection reports itself read-only")
    func flagTracked() async throws {
        let e = try await makeEngine("ro1", readOnly: true)
        #expect(e.isReadOnly("ro1"))
        let w = try await makeEngine("rw1", readOnly: false)
        #expect(!w.isReadOnly("rw1"))
    }

    @Test("mysqlExecute is refused on a read-only connection")
    func writeRefused() async throws {
        let e = try await makeEngine("ro2", readOnly: true)
        await #expect(throws: (any Error).self) {
            try await e.mysqlExecute(alias: "ro2",
                sql: "CREATE TABLE \(SQLBuilder.mysqlTable(database: ROEnv.db, table: "ro_should_not_exist")) (id INT)")
        }
        // Prove nothing was created: the table must not be there.
        let cols = try? await e.fetchColumns(alias: "ro2", database: ROEnv.db, table: "ro_should_not_exist")
        #expect(cols?.isEmpty ?? true)
    }

    @Test("executeDDL is refused on a read-only connection")
    func ddlRefused() async throws {
        let e = try await makeEngine("ro3", readOnly: true)
        await #expect(throws: (any Error).self) {
            try await e.executeDDL(alias: "ro3",
                sql: "DROP TABLE IF EXISTS \(SQLBuilder.mysqlTable(database: ROEnv.db, table: "whatever"))")
        }
    }

    @Test("reads still work on a read-only connection")
    func readsAllowed() async throws {
        let e = try await makeEngine("ro4", readOnly: true)
        let tables = try await e.fetchTables(alias: "ro4", database: ROEnv.db)
        #expect(tables.count >= 0)   // the call succeeds; count is environment-dependent
    }

    @Test("turning safe mode off restores writes")
    func writableWhenOff() async throws {
        let e = try await makeEngine("rw2", readOnly: false)
        let t = SQLBuilder.mysqlTable(database: ROEnv.db, table: "ro_toggle_check")
        try await e.mysqlExecute(alias: "rw2", sql: "DROP TABLE IF EXISTS \(t)")
        try await e.mysqlExecute(alias: "rw2", sql: "CREATE TABLE \(t) (id INT NOT NULL, PRIMARY KEY(id)) ENGINE=InnoDB")
        let cols = try await e.fetchColumns(alias: "rw2", database: ROEnv.db, table: "ro_toggle_check")
        #expect(cols.map(\.name) == ["id"])
        try await e.mysqlExecute(alias: "rw2", sql: "DROP TABLE IF EXISTS \(t)")
    }

    /// The Content tab's cell edits, inserts and deletes go through executeWrite. Before
    /// it existed they ran through query(), which has no safe-mode check, so editing a
    /// cell on a read-only connection wrote to the server.
    @Test("a Content-tab row edit is refused on a read-only connection, and the row is unchanged")
    func contentEditRefused() async throws {
        let w = try await makeEngine("rw3", readOnly: false)
        let t = SQLBuilder.mysqlTable(database: ROEnv.db, table: "ro_content_edit")
        try await w.mysqlExecute(alias: "rw3", sql: "DROP TABLE IF EXISTS \(t)")
        try await w.mysqlExecute(alias: "rw3", sql: "CREATE TABLE \(t) (id INT NOT NULL PRIMARY KEY, name VARCHAR(20)) ENGINE=InnoDB")
        try await w.mysqlExecute(alias: "rw3", sql: "INSERT INTO \(t) VALUES (1, 'before')")

        let ro = try await makeEngine("ro5", readOnly: true)
        let edit = SQLBuilder.update(alias: "ro5", database: ROEnv.db, table: "ro_content_edit",
                                     column: "name", newValue: "after", primaryKey: [(column: "id", value: "1")])
        do {
            try await ro.executeWrite(edit, alias: "ro5")
            Issue.record("the edit ran on a read-only connection")
        } catch {
            #expect(QueryEngine.extractReason(from: error).contains("read-only"))
        }
        let r = try await w.query("SELECT name FROM \(SQLBuilder.duckTable(alias: "rw3", database: ROEnv.db, table: "ro_content_edit"))")
        #expect(r.rows.first?.first == "before")

        // The same edit on the writable connection goes through.
        try await w.executeWrite(SQLBuilder.update(alias: "rw3", database: ROEnv.db, table: "ro_content_edit",
                                                   column: "name", newValue: "after", primaryKey: [(column: "id", value: "1")]),
                                 alias: "rw3")
        let after = try await w.query("SELECT name FROM \(SQLBuilder.duckTable(alias: "rw3", database: ROEnv.db, table: "ro_content_edit"))")
        #expect(after.rows.first?.first == "after")
        try await w.mysqlExecute(alias: "rw3", sql: "DROP TABLE IF EXISTS \(t)")
    }
}
