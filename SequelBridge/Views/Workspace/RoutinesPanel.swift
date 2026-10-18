//
//  RoutinesPanel.swift
//  SequelBridge
//
//  Browse a schema's stored procedures and functions (MySQL/MariaDB + Postgres),
//  read from the server's information_schema.ROUTINES. Read-only for now — pick a
//  routine on the left, read its definition on the right.
//

import SwiftUI

struct RoutinesPanel: View {
    @EnvironmentObject private var manager: ConnectionManager
    let conn: Connection
    @ObservedObject var session: WorkspaceSession

    @State private var routines: [[String]] = []    // [name, type, returns, body]
    @State private var loading = false
    @State private var selected: Int? = nil
    @State private var copied = false

    private var db: String { session.selectedDatabase[conn.alias] ?? conn.database }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: db) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "function").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Routines").font(.headline)
                Text(db).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if loading { ProgressView().scaleEffect(0.6).frame(width: 16, height: 16) }
            else { Text("\(routines.count)").font(.caption).foregroundColor(.secondary) }
            Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundColor(.secondary).help("Refresh")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if conn.engine != .mysql && conn.engine != .postgres {
            centered("Routines browsing is available for MySQL/MariaDB and PostgreSQL.")
        } else if !loading && routines.isEmpty {
            centered("No stored procedures or functions in “\(db)”.")
        } else {
            HSplitView {
                routineList.frame(minWidth: 200, idealWidth: 260, maxWidth: 380)
                detail.frame(minWidth: 300, maxWidth: .infinity)
            }
        }
    }

    private var routineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(routines.enumerated()), id: \.offset) { pair in
                    let i = pair.offset
                    let r = pair.element
                    HStack(spacing: 8) {
                        Text((r[safe: 1] ?? "").uppercased().hasPrefix("FUNC") ? "ƒ" : "▷")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.accentColor)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r[safe: 0] ?? "").font(.system(size: 12)).lineLimit(1)
                            Text(typeLabel(r)).font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(selected == i ? Color.accentColor.opacity(0.12) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = i }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let i = selected, i < routines.count {
            let r = routines[i]
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r[safe: 0] ?? "").font(.system(size: 14, weight: .semibold))
                        Text(typeLabel(r)).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(r[safe: 3] ?? "", forType: .string)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled((r[safe: 3] ?? "").isEmpty)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                ScrollView {
                    Text((r[safe: 3] ?? "").isEmpty ? "— definition not available —" : (r[safe: 3] ?? ""))
                        .font(Theme.mono(12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        } else {
            centered("Select a routine to see its definition.")
        }
    }

    private func centered(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "function").font(.system(size: 34)).foregroundColor(.secondary.opacity(0.3))
            Text(text).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func typeLabel(_ r: [String]) -> String {
        let type = (r[safe: 1] ?? "").capitalized
        let returns = r[safe: 2] ?? ""
        return returns.isEmpty ? type : "\(type) → \(returns)"
    }

    // MARK: - Load

    private func load(force: Bool = false) async {
        guard conn.engine == .mysql || conn.engine == .postgres, !db.isEmpty else {
            routines = []; return
        }
        loading = true
        let rows = (try? await manager.queryEngine.fetchRoutines(alias: conn.alias, database: db)) ?? []
        routines = rows
        if let sel = selected, sel >= rows.count { selected = nil }
        loading = false
    }
}

private extension Array {
    /// Bounds-checked access (the safe subscript in other files is file-private).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
