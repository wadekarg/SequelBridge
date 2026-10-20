//
//  ExtensionDownloadTests.swift
//  SequelBridgeTests
//
//  The DuckDB scanner extensions are ~90MB decompressed. Decompression must not
//  deadlock on the pipe buffer — if it does, the app hangs forever on first
//  connect, and only a warm cache hides it.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Extension decompression")
struct ExtensionDownloadTests {

    /// Runs `body` on a detached thread and fails rather than hanging forever.
    func withDeadline(seconds: Double, _ body: @escaping @Sendable () throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    Thread.detachNewThread {
                        do { try body(); c.resume() } catch { c.resume(throwing: error) }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DeadlineExceeded()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    struct DeadlineExceeded: Error, CustomStringConvertible {
        var description: String { "decompression deadlocked (exceeded deadline)" }
    }

    func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sb-gunzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Compressible but not trivially so, to keep the gzip stream realistic.
    func payload(bytes: Int) -> Data {
        var d = Data(capacity: bytes)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        while d.count < bytes {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            var chunk = withUnsafeBytes(of: seed.littleEndian) { Data($0) }
            chunk.append(Data(repeating: UInt8(truncatingIfNeeded: seed >> 32), count: 56))
            d.append(chunk)
        }
        return d.prefix(bytes)
    }

    @Test("a payload far larger than one pipe buffer decompresses")
    func largePayload() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 8MB — well past the 64KB pipe capacity that caused the deadlock.
        let original = payload(bytes: 8 * 1024 * 1024)
        let raw = dir.appendingPathComponent("payload.bin")
        try original.write(to: raw)

        let gz = Process()
        gz.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gz.arguments = ["-k", raw.path]
        try gz.run(); gz.waitUntilExit()
        #expect(gz.terminationStatus == 0)

        let gzFile = dir.appendingPathComponent("payload.bin.gz")
        let out = dir.appendingPathComponent("result.bin")

        try await withDeadline(seconds: 60) {
            try QueryEngine.gunzip(input: gzFile, output: out)
        }

        let restored = try Data(contentsOf: out)
        #expect(restored.count == original.count)
        #expect(restored == original)
    }

    @Test("a small payload still decompresses correctly")
    func smallPayload() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = Data("hello extension".utf8)
        let raw = dir.appendingPathComponent("small.bin")
        try original.write(to: raw)
        let gz = Process()
        gz.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gz.arguments = ["-k", raw.path]
        try gz.run(); gz.waitUntilExit()

        let out = dir.appendingPathComponent("small-out.bin")
        try await withDeadline(seconds: 30) {
            try QueryEngine.gunzip(input: dir.appendingPathComponent("small.bin.gz"), output: out)
        }
        #expect(try Data(contentsOf: out) == original)
    }

    @Test("a corrupt archive reports an error instead of hanging")
    func corruptArchive() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("bogus.gz")
        try Data(repeating: 0x41, count: 4096).write(to: bogus)

        let out = dir.appendingPathComponent("bogus-out.bin")
        await #expect(throws: (any Error).self) {
            try await withDeadline(seconds: 30) {
                try QueryEngine.gunzip(input: bogus, output: out)
            }
        }
    }
}

/// One Mac can run the app natively and under Rosetta, which need different builds of
/// a scanner. The cache kept one file per scanner for both, so after a run under the
/// other CPU every connect loaded a library it couldn't, and never fetched another.
@Suite("Extension cache: one build per CPU")
struct ExtensionCacheTests {
    let arm64: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]    // MH_MAGIC_64, CPU_TYPE_ARM64
    let x86_64: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01]   // MH_MAGIC_64, CPU_TYPE_X86_64
    var mine: [UInt8] { QueryEngine.extensionPlatform == "osx_arm64" ? arm64 : x86_64 }
    var other: [UInt8] { QueryEngine.extensionPlatform == "osx_arm64" ? x86_64 : arm64 }

    func versionDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sb-extcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func write(_ header: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(header + [UInt8](repeating: 0, count: 64)).write(to: url)
    }

    @Test("a file for this CPU is used; one for the other CPU is not, so a new one is fetched")
    func legacyFile() throws {
        let dir = try versionDir()
        let legacy = dir.appendingPathComponent("mysql_scanner.duckdb_extension")
        #expect(QueryEngine.cachedExtension(named: "mysql_scanner", in: dir) == nil)
        try write(mine, to: legacy)
        #expect(QueryEngine.cachedExtension(named: "mysql_scanner", in: dir) == legacy)
        try write(other, to: legacy)
        #expect(QueryEngine.cachedExtension(named: "mysql_scanner", in: dir) == nil)
        try Data("not a library".utf8).write(to: legacy)
        #expect(QueryEngine.cachedExtension(named: "mysql_scanner", in: dir) == nil)
    }

    @Test("a download goes in this CPU's folder, and that copy wins")
    func perCPUFolder() throws {
        let dir = try versionDir()
        let scoped = QueryEngine.extensionFile(named: "sqlite_scanner", in: dir)
        #expect(scoped.deletingLastPathComponent().lastPathComponent == QueryEngine.extensionPlatform)
        try write(other, to: dir.appendingPathComponent("sqlite_scanner.duckdb_extension"))
        try write(mine, to: scoped)
        #expect(QueryEngine.cachedExtension(named: "sqlite_scanner", in: dir) == scoped)
    }
}
