//
//  QueryTab.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation

struct QueryTab: Identifiable {
    var id: UUID = UUID()
    var title: String = "Query 1"
    var sql: String = ""
    var result: QueryResult?
    var isRunning: Bool = false
    /// True while later chunks of a large result are still streaming in behind the
    /// already-visible first rows (the grid is interactive during this).
    var isStreaming: Bool = false
    var error: String?
    /// Identifies the run that produced `result`, so a late answer about a previous
    /// run's result is dropped.
    var runID = UUID()
    /// Where the result's values are written when edited (the popup's Save), once known.
    var editTarget: ResultEditTarget? = nil
    /// Why the result can't be edited; nil while that is still being checked, or when it can.
    var editBlockedReason: String? = nil
    /// Bumped after a saved edit, so the grid redraws the changed cell.
    var editRevision = 0
}
