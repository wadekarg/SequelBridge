//
//  StatementTextTests.swift
//  SequelBridgeTests
//
//  How a statement's text is read before it is sent: comments made safe for PostgreSQL's
//  passthrough (which nests the statement in brackets), ClickHouse's own FORMAT clause,
//  and the numbers macOS's sqlite3 writes in its JSON.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Statement text: comments, FORMAT, SQLite's JSON")
struct StatementTextTests {
    @Test("-- comments become /* */ ones; block comments, nested ones, strings and E'…' escapes are left as they are")
    func lineCommentsAsBlocks() {
        #expect(SQLBuilder.lineCommentsAsBlocks("SELECT 4 -- trailing") == "SELECT 4 /* trailing */")
        #expect(SQLBuilder.lineCommentsAsBlocks("/* -- x -- */ SELECT 1") == "/* -- x -- */ SELECT 1")
        #expect(SQLBuilder.lineCommentsAsBlocks("/*------*/ SELECT 1") == "/*------*/ SELECT 1")
        #expect(SQLBuilder.lineCommentsAsBlocks("/* don't */ SELECT 1 -- note") == "/* don't */ SELECT 1 /* note */")
        #expect(SQLBuilder.lineCommentsAsBlocks("/* a /* b */ c */ SELECT 1 -- d") == "/* a /* b */ c */ SELECT 1 /* d */")
        #expect(SQLBuilder.lineCommentsAsBlocks(#"SELECT E'\'' -- c"#) == #"SELECT E'\'' /* c */"#)
        #expect(SQLBuilder.lineCommentsAsBlocks("SELECT '--not' -- yes") == "SELECT '--not' /* yes */")
    }

    @Test("a FORMAT clause of the statement's own is one naming a format, not a column called format")
    func clickHouseOwnFormat() {
        #expect(ClickHouseClient.hasOwnFormat("SELECT 1 FORMAT JSON"))
        #expect(ClickHouseClient.hasOwnFormat("SELECT * FROM t FORMAT JSONEachRow;"))
        #expect(ClickHouseClient.hasOwnFormat("SELECT * FROM t FORMAT CSVWithNames"))
        #expect(!ClickHouseClient.hasOwnFormat("SELECT * FROM t ORDER BY format DESC"))
        #expect(!ClickHouseClient.hasOwnFormat("SELECT * FROM t ORDER BY format"))
        #expect(!ClickHouseClient.hasOwnFormat("SELECT format FROM t"))
    }

    @Test("sqlite3's JSON: a real as SQLite would show it (0.1, not 0.10000000000000000555), an integer as written")
    func sqliteJSONNumbers() {
        let r = SQLiteTool.parseJSON(#"[{"a":0.10000000000000000555,"b":42,"c":"x","d":null,"e":1.5e+300}]"#)
        #expect(r.last?.columns == ["a", "b", "c", "d", "e"])
        #expect(r.last?.rows == [["0.1", "42", "x", nil, "1.5e+300"]])
    }
}

/// SQLite's own tool reading a script on its standard input.
@MainActor
@Suite("SQLite's own tool: a script on stdin")
struct SQLiteToolScriptTests {
    /// A script bigger than the pipe it goes through, failing early: sqlite3 stopped reading
    /// (-bail), the rest couldn't be written, and the write killed the app (SIGPIPE).
    @Test("a big script that fails early says which statement, and the app stays up", .timeLimit(.minutes(1)))
    func bigScriptFailingEarly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-sqlite-pipe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("big.sqlite").path
        let note = String(repeating: "x", count: 60)
        let rows = (1...5000).map { "INSERT INTO t VALUES (\($0), '\(note)')" }
        let statements = ["CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT)", "CREATE TABLE t (id INTEGER)"] + rows
        do {
            _ = try await SQLiteTool.script(statements, file: file, busyTimeout: 5)
            Issue.record("a script whose second statement fails ran")
        } catch {
            let reason = QueryEngine.extractReason(from: error)
            #expect(reason.contains("Statement 2 of 5002") && reason.contains("already exists"), "\(reason)")
        }
        // And a big script that runs whole still does.
        let rest = try await SQLiteTool.script(rows.map { $0.replacingOccurrences(of: "INSERT INTO t", with: "INSERT OR REPLACE INTO t") }
                                               + ["SELECT count(*) FROM t"], file: file, busyTimeout: 5)
        #expect(rest.rows == [["5000"]])
    }
}
