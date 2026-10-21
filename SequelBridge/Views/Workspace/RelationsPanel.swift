//  RelationsPanel.swift — Foreign key constraints

import SwiftUI

struct RelationInfo: Identifiable {
    let id = UUID()
    let name: String
    let column: String
    let referencedTable: String
    let referencedColumn: String
    let onDelete: String
    let onUpdate: String
}

struct RelationsPanel: View {
    let table: TableInfo
    let conn: Connection
    @ObservedObject var session: WorkspaceSession
    @EnvironmentObject private var manager: ConnectionManager
    @State private var relations: [RelationInfo] = []
    /// The foreign key Drop asks about: dropped only on its yes.
    @State private var dropping: RelationInfo?
    @State private var isLoading = true
    @State private var selectedId: UUID? = nil
    @State private var showAddSheet = false
    @State private var actionError: String? = nil

    /// Add Foreign Key offers the table's columns to pick from: they're read first when the
    /// left panel hasn't yet (it reads them when Structure opens). Without them the sheet
    /// fell back to typing the column's name.
    private func openAddSheet() async {
        let cached = session.sidebarTrees[conn.alias]?.first(where: { $0.id == table.id })?.columns ?? []
        if cached.isEmpty {
            let db = session.selectedDatabase[conn.alias] ?? conn.database
            if let cols = try? await manager.queryEngine.fetchColumns(alias: conn.alias, database: db, table: table.name),
               let i = session.sidebarTrees[conn.alias]?.firstIndex(where: { $0.id == table.id }) {
                session.sidebarTrees[conn.alias]?[i].columns = cols
            }
        }
        showAddSheet = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                panelHeader(icon: "link", title: table.name, subtitle: "Relations", tint: conn.displayColor)
                Spacer()
                Button { Task { await openAddSheet() } } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered).controlSize(.mini)
                .help("Add foreign key")
                .accessibilityIdentifier("relations.add")

                Button {
                    if let id = selectedId { dropping = relations.first(where: { $0.id == id }) }
                } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                .buttonStyle(.bordered).controlSize(.mini).disabled(selectedId == nil)
                .help("Drop selected foreign key")
                .accessibilityIdentifier("relations.drop")
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
                ProgressView("Loading relations…").padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if relations.isEmpty {
                emptyState(icon: "link.badge.plus",
                           message: "No foreign key constraints defined on this table")
            } else {
                RelationsTable(relations: relations, selectedId: $selectedId)
            }
        }
        .task(id: table.id) { await loadRelations() }
        // A schema change on the server: only after a yes (one click dropped the key).
        .confirmationDialog("Drop this foreign key?", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            presenting: dropping) { rel in
            Button("Drop “\(rel.name)”", role: .destructive) { Task { await dropFK(rel) } }
            Button("Cancel", role: .cancel) {}
        } message: { rel in
            Text("“\(rel.name)” (\(rel.column) → \(rel.referencedTable).\(rel.referencedColumn)) is dropped from “\(table.name)” on the server.")
        }
        .sheet(isPresented: $showAddSheet) {
            let localColumns = session.sidebarTrees[conn.alias]?
                .first(where: { $0.id == table.id })?.columns.map(\.name) ?? []
            let allTables = session.sidebarTrees[conn.alias]?.map(\.name) ?? []
            AddFKSheet(
                isPresented: $showAddSheet,
                localColumns: localColumns,
                availableTables: allTables
            ) { fkDef in
                Task { await addFK(fkDef) }
            }
        }
    }

    private func addFK(_ def: FKDefinition) async {
        let db     = session.selectedDatabase[conn.alias] ?? conn.database
        let name   = def.constraintName.isEmpty
            ? "fk_\(table.name)_\(def.localColumn)"
            : def.constraintName
        let sql: String
        if conn.engine == .clickhouse {
            actionError = "ClickHouse has no foreign keys."
            return
        }
        switch conn.engine {
        case .sqlite:
            // SQLite has no ADD CONSTRAINT; foreign keys can only be declared when
            // the table is created.
            actionError = "SQLite cannot add a foreign key to an existing table."
            return
        case .mysql:
            sql = SQLBuilder.addForeignKey(
                database: db, table: table.name, name: name, column: def.localColumn,
                referencedTable: def.referencedTable, referencedColumn: def.referencedColumn,
                onDelete: def.onDelete, onUpdate: def.onUpdate
            )
        case .clickhouse:
            return   // guarded above
        case .postgres:
            sql = SQLBuilder.pgAddForeignKey(
                schema: db, table: table.name, name: name, column: def.localColumn,
                referencedTable: def.referencedTable, referencedColumn: def.referencedColumn,
                onDelete: def.onDelete, onUpdate: def.onUpdate
            )
        }
        actionError = nil
        do {
            try await manager.queryEngine.executeDDL(alias: conn.alias, sql: sql)
        } catch {
            actionError = QueryEngine.extractReason(from: error)
        }
        await loadRelations()
    }

    private func dropFK(_ rel: RelationInfo) async {
        let db     = session.selectedDatabase[conn.alias] ?? conn.database
        guard conn.engine != .sqlite else {
            actionError = "SQLite cannot drop a foreign key; it is part of the table definition."
            return
        }
        let sql = conn.engine == .postgres
            ? SQLBuilder.pgDropForeignKey(schema: db, table: table.name, name: rel.name)
            : SQLBuilder.dropForeignKey(database: db, table: table.name, name: rel.name)
        actionError = nil
        do {
            try await manager.queryEngine.executeDDL(alias: conn.alias, sql: sql)
        } catch {
            actionError = QueryEngine.extractReason(from: error)
        }
        selectedId = nil
        await loadRelations()
    }

    // MARK: - Data loading

    private func loadRelations() async {
        isLoading = true; relations = []
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        guard !db.isEmpty else { isLoading = false; return }
        let rows = (try? await manager.queryEngine.fetchRelations(
            alias: conn.alias, database: db, table: table.name)) ?? []
        relations = rows.map {
            RelationInfo(name: $0[0], column: $0[1],
                         referencedTable: $0[2], referencedColumn: $0[3],
                         onDelete: $0[4], onUpdate: $0[5])
        }
        isLoading = false
    }
}

// MARK: - Table

/// The table's foreign keys, a row each; a click selects one for Drop. The columns keep
/// their widths: in a pane narrower than they are the table scrolls sideways, anchored at
/// the top left as the Structure panel's is. In a vertical ScrollView it was centered and
/// cut off on both sides, its name column squeezed to nothing (a 1024×768 screen's window).
struct RelationsTable: View {
    let relations: [RelationInfo]
    @Binding var selectedId: UUID?

    // Fixed column widths
    private let wColumn:    CGFloat = 140
    private let wRef:       CGFloat = 200
    private let wAction:    CGFloat = 110

    /// The Constraint column: as wide as the longest name, at least as wide as its header.
    static func nameColumnWidth(for relations: [RelationInfo]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11)
        let widest = relations.map { NSAttributedString(string: $0.name, attributes: [.font: font]).size().width }.max() ?? 0
        return max(widest.rounded(.up) + 4, 80)
    }

    private var contentWidth: CGFloat {
        16 + wColumn + wRef + wAction * 2 + Self.nameColumnWidth(for: relations) + 16
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    tableHeader
                    Divider()
                    ForEach(relations) { rel in
                        tableRow(rel)
                            .background(selectedId == rel.id ? Color.accentColor.opacity(0.08) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedId = rel.id }
                        Divider().padding(.leading, 16)
                    }
                }
                // As wide as the columns, or the pane when it's wider; from the top, not
                // centered when the rows don't fill it.
                .frame(width: max(contentWidth, geo.size.width), alignment: .leading)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            hdr("Column",     wColumn)
            hdr("References", wRef)
            hdr("On Delete",  wAction)
            hdr("On Update",  wAction)
            hdr("Constraint", nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func tableRow(_ rel: RelationInfo) -> some View {
        HStack(alignment: .center, spacing: 0) {
            cell(rel.column,
                 "\(rel.referencedTable).\(rel.referencedColumn)",
                 rel.onDelete, rel.onUpdate, rel.name)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // Build the row inline to keep widths consistent
    private func cell(_ col: String, _ ref: String,
                      _ del: String, _ upd: String, _ name: String) -> some View {
        HStack(spacing: 0) {
            Text(col)
                .font(Theme.mono(12))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: wColumn, alignment: .leading)

            Text(ref)
                .font(Theme.mono(12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: wRef, alignment: .leading)

            actionBadge(del).frame(width: wAction, alignment: .leading)
            actionBadge(upd).frame(width: wAction, alignment: .leading)

            Text(name)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func actionBadge(_ action: String) -> some View {
        let up = action.uppercased()
        let isPlain = up == "RESTRICT" || up == "NO ACTION" || up.isEmpty
        let color: Color = up == "CASCADE" ? .red : up == "SET NULL" ? .orange : .secondary
        Text(up.isEmpty ? "—" : up)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(isPlain ? .secondary : .white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(isPlain ? Color.secondary.opacity(0.1) : color)
            .cornerRadius(3)
    }

    private func hdr(_ label: String, _ width: CGFloat?) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: width, alignment: .leading)
    }
}

// MARK: - FK Definition

struct FKDefinition {
    var localColumn: String
    var referencedTable: String
    var referencedColumn: String
    var onDelete: String
    var onUpdate: String
    var constraintName: String
}

// MARK: - Add FK Sheet

struct AddFKSheet: View {
    @Binding var isPresented: Bool
    let localColumns: [String]
    let availableTables: [String]
    let onAdd: (FKDefinition) -> Void

    private let actions = ["RESTRICT", "CASCADE", "SET NULL", "NO ACTION"]

    @State private var localColumn     = ""
    @State private var referencedTable = ""
    @State private var referencedColumn = ""
    @State private var onDelete        = "RESTRICT"
    @State private var onUpdate        = "RESTRICT"
    @State private var constraintName  = ""

    private var isValid: Bool {
        !localColumn.isEmpty && !referencedTable.isEmpty && !referencedColumn.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Foreign Key").font(.title2).bold()
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                row("Local Column") {
                    if localColumns.isEmpty {
                        TextField("column_name", text: $localColumn).textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $localColumn) {
                            Text("Select column…").tag("")
                            ForEach(localColumns, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                }

                row("References Table") {
                    if availableTables.isEmpty {
                        TextField("table_name", text: $referencedTable).textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $referencedTable) {
                            Text("Select table…").tag("")
                            ForEach(availableTables, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                }

                row("References Column") {
                    TextField("column_name", text: $referencedColumn)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                row("On Delete") {
                    Picker("", selection: $onDelete) {
                        ForEach(actions, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }

                row("On Update") {
                    Picker("", selection: $onUpdate) {
                        ForEach(actions, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }

                Divider()

                row("Constraint Name") {
                    TextField("auto-generated if empty", text: $constraintName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(20)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Add Foreign Key") {
                    onAdd(FKDefinition(
                        localColumn: localColumn,
                        referencedTable: referencedTable,
                        referencedColumn: referencedColumn,
                        onDelete: onDelete,
                        onUpdate: onUpdate,
                        constraintName: constraintName
                    ))
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 420)
        .onAppear {
            localColumn     = localColumns.first ?? ""
            referencedTable = availableTables.first ?? ""
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .trailing)
            content()
        }
    }
}
