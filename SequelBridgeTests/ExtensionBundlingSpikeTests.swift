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
    /// i.e. the truncation point that removes DuckDB's appended footer. Read from the
    /// load commands directly: shelling out to otool found nothing on GitHub's Apple
    /// Silicon runners.
    private func machOEnd(_ path: String) throws -> UInt64? {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func u64(_ o: Int) -> UInt64 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
        guard data.count >= 32, u32(0) == 0xFEED_FACF else { return nil }      // MH_MAGIC_64, thin
        var off = 32                                                           // sizeof(mach_header_64)
        for _ in 0..<Int(u32(16)) {                                            // ncmds
            guard off + 56 <= data.count else { return nil }
            let cmd = u32(off), size = Int(u32(off + 4))
            if cmd == 0x19 {                                                   // LC_SEGMENT_64
                let name = String(decoding: data[(off + 8)..<(off + 24)].prefix { $0 != 0 }, as: UTF8.self)
                if name == "__LINKEDIT" { return u64(off + 40) + u64(off + 48) }   // fileoff + filesize
            }
            guard size > 0 else { return nil }
            off += size
        }
        return nil
    }

    /// A scanner extension cached by a previous run of the app, if any.
    private func cachedExtension() -> URL? {
        // Version-scoped to match the app's cache layout — a stale extension from an older
        // DuckDB version won't load into the current engine and would fail the baseline.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SequelBridge/duckdb/\(QueryEngine.duckDBVersion)", isDirectory: true)
        for name in ["mysql_scanner", "postgres_scanner", "sqlite_scanner"] {
            if let f = QueryEngine.cachedExtension(named: name, in: cache) { return f }
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
            let head = (try? Data(contentsOf: src).prefix(8).map { String(format: "%02x", $0) }.joined()) ?? "?"
            Issue.record("could not locate the end of __LINKEDIT in \(src.lastPathComponent) (starts \(head))")
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
