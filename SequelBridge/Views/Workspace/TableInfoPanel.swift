//  TableInfoPanel.swift — Table metadata + CREATE TABLE (Sequel Ace style)

import SwiftUI

struct TableInfoPanel: View {
    let table: TableInfo
    let conn: Connection
    @ObservedObject var session: WorkspaceSession
    @EnvironmentObject private var manager: ConnectionManager

    @State private var info: [(key: String, value: String)] = []
    @State private var createSQL = ""
    @State private var isLoading = true

    private let generalKeys = ["Engine", "Row Format", "Auto Increment", "Collation", "Create Options", "Comment"]
    private let storageKeys = ["Rows", "Avg Row Length", "Data Size", "Max Data Size", "Index Size", "Data Free"]
    private let timeKeys    = ["Created", "Updated", "Checked"]
    private let keyWidth: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(icon: "info.circle", title: table.name, subtitle: "Table Info", tint: conn.displayColor)
            Divider()
            if isLoading {
                ProgressView("Loading info…").padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if info.isEmpty {
                emptyState(icon: "questionmark.circle", message: "Could not load table information")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        infoBlock("GENERAL",    keys: generalKeys)
                        infoBlock("STORAGE",    keys: storageKeys)
                        infoBlock("TIMESTAMPS", keys: timeKeys)
                        if !createSQL.isEmpty { createBlock }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: table.id) { await loadInfo() }
    }

    // MARK: - Section blocks

    private func infoBlock(_ title: String, keys: [String]) -> some View {
        let rows = info.filter { keys.contains($0.key) }
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    blockHeader(title)
                    ForEach(rows, id: \.key) { row in
                        HStack(alignment: .top, spacing: 0) {
                            Text(row.key)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: keyWidth, alignment: .leading)
                            Text(row.value)
                                .font(.system(size: 12))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        Divider().padding(.leading, 16 + keyWidth)
                    }
                }
            }
        }
    }

    private var createBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with Copy button
            HStack(spacing: 0) {
                Text("CREATE STATEMENT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(createSQL, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // SQL text — horizontal scroll, strict left-align
            ScrollView(.horizontal, showsIndicators: true) {
                Text(createSQL)
                    .font(Theme.mono(11))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
        }
    }

    private func blockHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Data loading

    private func loadInfo() async {
        isLoading = true
        info = []
        createSQL = ""
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        guard !db.isEmpty else { isLoading = false; return }

        var engine = ""; var rowFormat = ""; var autoInc = ""
        var collation = ""; var tableComment = ""

        if let row = try? await manager.queryEngine.fetchTableMeta(
            alias: conn.alias, database: db, table: table.name), !row.isEmpty {
            let fmtBytes: (String) -> String = { val in
                let n = Int(val) ?? 0; if n == 0 { return "—" }
                let units = ["B", "KB", "MB", "GB", "TB"]
                var v = Double(n); var i = 0
                while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
                return String(format: "%.1f %@", v, units[i])
            }
            engine = row[0]; rowFormat = row[1]; autoInc = row[2]
            collation = row[3]; tableComment = row[5]

            var newInfo: [(key: String, value: String)] = []
            // General
            newInfo.append(("Engine",         engine.isEmpty    ? "—" : engine))
            newInfo.append(("Row Format",     rowFormat.isEmpty ? "—" : rowFormat))
            if let ai = Int(autoInc), ai > 0 { newInfo.append(("Auto Increment", autoInc)) }
            newInfo.append(("Collation",      collation.isEmpty ? "—" : collation))
            let opts = row[4].trimmingCharacters(in: .whitespaces)
            if !opts.isEmpty && opts != "0" { newInfo.append(("Create Options", opts)) }
            newInfo.append(("Comment",        tableComment.isEmpty ? "—" : tableComment))
            // Storage
            newInfo.append(("Rows",           row[6].isEmpty ? "—" : row[6]))
            let avgLen = Int(row[7]) ?? 0
            newInfo.append(("Avg Row Length", avgLen == 0 ? "—" : "\(avgLen) B"))
            newInfo.append(("Data Size",      fmtBytes(row[8])))
            newInfo.append(("Max Data Size",  fmtBytes(row[9])))
            newInfo.append(("Index Size",     fmtBytes(row[10])))
            newInfo.append(("Data Free",      fmtBytes(row[11])))
            // Timestamps
            if !row[12].isEmpty { newInfo.append(("Created", row[12])) }
            if !row[13].isEmpty { newInfo.append(("Updated", row[13])) }
            if !row[14].isEmpty { newInfo.append(("Checked", row[14])) }
            info = newInfo
        }

        let cached = session.sidebarTrees[conn.alias]?.first(where: { $0.id == table.id })
        let columns: [ColumnInfo] = cached?.columns.isEmpty == false
            ? cached!.columns
            : ((try? await manager.queryEngine.fetchColumns(alias: conn.alias, database: db, table: table.name)) ?? [])
        let indexes: [IndexInfo] = cached?.indexes.isEmpty == false
            ? cached!.indexes
            : ((try? await manager.queryEngine.fetchIndexes(alias: conn.alias, database: db, table: table.name)) ?? [])

        if !columns.isEmpty {
            createSQL = buildCreateSQL(engine: engine, collation: collation,
                                       autoInc: autoInc, comment: tableComment,
                                       columns: columns, indexes: indexes)
        }
        isLoading = false
    }

    // MARK: - CREATE TABLE builder

    private func buildCreateSQL(engine: String, collation: String, autoInc: String,
                                comment: String, columns: [ColumnInfo], indexes: [IndexInfo]) -> String {
        SQLBuilder.showCreateTable(table: table.name, columns: columns, indexes: indexes,
                                   engine: engine, collation: collation,
                                   autoIncrement: autoInc, comment: comment)
    }
}
