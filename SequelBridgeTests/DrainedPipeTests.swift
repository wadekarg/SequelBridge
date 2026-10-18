//
//  DrainedPipeTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Drained pipe")
struct DrainedPipeTests {

    struct DeadlineExceeded: Error, CustomStringConvertible {
        var description: String { "writer blocked — the pipe is not being drained" }
    }

    /// Writes on a detached thread so a blocked write fails the test instead of
    /// hanging the whole run.
    func write(_ data: Data, to pipe: Pipe, deadline: Double = 30) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    Thread.detachNewThread {
                        pipe.fileHandleForWriting.write(data)
                        try? pipe.fileHandleForWriting.close()
                        c.resume()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw DeadlineExceeded()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Gives the reader a moment to drain what was just written.
    func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    @Test("a writer far exceeding the pipe buffer never blocks")
    func largeWriteDoesNotBlock() async throws {
        let drained = DrainedPipe()
        defer { drained.stop() }
        // 512KB — roughly eight times the pipe capacity.
        try await write(Data(repeating: UInt8(ascii: "x"), count: 512 * 1024), to: drained.pipe)
    }

    @Test("the most recent output is kept")
    func keepsRecentOutput() async throws {
        let drained = DrainedPipe()
        defer { drained.stop() }
        try await write(Data("ssh: connect to host example.com port 22: No route to host".utf8), to: drained.pipe)
        try await settle()
        #expect(drained.text.contains("No route to host"))
    }

    @Test("memory stays bounded no matter how much is written")
    func boundedMemory() async throws {
        let drained = DrainedPipe(limit: 4096)
        defer { drained.stop() }
        try await write(Data(repeating: UInt8(ascii: "y"), count: 512 * 1024), to: drained.pipe)
        try await settle()
        #expect(drained.text.utf8.count <= 4096, "buffer grew to \(drained.text.utf8.count)")
    }

    @Test("the tail is what survives truncation")
    func keepsTail() async throws {
        let drained = DrainedPipe(limit: 64)
        defer { drained.stop() }
        var payload = Data(repeating: UInt8(ascii: "a"), count: 8192)
        payload.append(Data("THE-END".utf8))
        try await write(payload, to: drained.pipe)
        try await settle()
        #expect(drained.text.hasSuffix("THE-END"), "got: \(drained.text.suffix(20))")
    }

    @Test("an empty stream yields empty text")
    func emptyStream() async throws {
        let drained = DrainedPipe()
        defer { drained.stop() }
        try? drained.pipe.fileHandleForWriting.close()
        try await settle()
        #expect(drained.text.isEmpty)
    }
}
