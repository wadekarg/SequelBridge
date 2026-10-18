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
