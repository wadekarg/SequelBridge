//
//  ReadFallbackTests.swift
//  SequelBridgeTests
//
//  Where a Query-tab read that failed through DuckDB runs again: the app's own client for
//  two columns of one name or a value the MySQL driver can't convert, macOS's sqlite3 for
//  SQLite newer than DuckDB's. Never for a read the user stopped, nor, inside a
//  transaction begun in the Query tab, on another connection that can't see its changes.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("A failed read run again elsewhere")
struct ReadFallbackTests {
    private func fallback(_ engine: DatabaseEngine, _ reason: String, _ sql: String = "SELECT * FROM t",
                          cancelled: Bool = false, inTransaction: Bool = false) -> QueryEngine.ReadFallback {
        QueryEngine.readFallback(engine: engine, error: SequelBridgeError.attachFailed(reason), sql: sql,
                                 cancelled: cancelled, inTransaction: inTransaction)
    }

    @Test("what runs again, and where")
    func runsAgain() {
        #expect(fallback(.mysql, "Binder Error: duplicate column name \"id\"") == .nativeClient)
        #expect(fallback(.postgres, "duplicate column name \"id\"") == .nativeClient)
        #expect(fallback(.mysql, "Conversion Error: Date out of range: 2026-0-15") == .nativeClient)
        #expect(fallback(.sqlite, "no such function: concat", "SELECT concat(1)") == .sqliteTool)
        #expect(fallback(.sqlite, "RIGHT and FULL OUTER JOINs are not currently supported") == .sqliteTool)
        #expect(fallback(.mysql, "Table 'shop.nope' doesn't exist") == .none)
        #expect(fallback(.sqlite, "no such function: concat", "INSERT INTO t SELECT concat(1)") == .none)
    }

    /// Cancel interrupts DuckDB ("Interrupted"), which isn't a CancellationError: the read
    /// ran again in sqlite3, where nothing can stop it, and painted over a newer result.
    @Test("a read the user stopped doesn't run again")
    func stopped() {
        #expect(fallback(.sqlite, "INTERRUPT Error: Interrupted!") == .none)
        #expect(fallback(.sqlite, "no such function: concat", cancelled: true) == .none)
        #expect(fallback(.mysql, "Conversion Error: Date out of range: 2026-0-15", cancelled: true) == .none)
    }

    /// Another connection doesn't see the transaction's own changes, and a FOR UPDATE there
    /// waits on the transaction's locks.
    @Test("inside a Query-tab transaction a read stays in it")
    func inTransaction() {
        #expect(fallback(.mysql, "Conversion Error: Date out of range: 2026-0-15", inTransaction: true) == .none)
        #expect(fallback(.mysql, "duplicate column name \"id\"", inTransaction: true) == .none)
    }
}
