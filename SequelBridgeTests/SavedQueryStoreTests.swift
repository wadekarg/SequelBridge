//
//  SavedQueryStoreTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("SavedQueryStore")
struct SavedQueryStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString).json")
    }

    @Test("save then load round-trips")
    func roundTrip() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = SavedQueryStore(fileURL: url)
        let list = [SavedQuery(name: "a", sql: "SELECT 1"), SavedQuery(name: "b", sql: "SELECT 2")]
        store.save(list)
        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.sql).sorted() == ["SELECT 1", "SELECT 2"])
    }

    @Test("missing file loads as empty, not an error")
    func missingFile() {
        let store = SavedQueryStore(fileURL: tempURL())
        #expect(store.load().isEmpty)
    }

    @Test("corrupt file loads as empty")
    func corruptFile() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not json".utf8).write(to: url)
        #expect(SavedQueryStore(fileURL: url).load().isEmpty)
    }

    @Test("upsert replaces an existing name case-insensitively and sorts")
    func upsertDedup() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = SavedQueryStore(fileURL: url)
        var list = store.upsert(SavedQuery(name: "Report", sql: "SELECT 1"), into: [])
        list = store.upsert(SavedQuery(name: "alpha", sql: "SELECT 0"), into: list)
        // Same name (different case) updates in place rather than duplicating.
        list = store.upsert(SavedQuery(name: "report", sql: "SELECT 99"), into: list)
        #expect(list.count == 2)
        #expect(list.map(\.name) == ["alpha", "report"])   // sorted, case-insensitive
        #expect(list.first(where: { $0.name.lowercased() == "report" })?.sql == "SELECT 99")
        // Persisted, not just in-memory.
        #expect(store.load().count == 2)
    }

    @Test("remove deletes by id and persists")
    func remove() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = SavedQueryStore(fileURL: url)
        let keep = SavedQuery(name: "keep", sql: "SELECT 1")
        let drop = SavedQuery(name: "drop", sql: "SELECT 2")
        store.save([keep, drop])
        let after = store.remove(id: drop.id, from: [keep, drop])
        #expect(after.map(\.name) == ["keep"])
        #expect(store.load().map(\.name) == ["keep"])
    }
}
