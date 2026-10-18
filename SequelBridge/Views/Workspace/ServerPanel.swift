//
//  ServerPanel.swift
//  SequelBridge
//
//  Server inspection. For MySQL/MariaDB + Postgres: the live process list (with
//  KILL), configuration variables, and runtime status. For ClickHouse: Query
//  Insights from system.query_log (recent queries, slowest queries, per-type
//  rollup). Connection-scoped; reuses the results grid so sort/copy come for free.
//

import SwiftUI

struct ServerPanel: View {
    @EnvironmentObject private var manager: ConnectionManager
    let conn: Connection
    @ObservedObject var session: WorkspaceSession

    /// What the panel shows: the first three for MySQL/Postgres, the rest for ClickHouse.
    private enum Mode: String, Identifiable {
        case processes = "Processes", variables = "Variables", status = "Status"
        case recent = "Recent", slow = "Slow Queries", byType = "By Type"
        var id: String { rawValue }
        var insight: QueryEngine.ClickHouseInsight? {
            switch self {
            case .recent: return .recent
            case .slow:   return .slow
            case .byType: return .byType
            default:      return nil
            }
        }
    }

    @State private var selectedMode: Mode = .processes
    @State private var result = QueryResult(columns: [], rows: [], executionTime: 0)
    @State private var loading = false
    @State private var filter = ""
    @State private var selectedRows: Set<Int> = []
    @State private var killIds: [String] = []     // captured on Kill tap, confirmed in dialog
    @State private var errorText: String?

    private var supported: Bool {
        conn.engine == .mysql || conn.engine == .postgres || conn.engine == .clickhouse
    }
    private var modes: [Mode] {
        conn.engine == .clickhouse ? [.recent, .slow, .byType] : [.processes, .variables, .status]
    }
    private var isProcesses: Bool { selectedMode == .processes }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !supported {
                centered("Server inspection is available for MySQL/MariaDB, PostgreSQL and ClickHouse.")
            } else if loading && result.rowCount == 0 {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = displayed          // compute the filtered view once per render
                ResultsTableView(result: shown, onSelectionChange: { selectedRows = $0 })
                    .id(selectedMode)   // reset grid state (sort/selection) when switching mode
                statusBar(shown)
            }
        }
        .onAppear { if !modes.contains(selectedMode) { selectedMode = modes[0] } }
        .task(id: selectedMode) { await load() }
        .confirmationDialog(
            "Kill \(killIds.count) process\(killIds.count == 1 ? "" : "es")?",
            isPresented: Binding(get: { !killIds.isEmpty }, set: { if !$0 { killIds = [] } }),
            titleVisibility: .visible
        ) {
            Button("Kill \(killIds.joined(separator: ", "))", role: .destructive) {
                let ids = killIds; killIds = []
                Task { await performKill(ids) }
            }
            Button("Cancel", role: .cancel) { killIds = [] }
        } message: {
            Text("This terminates the selected server session(s). In-flight statements are aborted.")
        }
        .alert("Server", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: conn.engine == .clickhouse ? "chart.bar.doc.horizontal" : "server.rack")
                .foregroundColor(.secondary)
            Picker("", selection: $selectedMode) {
                ForEach(modes) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .labelsHidden()

            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()

            if isProcesses {
                Button(role: .destructive) { requestKill() } label: {
                    Label("Kill", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(selectedRows.isEmpty)
                .help("Terminate the selected process(es)")
            }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundColor(.secondary).help("Refresh")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func statusBar(_ shown: QueryResult) -> some View {
        HStack {
            if loading { ProgressView().scaleEffect(0.5).frame(width: 12, height: 12) }
            Text("\(shown.rowCount)\(filter.isEmpty ? "" : " of \(result.rowCount)") rows")
                .font(.caption2).monospacedDigit().foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // Filtered view (the MySQL/PG process list stays unfiltered so selection maps to
    // real rows for KILL).
    private var displayed: QueryResult {
        guard !filter.isEmpty, !isProcesses else { return result }
        let f = filter.lowercased()
        var out = result
        out.rows = result.rows.filter { row in row.contains { $0.lowercased().contains(f) } }
        out.nullMask = []
        return out
    }

    private func centered(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 34)).foregroundColor(.secondary.opacity(0.3))
            Text(text).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: - Actions

    private func load() async {
        guard supported else { return }
        loading = true
        selectedRows = []
        do {
            if let insight = selectedMode.insight {
                result = try await manager.queryEngine.clickhouseQueryInsights(alias: conn.alias, kind: insight)
            } else {
                switch selectedMode {
                case .processes: result = try await manager.queryEngine.serverProcesses(alias: conn.alias)
                case .variables: result = try await manager.queryEngine.serverVariables(alias: conn.alias)
                case .status:    result = try await manager.queryEngine.serverStatus(alias: conn.alias)
                default: break
                }
            }
        } catch {
            if QueryEngine.isCancellation(error) { loading = false; return }   // superseded by a tab/mode switch
            result = QueryResult(columns: [], rows: [], executionTime: 0)
            errorText = QueryEngine.extractReason(from: error)
        }
        loading = false
    }

    private func requestKill() {
        // Process id is the first column (MySQL Id / Postgres pid).
        let ids = selectedRows.compactMap { i -> String? in
            guard i < result.rowCount, result.columns.count > 0 else { return nil }
            let first = result.cells.value(i, 0)
            return first.isEmpty ? nil : first
        }
        guard !ids.isEmpty else { return }
        killIds = ids
    }

    private func performKill(_ ids: [String]) async {
        for id in ids {
            do { try await manager.queryEngine.killProcess(alias: conn.alias, id: id) }
            catch { if !QueryEngine.isCancellation(error) { errorText = QueryEngine.extractReason(from: error) } }
        }
        await load()
    }
}
