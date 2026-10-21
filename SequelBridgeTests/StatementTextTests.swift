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
