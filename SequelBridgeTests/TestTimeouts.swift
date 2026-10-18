//
//  TestTimeouts.swift
//  SequelBridgeTests
//
//  For tests whose failure mode is a hang: the outcome of an async operation, or nil
//  when it is still running after a deadline. The operation is left running, so a hang
//  fails the test instead of stalling the whole suite.
//

import Foundation

@MainActor
private final class Once { var done = false }

/// `op`'s result, or nil if it hasn't finished within `seconds`.
@MainActor
func finishes<T>(within seconds: Double, _ op: @escaping @MainActor () async throws -> T) async -> Result<T, Error>? {
    await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>?, Never>) in
        let once = Once()
        Task { @MainActor in
            let r: Result<T, Error>
            do { r = .success(try await op()) } catch { r = .failure(error) }
            if !once.done { once.done = true; cont.resume(returning: r) }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !once.done { once.done = true; cont.resume(returning: nil) }
        }
    }
}
