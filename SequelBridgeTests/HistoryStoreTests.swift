//
//  HistoryStoreTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("History store")
struct HistoryStoreTests {

    func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sb-history-\(UUID().uuidString).jsonl")
    }

    func entry(_ sql: String, rows: Int? = nil, error: String? = nil) -> HistoryStore.Entry {
        .init(timestamp: Date(), sql: sql, rowsAffected: rows, error: error, duration: 0.05)
    }

    @Test("entries round-trip across store instances in order")
    func roundTrip() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        store.append(entry("SELECT 1", rows: 1))
        store.append(entry("UPDATE t SET x = 2", rows: 3))
        store.append(entry("SELECT broken", error: "syntax error"))

        let loaded = HistoryStore(fileURL: url).loadRecent()
        #expect(loaded.map(\.sql) == ["SELECT 1", "UPDATE t SET x = 2", "SELECT broken"])
        #expect(loaded[1].rowsAffected == 3)
        #expect(loaded[2].error == "syntax error")
    }

    @Test("only the most recent entries up to the cap are kept")
    func caps() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url, cap: 50)
        for i in 1...170 { store.append(entry("STATEMENT \(i)")) }

        let loaded = HistoryStore(fileURL: url, cap: 50).loadRecent()
        #expect(loaded.count == 50)
        #expect(loaded.last?.sql == "STATEMENT 170")
        #expect(loaded.first?.sql == "STATEMENT 121")
    }

    @Test("a corrupt line is skipped, not fatal")
    func corruptLine() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        store.append(entry("GOOD ONE"))
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("this is not json\n".utf8))
        try handle.close()
        store.append(entry("GOOD TWO"))

        let loaded = HistoryStore(fileURL: url).loadRecent()
        #expect(loaded.map(\.sql) == ["GOOD ONE", "GOOD TWO"])
    }

    @Test("no file yet means empty history")
    func missingFile() {
        #expect(HistoryStore(fileURL: tempFile()).loadRecent().isEmpty)
    }
}
