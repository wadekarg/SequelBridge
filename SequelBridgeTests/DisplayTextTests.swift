//
//  DisplayTextTests.swift
//  SequelBridgeTests
//
//  Words on screen, from a review of the visual tour (VisualTourUITests): "1 rows", a
//  collation labelled "encoding", the word NULL where a value is missing, and a row
//  sheet that said "value or NULL" for a column whose empty field gets a default.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Display text: counts")
struct PluralTests {
    @Test("one row, two rows")
    func count() {
        #expect(Plural.count(1, "row") == "1 row")
        #expect(Plural.count(0, "row") == "0 rows")
        #expect(Plural.count(3, "row") == "3 rows")
        #expect(Plural.count(1, "index", "indexes") == "1 index")
        #expect(Plural.count(2, "index", "indexes") == "2 indexes")
    }

    @Test("a part of a whole agrees with the whole: 1 of 6 tables, 1 of 1 table")
    func part() {
        #expect(Plural.part(1, of: 6, "table") == "1 of 6 tables")
        #expect(Plural.part(1, of: 1, "table") == "1 of 1 table")
        #expect(Plural.part(0, of: 2, "row") == "0 of 2 rows")
    }
}

@Suite("Display text: table information")
struct TableMetaTests {
    // SHOW TABLE STATUS, in fetchTableMeta's order; the server's NULLs arrive as "NULL".
    let row = ["InnoDB", "Compact", "4", "utf8mb4_general_ci", "", "", "3", "5461",
               "16384", "0", "16384", "0", "2026-10-18 20:48:33", "NULL", "NULL"]

    @Test("a value the server leaves NULL is left out, not shown as the word NULL")
    func nulls() {
        let summary = TableMeta.summary(row)
        #expect(!summary.contains { $0.value == "NULL" }, "\(summary)")
        #expect(summary.first { $0.key == "updated" } == nil)
        #expect(summary.first { $0.key == "created" }?.value == "2026-10-18 20:48:33")
        let details = TableMeta.details(row)
        #expect(!details.contains { $0.value == "NULL" }, "\(details)")
        #expect(details.first { $0.key == "Checked" } == nil)
        #expect(details.first { $0.key == "Created" }?.value == "2026-10-18 20:48:33")
    }

    @Test("the left panel calls a collation a collation")
    func collation() {
        let summary = TableMeta.summary(row)
        #expect(summary.first { $0.key == "collation" }?.value == "utf8mb4_general_ci")
        #expect(summary.first { $0.key == "encoding" } == nil)
    }

    @Test("a view's NULL engine and sizes read as a dash")
    func view() {
        let view = ["NULL", "NULL", "NULL", "NULL", "NULL", "VIEW", "NULL", "NULL",
                    "NULL", "NULL", "NULL", "NULL", "NULL", "NULL", "NULL"]
        let summary = TableMeta.summary(view)
        #expect(summary.first { $0.key == "engine" }?.value == "—")
        #expect(summary.first { $0.key == "rows" }?.value == "—")
        #expect(summary.first { $0.key == "data" }?.value == "—")
        #expect(!summary.contains { $0.value == "NULL" }, "\(summary)")
    }

    @Test("sizes read in KB, MB and up; nothing reads as a dash")
    func sizes() {
        #expect(TableMeta.bytes("16384") == "16.0 KB")
        #expect(TableMeta.bytes("512") == "512.0 B")
        #expect(TableMeta.bytes("0") == "—")
        #expect(TableMeta.bytes("NULL") == "—")
    }
}

@Suite("Display text: the row sheet")
struct RowSheetPlaceholderTests {
    func col(_ name: String, nullable: Bool = true, def: String = "", extra: String = "") -> ColumnInfo {
        ColumnInfo(id: name, name: name, dataType: "varchar(20)", nullable: nullable, keyType: "",
                   defaultValue: def, extra: extra, encoding: "", collation: "", comment: "")
    }

    @Test("an empty field says what the server puts there")
    func placeholders() {
        #expect(ContentPaging.placeholder(for: col("id", nullable: false, extra: "auto_increment"), generated: true) == "set by the server")
        #expect(ContentPaging.placeholder(for: col("status", def: "new"), generated: false) == "default: new")
        #expect(ContentPaging.placeholder(for: col("placed_at", nullable: false, def: "CURRENT_TIMESTAMP"), generated: false)
                == "default: CURRENT_TIMESTAMP")
        #expect(ContentPaging.placeholder(for: col("note"), generated: false) == "NULL")
        #expect(ContentPaging.placeholder(for: col("total", def: "NULL"), generated: false) == "NULL")
        #expect(ContentPaging.placeholder(for: col("email", nullable: false), generated: false) == "required")
    }
}
