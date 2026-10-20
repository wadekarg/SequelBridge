//
//  SQLFileTests.swift
//  SequelBridgeTests
//
//  Opening and saving .sql files in the Query tab, and Import SQL file: from the Sequel
//  Ace checklist (guide/SEQUEL-ACE.md), where they were missing.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("SQL files: open, save")
struct SQLFileTests {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sb-sqlfile-\(UUID().uuidString)-\(name)")
    }

    @Test("a file reads as UTF-8, else as Latin-1, so an old dump still opens")
    func read() throws {
        let utf8 = temp("u.sql")
        try "SELECT 'café';".write(to: utf8, atomically: true, encoding: .utf8)
        #expect(try SQLFile.read(utf8) == "SELECT 'café';")
        let latin1 = temp("l.sql")
        try Data([0x53, 0x45, 0x4C, 0x20, 0x27, 0xE9, 0x27]).write(to: latin1)      // SEL 'é' in Latin-1
        #expect(try SQLFile.read(latin1) == "SEL 'é'")
    }

    @Test("a save writes the tab's text as UTF-8")
    func write() throws {
        let url = temp("w.sql")
        try SQLFile.write("SELECT 'é'", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "SELECT 'é'")
    }

    @Test("an import refuses COPY … FROM stdin, whose rows follow it in the file, and says how to dump instead")
    func copyFromStdin() {
        let reason = SQLFile.unsupported("COPY public.orders (id, status) FROM stdin")
        #expect(reason?.contains("--inserts") == true, "got: \(reason ?? "nil")")
        #expect(SQLFile.unsupported("copy t from STDIN with csv") != nil)
        #expect(SQLFile.unsupported("COPY t FROM '/tmp/x.csv'") == nil)       // the server reads that file itself
        #expect(SQLFile.unsupported("INSERT INTO t VALUES ('COPY x FROM stdin')") == nil)
    }

    @Test("an import skips LOCK TABLES and UNLOCK TABLES, which only speed a dump up")
    func importStatements() {
        let dump = "LOCK TABLES `t` WRITE;\nINSERT INTO `t` VALUES (1);\nUNLOCK TABLES;\nunlock tables;"
        #expect(SQLFile.importStatements(dump) == ["INSERT INTO `t` VALUES (1)"])
    }
}

@MainActor
@Suite("SQL files: where an opened file goes")
struct OpenSQLTabTests {
    private func session() throws -> WorkspaceSession {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WorkspaceSession(connections: [], arguments: ["-SBSupportDir", dir.path])
    }

    @Test("into the current tab when it is empty, else into a new tab, named after the file")
    func placement() throws {
        let s = try session()
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        s.openSQL("SELECT 1", from: url)
        #expect(s.tabs.count == 1)
        #expect(s.activeTab?.sql == "SELECT 1")
        #expect(s.activeTab?.title == "report.sql")
        #expect(s.activeTab?.fileURL == url)

        s.openSQL("SELECT 2", from: URL(fileURLWithPath: "/tmp/other.sql"))
        #expect(s.tabs.count == 2)
        #expect(s.activeTab?.sql == "SELECT 2")
        #expect(s.activeTab?.title == "other.sql")
    }
}
