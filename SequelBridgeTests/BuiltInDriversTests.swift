//
//  BuiltInDriversTests.swift
//  SequelBridgeTests
//
//  The MySQL, PostgreSQL and SQLite drivers (DuckDB's scanner extensions) are built into
//  the app (scripts/build-duckdb.sh): nothing is downloaded at the first connection, as
//  it was (~90 MB a driver, from extensions.duckdb.org, loaded unsigned), and DuckDB can't
//  install anything either.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Built-in drivers")
struct BuiltInDriversTests {
    @Test("MySQL, PostgreSQL and SQLite are built in and loaded; DuckDB installs nothing")
    func builtIn() async throws {
        let engine = try QueryEngine()
        let drivers = try await engine.query("""
            SELECT extension_name, loaded, install_mode FROM duckdb_extensions()
            WHERE extension_name IN ('mysql_scanner', 'postgres_scanner', 'sqlite_scanner') ORDER BY 1
            """)
        #expect(drivers.rows.map { $0[0] } == ["mysql_scanner", "postgres_scanner", "sqlite_scanner"])
        for row in drivers.rows {
            #expect(row[1] == "true" && row[2] == "STATICALLY_LINKED", "\(row)")
        }
        let install = try await engine.query("SELECT current_setting('autoinstall_known_extensions')")
        #expect(install.rows.first?.first == "false")
        // Not DuckDB's shared ~/.duckdb/extensions, where any DuckDB program installs: a
        // driver installed there by another program was reported (and could load) in
        // place of the app's own.
        let folder = try await engine.query("SELECT current_setting('extension_directory')")
        let path = try #require(folder.rows.first?.first)
        #expect(path.hasSuffix("SequelBridge/duckdb-extensions") && !path.contains("/.duckdb/"), "\(path)")
    }

    /// The downloaded drivers were unsigned: DuckDB had to allow unsigned extensions, and
    /// macOS had to let the app load code no one had signed (an entitlement). Neither is
    /// needed now, and each would let a file put on the Mac run inside the app.
    @Test("no unsigned extension loads, and the app keeps macOS's library validation")
    func noUnsignedCode() async throws {
        let engine = try QueryEngine()
        let unsigned = try await engine.query("SELECT current_setting('allow_unsigned_extensions')")
        #expect(unsigned.rows.first?.first == "false")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let entitlements = try String(contentsOf: repo.appendingPathComponent("SequelBridge/SequelBridge.entitlements"), encoding: .utf8)
        #expect(!entitlements.contains("com.apple.security.cs.disable-library-validation"))
    }
}
