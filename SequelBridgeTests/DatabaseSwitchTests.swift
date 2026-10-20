//
//  DatabaseSwitchTests.swift
//  SequelBridgeTests
//
//  The database picked at the top of the left panel. A tester reported that picking
//  another database showed no tables. Each pick detached the connection and attached it
//  again on the new database, in a task of its own: two picks close together interleaved,
//  so the second list failed and the connection was left on the first database; and a
//  database that couldn't be opened left no connection at all. The panel showed the
//  same blank space for loading, failed and empty. `USE other_db` in the Query tab
//  didn't move the picker either, and the next statement went back to the old database.
//  Skipped unless SB_MYSQL_VERIFY=1.
//

import Foundation
import Testing
@testable import SequelBridge

private struct SwitchEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_MYSQL_VERIFY"] == "1" }
    static var host: String { e["SB_MYSQL_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_MYSQL_PORT"] ?? "3309") ?? 3309 }
    static var user: String { e["SB_MYSQL_USER"] ?? "sbuser" }
    static var pass: String { e["SB_MYSQL_PASS"] ?? "" }
    static var db: String { e["SB_MYSQL_DB"] ?? "sbtest" }
    static var otherDB: String { e["SB_MYSQL_REAL_DB"] ?? "sbreal" }
    static var writeDB: String { e["SB_MYSQL_WRITE_DB"] ?? "sbwrite" }
}

@MainActor
@Suite("Switching database", .enabled(if: SwitchEnv.enabled), .serialized)
struct DatabaseSwitchTests {

    /// A connected ConnectionManager over a one-connection fixture with its password
    /// inline, and a workspace whose history lives in a temporary folder.
    func connect(_ alias: String) async throws -> (ConnectionManager, Connection, WorkspaceSession) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        let entry: [String: Any] = [
            "id": UUID().uuidString, "name": alias, "alias": alias, "connectionType": "TCP/IP",
            "color": "#3A9AA8", "host": SwitchEnv.host, "port": SwitchEnv.port,
            "username": SwitchEnv.user, "password": SwitchEnv.pass, "database": SwitchEnv.db,
            "engine": "mysql", "folder": "", "readOnly": false,
        ]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: fixture)
        let manager = try ConnectionManager(arguments: ["-SBConnectionsFile", fixture.path])
        let conn = try #require(manager.saved.first)
        try await manager.connect([conn])
        let session = WorkspaceSession(connections: [conn], arguments: ["-SBSupportDir", dir.path])
        session.activeConnectionAlias = conn.alias
        await session.loadDatabases(for: conn, manager: manager)
        return (manager, conn, session)
    }

    func tables(_ session: WorkspaceSession, _ conn: Connection) -> [String] {
        session.sidebarTrees[conn.alias]?.map(\.name) ?? []
    }

    /// An unqualified statement on the server, the way the Query tab sends a read.
    func count(_ manager: ConnectionManager, _ conn: Connection, _ table: String) async throws -> String? {
        try await manager.queryEngine.serverPassthroughQuery(alias: conn.alias, serverSQL: "SELECT COUNT(*) FROM \(table)")
            .rows.first?.first
    }

    @Test("picking another database lists its tables, and queries run there")
    func pick() async throws {
        let (manager, conn, session) = try await connect("sw1")
        #expect(session.availableDatabases[conn.alias]?.contains(SwitchEnv.otherDB) == true)

        await session.showDatabase(SwitchEnv.otherDB, for: conn, manager: manager)
        #expect(session.selectedDatabase[conn.alias] == SwitchEnv.otherDB)
        #expect(tables(session, conn).contains("legacy_notes"), "got: \(tables(session, conn))")
        #expect(session.tableListError[conn.alias] == nil)
        #expect(manager.queryEngine.attachedDatabase(conn.alias) == SwitchEnv.otherDB)
        #expect(try await count(manager, conn, "legacy_notes") == "3")
    }

    @Test("two picks close together: the second one wins, and nothing fails")
    func quickPicks() async throws {
        let (manager, conn, session) = try await connect("sw2")
        session.selectedDatabase[conn.alias] = SwitchEnv.otherDB
        let first = Task { @MainActor in await session.showDatabase(SwitchEnv.otherDB, for: conn, manager: manager) }
        await Task.yield()
        session.selectedDatabase[conn.alias] = SwitchEnv.db
        let second = Task { @MainActor in await session.showDatabase(SwitchEnv.db, for: conn, manager: manager) }
        await first.value
        await second.value

        #expect(session.selectedDatabase[conn.alias] == SwitchEnv.db)
        #expect(tables(session, conn).contains("orders"), "got: \(tables(session, conn))")
        #expect(session.tableListError[conn.alias] == nil, "\(session.tableListError[conn.alias]?.message ?? "")")
        #expect(manager.queryEngine.attachedDatabase(conn.alias) == SwitchEnv.db)
        #expect(try await count(manager, conn, "orders") != nil)
    }

    @Test("a database that can't be opened: the panel says why, and the connection stays where it was")
    func cannotOpen() async throws {
        let (manager, conn, session) = try await connect("sw3")
        await session.showDatabase("sb_no_such_db", for: conn, manager: manager)

        let reason = try #require(session.tableListError[conn.alias]?.message, "no reason shown")
        #expect(reason.contains("sb_no_such_db"), "got: \(reason)")
        #expect(session.selectedDatabase[conn.alias] == SwitchEnv.db)
        #expect(tables(session, conn).contains("orders"), "got: \(tables(session, conn))")
        #expect(manager.queryEngine.attachedDatabase(conn.alias) == SwitchEnv.db)
        #expect(try await count(manager, conn, "orders") != nil)
    }

    @Test("USE in the Query tab picks that database, and the next statement runs there")
    func useFollows() async throws {
        let (manager, conn, session) = try await connect("sw4")
        let use = "USE \(SwitchEnv.otherDB)"
        _ = try await manager.queryEngine.query(use)   // what the Query tab runs for it
        await session.followRun(use, on: conn, manager: manager)

        #expect(session.selectedDatabase[conn.alias] == SwitchEnv.otherDB)
        #expect(tables(session, conn).contains("legacy_notes"), "got: \(tables(session, conn))")
        #expect(manager.queryEngine.attachedDatabase(conn.alias) == SwitchEnv.otherDB)
        #expect(try await count(manager, conn, "legacy_notes") == "3")
    }

    @Test("CREATE TABLE and DROP TABLE in the Query tab update the table list")
    func tableDDL() async throws {
        let (manager, conn, session) = try await connect("sw5")
        await session.showDatabase(SwitchEnv.writeDB, for: conn, manager: manager)
        let t = SQLBuilder.mysqlTable(database: SwitchEnv.writeDB, table: "sw_ddl_probe")
        try await manager.queryEngine.mysqlExecute(alias: conn.alias, sql: "DROP TABLE IF EXISTS \(t)")
        try await manager.queryEngine.mysqlExecute(alias: conn.alias, sql: "CREATE TABLE \(t) (id INT PRIMARY KEY)")
        await session.followRun("CREATE TABLE sw_ddl_probe (id INT PRIMARY KEY)", on: conn, manager: manager)
        #expect(tables(session, conn).contains("sw_ddl_probe"), "got: \(tables(session, conn))")

        try await manager.queryEngine.mysqlExecute(alias: conn.alias, sql: "DROP TABLE \(t)")
        await session.followRun("DROP TABLE sw_ddl_probe", on: conn, manager: manager)
        #expect(!tables(session, conn).contains("sw_ddl_probe"))
    }

    @Test("Refresh lists what changed outside the app: a table, a database, and a picked database that is gone")
    func refresh() async throws {
        let (manager, conn, session) = try await connect("sw7")
        let e = manager.queryEngine
        await session.showDatabase(SwitchEnv.writeDB, for: conn, manager: manager)
        // Changes made by someone else: the app's own DDL refreshes the lists by itself.
        let t = SQLBuilder.mysqlTable(database: SwitchEnv.writeDB, table: "rf_probe")
        try await e.mysqlExecute(alias: conn.alias, sql: "DROP TABLE IF EXISTS \(t)")
        try await e.mysqlExecute(alias: conn.alias, sql: "CREATE TABLE \(t) (id INT PRIMARY KEY)")
        #expect(!tables(session, conn).contains("rf_probe"))
        await session.refreshTables(for: conn, manager: manager)
        #expect(tables(session, conn).contains("rf_probe"), "got: \(tables(session, conn))")
        try await e.mysqlExecute(alias: conn.alias, sql: "DROP TABLE \(t)")

        let scratch = "sbrefresh_tmp"
        try await e.mysqlExecute(alias: conn.alias, sql: "DROP DATABASE IF EXISTS `\(scratch)`")
        try await e.mysqlExecute(alias: conn.alias, sql: "CREATE DATABASE `\(scratch)`")
        await session.refreshDatabases(for: conn, manager: manager)
        #expect(session.availableDatabases[conn.alias]?.contains(scratch) == true)

        await session.showDatabase(scratch, for: conn, manager: manager)
        try await e.mysqlExecute(alias: conn.alias, sql: "DROP DATABASE `\(scratch)`")
        await session.refreshDatabases(for: conn, manager: manager)
        #expect(session.availableDatabases[conn.alias]?.contains(scratch) == false)
        #expect(session.selectedDatabase[conn.alias] == SwitchEnv.db)
        #expect(tables(session, conn).contains("orders"), "got: \(tables(session, conn))")
        #expect(session.tableListError[conn.alias] == nil, "\(session.tableListError[conn.alias]?.message ?? "")")
    }

    @Test("CREATE and DROP DATABASE update the database list; dropping the picked one goes back to the saved one")
    func databaseDDL() async throws {
        let (manager, conn, session) = try await connect("sw6")
        let scratch = "sbswitch_tmp"
        try await manager.queryEngine.mysqlExecute(alias: conn.alias, sql: "DROP DATABASE IF EXISTS `\(scratch)`")
        try await manager.queryEngine.mysqlExecute(alias: conn.alias, sql: "CREATE DATABASE `\(scratch)`")
        await session.followRun("CREATE DATABASE \(scratch)", on: conn, manager: manager)
        #expect(session.availableDatabases[conn.alias]?.contains(scratch) == true)

        await session.showDatabase(scratch, for: conn, manager: manager)
        #expect(session.selectedDatabase[conn.alias] == scratch)
        try await manager.queryEngine.mysqlExecute(alias: conn.alias, sql: "DROP DATABASE `\(scratch)`")
        await session.followRun("DROP DATABASE \(scratch)", on: conn, manager: manager)

        #expect(session.availableDatabases[conn.alias]?.contains(scratch) == false)
        #expect(session.selectedDatabase[conn.alias] == SwitchEnv.db)
        #expect(tables(session, conn).contains("orders"), "got: \(tables(session, conn))")
        #expect(session.tableListError[conn.alias] == nil, "\(session.tableListError[conn.alias]?.message ?? "")")
    }
}
