//
//  PostgresWorkspaceTests.swift
//  SequelBridgeTests
//
//  What guide/FEATURES.md promises for PostgreSQL, run the way the panels run it against
//  a real server: the schemas in the left panel's picker and their tables, Content's
//  pages, filter and sort, following a foreign key, Routines, the Server tab, Export
//  database as SQL, CSV import into an existing table, and triggers.
//

import Foundation
import Testing
@testable import SequelBridge

private enum PGWEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_PG_VERIFY"] == "1" }
    static var host: String { e["SB_PG_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(e["SB_PG_PORT"] ?? "5433") ?? 5433 }
    static var user: String { e["SB_PG_USER"] ?? "sbuser" }
    static var pass: String { e["SB_PG_PASS"] ?? "" }
    static var db: String { e["SB_PG_DB"] ?? "sbtest" }
}

@MainActor
@Suite("PostgreSQL in the workspace (real server)", .enabled(if: PGWEnv.enabled), .serialized)
struct PostgresWorkspaceTests {

    /// A connected ConnectionManager over a one-connection fixture with its password
    /// inline, and a workspace that has listed the connection's schemas.
    func connect(_ alias: String) async throws -> (ConnectionManager, Connection, WorkspaceSession) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-pgw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        let entry: [String: Any] = [
            "id": UUID().uuidString, "name": alias, "alias": alias, "connectionType": "TCP/IP",
            "color": "#3A9AA8", "host": PGWEnv.host, "port": PGWEnv.port,
            "username": PGWEnv.user, "password": PGWEnv.pass, "database": PGWEnv.db,
            "engine": "postgres", "folder": "", "readOnly": false,
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

    func page(_ e: QueryEngine, _ alias: String, _ schema: String, _ table: String, filter: String = "",
              sort: String? = nil, ascending: Bool = true, limit: Int = 100) async throws -> QueryResult {
        try await e.serverContentPage(alias: alias, database: schema, table: table, filter: filter,
                                      sortColumn: sort, sortAscending: ascending, limit: limit, offset: 0)
    }

    @Test("the picker lists the schemas; picking one lists its tables, and the connection stays on its database")
    func schemas() async throws {
        let (manager, conn, session) = try await connect("pw1")
        #expect(session.availableDatabases[conn.alias]?.contains("reporting") == true, "\(session.availableDatabases[conn.alias] ?? [])")
        #expect(session.tableListError[conn.alias] == nil, "\(session.tableListError[conn.alias]?.message ?? "")")
        #expect(session.selectedDatabase[conn.alias] == "public")
        #expect(tables(session, conn).contains("customers"), "\(tables(session, conn))")

        await session.showDatabase("reporting", for: conn, manager: manager)
        #expect(session.tableListError[conn.alias] == nil, "\(session.tableListError[conn.alias]?.message ?? "")")
        #expect(tables(session, conn) == ["daily_totals"], "\(tables(session, conn))")
        #expect(try await page(manager.queryEngine, conn.alias, "reporting", "daily_totals").rows.count == 1)
        #expect(try await manager.queryEngine.fetchColumns(alias: conn.alias, database: "reporting", table: "daily_totals")
                    .map(\.name) == ["day", "total"])
    }

    @Test("Content: a page filtered and sorted on the server; a % or _ in the value matches as itself")
    func content() async throws {
        let (manager, conn, _) = try await connect("pw2")
        let e = manager.queryEngine
        let dialect = ContentFilter.dialect(engine: .postgres, passthrough: true)
        let love = try #require(ContentFilter.condition(column: "full_name", op: .contains, value: "Love", dialect: dialect))
        #expect(try await page(e, conn.alias, "public", "customers", filter: love).rows.map { $0[0] } == ["1"])
        let underscore = try #require(ContentFilter.condition(column: "email", op: .contains, value: "_", dialect: dialect))
        #expect(try await page(e, conn.alias, "public", "customers", filter: underscore).rows.isEmpty, "an underscore matched as a wildcard")
        let sorted = try await page(e, conn.alias, "public", "customers", sort: "id", ascending: false, limit: 2)
        #expect(sorted.rows.map { $0[0] } == ["3", "2"])
    }

    @Test("Content: a row added with its serial key left to the server, then deleted")
    func insertAndDelete() async throws {
        let (manager, conn, _) = try await connect("pw9")
        let e = manager.queryEngine
        try await e.executeDDL(alias: conn.alias, sql: "CREATE SCHEMA IF NOT EXISTS sbro")
        try await e.executeDDL(alias: conn.alias, sql: "DROP TABLE IF EXISTS sbro.rows_t")
        try await e.executeDDL(alias: conn.alias, sql: "CREATE TABLE sbro.rows_t (id serial PRIMARY KEY, note text, made timestamp DEFAULT now())")
        // What the row sheet sends: only the fields filled in.
        try await e.executeWrite(SQLBuilder.insert(alias: conn.alias, database: "sbro", table: "rows_t", values: ["note": "first"]),
                                 alias: conn.alias)
        try await e.executeWrite(SQLBuilder.insert(alias: conn.alias, database: "sbro", table: "rows_t", values: ["note": "second"]),
                                 alias: conn.alias)
        let rows = try await page(e, conn.alias, "sbro", "rows_t", sort: "id").rows
        #expect(rows.map { [$0[0], $0[1]] } == [["1", "first"], ["2", "second"]], "\(rows)")
        #expect(rows.allSatisfy { $0[2] != "NULL" }, "the server's default for made wasn't used: \(rows)")
        try await e.executeWrite(SQLBuilder.delete(alias: conn.alias, database: "sbro", table: "rows_t",
                                                   primaryKey: [(column: "id", value: "1")]), alias: conn.alias)
        #expect(try await page(e, conn.alias, "sbro", "rows_t").rows.map { $0[1] } == ["second"])
        try await e.executeDDL(alias: conn.alias, sql: "DROP TABLE sbro.rows_t")
    }

    @Test("Content: a foreign key's cell leads to the row it points at")
    func followForeignKey() async throws {
        let (manager, conn, _) = try await connect("pw3")
        let e = manager.queryEngine
        let targets = ForeignKeyFollow.targets(try await e.fetchRelations(alias: conn.alias, database: "public", table: "orders"))
        let target = try #require(targets["customer_id"], "\(targets)")
        #expect(target.table == "customers")
        let condition = try #require(ForeignKeyFollow.condition(target, values: ["customer_id": "2"],
                                                                dialect: ContentFilter.dialect(engine: .postgres, passthrough: true)))
        #expect(try await page(e, conn.alias, "public", "customers", filter: condition).rows.map { $0[2] } == ["Alan Turing"])
    }

    @Test("Routines lists the schema's functions with their definitions")
    func routines() async throws {
        let (manager, conn, _) = try await connect("pw4")
        let e = manager.queryEngine
        try await e.executeDDL(alias: conn.alias, sql: "CREATE OR REPLACE FUNCTION public.sb_add(a int, b int) RETURNS int LANGUAGE sql AS 'SELECT a + b'")
        let rows = try await e.fetchRoutines(alias: conn.alias, database: "public")
        try await e.executeDDL(alias: conn.alias, sql: "DROP FUNCTION IF EXISTS public.sb_add(int, int)")
        let add = try #require(rows.first { $0.first == "sb_add" }, "\(rows.map { $0.first ?? "" })")
        #expect(add.count >= 4 && add[3].contains("a + b"), "\(add)")
    }

    @Test("the Server tab: processes, variables and status")
    func server() async throws {
        let (manager, conn, _) = try await connect("pw5")
        let e = manager.queryEngine
        let processes = try await e.serverProcesses(alias: conn.alias)
        #expect(processes.columns.first == "pid" && processes.rowCount > 0, "\(processes.columns)")
        #expect(try await e.serverVariables(alias: conn.alias).rowCount > 50)
        #expect(try await e.serverStatus(alias: conn.alias).rowCount > 0)
    }

    @Test("the Server tab's Kill ends a running statement")
    func kill() async throws {
        let (sleeperManager, sleeperConn, _) = try await connect("pk1")
        let (manager, conn, _) = try await connect("pk2")
        let running = Task { @MainActor in
            try await sleeperManager.queryEngine.query(
                "SELECT * FROM postgres_query('\(sleeperConn.alias)', 'SELECT pg_sleep(30) AS sb_kill_probe')")
        }
        // Find it in the process list, as the Server tab shows it.
        var pid: String?
        for _ in 0..<40 where pid == nil {
            try await Task.sleep(nanoseconds: 250_000_000)
            let list = try await manager.queryEngine.serverProcesses(alias: conn.alias)
            let query = list.columns.firstIndex(of: "query") ?? 6
            pid = list.rows.first { $0.count > query && $0[query].contains("sb_kill_probe") && !$0[query].contains("pg_stat_activity") }?[0]
        }
        let id = try #require(pid, "the sleeping statement never showed in the process list")
        let started = Date()
        try await manager.queryEngine.killProcess(alias: conn.alias, id: id)
        _ = await running.result
        #expect(Date().timeIntervalSince(started) < 10, "the statement kept running after Kill")
    }

    @Test("Export database as SQL: a schema's tables and rows")
    func export() async throws {
        let (manager, conn, _) = try await connect("pw6")
        let dump = try await manager.queryEngine.sqlDumpDatabase(alias: conn.alias, database: "reporting")
        #expect(dump.text.contains("daily_totals") && dump.text.contains("1234.56"), "\(dump.text.prefix(600))")
    }

    @Test("CSV import into an existing table: a quote kept, an empty field NULL, the word NULL text")
    func importCSV() async throws {
        let (manager, conn, _) = try await connect("pw7")
        let e = manager.queryEngine
        try await e.executeDDL(alias: conn.alias, sql: "CREATE SCHEMA IF NOT EXISTS sbro")
        try await e.executeDDL(alias: conn.alias, sql: "DROP TABLE IF EXISTS sbro.csv_t")
        try await e.executeDDL(alias: conn.alias, sql: "CREATE TABLE sbro.csv_t (id int PRIMARY KEY, name text)")
        let n = try await e.importCSV(alias: conn.alias, database: "sbro", table: "csv_t", columns: ["id", "name"],
                                      rows: [["1", "it's"], ["2", ""], ["3", "NULL"]])
        #expect(n == 3)
        let read = try await page(e, conn.alias, "sbro", "csv_t", sort: "id")
        #expect(read.rows.map { $0[1] } == ["it's", "NULL", "NULL"], "\(read.rows)")
        #expect(read.nullMask.map { $0[1] } == [false, true, false], "\(read.nullMask)")
        try await e.executeDDL(alias: conn.alias, sql: "DROP TABLE sbro.csv_t")
    }

    @Test("Triggers: listed with timing and event, and dropped")
    func triggers() async throws {
        let (manager, conn, _) = try await connect("pw8")
        let e = manager.queryEngine
        for sql in ["CREATE SCHEMA IF NOT EXISTS sbro", "DROP TABLE IF EXISTS sbro.trg_t",
                    "CREATE TABLE sbro.trg_t (id int, touched timestamp)",
                    "CREATE OR REPLACE FUNCTION sbro.touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.touched := now(); RETURN NEW; END $$",
                    "CREATE TRIGGER trg_touch BEFORE INSERT OR UPDATE ON sbro.trg_t FOR EACH ROW EXECUTE FUNCTION sbro.touch()"] {
            try await e.executeDDL(alias: conn.alias, sql: sql)
        }
        let listed = try await e.fetchTriggers(alias: conn.alias, database: "sbro", table: "trg_t")
        let row = try #require(listed.first { $0.first == "trg_touch" }, "\(listed)")
        // Name, timing, event, as the Triggers tab reads them.
        #expect(Array(row.prefix(3)) == ["trg_touch", "BEFORE", "INSERT OR UPDATE"], "\(row)")
        try await e.executeDDL(alias: conn.alias, sql: SQLBuilder.dropTrigger(engine: .postgres, database: "sbro", table: "trg_t", name: "trg_touch"))
        #expect(try await e.fetchTriggers(alias: conn.alias, database: "sbro", table: "trg_t").isEmpty)
        try await e.executeDDL(alias: conn.alias, sql: "DROP TABLE sbro.trg_t")
        try await e.executeDDL(alias: conn.alias, sql: "DROP FUNCTION sbro.touch()")
    }
}
