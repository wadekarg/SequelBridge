//
//  ContentPagingTests.swift
//  SequelBridgeTests
//
//  The Content tab's page size, jump to a page (⌘J) and Duplicate Row (⌘D), as in Sequel
//  Ace: from the Sequel Ace checklist (guide/SEQUEL-ACE.md), where the page size was fixed
//  at 200, a page could only be reached one at a time, and a row couldn't be duplicated.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Content tab: pages and duplicating a row")
struct ContentPagingTests {
    @Test("how many pages the rows make")
    func pageCount() {
        #expect(ContentPaging.pageCount(total: 0, pageSize: 200) == 1)
        #expect(ContentPaging.pageCount(total: 200, pageSize: 200) == 1)
        #expect(ContentPaging.pageCount(total: 201, pageSize: 200) == 2)
        #expect(ContentPaging.pageCount(total: nil, pageSize: 200) == nil)
    }

    @Test("a typed page number jumps there, kept within the pages that exist")
    func jump() {
        #expect(ContentPaging.page(typed: "3", pageCount: 10) == 2)
        #expect(ContentPaging.page(typed: " 12 ", pageCount: 10) == 9)
        #expect(ContentPaging.page(typed: "0", pageCount: 10) == 0)
        #expect(ContentPaging.page(typed: "x", pageCount: 10) == nil)
        #expect(ContentPaging.page(typed: "5", pageCount: nil) == 4)
    }

    @Test("duplicating a row copies its values, NULLs as NULL, leaving out what the server fills in")
    func duplicate() {
        let values = ContentPaging.duplicateValues(row: ["7", "paid", "NULL"], nulls: [false, false, true],
                                                   columns: ["id", "status", "note"], generated: ["id"])
        #expect(values == ["status": "paid", "note": "NULL"])
    }

    @Test("what the server fills in: an auto-increment key, a generated column, SQLite's INTEGER PRIMARY KEY")
    func generated() {
        func col(_ name: String, _ type: String = "varchar(20)", key: String = "", extra: String = "") -> ColumnInfo {
            ColumnInfo(id: name, name: name, dataType: type, nullable: true, keyType: key, defaultValue: "",
                       extra: extra, encoding: "", collation: "", comment: "")
        }
        let mysql = [col("id", "int", key: "PRI", extra: "auto_increment"), col("total", extra: "VIRTUAL GENERATED"),
                     col("kept", extra: "STORED GENERATED"), col("created", "timestamp", extra: "DEFAULT_GENERATED"),
                     col("status")]
        #expect(ContentPaging.generatedColumns(mysql, engine: .mysql) == ["id", "total", "kept"])
        // MySQL needs a value for a plain INTEGER key; SQLite numbers its rows itself.
        let plainKey = [col("id", "INTEGER", key: "PRI"), col("body", "TEXT")]
        #expect(ContentPaging.generatedColumns(plainKey, engine: .mysql).isEmpty)
        #expect(ContentPaging.generatedColumns(plainKey, engine: .sqlite) == ["id"])
        // …but only when the INTEGER column is the whole key.
        let twoPart = [col("a", "INTEGER", key: "PRI"), col("b", "INTEGER", key: "PRI")]
        #expect(ContentPaging.generatedColumns(twoPart, engine: .sqlite).isEmpty)
    }

    @MainActor @Test("the page sizes on offer, 200 unless changed, kept across launches")
    func pageSize() {
        #expect(ContentPaging.pageSizes == [100, 200, 500, 1000, 5000])
        let store = UserDefaults(suiteName: "sb.test.\(UUID().uuidString)")!
        #expect(AppSettings(defaults: store).contentPageSize == 200)
        AppSettings(defaults: store).contentPageSize = 1000
        #expect(AppSettings(defaults: store).contentPageSize == 1000)
    }

    @MainActor @Test("a copy launched apart (-SBSupportDir: UI tests, screenshots) keeps its settings apart, fresh each launch")
    func isolatedSettings() {
        #expect(AppSettings.store(arguments: ["SequelBridge"]) === UserDefaults.standard)
        // The owner's value is put back whatever happens, so a failing run can't leave one.
        let owner = UserDefaults.standard, key = "contentPageSize"
        let before = owner.object(forKey: key)
        defer { if let before { owner.set(before, forKey: key) } else { owner.removeObject(forKey: key) } }
        let apart = ["SequelBridge", "-SBSupportDir", "/tmp/sb-apart"]
        let first = AppSettings.store(arguments: apart)
        #expect(first !== owner)
        AppSettings(defaults: first).contentPageSize = 4321
        #expect(owner.object(forKey: key) as? Int != 4321, "the owner's settings changed")
        #expect(AppSettings(defaults: AppSettings.store(arguments: apart)).contentPageSize == 200, "the next launch didn't start fresh")
    }
}
