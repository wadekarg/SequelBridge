//
//  DrainedPipe.swift
//  SequelBridge
//
//  A pipe that is read continuously, so the child process writing into it can
//  never block on a full buffer.
//
//  A Pipe handed to a Process and left unread holds only ~64KB. Once it fills,
//  the child blocks on write — forever, if nobody drains it. For a long-lived
//  child such as an SSH tunnel that means the tunnel silently freezes.
//

import Foundation

nonisolated final class DrainedPipe: @unchecked Sendable {
    let pipe = Pipe()

    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()

    init(limit: Int = 8192) {
        self.limit = limit
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            guard !chunk.isEmpty else {          // EOF
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.buffer.append(chunk)
            // Keep only the tail: for diagnostics the last words matter, and this
            // bounds memory no matter how noisy the child becomes.
            if self.buffer.count > self.limit {
                self.buffer.removeFirst(self.buffer.count - self.limit)
            }
        }
    }

    /// Most recent output, capped at the configured limit.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Stops draining. Safe to call more than once.
    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    deinit {
        pipe.fileHandleForReading.readabilityHandler = nil
    }
}
