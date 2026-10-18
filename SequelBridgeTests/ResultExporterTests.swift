//
//  ResultExporterTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Result export")
struct ResultExporterTests {

    func result() -> QueryResult {
        var r = QueryResult(columns: ["id", "name", "note"],
                            rows: [["1", "Ada", "first"],
                                   ["2", "O'Brien, Jr", "NULL"],
                                   ["3", "quote\"here", "line\nbreak"]],
                            executionTime: 0)
        r.columnTypes = ["INT", "VARCHAR", "VARCHAR"]
        return r
    }

    @Test("CSV quotes fields with commas, quotes and newlines")
    func csv() {
        let out = ResultExporter.csv(result())
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "id,name,note")
        #expect(lines[1] == "1,Ada,first")
        #expect(lines[2] == "2,\"O'Brien, Jr\",")          // NULL → empty, comma quoted
        #expect(out.contains("\"quote\"\"here\""))          // doubled quote
    }

    @Test("JSON emits null for NULL and numbers for numeric columns")
    func json() throws {
        let data = try ResultExporter.json(result())
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        #expect(arr.count == 3)
        // id is numeric → a JSON number, not a string
        #expect(arr[0]["id"] as? Int == 1)
        #expect(arr[0]["name"] as? String == "Ada")
        // NULL note → JSON null
        #expect(arr[1]["note"] is NSNull)
        // text with a quote stays a string, intact
        #expect(arr[2]["name"] as? String == "quote\"here")
    }

    @Test("empty result exports header-only CSV and an empty JSON array")
    func empty() throws {
        let r = QueryResult(columns: ["a", "b"], rows: [], executionTime: 0)
        #expect(ResultExporter.csv(r) == "a,b")
        let arr = try JSONSerialization.jsonObject(with: ResultExporter.json(r)) as! [Any]
        #expect(arr.isEmpty)
    }

    @Test("NaN / Infinity in a numeric column do not abort JSON export")
    func nonFiniteJSON() throws {
        var r = QueryResult(columns: ["x"], rows: [["NaN"], ["Infinity"], ["-Infinity"], ["1.5"]], executionTime: 0)
        r.columnTypes = ["DOUBLE"]
        // Must not throw (JSONSerialization rejects non-finite numbers) and must
        // preserve the values as strings so the file is still written.
        let data = try ResultExporter.json(r)
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        #expect(arr[0]["x"] as? String == "NaN")
        #expect(arr[1]["x"] as? String == "Infinity")
        #expect(arr[3]["x"] as? Double == 1.5)
    }

    @Test("a real \"NULL\" string is exported distinctly from an actual SQL NULL")
    func nullVsNullString() throws {
        // row 0: genuine string value "NULL"; row 1: actual SQL NULL (per mask).
        var r = QueryResult(columns: ["note"], rows: [["NULL"], ["NULL"]], executionTime: 0)
        r.columnTypes = ["VARCHAR"]
        r.nullMask = [[false], [true]]

        let csvLines = ResultExporter.csv(r).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(csvLines[1] == "NULL")   // real string kept
        #expect(csvLines[2] == "")       // actual NULL → empty field

        let arr = try JSONSerialization.jsonObject(with: ResultExporter.json(r)) as! [[String: Any]]
        #expect(arr[0]["note"] as? String == "NULL")  // real string
        #expect(arr[1]["note"] is NSNull)              // actual NULL
    }

    @Test("Markdown renders a GFM table; NULL is blank, pipes/newlines escaped")
    func markdown() {
        let out = ResultExporter.markdown(result())
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "| id | name | note |")
        #expect(lines[1] == "| --- | --- | --- |")
        #expect(lines[2] == "| 1 | Ada | first |")
        #expect(lines[3] == "| 2 | O'Brien, Jr |  |")   // NULL → blank cell
        #expect(out.contains("line<br>break"))           // newline escaped
    }

    @Test("Markdown escapes a pipe inside a value")
    func markdownPipe() {
        var r = QueryResult(columns: ["a"], rows: [["x|y"]], executionTime: 0)
        r.columnTypes = ["VARCHAR"]
        #expect(ResultExporter.markdown(r).contains("x\\|y"))
    }

    @Test("SQL INSERTs quote strings, leave numbers bare, and emit NULL literally")
    func sqlInserts() {
        let out = ResultExporter.sqlInserts(result(), table: "people")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "INSERT INTO people (id, name, note) VALUES (1, 'Ada', 'first');")
        // numeric id bare, O'Brien's quote doubled, NULL literal
        #expect(lines[1] == "INSERT INTO people (id, name, note) VALUES (2, 'O''Brien, Jr', NULL);")
    }

    @Test("empty result produces no INSERTs and a header-only Markdown table")
    func exportEmpty() {
        let r = QueryResult(columns: ["a", "b"], rows: [], executionTime: 0)
        #expect(ResultExporter.sqlInserts(r, table: "t") == "")
        #expect(ResultExporter.markdown(r) == "| a | b |\n| --- | --- |")
    }

    @Test("integers beyond Int64 are exported exactly as strings, not lossy doubles")
    func hugeIntPrecision() throws {
        let huge = "123456789012345678901234567890"   // > Int64 and > Double exact range
        var r = QueryResult(columns: ["big"], rows: [[huge], ["42"]], executionTime: 0)
        r.columnTypes = ["HUGEINT"]
        let data = try ResultExporter.json(r)
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        #expect(arr[0]["big"] as? String == huge)   // exact, no precision loss
        #expect(arr[1]["big"] as? Int == 42)         // fits Int64 → real number
    }
}
