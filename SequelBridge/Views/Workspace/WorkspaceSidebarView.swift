//  WorkspaceSidebarView.swift

import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceSidebarView: View {
    @EnvironmentObject private var manager: ConnectionManager
    @ObservedObject var session: WorkspaceSession
    @State private var showAddSheet = false          // pick from existing favorites
    @State private var showNewConnectionSheet = false // create brand-new connection
    /// The saved connections when New Connection… opened: closing it opens only one it added.
    @State private var savedBeforeNewConnection: Set<UUID> = []
    @State private var tableInfo: [(key: String, value: String)] = []
    @State private var tableInfoLoading = false
    @State private var tableInfoForId: String? = nil
    @State private var copiedTableId: String? = nil   // shows "Copied!" badge briefly
    @State private var showCreateTable = false
    @State private var destructTarget: DestructTarget? = nil   // pending drop/truncate awaiting confirm
    @State private var addDatabaseRequest: AddDatabaseRequest?    // Add Database…
    @State private var databaseToDelete: DatabaseToDelete?        // Delete Database…, awaiting confirm
    @State private var maintenanceAnswer: (title: String, message: String)?   // Table Maintenance's answer
    @State private var tableNameRequest: TableNameRequest?   // Rename / Duplicate Table…
    @State private var importProgress: ImportProgress?             // Import SQL file…, while it runs
    @State private var importTask: Task<Void, Never>?
    @State private var destructError: String? = nil
    @State private var exportInfo: String? = nil               // neutral note after a SQL export

    var body: some View {
        VStack(spacing: 0) {
            connectionTabs
            if let conn = session.connections.first(where: { $0.alias == session.activeConnectionAlias })
                ?? session.connections.first {
                VStack(spacing: 0) {
                    databaseSelector(conn)
                    filterBox(for: conn.alias)
                    tableList(conn)
                    tableInfoPanel(conn)
                }
                // One per connection: a keyboard shortcut runs the action its button had
                // when first drawn, so ⇧⌘R and ⌃⌘R refreshed the first connection shown.
                .id(conn.alias)
                // Delete Database… confirms first (here: the table drop has the outer view's).
                .confirmationDialog(
                    "Delete this database?",
                    isPresented: Binding(get: { databaseToDelete != nil }, set: { if !$0 { databaseToDelete = nil } }),
                    presenting: databaseToDelete
                ) { target in
                    Button("Delete “\(target.name)”", role: .destructive) {
                        Task {
                            if let failure = await session.deleteDatabase(target.name, on: target.conn, manager: manager) {
                                destructError = failure
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { target in
                    Text("This permanently deletes the database “\(target.name)” with all of its tables and data. This cannot be undone.")
                }
            } else {
                Spacer()
                Text("No active connection").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        }
        // Pick an existing favourite to connect to this workspace
        .sheet(isPresented: $showAddSheet) {
            AddServerSheet(
                isPresented: $showAddSheet,
                showNewConnection: $showNewConnectionSheet,
                alreadyConnected: session.connections.map(\.id)
            ) { conn in
                Task { await connectOne(conn) }
            }
        }
        // Create a brand-new connection
        .sheet(isPresented: $showNewConnectionSheet) {
            AddConnectionSheet(isPresented: $showNewConnectionSheet)
                .onAppear { savedBeforeNewConnection = Set(manager.saved.map(\.id)) }
                .onDisappear { Task { await attachNewConnections(savedBefore: savedBeforeNewConnection) } }
        }
        // Create new table
        .sheet(isPresented: $showCreateTable) {
            if let conn = session.connections.first(where: { $0.alias == session.activeConnectionAlias })
                ?? session.connections.first {
                let db = session.selectedDatabase[conn.alias] ?? conn.database
                CreateTableSheet(isPresented: $showCreateTable, conn: conn, database: db) {
                    Task { await loadTables(for: conn) }
                }
                .environmentObject(manager)
            }
        }
        .sheet(item: $importProgress) { progress in
            ImportProgressSheet(progress: progress) { importTask?.cancel() }
        }
        .sheet(item: $addDatabaseRequest) { request in
            AddDatabaseSheet(request: request, engine: manager.queryEngine) { name, charset, collation in
                await session.createDatabase(name, charset: charset, collation: collation, on: request.conn, manager: manager)
            }
        }
        .sheet(item: $tableNameRequest) { request in
            TableNameSheet(request: request) { name, withRows in
                Task { await renameOrDuplicate(request, name: name, withRows: withRows) }
            }
        }
        // Confirm a destructive drop/truncate before touching the server.
        .confirmationDialog(
            destructTarget?.action == .drop ? "Drop this table?" : "Truncate this table?",
            isPresented: Binding(
                get: { destructTarget != nil },
                set: { if !$0 { destructTarget = nil } }
            ),
            presenting: destructTarget
        ) { target in
            Button(target.action == .drop ? "Drop “\(target.table.name)”" : "Truncate “\(target.table.name)”",
                   role: .destructive) {
                Task { await performDestruct(target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(target.action == .drop
                 ? "This permanently deletes the table “\(target.table.name)” and all of its data. This cannot be undone."
                 : "This permanently deletes every row in “\(target.table.name)”. This cannot be undone.")
        }
        .alert("Couldn’t complete the operation",
               isPresented: Binding(get: { destructError != nil }, set: { if !$0 { destructError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(destructError ?? "")
        }
        .alert(maintenanceAnswer?.title ?? "",
               isPresented: Binding(get: { maintenanceAnswer != nil }, set: { if !$0 { maintenanceAnswer = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(maintenanceAnswer?.message ?? "")
        }
        .alert("Done",
               isPresented: Binding(get: { exportInfo != nil }, set: { if !$0 { exportInfo = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportInfo ?? "")
        }
    }

    private func importCSV(_ table: TableInfo, conn: Connection) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, UTType(filenameExtension: "csv") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CSV file to import into “\(table.name)” (first row = column names)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            destructError = "Couldn't read the CSV file."; return
        }
        let parsed = CSVParser.parse(text)
        guard parsed.count >= 2 else {
            destructError = "The CSV needs a header row and at least one data row."; return
        }
        let header = parsed[0]
        let dataRows = Array(parsed.dropFirst())
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        Task {
            do {
                let cols = (try? await manager.queryEngine.fetchColumns(
                    alias: conn.alias, database: db, table: table.name)) ?? []
                let tableColNames = Set(cols.map(\.name))
                // Keep only CSV columns whose header names exist in the table, and
                // project each data row to those columns (by CSV position).
                let matched = header.enumerated().filter { tableColNames.contains($0.element) }
                guard !matched.isEmpty else {
                    destructError = "None of the CSV columns (\(header.joined(separator: ", "))) match columns in “\(table.name)”."
                    return
                }
                let importCols = matched.map(\.element)
                let projected = dataRows.map { row in matched.map { $0.offset < row.count ? row[$0.offset] : "" } }
                let n = try await manager.queryEngine.importCSV(
                    alias: conn.alias, database: db, table: table.name, columns: importCols, rows: projected)
                let skipped = header.count - importCols.count
                exportInfo = "Imported \(n.formatted()) row\(n == 1 ? "" : "s") into “\(table.name)” "
                    + "(\(importCols.count) column\(importCols.count == 1 ? "" : "s"): \(importCols.joined(separator: ", ")))."
                    + (skipped > 0 ? " Skipped \(skipped) unmatched CSV column\(skipped == 1 ? "" : "s")." : "")
                await loadTables(for: conn)
            } catch {
                destructError = QueryEngine.extractReason(from: error)
            }
        }
    }

    private func exportSQL(_ table: TableInfo, conn: Connection) {
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "\(table.name).sql"
        panel.message = "Export “\(table.name)” as a SQL dump (schema + data)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let dump = try await manager.queryEngine.sqlDump(
                    alias: conn.alias, database: db, table: table.name)
                try dump.text.write(to: url, atomically: true, encoding: .utf8)
                if dump.truncated {
                    exportInfo = "Saved the first \(dump.rowCount.formatted()) rows of “\(table.name)”. The table may contain more rows than were exported — add a WHERE/LIMIT or raise the limit to capture everything."
                }
            } catch {
                destructError = QueryEngine.extractReason(from: error)
            }
        }
    }

    private func exportDatabaseSQL(_ conn: Connection) {
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        guard !db.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "\(db).sql"
        panel.message = "Export the whole “\(db)” database as a SQL dump (every table: schema + data)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let dump = try await manager.queryEngine.sqlDumpDatabase(alias: conn.alias, database: db)
                try dump.text.write(to: url, atomically: true, encoding: .utf8)
                if dump.truncated {
                    exportInfo = "Saved “\(db)”, but at least one table hit the \(100_000.formatted())-row export cap, so the dump may be partial for those tables."
                }
            } catch {
                destructError = QueryEngine.extractReason(from: error)
            }
        }
    }

    private func importCSVNewTable(_ conn: Connection) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, UTType(filenameExtension: "csv") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CSV to import into a NEW table (first row = column names; types inferred)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            destructError = "Couldn't read the CSV file."; return
        }
        let parsed = CSVParser.parse(text)
        guard parsed.count >= 2 else {
            destructError = "The CSV needs a header row and at least one data row."; return
        }
        let header = parsed[0]
        let dataRows = Array(parsed.dropFirst())
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        let tableName = SQLBuilder.sanitizeColumnName(url.deletingPathExtension().lastPathComponent, fallback: "imported_table")

        // Build a column per CSV header with a sampled, inferred type.
        let columns: [NewColumnDef] = header.enumerated().map { (i, raw) in
            let name = SQLBuilder.sanitizeColumnName(raw, fallback: "col\(i + 1)")
            let sample = dataRows.prefix(500).map { i < $0.count ? $0[i] : "" }
            let inferred = SQLBuilder.inferCSVColumnType(Array(sample))
            var def = NewColumnDef()
            def.name = name
            def.baseType = inferred.base
            def.length = inferred.length
            def.nullable = true
            return def
        }
        let colNames = columns.map(\.name)

        Task {
            do {
                let createSQL = SQLBuilder.createTable(database: db, table: tableName,
                                                       columns: columns, engine: "InnoDB", charset: "utf8mb4")
                try await manager.queryEngine.executeDDL(alias: conn.alias, sql: createSQL)
                let projected = dataRows.map { row in (0..<header.count).map { $0 < row.count ? row[$0] : "" } }
                let n = try await manager.queryEngine.importCSV(
                    alias: conn.alias, database: db, table: tableName, columns: colNames, rows: projected)
                exportInfo = "Created “\(tableName)” (\(columns.count) columns) and imported \(n.formatted()) row\(n == 1 ? "" : "s")."
                await loadTables(for: conn)
            } catch {
                destructError = QueryEngine.extractReason(from: error)
            }
        }
    }

    /// Import SQL file…: runs a .sql file's statements on the server in order, as Sequel
    /// Ace's import does, with progress and Stop; the first that fails stops it and says
    /// which. A `USE` in the file picks that database, as in the Query tab.
    private func importSQLFile(_ conn: Connection) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .sql file to run on \(conn.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let statements: [String]
        do { statements = SQLFile.importStatements(try SQLFile.read(url)) }
        catch { destructError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"; return }
        guard !statements.isEmpty else { exportInfo = "\(url.lastPathComponent) has no statements to run."; return }
        importProgress = ImportProgress(file: url.lastPathComponent, done: 0, total: statements.count)
        importTask = Task {
            var outcome: Result<Void, Error> = .success(())
            var lastRedraw = Date.distantPast
            do {
                try await manager.queryEngine.runScript(
                    alias: conn.alias, statements: statements,
                    use: { db in await session.showDatabase(db, for: conn, manager: manager) }
                ) { done in
                    // A few redraws a second, not one per statement: a dump can hold thousands.
                    let now = Date()
                    if done == statements.count || now.timeIntervalSince(lastRedraw) > 0.1 {
                        importProgress?.done = done
                        lastRedraw = now
                    }
                }
            } catch { outcome = .failure(error) }
            let done = importProgress?.done ?? 0
            importProgress = nil
            await session.refreshDatabases(for: conn, manager: manager)
            switch outcome {
            case .success:
                exportInfo = "Ran \(statements.count.formatted()) statements from \(url.lastPathComponent)."
            case .failure(let error) where error is CancellationError:
                exportInfo = "Stopped after \(done.formatted()) of \(statements.count.formatted()) statements."
            case .failure(let error):
                destructError = QueryEngine.extractReason(from: error)
            }
        }
    }

    /// Rename or duplicate a table, then list the tables again; a renamed table stays selected.
    private func renameOrDuplicate(_ request: TableNameRequest, name: String, withRows: Bool) async {
        let conn = request.conn
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        let statements = request.action == .rename
            ? [SQLBuilder.renameTable(engine: conn.engine, database: db, from: request.table.name, to: name)]
            : SQLBuilder.duplicateTable(engine: conn.engine, database: db, from: request.table.name, to: name, withRows: withRows)
        do {
            for sql in statements { try await manager.queryEngine.executeDDL(alias: conn.alias, sql: sql) }
            await loadTables(for: conn)
            if request.action == .rename, session.selectedTable?.id == request.table.id {
                session.selectedTable = session.sidebarTrees[conn.alias]?.first { $0.name == name }
            }
        } catch {
            destructError = QueryEngine.extractReason(from: error)
        }
    }

    private func performDestruct(_ target: DestructTarget) async {
        let conn = target.conn
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        let sql = target.action == .drop
            ? SQLBuilder.dropTable(engine: conn.engine, database: db, table: target.table.name)
            : SQLBuilder.truncateTable(engine: conn.engine, database: db, table: target.table.name)
        do {
            try await manager.queryEngine.executeDDL(alias: conn.alias, sql: sql)
            if target.action == .drop, session.selectedTable?.id == target.table.id {
                session.selectedTable = nil
            }
            await loadTables(for: conn)
        } catch {
            destructError = QueryEngine.extractReason(from: error)
        }
    }

    // MARK: - Connection tabs

    private var connectionTabs: some View {
        HStack(alignment: .top, spacing: 0) {
            // The tabs wrap onto more rows rather than scrolling sideways out of sight.
            WrappingHStack {
                ForEach(session.connections) { conn in
                    connectionTab(conn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The + keeps the top right corner, above the database menu's ….
            Button { showAddSheet = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: Self.trailingColumn, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add connection")
            .accessibilityIdentifier("sidebar.addConnection")
        }
        // Off the window's top edge: on macOS 15 the strip, when it was a scroll view
        // touching that edge, grew up under the toolbar and its tabs stopped taking clicks.
        .padding(.top, 1)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    /// The width of the left panel's right-hand column: the + above, the database menu below.
    private static let trailingColumn: CGFloat = 28

    private func connectionTab(_ conn: Connection) -> some View {
        let isActive = conn.alias == (session.activeConnectionAlias ?? session.connections.first?.alias)
        return HStack(spacing: Theme.space2) {
            Circle().fill(conn.displayColor).frame(width: 7, height: 7)
            Text(conn.alias).font(isActive ? Theme.fontChromeStrong : Theme.fontChrome)
                .lineLimit(1).truncationMode(.tail)
            EngineBadge(engine: conn.engine)
            Button {
                removeConnection(conn)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(isActive ? Color(NSColor.textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            // The underline is the server's own color: at a glance, the active tab
            // says WHICH server, not merely that one is active.
            if isActive { Rectangle().fill(conn.displayColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .help("\(conn.name): \(session.selectedDatabase[conn.alias] ?? conn.database)")
        .onTapGesture { session.activeConnectionAlias = conn.alias }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.connection.\(conn.alias)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Database selector

    private func databaseSelector(_ conn: Connection) -> some View {
        Group {
            if let databases = session.availableDatabases[conn.alias], !databases.isEmpty {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { session.selectedDatabase[conn.alias] ?? databases.first ?? "" },
                        set: { newDb in
                            session.selectedDatabase[conn.alias] = newDb
                            session.sidebarTrees[conn.alias] = nil
                            Task { await session.showDatabase(newDb, for: conn, manager: manager) }
                        }
                    )) {
                        ForEach(databases, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("sidebar.database")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.vertical, 4)

                    // Refresh, as in Sequel Ace: ⇧⌘R re-reads the databases and the
                    // picked one's tables, ⌃⌘R the tables alone. For changes made
                    // outside the app; its own DDL refreshes the lists by itself.
                    Button { Task { await session.refreshDatabases(for: conn, manager: manager) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Refresh databases and tables (⇧⌘R); tables only: ⌃⌘R")
                    .accessibilityIdentifier("sidebar.refresh")
                    .background {
                        Button("") { Task { await session.refreshTables(for: conn, manager: manager) } }
                            .keyboardShortcut("r", modifiers: [.command, .control])
                            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                    }

                    if !conn.engine.isNative {
                        Menu {
                            if conn.engine == .mysql {
                                Button("Add Database…") { addDatabaseRequest = AddDatabaseRequest(conn: conn) }
                                    .disabled(conn.readOnly)
                                if let db = session.selectedDatabase[conn.alias], !db.isEmpty {
                                    Button("Delete Database “\(db)”…") { databaseToDelete = DatabaseToDelete(conn: conn, name: db) }
                                        .disabled(conn.readOnly)
                                }
                                Divider()
                            }
                            Button("Export database as SQL…") { exportDatabaseSQL(conn) }
                            if conn.engine == .mysql || conn.engine == .postgres {
                                Button("Import SQL file…") { importSQLFile(conn) }
                            }
                            if conn.engine == .mysql {
                                Button("Import CSV into new table…") { importCSVNewTable(conn) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)      // hide the extra dropdown chevron next to the ⋯
                        .fixedSize()
                        .frame(width: Self.trailingColumn)   // centred under the + above
                        .help("Database actions")
                        .accessibilityIdentifier("sidebar.databaseMenu")
                    }
                }
            } else {
                HStack {
                    ProgressView().scaleEffect(0.5)
                    Text("Loading databases…").font(.caption).foregroundColor(.secondary)
                }
                .padding(8)
                .onAppear { Task { await loadDatabases(for: conn) } }
            }
        }
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Filter box

    private func filterBox(for alias: String) -> some View {
        let binding = Binding(
            get: { session.tableFilter[alias] ?? "" },
            set: { session.tableFilter[alias] = $0 }
        )
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
            TextField("Filter tables…", text: binding)
                .accessibilityIdentifier("sidebar.filter")
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !(session.tableFilter[alias] ?? "").isEmpty {
                Button { session.tableFilter[alias] = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button { showCreateTable = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Create new table")
            .accessibilityIdentifier("sidebar.createTable")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(NSColor.textBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Table list

    private func tableList(_ conn: Connection) -> some View {
        let filter = session.tableFilter[conn.alias] ?? ""
        let allTables = session.sidebarTrees[conn.alias] ?? []
        let (tables, views) = TableListFilter.listed(allTables, filter: filter)
        let filtered = tables + views

        return List {
            if let problem = session.tableListError[conn.alias] {
                VStack(alignment: .leading, spacing: 6) {
                    Text(problem.message)
                        .font(.caption).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sidebar.tables.error")
                    Button("Try Again") {
                        Task { await session.showDatabase(problem.database, for: conn, manager: manager) }
                    }
                    .font(.caption)
                    .accessibilityIdentifier("sidebar.tables.retry")
                }
                .padding(.vertical, 4)
            }
            if session.sidebarTrees[conn.alias] == nil {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    Text("Loading tables…").font(.caption).foregroundColor(.secondary)
                }
                .accessibilityIdentifier("sidebar.tables.loading")
            } else if allTables.isEmpty, session.tableListError[conn.alias] == nil {
                Text("No tables in \(session.selectedDatabase[conn.alias] ?? conn.database)")
                    .font(.caption).foregroundColor(.secondary)
                    .accessibilityIdentifier("sidebar.tables.empty")
            }
            if !tables.isEmpty {
                Section("Tables") {
                    ForEach(tables) { table in tableRow(table, conn: conn) }
                }
            }
            if !views.isEmpty {
                Section("Views") {
                    ForEach(views) { table in tableRow(table, conn: conn) }
                }
            }
            if filtered.isEmpty && !allTables.isEmpty {
                Text("No tables match \"\(filter)\"")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .listStyle(.sidebar)
        // Match the app's content background instead of the darker translucent
        // sidebar material, so the tables list doesn't read as a dark block.
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.textBackgroundColor))
        .overlay(alignment: .bottom) {
            if !allTables.isEmpty {
                Text(Plural.part(filtered.count, of: allTables.count, "table"))
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .overlay(Divider(), alignment: .top)
            }
        }
    }

    private func tableRow(_ table: TableInfo, conn: Connection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: table.type == .view ? "eye" : "tablecells")
                .foregroundColor(conn.displayColor)
                .font(.caption)
            Text(table.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            if copiedTableId == table.id {
                Text("Copied!")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.accentColor).cornerRadius(3)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.table.\(table.name)")
        .padding(.vertical, 2)
        .background(
            session.selectedTable?.id == table.id
                ? Color.accentColor.opacity(0.12) : Color.clear
        )
        .onTapGesture {
            session.selectedTable = table
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(table.name, forType: .string)
            withAnimation { copiedTableId = table.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { if copiedTableId == table.id { copiedTableId = nil } }
            }
        })
        .contextMenu {
            Button("SELECT * FROM \(table.name)") { quickSelect(table, conn: conn) }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(table.name, forType: .string)
            }
            // MySQL/MariaDB have an authoritative SHOW CREATE TABLE, so the dump is exact.
            if conn.engine == .mysql {
                Button("Export as SQL…") { exportSQL(table, conn: conn) }
            }
            // CSV import uses the per-engine executeDDL INSERT path (MySQL/Postgres).
            if conn.engine == .mysql || conn.engine == .postgres {
                Button("Import CSV…") { importCSV(table, conn: conn) }
            }
            // Destructive DDL is exposed only for the engines whose executeDDL path
            // is proven (create/alter already use it). SQLite/ClickHouse users can
            // DROP from the Query tab.
            if conn.engine == .mysql || conn.engine == .postgres {
                Divider()
                Button("Rename Table…") { tableNameRequest = TableNameRequest(table: table, conn: conn, action: .rename) }
                Button("Duplicate Table…") { tableNameRequest = TableNameRequest(table: table, conn: conn, action: .duplicate) }
                if conn.engine == .mysql {
                    Menu("Table Maintenance") {
                        ForEach(TableMaintenance.allCases) { task in
                            Button("\(task.rawValue) Table") { Task { await runMaintenance(task, table, conn) } }
                                .disabled(conn.readOnly && task.changesTheTable)
                        }
                    }
                }
                Divider()
                Button("Truncate Table…") {
                    destructTarget = DestructTarget(table: table, conn: conn, action: .truncate)
                }
                Button("Drop Table…", role: .destructive) {
                    destructTarget = DestructTarget(table: table, conn: conn, action: .drop)
                }
            }
        }
    }

    // MARK: - Actions

    /// Table Maintenance: runs the task and shows the server's answer.
    private func runMaintenance(_ task: TableMaintenance, _ table: TableInfo, _ conn: Connection) async {
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        do {
            let answer = try await manager.queryEngine.tableMaintenance(task, alias: conn.alias, database: db, table: table.name)
            maintenanceAnswer = (title: "\(task.rawValue) “\(table.name)”", message: answer)
        } catch {
            destructError = QueryEngine.extractReason(from: error)
        }
    }

    private func quickSelect(_ table: TableInfo, conn: Connection) {
        session.activeFeatureTab = .query
        session.addTab()
        if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
            session.tabs[idx].sql   = "SELECT *\nFROM \"\(conn.alias)\".\"\(table.name)\"\nLIMIT 200"
            session.tabs[idx].title = table.name
        }
    }

    // MARK: - Table info panel (bottom of sidebar)

    private func tableInfoPanel(_ conn: Connection) -> some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("TABLE INFORMATION")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if tableInfoLoading {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if session.selectedTable != nil {
                    if tableInfo.isEmpty && !tableInfoLoading {
                        Text("Select a table to see info")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    } else {
                        ForEach(tableInfo, id: \.key) { row in
                            HStack(alignment: .top, spacing: 6) {
                                Text(row.key)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .frame(width: 62, alignment: .leading)
                                Text(row.value)
                                    .font(.system(size: 10))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                        }
                        .padding(.bottom, 6)
                    }
                } else {
                    Text("No table selected")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        }
        // Reload whenever the selected table changes. `.task(id:)` reliably re-runs
        // on every id change and auto-cancels the previous load — unlike the old
        // onChange-on-a-zero-frame-view trigger, which could miss a selection change
        // and leave the panel showing the previous table's size/row stats.
        .task(id: session.selectedTable?.id) {
            if let table = session.selectedTable {
                await loadTableInfo(for: table, conn: conn)
            }
        }
    }

    private func loadTableInfo(for table: TableInfo, conn: Connection) async {
        guard tableInfoForId != table.id else { return }
        tableInfoLoading = true
        tableInfoForId = table.id
        tableInfo = []

        let db = session.selectedDatabase[conn.alias] ?? conn.database
        // fetchTableMeta uses a dedicated meta connection + in-memory cache —
        // result is shared with Table Info panel so the query only runs once.
        if let row = try? await manager.queryEngine.fetchTableMeta(
            alias: conn.alias, database: db, table: table.name), !row.isEmpty {
            tableInfo = TableMeta.summary(row)
        }
        tableInfoLoading = false
    }

    // MARK: - Data loading

    private func loadDatabases(for conn: Connection) async {
        await session.loadDatabases(for: conn, manager: manager)
    }

    private func loadTables(for conn: Connection) async {
        await session.loadTables(for: conn, manager: manager)
    }

    private func connectOne(_ conn: Connection) async {
        guard !session.connections.contains(where: { $0.id == conn.id }),
              let password = manager.password(for: conn) else { return }
        do {
            try await manager.queryEngine.attach(conn, password: password)
            session.connections.append(conn)
            if session.activeConnectionAlias == nil { session.activeConnectionAlias = conn.alias }
            await loadDatabases(for: conn)
        } catch {}
    }

    /// After New Connection… closes: opens the connection it saved, if it saved one. It
    /// opened every saved favorite not yet open, Cancel included.
    private func attachNewConnections(savedBefore: Set<UUID>) async {
        manager.reloadSaved()
        for conn in manager.saved where !savedBefore.contains(conn.id) {
            await connectOne(conn)
        }
    }

    private func removeConnection(_ conn: Connection) {
        // Clear selected table if it belongs to this connection so panels don't
        // query a detached catalog (which causes a DuckDB crash).
        session.selectedTables[conn.alias] = nil
        // Clean up all per-connection state
        session.sidebarTrees.removeValue(forKey: conn.alias)
        session.availableDatabases.removeValue(forKey: conn.alias)
        session.selectedDatabase.removeValue(forKey: conn.alias)
        session.tableFilter.removeValue(forKey: conn.alias)

        // Switch active tab before disconnecting
        if session.activeConnectionAlias == conn.alias {
            session.activeConnectionAlias = session.connections.first(where: { $0.id != conn.id })?.alias
        }
        session.connections.removeAll { $0.id == conn.id }

        // Detach last — session state is already clean so no panel will race against it
        manager.disconnect(conn.alias)
    }
}

// MARK: - Destructive DDL target

private enum DestructAction { case drop, truncate }

private struct DestructTarget {
    let table: TableInfo
    let conn: Connection
    let action: DestructAction
}
