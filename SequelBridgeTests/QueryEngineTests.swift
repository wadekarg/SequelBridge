//
//  QueryEngineTests.swift
//  SequelBridgeTests
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("QueryEngine Tests")
struct QueryEngineTests {

    @Test func simpleQuery() async throws {
        let engine = try await QueryEngine()
        let result = try await engine.query("SELECT 42 AS answer, 'hello' AS greeting")
        #expect(result.columns == ["answer", "greeting"])
        #expect(result.rows.count == 1)
        #expect(result.rows[0][0] == "42")
        #expect(result.rows[0][1] == "hello")
    }

    @Test func multiRowQuery() async throws {
        let engine = try await QueryEngine()
        let result = try await engine.query(
            "SELECT * FROM (VALUES (1, 'a'), (2, 'b'), (3, 'c')) t(num, letter)"
        )
        #expect(result.rows.count == 3)
        #expect(result.columns.count == 2)
    }

    @Test func invalidQueryThrows() async throws {
        let engine = try await QueryEngine()
        await #expect(throws: (any Error).self) {
            try await engine.query("SELECT * FROM nonexistent_table_xyz_abc")
        }
    }

    @Test func executionTimeRecorded() async throws {
        let engine = try await QueryEngine()
        let result = try await engine.query("SELECT 1 AS n")
        #expect(result.executionTime >= 0)
    }

    @Test func nullValuesRepresentedAsString() async throws {
        let engine = try await QueryEngine()
        let result = try await engine.query("SELECT NULL AS empty_col")
        #expect(result.rows[0][0] == "NULL")
    }
}