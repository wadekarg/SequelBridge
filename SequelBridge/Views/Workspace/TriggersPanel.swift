//  TriggersPanel.swift — Trigger list

import SwiftUI

struct TriggerInfo: Identifiable {
    let id = UUID()
    let name: String
    let timing: String
    let event: String
    let definer: String
    let statement: String
    let created: String
}

struct TriggersPanel: View {
    let table: TableInfo
    let conn: Connection
    @ObservedObject var session: WorkspaceSession
    @EnvironmentObject private var manager: ConnectionManager
    @State private var triggers: [TriggerInfo] = []
    @State private var isLoading = true
    @State private var expanded: Set<UUID> = []
    @State private var selectedId: UUID? = nil
    @State private var showCreateSheet = false
    /// The trigger Drop asks about: dropped only on its yes.
    @State private var dropping: TriggerInfo?
    @State private var actionError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with +/- buttons (Sequel Ace style)
            HStack {
                panelHeader(icon: "bolt", title: table.name, subtitle: "Triggers", tint: conn.displayColor)
                Spacer()
                Button {
                    if let id = selectedId { dropping = triggers.first(where: { $0.id == id }) }
                } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                .buttonStyle(.bordered).controlSize(.mini)
                .disabled(selectedId == nil || !TriggerEditing.canDrop(on: conn.engine))
                .help(TriggerEditing.canDrop(on: conn.engine) ? "Drop trigger" : (TriggerEditing.reason(conn.engine) ?? ""))
                .accessibilityIdentifier("triggers.drop")
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderedProminent).controlSize(.mini)
                .disabled(!TriggerEditing.canCreate(on: conn.engine))
                .accessibilityIdentifier("triggers.add")
                .help(TriggerEditing.canCreate(on: conn.engine) ? "Create trigger" : (TriggerEditing.reason(conn.engine) ?? ""))
            }
            .padding(.trailing, 12)
            Divider()
            if let actionError {
                Text(actionError)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isLoading {
                ProgressView("Loading triggers…").padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if triggers.isEmpty {
                emptyState(icon: "bolt.slash", message: "No triggers defined on this table")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(triggers) { t in
                            triggerRow(t)
                                .background(selectedId == t.id ? Color.accentColor.opacity(0.08) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedId = t.id }
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: table.id) { await loadTriggers() }
        // A schema change on the server: only after a yes (one click dropped the trigger).
        .confirmationDialog("Drop this trigger?", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            presenting: dropping) { t in
            Button("Drop “\(t.name)”", role: .destructive) { Task { await dropTrigger(t) } }
            Button("Cancel", role: .cancel) {}
        } message: { t in
            Text("“\(t.name)” (\(t.timing) \(t.event)) is dropped from “\(table.name)” on the server.")
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateTriggerSheet(engine: conn.engine, tableName: table.name,
                               database: session.selectedDatabase[conn.alias] ?? conn.database) { sql in
                Task {
                    actionError = nil
                    do {
                        // Runs on the server, or in SQLite itself: DuckDB has no CREATE TRIGGER.
                        try await manager.queryEngine.executeDDL(alias: conn.alias, sql: sql)
                    } catch {
                        actionError = QueryEngine.extractReason(from: error)
                    }
                    await loadTriggers()
                }
            }
        }
    }

    // MARK: - Row

    private func triggerRow(_ t: TriggerInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name row + badges
            HStack(spacing: 6) {
                Text(t.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                timingBadge(t.timing)
                eventBadge(t.event)
                Spacer()
                if !t.created.isEmpty {
                    Text(t.created)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Definer
            if !t.definer.isEmpty {
                HStack(spacing: 4) {
                    Text("Definer:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(t.definer)
                        .font(Theme.mono(11))
                        .foregroundColor(.secondary)
                }
            }

            // Statement
            let isExpanded = expanded.contains(t.id)
            let lines = t.statement.components(separatedBy: "\n")
            Text(t.statement)
                .font(Theme.mono(11))
                .foregroundColor(.primary.opacity(0.8))
                .multilineTextAlignment(.leading)
                .lineLimit(isExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if lines.count > 4 || t.statement.count > 160 {
                Button(isExpanded ? "Show less" : "Show more") {
                    if isExpanded { expanded.remove(t.id) } else { expanded.insert(t.id) }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Badges

    private func timingBadge(_ timing: String) -> some View {
        let color: Color = timing.uppercased() == "BEFORE" ? .orange : .blue
        return Text(timing.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color).cornerRadius(3)
    }

    private func eventBadge(_ event: String) -> some View {
        let color: Color = event.uppercased() == "INSERT" ? .green
                         : event.uppercased() == "UPDATE" ? .purple : .red
        return Text(event.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color).cornerRadius(3)
    }

    private func dropTrigger(_ t: TriggerInfo) async {
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        let sql = SQLBuilder.dropTrigger(engine: conn.engine, database: db, table: table.name, name: t.name)
        actionError = nil
        do {
            try await manager.queryEngine.executeDDL(alias: conn.alias, sql: sql)
        } catch {
            actionError = QueryEngine.extractReason(from: error)
        }
        selectedId = nil
        await loadTriggers()
    }

    // MARK: - Data loading

    private func loadTriggers() async {
        isLoading = true; triggers = []
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        guard !db.isEmpty else { isLoading = false; return }
        let rows = (try? await manager.queryEngine.fetchTriggers(
            alias: conn.alias, database: db, table: table.name)) ?? []
        triggers = rows.map {
            // A server that keeps no definer or time (SQLite, PostgreSQL, MariaDB 10.0's
            // Created) says NULL: nothing is shown for it.
            TriggerInfo(name: $0[0], timing: $0[1], event: $0[2],
                        definer: TableMeta.field($0, 3) ?? "", statement: $0[4], created: TableMeta.field($0, 5) ?? "")
        }
        isLoading = false
    }
}

// MARK: - Create Trigger sheet

private struct CreateTriggerSheet: View {
    let engine: DatabaseEngine
    let tableName: String
    let database: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name          = ""
    @State private var timing        = "BEFORE"
    @State private var triggerEvent  = "INSERT"
    @State private var triggerSQL    = "BEGIN\n  -- trigger body here\nEND"

    var generatedSQL: String {
        SQLBuilder.createTrigger(engine: engine, database: database, table: tableName, name: name,
                                 timing: timing, event: triggerEvent, body: triggerSQL)
    }

    var isValid: Bool { !name.isEmpty && !triggerSQL.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Create Trigger").font(.title2).bold()
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trigger Name").font(.caption).foregroundColor(.secondary)
                        TextField("e.g. before_insert_check", text: $name).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timing").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: $timing) {
                            Text("BEFORE").tag("BEFORE"); Text("AFTER").tag("AFTER")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Event").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: $triggerEvent) {
                            Text("INSERT").tag("INSERT")
                            Text("UPDATE").tag("UPDATE")
                            Text("DELETE").tag("DELETE")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trigger Body").font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $triggerSQL)
                        .font(Theme.mono(12))
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }
            }
            .padding(20)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Trigger") { onSave(generatedSQL); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }.padding(20)
        }
        .frame(width: 560, height: 360)
    }
}
