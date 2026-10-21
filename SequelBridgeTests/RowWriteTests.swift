//
//  RowWriteTests.swift
//  SequelBridgeTests
//
//  A row write from the Content tab or an edited query result. Found testing against a
//  MariaDB 10.0 database of 3,275 tables: through DuckDB the first edit waited while
//  DuckDB read the column list of every table there (16 s on a local container, minutes
//  over a network), and every Content read queued behind it. On MySQL the statement goes
//  to the server as MySQL's own, as Sequel Ace sends it; the grid shows TINYINT(1) and
//  BIT(1) as true and false, which MySQL takes for them only as 1 and 0. And a result on
//  a workspace with two connections: a statement naming no server runs on the one picked
//  in the left panel, so its result is edited there.
//

import Foundation
import Testing
@testable import SequelBridge

private enum RWEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static func value(_ key: String, _ fallback: String) -> String { e[key] ?? fallback }
}

@Suite("Row writes in MySQL's own SQL")
struct MySQLRowWriteSQLTests {
    let types = ["id": "int(11)", "flag": "tinyint(1)", "b": "bit(1)", "b8": "bit(8)", "note": "varchar(40)",
                 "made": "timestamp", "part": "varchar(10)"]

    func set(_ column: String, _ value: String?) -> String {
        SQLBuilder.mysqlWrite(RowWrite(database: "db", table: "t", change: .set(column: column, value: value),
                                       key: [.init(column: "id", value: "1")]), columnTypes: types)
    }

    @Test("a cell: true and false are 1 and 0 for TINYINT(1) and BIT, a BIT is a number, text is quoted with its backslashes")
    func cell() {
        #expect(set("flag", "true") == "UPDATE `db`.`t` SET `flag` = 1 WHERE `id` = '1'")
        #expect(set("flag", "False") == "UPDATE `db`.`t` SET `flag` = 0 WHERE `id` = '1'")
        #expect(set("b", "true") == "UPDATE `db`.`t` SET `b` = 1 WHERE `id` = '1'")
        #expect(set("b8", "5") == "UPDATE `db`.`t` SET `b8` = 5 WHERE `id` = '1'")
        #expect(set("note", #"it's C:\temp"#) == #"UPDATE `db`.`t` SET `note` = 'it''s C:\\temp' WHERE `id` = '1'"#)
        #expect(set("note", nil) == "UPDATE `db`.`t` SET `note` = NULL WHERE `id` = '1'")
        #expect(set("note", "NULL") == "UPDATE `db`.`t` SET `note` = 'NULL' WHERE `id` = '1'", "the text NULL in a cell stays text")
    }

    @Test("a row added, NULL and CURRENT_TIMESTAMP as the row sheet means them; one deleted, a NULL key matched with IS NULL")
    func insertAndDelete() {
        let insert = SQLBuilder.mysqlWrite(RowWrite(database: "db", table: "t",
                                                    change: .insert(["note": "NULL", "made": "CURRENT_TIMESTAMP", "flag": "false"])),
                                           columnTypes: types)
        #expect(insert == "INSERT INTO `db`.`t` (`flag`, `made`, `note`) VALUES (0, CURRENT_TIMESTAMP, NULL)")
        let delete = SQLBuilder.mysqlWrite(RowWrite(database: "db", table: "t", change: .delete,
                                                    key: [.init(column: "id", value: "1"), .init(column: "part", value: nil)]),
                                           columnTypes: types)
        #expect(delete == "DELETE FROM `db`.`t` WHERE `id` = '1' AND `part` IS NULL")
    }

    @Test("on the other engines the write is DuckDB's, as before")
    func duck() {
        let w = RowWrite(database: "main", table: "t", change: .set(column: "note", value: "x"), key: [.init(column: "id", value: "1")])
        #expect(SQLBuilder.duckWrite(w, alias: "a") == SQLBuilder.update(alias: "a", database: "main", table: "t", column: "note",
                                                                         newValue: "x", primaryKey: [(column: "id", value: "1")]))
    }
}

@MainActor
@Suite("Row writes on MySQL (real server)", .enabled(if: RWEnv.e["SB_MYSQL_VERIFY"] == "1"), .serialized)
struct MySQLRowWriteTests {
    var db: String { RWEnv.value("SB_MYSQL_WRITE_DB", "sbwrite") }

    func engine(_ alias: String, database: String? = nil) async throws -> QueryEngine {
        let e = try QueryEngine()
        let c = Connection(name: "MySQL \(alias)", alias: alias, connectionType: .tcpip,
                           host: RWEnv.value("SB_MYSQL_HOST", "127.0.0.1"),
                           port: Int(RWEnv.value("SB_MYSQL_PORT", "3307")) ?? 3307,
                           username: RWEnv.value("SB_MYSQL_USER", "sbuser"), database: database ?? db, engine: .mysql)
        try await e.attach(c, password: RWEnv.value("SB_MYSQL_PASS", ""))
        return e
    }

    func cell(_ column: String, _ value: String?) -> RowWrite {
        RowWrite(database: db, table: "zz_rows", change: .set(column: column, value: value), key: [.init(column: "id", value: "1")])
    }

    @Test("a cell edit is sent as MySQL's own UPDATE, and each type is stored as meant")
    func cells() async throws {
        let e = try await engine("rw1")
        let t = SQLBuilder.mysqlTable(database: db, table: "zz_rows")
        try await e.mysqlExecute(alias: "rw1", sql: "DROP TABLE IF EXISTS \(t)")
        try await e.mysqlExecute(alias: "rw1", sql: "CREATE TABLE \(t) (id INT PRIMARY KEY, flag TINYINT(1), b BIT(1), note VARCHAR(40), d DATE)")
        try await e.mysqlExecute(alias: "rw1", sql: "INSERT INTO \(t) VALUES (1, 0, b'0', 'x', '2026-01-01')")
        var sent: [String] = []
        e.onStatement = { sql, _, _, _ in sent.append(sql) }
        for w in [cell("flag", "true"), cell("b", "true"), cell("note", #"it's C:\temp"#), cell("d", "2026-02-03")] {
            try await e.writeRow(w, alias: "rw1")
        }
        #expect(try await e.nativeMySQLQuery(alias: "rw1", sql: "SELECT flag, b + 0, note, d FROM \(t) WHERE id = 1").rows
                == [["1", "1", #"it's C:\temp"#, "2026-02-03"]])
        #expect(sent.contains { $0.hasPrefix("UPDATE `\(db)`.`zz_rows` SET `flag` = 1") }, "\(sent)")
        try await e.writeRow(cell("note", nil), alias: "rw1")
        #expect(try await e.nativeMySQLQuery(alias: "rw1", sql: "SELECT note IS NULL FROM \(t) WHERE id = 1").rows == [["1"]])
        try await e.mysqlExecute(alias: "rw1", sql: "DROP TABLE \(t)")
    }

    @Test("a row added with its key left to the server, then deleted")
    func insertAndDelete() async throws {
        let e = try await engine("rw2")
        let t = SQLBuilder.mysqlTable(database: db, table: "zz_rows2")
        try await e.mysqlExecute(alias: "rw2", sql: "DROP TABLE IF EXISTS \(t)")
        try await e.mysqlExecute(alias: "rw2", sql: "CREATE TABLE \(t) (id INT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(40), flag TINYINT(1))")
        try await e.writeRow(RowWrite(database: db, table: "zz_rows2", change: .insert(["note": "added", "flag": "true"])), alias: "rw2")
        #expect(try await e.nativeMySQLQuery(alias: "rw2", sql: "SELECT id, note, flag FROM \(t)").rows == [["1", "added", "1"]])
        try await e.writeRow(RowWrite(database: db, table: "zz_rows2", change: .delete, key: [.init(column: "id", value: "1")]), alias: "rw2")
        #expect(try await e.nativeMySQLQuery(alias: "rw2", sql: "SELECT COUNT(*) FROM \(t)").rows == [["0"]])
        try await e.mysqlExecute(alias: "rw2", sql: "DROP TABLE \(t)")
    }

    @Test("a cell edit on a database of 3,275 tables is written at once",
          .enabled(if: !(RWEnv.e["SB_MYSQL_BIG_DB"] ?? "").isEmpty))
    func bigDatabase() async throws {
        let big = RWEnv.value("SB_MYSQL_BIG_DB", "sbbig")
        let e = try await engine("rw3", database: big)
        let started = Date()
        try await e.writeRow(RowWrite(database: big, table: "sla_like", change: .set(column: "priority", value: "3"),
                                      key: [.init(column: "id", value: "1")]), alias: "rw3")
        let took = Date().timeIntervalSince(started)
        #expect(took < 2, "the edit took \(took) s")
        #expect(try await e.nativeMySQLQuery(alias: "rw3", sql: "SELECT priority FROM `\(big)`.`sla_like` WHERE id = 1").rows == [["3"]])
    }
}

@MainActor
@Suite("A query result with two connections open", .serialized)
struct ResultEditingPickedConnectionTests {
    func file(_ name: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sb_pick_\(name)_\(UUID().uuidString).sqlite").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO items VALUES (1, '\(name)');"]
        try p.run(); p.waitUntilExit()
        return path
    }

    @Test("a statement naming no server is edited on the connection picked in the left panel")
    func picked() async throws {
        let engine = try QueryEngine()
        let a = Connection(name: "la", alias: "la", database: try file("a"), engine: .sqlite)
        let b = Connection(name: "lb", alias: "lb", database: try file("b"), engine: .sqlite)
        try await engine.attach(a, password: "")
        try await engine.attach(b, password: "")
        let result = try await engine.query(#"SELECT * FROM "lb"."main"."items""#)
        let check = await engine.resultEditing(sql: "select * from items;", resultColumns: result.columns,
                                               connections: [a, b], active: "lb") { _ in "main" }
        #expect(check.reason == nil, "\(check.reason ?? "")")
        #expect(check.target?.alias == "lb")
    }
}
