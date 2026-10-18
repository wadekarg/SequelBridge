//
//  ConsoleExporterTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("ConsoleExporter")
struct ConsoleExporterTests {
    typealias Entry = WorkspaceSession.ConsoleEntry
    private func e(_ sql: String) -> Entry {
        Entry(timestamp: Date(), sql: sql, rowsAffected: nil, error: nil, duration: 0)
    }

    @Test("sqlDump terminates each statement once and drops blank ones")
    func dump() {
        let out = ConsoleExporter.sqlDump([e("SELECT 1"), e("SELECT 2;"), e("   ")])
        #expect(out.contains("SELECT 1;"))
        #expect(out.contains("SELECT 2;"))
        #expect(!out.contains("SELECT 2;;"))       // already-terminated isn't doubled
        #expect(out.contains("2 statement(s)"))     // the blank entry was dropped
    }

    @Test("sqlDump on an empty log is a header only")
    func dumpEmpty() {
        #expect(ConsoleExporter.sqlDump([]).contains("0 statement(s)"))
    }

    @Test("recent returns distinct statements newest-first within the limit")
    func recent() {
        let entries = [e("A"), e("B"), e("A"), e("C")]
        #expect(ConsoleExporter.recent(entries, limit: 2) == ["C", "A"])
        #expect(ConsoleExporter.recent(entries, limit: 10) == ["C", "A", "B"])
    }
}
