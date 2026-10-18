//
//  StreamBatcher.swift
//  SequelBridge
//
//  Decides when streamed result chunks are published to the UI. A streaming query
//  pulls 20k-row chunks; publishing each one re-renders the workspace and
//  copy-on-writes the tab's growing rows array (the tab is a value in a @Published
//  array), so per-chunk publishing made a million rows cost fifty O(rows) copies —
//  super-linear, minutes for wide results. Chunks are instead buffered and flushed
//  when enough rows have accumulated OR enough time has passed, so the row counter
//  keeps moving while publishes stay bounded to a handful per million rows.
//  Pure and clock-agnostic: the caller passes its own monotonic `now`.
//

import Foundation

nonisolated struct StreamBatcher {
    let maxPendingRows: Int
    let maxInterval: TimeInterval
    private(set) var pendingRows = 0
    private(set) var lastFlush: TimeInterval

    init(maxPendingRows: Int = 200_000, maxInterval: TimeInterval = 0.4, now: TimeInterval) {
        self.maxPendingRows = maxPendingRows
        self.maxInterval = maxInterval
        self.lastFlush = now
    }

    /// Records `count` newly buffered rows at time `now`. Returns true when the caller
    /// should flush the buffer now; the pending count then restarts from zero. The
    /// final partial batch is the caller's to flush when the stream ends.
    mutating func add(_ count: Int, now: TimeInterval) -> Bool {
        pendingRows += count
        guard pendingRows >= maxPendingRows || now - lastFlush >= maxInterval else { return false }
        pendingRows = 0
        lastFlush = now
        return true
    }
}
