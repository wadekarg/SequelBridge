//
//  ExtensionBundlingSpikeTests.swift
//  SequelBridgeTests
//
//  FEASIBILITY SPIKE for App Store / TestFlight distribution.
//
//  Today the mysql/postgres/sqlite scanner extensions are DOWNLOADED at connect
//  time and LOADed from a Caches path (QueryEngine.prepareExtension). The App
//  Store forbids downloading executable code (Guideline 2.5.2), so for TestFlight
//  the extensions must be bundled in the .app and code-signed with the team cert.
//
//  A DuckDB extension carries a trailing footer (metadata + DuckDB signature)
//  AFTER the Mach-O. `codesign` refuses any file with bytes past the Mach-O
//  ("main executable failed strict validation"), so the footer must be stripped
//  before signing. This spike answers the load-bearing question:
//
//      Does DuckDB's LOAD still accept a footer-stripped extension
//      (with allow_unsigned_extensions=true)?
//
//  PASS  → bundle + strip + re-sign is viable; sandbox work can proceed.
//  FAIL  → footer is required; fall back to statically linking the scanner repos
//          into a custom duckdb-swift build (larger effort).
//
//  Skips cleanly if no scanner is cached on the machine.
//

import Foundation
import Testing
import DuckDB
@testable import SequelBridge

@Suite("Extension bundling feasibility (App Store spike)")
struct ExtensionBundlingSpikeTests {

    /// Byte offset where the Mach-O proper ends (end of the __LINKEDIT segment),
    /// i.e. the truncation point that removes DuckDB's appended footer.
    private func machOEnd(_ path: String) throws -> UInt64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        p.arguments = ["-l", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var inLinkedit = false
        var fileoff: UInt64 = 0
        var filesize: UInt64 = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("segname ") {
                inLinkedit = line.contains("__LINKEDIT")
            } else if inLinkedit, line.hasPrefix("fileoff ") {
                fileoff = UInt64(line.dropFirst("fileoff ".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if inLinkedit, line.hasPrefix("filesize ") {
                filesize = UInt64(line.dropFirst("filesize ".count).trimmingCharacters(in: .whitespaces)) ?? 0
                break
            }
        }
        guard fileoff > 0, filesize > 0 else { return nil }
        return fileoff + filesize
    }

    /// A scanner extension cached by a previous run of the app, if any.
    private func cachedExtension() -> URL? {
        // Version-scoped to match the app's cache layout — a stale extension from an older
        // DuckDB version won't load into the current engine and would fail the baseline.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SequelBridge/duckdb/\(QueryEngine.duckDBVersion)", isDirectory: true)
        for name in ["mysql_scanner", "postgres_scanner", "sqlite_scanner"] {
            let f = cache.appendingPathComponent("\(name).duckdb_extension")
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    private func tryLoad(_ path: URL) -> String {
        do {
            let config = Database.Configuration()
            try? config.setValue("true", forKey: "allow_unsigned_extensions")
            let db = try Database(store: .inMemory, configuration: config)
            let conn = try db.connect()
            _ = try conn.query("LOAD '\(path.path)'")
            return "OK"
        } catch {
            return "FAIL: \(error)"
        }
    }

    @Test("DuckDB LOADs a footer-stripped extension")
    func loadsStripped() async throws {
        guard let src = cachedExtension() else {
            print("[spike] no cached scanner extension on this machine — skipping")
            return
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sb-ext-spike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Baseline: the unstripped extension should always LOAD (proves the harness).
        let orig = dir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: orig)

        // Stripped: truncate to the end of the Mach-O, removing DuckDB's footer.
        let stripped = dir.appendingPathComponent("stripped-\(src.lastPathComponent)")
        try FileManager.default.copyItem(at: src, to: stripped)

        let sizeBefore = (try FileManager.default.attributesOfItem(atPath: stripped.path)[.size] as? UInt64) ?? 0
        guard let end = try machOEnd(stripped.path) else {
            Issue.record("could not locate __LINKEDIT end via otool")
            return
        }
        let handle = try FileHandle(forWritingTo: stripped)
        try handle.truncate(atOffset: end)
        try handle.close()
        let footerBytes = sizeBefore - end
        print("[spike] \(src.lastPathComponent): size=\(sizeBefore) machOEnd=\(end) strippedFooter=\(footerBytes) bytes")

        let baseline = tryLoad(orig)
        let strippedResult = tryLoad(stripped)
        print("[spike] baseline (unstripped) = \(baseline)")
        print("[spike] stripped             = \(strippedResult)")

        // FINDING (spike, 2026-09-27): the bundle+strip+re-sign path to App Store
        // compliance is NOT viable. There is a hard contradiction:
        //   • codesign refuses ANY bytes after the Mach-O (the DuckDB footer) —
        //     "main executable failed strict validation"
        //   • DuckDB refuses an extension WITHOUT that footer —
        //     "The metadata at the end of the file is invalid"
        // The same file cannot satisfy both, so extensions cannot be both
        // code-signed for distribution AND loaded by DuckDB. The App Store path
        // therefore requires STATICALLY LINKING the scanner extensions into a
        // custom duckdb-swift build (no loadable dylibs at all). This test pins
        // both halves of that contradiction so the decision stays documented and
        // a future DuckDB that relaxes the footer requirement fails loudly here.

        // Half 1: an intact extension loads (proves the harness + baseline).
        #expect(baseline == "OK", "baseline unstripped extension failed to LOAD — harness problem")

        // Half 2: stripping the footer (required for codesign) breaks the load.
        #expect(strippedResult != "OK",
                "footer-stripped extension unexpectedly LOADed — re-evaluate strip+sign path")
        #expect(strippedResult.contains("metadata"),
                "expected a metadata-footer rejection; got: \(strippedResult)")
    }
}
