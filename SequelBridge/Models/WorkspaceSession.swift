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
    @Published var tableListError: [String: TableListError] = [:]  // alias → why its tables couldn't be listed
    var shownDatabase: [String: String] = [:]                        // alias → database whose tables were last listed

    struct TableListError: Equatable {
        let database: String   // the database to try again
        let message: String
    }
    @Published var selectedTables: [String: TableInfo] = [:]      // alias → selected table
    /// A filter for a table's Content tab to open with, by table id: following a foreign key.
    var contentFollows: [String: ContentFollow] = [:]

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

        /// ⌘ plus this key: Sequel Ace's ⌘1–⌘6 (Structure, Content, Relations, Triggers,
        /// Table Info, Query), then ⌘7–⌘9 for Routines, Server, Console.
        var shortcutKey: Character {
            switch self {
            case .structure: return "1"
            case .content:   return "2"
            case .relations: return "3"
            case .triggers:  return "4"
            case .tableInfo: return "5"
            case .query:     return "6"
            case .routines:  return "7"
            case .server:    return "8"
            case .console:   return "9"
            }
        }
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
        /// True for a statement the app built or ran on its own; nil (older history) or
        /// false for one you typed in the Query tab.
        var byApp: Bool? = nil
    }

    /// Statement history persists across launches; the console shows it.
    private let historyStore: HistoryStore

    /// Named, reusable SQL snippets — persisted globally, shown in the query tab.
    @Published var savedQueries: [SavedQuery] = []
    private let savedQueryStore: SavedQueryStore

    /// `arguments` picks the folder history and saved queries live in (see SupportDirectory).
    init(connections: [Connection], arguments: [String] = CommandLine.arguments) {
        self.historyStore = HistoryStore(arguments: arguments)
        self.savedQueryStore = SavedQueryStore(arguments: arguments)
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

    /// A .sql file opened into the Query tab: into the current tab when it is empty,
    /// else into a new one, named after the file, which ⌘S then saves back to.
    func openSQL(_ text: String, from url: URL) {
        if !(activeTab?.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false) { addTab() }
        guard let i = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        tabs[i].sql = text
        tabs[i].title = url.lastPathComponent
        tabs[i].fileURL = url
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

    func appendConsole(sql: String, rowsAffected: Int?, error: String?, duration: TimeInterval, byApp: Bool = false) {
        let entry = ConsoleEntry(
            timestamp: Date(), sql: sql,
            rowsAffected: rowsAffected, error: error, duration: duration,
            byApp: byApp ? true : nil
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