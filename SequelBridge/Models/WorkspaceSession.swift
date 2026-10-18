//
//  WorkspaceSession.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation
import Combine

@MainActor
class WorkspaceSession: ObservableObject {
    @Published var connections: [Connection]
    @Published var tabs: [QueryTab]
    @Published var activeTabId: UUID?
    @Published var sidebarTrees: [String: [TableInfo]] = [:]       // alias → tables
    @Published var availableDatabases: [String: [String]] = [:]    // alias → list of databases
    @Published var selectedDatabase: [String: String] = [:]        // alias → selected database name
    @Published var selectedTables: [String: TableInfo] = [:]      // alias → selected table

    /// The selected table of the ACTIVE connection. Selection is remembered per
    /// server: switching tabs never shows one server's chrome over another
    /// server's data.
    var selectedTable: TableInfo? {
        get { activeConnectionAlias.flatMap { selectedTables[$0] } }
        set {
            guard let alias = activeConnectionAlias else { return }
            selectedTables[alias] = newValue
        }
    }

    // Which feature panel is active in the main area
    enum FeatureTab: String, CaseIterable {
        case structure = "Structure"
        case content   = "Content"
        case relations = "Relations"
        case triggers  = "Triggers"
        case tableInfo = "Table Info"
        case routines  = "Routines"
        case server    = "Server"
        case query     = "Query"
        case console   = "Console"
    }

    @Published var activeFeatureTab: FeatureTab = .query
    @Published var tableFilter: [String: String] = [:]  // alias → filter text (per-connection)
    @Published var consoleLog: [ConsoleEntry] = []
    @Published var activeConnectionAlias: String?

    struct ConsoleEntry: Identifiable, Codable, Equatable {
        var id = UUID()
        let timestamp: Date
        let sql: String
        let rowsAffected: Int?
        let error: String?
        let duration: TimeInterval
    }

    /// Statement history persists across launches; the console shows it.
    private let historyStore = HistoryStore()

    /// Named, reusable SQL snippets — persisted globally, shown in the query tab.
    @Published var savedQueries: [SavedQuery] = []
    private let savedQueryStore = SavedQueryStore()

    init(connections: [Connection]) {
        self.connections = connections
        self.consoleLog = historyStore.loadRecent()
        self.savedQueries = savedQueryStore.load()
        let firstTab = QueryTab(title: "Query 1")
        self.tabs = [firstTab]
        self.activeTabId = firstTab.id
    }

    var activeTab: QueryTab? {
        get { tabs.first { $0.id == activeTabId } }
        set {
            guard let newValue else { return }
            if let idx = tabs.firstIndex(where: { $0.id == newValue.id }) {
                tabs[idx] = newValue
            }
        }
    }

    func addTab() {
        let tab = QueryTab(title: "Query \(tabs.count + 1)")
        tabs.append(tab)
        activeTabId = tab.id
    }

    func closeTab(id: UUID) {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if activeTabId == id {
            activeTabId = tabs[max(0, idx - 1)].id
        }
    }

    func appendConsole(sql: String, rowsAffected: Int?, error: String?, duration: TimeInterval) {
        let entry = ConsoleEntry(
            timestamp: Date(), sql: sql,
            rowsAffected: rowsAffected, error: error, duration: duration
        )
        consoleLog.append(entry)
        // Cap the in-memory log the same way HistoryStore caps the on-disk one, so a
        // long-lived session doesn't grow memory unbounded (and SwiftUI doesn't diff
        // an ever-larger array on every statement). The full history lives on disk.
        if consoleLog.count > Self.consoleLogCap {
            consoleLog.removeFirst(consoleLog.count - Self.consoleLogCap)
        }
        historyStore.append(entry)
    }

    // MARK: - Saved queries

    /// Saves (or updates, by name) a named query and persists it.
    func saveQuery(name: String, sql: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savedQueries = savedQueryStore.upsert(SavedQuery(name: trimmed, sql: sql), into: savedQueries)
    }

    func deleteSavedQuery(_ id: UUID) {
        savedQueries = savedQueryStore.remove(id: id, from: savedQueries)
    }

    private static let consoleLogCap = 1000
}