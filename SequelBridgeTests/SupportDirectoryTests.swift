//
//  SupportDirectoryTests.swift
//  SequelBridgeTests
//
//  A demo or screenshot instance (launched with -SBSupportDir) must keep its
//  statement history, saved queries and connection list apart from the owner's
//  Application Support folder — the console it shows, and what it writes, is then
//  its own.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Support directory")
struct SupportDirectoryTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sb_support_\(UUID().uuidString)")
    }

    @Test("-SBSupportDir names the folder (created on demand); without it, Application Support/SequelBridge")
    func resolution() {
        let dir = scratch()
        #expect(SupportDirectory.url(from: ["app", "-SBSupportDir", dir.path]).path == dir.path)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        let standard = SupportDirectory.url(from: ["app"])
        #expect(standard.lastPathComponent == "SequelBridge")
        #expect(standard.deletingLastPathComponent().lastPathComponent == "Application Support")
        #expect(SupportDirectory.url(from: ["app", "-SBSupportDir"]).path == standard.path)   // dangling: ignored
    }

    @Test("history, saved queries and connections of an -SBSupportDir instance stay in that folder")
    func storesFollowTheArgument() throws {
        let dir = scratch()
        let args = ["app", "-SBSupportDir", dir.path]
        HistoryStore(arguments: args).append(.init(timestamp: Date(), sql: "SELECT 1", rowsAffected: 1, error: nil, duration: 0.01))
        SavedQueryStore(arguments: args).save([SavedQuery(name: "demo", sql: "SELECT 1")])
        try ConnectionStore(arguments: args).save([])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["connections.json", "history.jsonl", "saved_queries.json"])
    }
}
