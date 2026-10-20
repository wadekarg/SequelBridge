//
//  SidebarAndEditorTests.swift
//  SequelBridgeTests
//
//  The left panel's table filter, the editor's completion and highlighting, and the
//  results grid's Copy Row: items from the Sequel Ace checklist (guide/SEQUEL-ACE.md)
//  that worked with no test. Writing the highlighting tests found three bugs: `--` inside
//  a string turned the rest of the string grey, `#` and `/* */` comments weren't marked,
//  and a keyword inside backticks was coloured as a keyword.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Left panel: filter tables")
struct TableListFilterTests {
    private func t(_ name: String, _ type: TableType = .table) -> TableInfo {
        TableInfo(id: "a.\(name)", name: name, type: type, alias: "a")
    }
    private var all: [TableInfo] { [t("orders"), t("order_items"), t("customers"), t("open_orders", .view)] }

    @Test("no filter lists everything, views apart from tables")
    func everything() {
        let r = TableListFilter.listed(all, filter: "")
        #expect(r.tables.map(\.name) == ["orders", "order_items", "customers"])
        #expect(r.views.map(\.name) == ["open_orders"])
    }

    @Test("the filter matches part of a name, ignoring case, in tables and views")
    func match() {
        let r = TableListFilter.listed(all, filter: "ORD")
        #expect(r.tables.map(\.name) == ["orders", "order_items"])
        #expect(r.views.map(\.name) == ["open_orders"])
        #expect(TableListFilter.listed(all, filter: "zzz").tables.isEmpty)
    }

    @Test("spaces around a pasted name don't hide it")
    func trimmed() {
        #expect(TableListFilter.listed(all, filter: " customers ").tables.map(\.name) == ["customers"])
    }
}

@Suite("Editor: completion")
struct SQLCompletionTests {
    @Test("keywords and the connection's names that start with the word, ignoring case, once each")
    func candidates() {
        let items = ["orders", "order_items", "customers", "orders"]
        #expect(SQLCompletion.candidates(for: "ord", items: items) == ["ORDER", "order_items", "orders"])
        #expect(SQLCompletion.candidates(for: "SEL", items: items) == ["SELECT"])
        #expect(SQLCompletion.candidates(for: "cust", items: items) == ["customers"])
        #expect(SQLCompletion.candidates(for: "", items: items).isEmpty)
    }
}

@Suite("Editor: highlighting")
struct SQLHighlighterTests {
    private func marked(_ sql: String) -> [String] {
        SQLHighlighter.spans(in: sql).map { span in
            let text = (sql as NSString).substring(with: span.range)
            switch span.kind {
            case .keyword: return "k:\(text)"
            case .string:  return "s:\(text)"
            case .comment: return "c:\(text)"
            }
        }
    }

    @Test("keywords, strings and line comments")
    func basics() {
        #expect(marked("SELECT * FROM t WHERE a = 'x'") == ["k:SELECT", "k:FROM", "k:WHERE", "s:'x'"])
        #expect(marked("-- note\nselect 1") == ["c:-- note", "k:select"])
    }

    @Test("-- inside a string is part of the string")
    func dashesInString() {
        #expect(marked("SELECT 'a -- b' FROM t") == ["k:SELECT", "s:'a -- b'", "k:FROM"])
    }

    @Test("MySQL's # comments and /* */ block comments are comments")
    func otherComments() {
        #expect(marked("# note\nSELECT 1") == ["c:# note", "k:SELECT"])
        #expect(marked("SELECT /* not FROM here */ 1") == ["k:SELECT", "c:/* not FROM here */"])
    }

    @Test("a doubled quote stays inside its string, and a backticked name is never a keyword")
    func quoting() {
        #expect(marked("SELECT 'it''s' FROM t") == ["k:SELECT", "s:'it''s'", "k:FROM"])
        #expect(marked("SELECT `from` FROM t") == ["k:SELECT", "k:FROM"])
    }
}

@Suite("Results grid: Copy Row")
struct RowCopyTests {
    @Test("a row copies as tab-separated values, a NULL as an empty value")
    func tabbed() {
        #expect(RowCopy.tabbed(["1", "NULL", "paid"], nulls: [false, true, false]) == "1\t\tpaid")
        #expect(RowCopy.tabbed(["1", "NULL"], nulls: [false, false]) == "1\tNULL")
    }

    @Test("with column names: a header line, then the rows")
    func withNames() {
        #expect(RowCopy.withColumnNames(["id", "status"], rows: ["1\tpaid", "2\tnew"]) == "id\tstatus\n1\tpaid\n2\tnew")
    }
}
