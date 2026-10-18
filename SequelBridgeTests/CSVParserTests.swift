//
//  CSVParserTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("CSVParser")
struct CSVParserTests {

    @Test("simple rows and columns")
    func simple() {
        #expect(CSVParser.parse("a,b,c\n1,2,3") == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test("quoted field containing the delimiter")
    func quotedDelimiter() {
        #expect(CSVParser.parse("\"a,b\",c") == [["a,b", "c"]])
    }

    @Test("quoted field containing a newline")
    func quotedNewline() {
        #expect(CSVParser.parse("\"line1\nline2\",x") == [["line1\nline2", "x"]])
    }

    @Test("doubled quotes decode to a single quote")
    func escapedQuotes() {
        #expect(CSVParser.parse("\"she said \"\"hi\"\"\",x") == [["she said \"hi\"", "x"]])
    }

    @Test("CRLF line endings")
    func crlf() {
        #expect(CSVParser.parse("a,b\r\n1,2") == [["a", "b"], ["1", "2"]])
    }

    @Test("empty fields are preserved")
    func emptyFields() {
        #expect(CSVParser.parse("a,,c") == [["a", "", "c"]])
        #expect(CSVParser.parse("\"\",x") == [["", "x"]])
    }

    @Test("a trailing newline does not add a blank row")
    func trailingNewline() {
        #expect(CSVParser.parse("a,b\n") == [["a", "b"]])
        #expect(CSVParser.parse("a,b\r\n") == [["a", "b"]])
    }

    @Test("no trailing newline still yields the last row")
    func noTrailingNewline() {
        #expect(CSVParser.parse("a,b") == [["a", "b"]])
    }

    @Test("a genuinely empty middle line is kept as one empty field")
    func blankMiddleLine() {
        #expect(CSVParser.parse("a\n\nb") == [["a"], [""], ["b"]])
    }
}
