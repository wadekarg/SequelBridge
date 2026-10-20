//
//  ConsoleSourceTests.swift
//  SequelBridgeTests
//
//  The Console shows every statement the app runs: the ones you type, the ones it
//  builds for you (an edit, a page of rows) and the reads it makes on its own (the
//  tables, columns and keys it lists). The last were never logged, though the README
//  said the Console shows "every statement the app sent on your behalf". Your own are
//  told apart, and only they fill the Recent menu.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Console: every statement, yours told apart")
struct ConsoleSourceTests {
    typealias Entry = WorkspaceSession.ConsoleEntry

    final class Log { var typed: [String] = []; var app: [String] = [] }

    func engine(_ log: Log) throws -> QueryEngine {
        let q = try QueryEngine()
        q.onStatement = { sql, _, _, _ in log.typed.append(sql) }
        q.onAppStatement = { sql, _, _, _ in log.app.append(sql) }
        return q
    }

    @Test("a Query-tab run is yours; a statement outside one is the app's")
    func source() async throws {
        let log = Log()
        let q = try engine(log)
        _ = try await q.query("SELECT 'built by the app' AS v")
        await StatementSource.$typedByYou.withValue(true) {
            _ = try? await q.query("SELECT 'typed' AS v")
        }
        #expect(log.typed == ["SELECT 'typed' AS v"])
        #expect(log.app == ["SELECT 'built by the app' AS v"])
    }

    @Test("the app's own reads are logged, even during a run of yours")
    func ownReads() async throws {
        let log = Log()
        let q = try engine(log)
        await StatementSource.$typedByYou.withValue(true) {
            _ = try? await q.metaQueryPublic("SELECT 'columns' AS v")
            _ = try? await q.sidebarQueryPublic("SELECT 'tables' AS v")
        }
        #expect(log.app == ["SELECT 'columns' AS v", "SELECT 'tables' AS v"])
        #expect(log.typed.isEmpty)
    }

    @Test("the Recent menu lists what you typed, not what the app ran")
    func recent() {
        let entries = [Entry(timestamp: Date(), sql: "SELECT typed", rowsAffected: nil, error: nil, duration: 0),
                       Entry(timestamp: Date(), sql: "SHOW FULL COLUMNS FROM t", rowsAffected: nil, error: nil, duration: 0, byApp: true)]
        #expect(ConsoleExporter.recent(entries, limit: 10) == ["SELECT typed"])
    }

    @Test("a history saved before the mark still loads, as yours")
    func oldHistory() throws {
        let json = #"{"id":"5B0A0000-0000-4000-8000-000000000001","timestamp":0,"sql":"SELECT 1","duration":0.1}"#
        let entry = try JSONDecoder().decode(Entry.self, from: Data(json.utf8))
        #expect(entry.sql == "SELECT 1")
        #expect(entry.byApp == nil)
    }
}
