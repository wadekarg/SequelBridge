//
//  SQLFormatterTests.swift
//  SequelBridgeTests
//
//  The "Format" button's beautifier. These are hermetic (no DB) and run in the
//  normal suite. The golden rule for a formatter: it is a presentation transform,
//  so format(x) must be idempotent and must never alter string/comment content.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("SQL formatter")
struct SQLFormatterTests {

    @Test("a one-line multi-column SELECT becomes clause- and column-per-line")
    func oneLinerStructured() {
        let input = "select id,name,value from wide_events where value>100 and status='x' order by id desc limit 20"
        let expected = """
        SELECT
            id,
            name,
            value
        FROM wide_events
        WHERE value > 100
            AND status = 'x'
        ORDER BY id DESC
        LIMIT 20
        """
        #expect(SQLFormatter.format(input) == expected)
    }

    @Test("keywords are uppercased, identifiers are not")
    func keywordCasing() {
        let out = SQLFormatter.format("select a from t")
        #expect(out.contains("SELECT"))
        #expect(out.contains("FROM"))
        #expect(out.contains(" a"))        // identifier kept lowercase
        #expect(out.contains("FROM t"))
    }

    @Test("a single-column SELECT stays on one line")
    func singleColumnInline() {
        #expect(SQLFormatter.format("select * from t") == "SELECT *\nFROM t")
        #expect(SQLFormatter.format("select count(*) from t") == "SELECT COUNT(*)\nFROM t")
    }

    @Test("DISTINCT stays on the SELECT line")
    func distinctInline() {
        let out = SQLFormatter.format("select distinct a, b from t")
        #expect(out.hasPrefix("SELECT DISTINCT\n"))
    }

    @Test("each JOIN goes on its own line with ON inline")
    func joinsBreak() {
        let input = "select a.id from a join b on a.id=b.id left join c on b.k=c.k"
        let out = SQLFormatter.format(input)
        #expect(out.contains("\nJOIN b ON a.id = b.id"))
        #expect(out.contains("\nLEFT JOIN c ON b.k = c.k"))
    }

    @Test("AND / OR in a WHERE break onto their own indented lines")
    func conditionsBreak() {
        let out = SQLFormatter.format("select a from t where x=1 and y=2 or z=3")
        #expect(out.contains("WHERE x = 1\n    AND y = 2\n    OR z = 3"))
    }

    @Test("function calls have no space before the paren; IN keeps a space")
    func parenSpacing() {
        #expect(SQLFormatter.format("select count(*) from t").contains("COUNT(*)"))
        let inOut = SQLFormatter.format("select a from t where a in (1,2,3)")
        #expect(inOut.contains("IN (1, 2, 3)"))
    }

    @Test("string literals are preserved verbatim — keywords inside them are not touched")
    func stringsPreserved() {
        let out = SQLFormatter.format("select a from t where name='select from where'")
        #expect(out.contains("'select from where'"))
    }

    @Test("qualified names keep the dot tight")
    func dottedNames() {
        let out = SQLFormatter.format("select t.a, t.b from schema.t")
        #expect(out.contains("t.a"))
        #expect(out.contains("FROM schema.t"))
    }

    @Test("line comments are preserved")
    func lineComments() {
        let out = SQLFormatter.format("select a -- the id\nfrom t")
        #expect(out.contains("-- the id"))
    }

    @Test("multiple statements are separated by a blank line")
    func multiStatement() {
        let out = SQLFormatter.format("select a from t; select b from u")
        #expect(out.contains(";\n\n"))
        #expect(out.contains("SELECT a"))
        #expect(out.contains("SELECT b"))
    }

    @Test("formatting is idempotent")
    func idempotent() {
        let samples = [
            "select id,name from wide_events where value>100 and status='x' order by id desc",
            "select count(*) from t",
            "select a.id from a join b on a.id=b.id where a.x=1 or a.y=2",
            "select distinct a, b, c from t limit 5",
        ]
        for s in samples {
            let once = SQLFormatter.format(s)
            let twice = SQLFormatter.format(once)
            #expect(once == twice, "not idempotent for: \(s)")
        }
    }

    @Test("empty or whitespace input is returned unchanged")
    func emptyInput() {
        #expect(SQLFormatter.format("") == "")
        #expect(SQLFormatter.format("   \n  ") == "   \n  ")
    }
}
