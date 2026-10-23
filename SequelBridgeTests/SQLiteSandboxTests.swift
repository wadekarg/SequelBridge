//
//  SQLiteSandboxTests.swift
//  SequelBridgeTests
//
//  A SQLite file in the App Store build: the app opens it only in a folder the user granted,
//  since SQLite writes its journal beside the file (a grant of the file alone lets reads
//  through and stops every write). The DMG build sets none of this.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("SQLite in the App Store build", .serialized)
struct SQLiteSandboxTests {
    private func file() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-lite-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("a.sqlite").path
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }

    private func lite(_ path: String) -> Connection {
        var c = Connection(name: "lite", alias: "lite")
        c.engine = .sqlite
        c.database = path
        return c
    }

    @Test("no folder granted: the connection says which and why, and nothing is attached")
    func folderMissing() async throws {
        QueryEngine.fileGrant = { _ in nil }
        defer { QueryEngine.fileGrant = nil }
        let path = file()
        let engine = try QueryEngine()
        do {
            try await engine.attach(lite(path), password: "")
            Issue.record("attached")
        } catch {
            #expect(error.localizedDescription == QueryEngine.sqliteFolderMissing(path), "\(error)")
        }
        #expect(engine.attachedDatabase("lite") == "")
    }

    @Test("a file that isn't there (moved, renamed) says so, and no folder is asked for")
    func missingFile() async throws {
        var asked: [String] = []
        QueryEngine.fileGrant = { p in asked.append(p); return nil }
        defer { QueryEngine.fileGrant = nil }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sb-lite-gone-\(UUID().uuidString)/a.sqlite").path
        let engine = try QueryEngine()
        do {
            try await engine.attach(lite(path), password: "")
            Issue.record("attached")
        } catch {
            #expect(error.localizedDescription == "No SQLite database at \(path)", "\(error)")
        }
        #expect(asked.isEmpty)
    }

    @Test("the folder granted: the file is opened and written, after the grant was asked for that file")
    func granted() async throws {
        let path = file()
        var asked: [String] = []
        QueryEngine.fileGrant = { p in asked.append(p); return URL(fileURLWithPath: (p as NSString).deletingLastPathComponent) }
        defer { QueryEngine.fileGrant = nil }
        let engine = try QueryEngine()
        try await engine.attach(lite(path), password: "")
        try await engine.executeDDL(alias: "lite", sql: "CREATE TABLE t (x INTEGER)")
        #expect(asked == [path])
        try await engine.detach("lite")
    }
}
