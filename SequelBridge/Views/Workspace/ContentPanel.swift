//  ContentPanel.swift — Paginated, filterable, editable row browser (Sequel Ace style)

import SwiftUI
import AppKit

struct ContentPanel: View {
    let table: TableInfo
    let conn: Connection
    @ObservedObject var session: WorkspaceSession
    @EnvironmentObject private var manager: ConnectionManager
    @EnvironmentObject private var appSettings: AppSettings

    @State private var rows:      [[String]] = []
    @State private var nullMask:  [[Bool]]  = []
    @State private var columns:   [String]   = []
    @State private var columnTypes: [String]  = []
    @State private var isLoading  = false
    @State private var error:     String?
    @State private var page       = 0
    @State private var totalRows: Int? = nil
    @State private var rowCountIsEstimate = false
    @State private var pkColumns: [String] = []
    /// Columns the server fills in itself (an auto-increment key): left out of a duplicate.
    @State private var generatedColumns: Set<String> = []
    /// What each empty field of the row sheet gets: a default, NULL, or the server's own value.
    @State private var emptyFieldHints: [String: String] = [:]
    /// The foreign keys of this table, by column: a cell of one leads to the row it points at.
    @State private var foreignKeyTargets: [String: ForeignKeyFollow.Target] = [:]
    @State private var selectedRowIndices: Set<Int> = []
    /// Bumped after each saved cell edit, so the grid redraws the changed row.
    @State private var editRevision = 0

    // Filter: a column, an operator and a value, as in Sequel Ace; or a typed WHERE.
    @State private var filterText    = ""
    @State private var appliedFilter = ""
    @State private var showFilter    = false
    @State private var typedWhere    = false
    @State private var ruleColumn    = ""
    @State private var ruleOp: ContentFilter.Op = .equals
    @State private var ruleValue     = ""
    @State private var ruleValue2    = ""

    // The row sheet: Add Row, or Duplicate Row (⌘D) starting from the selected row.
    @State private var rowSheet: RowSheetRequest?

    // Jump to a page, and the rows per page (⌘J), as in Sequel Ace.
    @State private var showPageOptions = false
    @State private var typedPage = ""

    // Server-side sort: clicking a column header reloads the page with ORDER BY,
    // so sorting spans the whole table, not just the page on screen.
    @State private var sortColumn: String? = nil
    @State private var sortAscending = true

    private var pageSize: Int { appSettings.contentPageSize }

    private var pageCount: Int? { ContentPaging.pageCount(total: totalRows, pageSize: pageSize) }

    private var pageLabel: String {
        guard let pageCount else { return "Page \(page + 1)" }
        return "Page \(page + 1) of \(rowCountIsEstimate ? "~" : "")\(pageCount)"
    }

    /// Whether reads can go through the fast server-side passthrough. Requires a
    /// MySQL/Postgres engine AND a database in the connection's DSN: `mysql_query`/
    /// `postgres_query` fetch the connection's default schema before running, so a
    /// connection saved without a database ("no database was provided in the connection
    /// string") falls back to the scanner, which addresses tables by full 3-part path.
    private var passthroughEligible: Bool {
        (conn.engine == .mysql || conn.engine == .postgres)
            && !manager.queryEngine.attachedDatabase(conn.alias).isEmpty
    }

    /// Cells are edited in place, like Sequel Ace: double-click, type, Return saves and
    /// Esc cancels. A cell that can't be edited (a read-only connection, ClickHouse, a
    /// table without a primary key) says why instead.
    private var cellEditing: CellEditing {
        let reason = CellEditability.reason(engine: conn.engine, readOnly: conn.readOnly,
                                            hasPrimaryKey: !pkColumns.isEmpty)
        return CellEditing(
            style: .inCell,
            reason: { _ in reason },
            revision: editRevision,
            save: { row, col, val in
                // `row` is the ORIGINAL result-row index (the grid translates any active
                // sort before calling back), so it addresses `rows` directly. `val == nil`
                // means "set NULL"; an empty string means the empty string.
                await self.handleCellEdit(rowIndex: row, colIndex: col, newValue: val)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(icon: "tablecells", title: table.name, subtitle: "Content", tint: conn.displayColor)
            Divider()
            controlsBar
            if showFilter { filterBar }
            noPKWarning

            if let err = error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultsTableView(
                    // Rebuilding the result for the grid must keep the column types —
                    // they drive numeric right-alignment and the type row in headers.
                    result: {
                        var r = QueryResult(columns: columns, rows: rows, executionTime: 0)
                        r.columnTypes = columnTypes
                        r.nullMask = nullMask
                        return r
                    }(),
                    tableName: table.name,
                    cellEditing: cellEditing,
                    foreignKeys: foreignKeyTargets.isEmpty ? nil : ForeignKeyLinks(
                        title: { col, value in
                            guard col < columns.count, let target = foreignKeyTargets[columns[col]] else { return nil }
                            let shown = value.count > 40 ? value.prefix(40) + "…" : Substring(value)
                            return target.columns.count == 1
                                ? "Go to \(target.table) where \(target.referenced[0]) = \(shown)"
                                : "Go to the \(target.table) row this key points at"
                        },
                        follow: { row, col in followForeignKey(row: row, col: col) }),
                    onSelectionChange: { selectedRowIndices = $0 },
                    onSortChange: { colIndex, ascending in
                        guard colIndex < columns.count else { return }
                        sortColumn = columns[colIndex]
                        sortAscending = ascending
                        page = 0
                        Task { await load() }
                    }
                )
                .id(table.id)   // reset per-table grid state (sort chevron, widths)
            }
        }
        .task(id: table.id) {
            page = 0; appliedFilter = ""; filterText = ""; totalRows = nil
            sortColumn = nil; sortAscending = true
            if let follow = session.contentFollows.removeValue(forKey: table.id) { apply(follow) }
            let db = session.selectedDatabase[conn.alias] ?? conn.database
            foreignKeyTargets = ForeignKeyFollow.targets(
                (try? await manager.queryEngine.fetchRelations(alias: conn.alias, database: db, table: table.name)) ?? [])
            await load()
        }
        .sheet(item: $rowSheet) { request in
            InsertRowSheet(
                title: request.title,
                columns: columns.isEmpty ? (session.sidebarTrees[conn.alias]?
                    .first(where: { $0.id == table.id })?.columns.map(\.name) ?? []) : columns,
                initial: request.initial,
                generated: generatedColumns,
                hints: emptyFieldHints
            ) { values in
                Task { await insertRow(values) }
            }
        }
    }

    // MARK: - Controls bar

    private var controlsBar: some View {
        HStack(spacing: 8) {
            // Pagination
            Button { if page > 0 { page -= 1; Task { await load() } } } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(page == 0 || isLoading)
            .help("Previous page")
            .accessibilityIdentifier("content.previousPage")

            Button {
                typedPage = "\(page + 1)"
                showPageOptions = true
            } label: {
                HStack(spacing: 3) {
                    Text(pageLabel).font(.caption).monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("j", modifiers: .command)
            .help("Jump to a page, or change the rows per page (⌘J)")
            .accessibilityIdentifier("content.page")
            .popover(isPresented: $showPageOptions, arrowEdge: .bottom) { pageOptions }

            Button { page += 1; Task { await load() } } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(rows.count < pageSize || isLoading)
            .help("Next page")
            .accessibilityIdentifier("content.nextPage")

            Divider().frame(height: 14)

            // Filter toggle
            Button {
                showFilter.toggle()
                if !showFilter && !appliedFilter.isEmpty {
                    appliedFilter = ""; filterText = ""; page = 0; Task { await load() }
                }
            } label: {
                Label("Filter", systemImage: appliedFilter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(appliedFilter.isEmpty ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .help("Show only the rows that match a rule")
            .accessibilityIdentifier("content.filterToggle")

            Spacer()

            if isLoading {
                ProgressView().scaleEffect(0.7)
            } else if let total = totalRows {
                Text(appliedFilter.isEmpty ? "\(rowCountIsEstimate ? "~" : "")\(Plural.count(total, "row")) in the table" : "\(Plural.count(total, "row")) match").font(.caption).monospacedDigit().foregroundColor(.secondary)
                    .help(rowCountIsEstimate ? "Estimated from table statistics (instant). Apply a filter for an exact count." : "")
            } else if !rows.isEmpty {
                Text(Plural.count(rows.count, "row")).font(.caption).monospacedDigit().foregroundColor(.secondary)
            }

            Divider().frame(height: 14)

            // Delete selected rows
            Button {
                Task { await deleteSelectedRows() }
            } label: {
                Image(systemName: "minus").modifier(RowButtonIcon())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedRowIndices.isEmpty || pkColumns.isEmpty || isLoading || conn.engine.isNative || conn.readOnly)
            .help(conn.readOnly ? "Read-only connection" : (pkColumns.isEmpty ? "Need primary key to delete rows" : "Delete selected row(s)"))
            .accessibilityIdentifier("content.deleteRows")

            // Duplicate the selected row (⌘D), as in Sequel Ace: the copy opens in the row
            // sheet, without what the server fills in itself.
            Button { duplicateSelectedRow() } label: {
                Image(systemName: "plus.square.on.square").modifier(RowButtonIcon())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: .command)
            .disabled(selectedRowIndices.count != 1 || isLoading || conn.engine.isNative || conn.readOnly)
            .help(conn.readOnly ? "Read-only connection" : (conn.engine.isNative ? "ClickHouse rows are inserted with INSERT statements in the Query tab" : "Duplicate the selected row (⌘D)"))
            .accessibilityIdentifier("content.duplicateRow")

            // Add new row
            Button {
                rowSheet = RowSheetRequest(title: "Add Row", initial: [:])
            } label: {
                Image(systemName: "plus").modifier(RowButtonIcon())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isLoading || conn.engine.isNative || conn.readOnly)
            .help(conn.readOnly ? "Read-only connection" : (conn.engine.isNative ? "ClickHouse rows are inserted with INSERT statements in the Query tab" : "Add new row"))
            .accessibilityIdentifier("content.addRow")

            // Reload
            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise").modifier(RowButtonIcon())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoading)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh the rows (⌘R)")
            .accessibilityIdentifier("content.refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Page options (⌘J)

    private var pageOptions: some View {
        PageOptions(typedPage: $typedPage, pageCount: pageCount, estimated: rowCountIsEstimate,
                    pageSize: Binding(get: { pageSize }, set: { changePageSize(to: $0) }),
                    go: jumpToTypedPage)
    }

    /// An estimated count can be short of the real one, so it doesn't cap the jump: a
    /// page past the end shows no rows.
    private func jumpToTypedPage() {
        guard let target = ContentPaging.page(typed: typedPage, pageCount: rowCountIsEstimate ? nil : pageCount) else { return }
        showPageOptions = false
        guard target != page else { return }
        page = target
        Task { await load() }
    }

    /// Keeps the first row on screen in view.
    private func changePageSize(to size: Int) {
        guard size != pageSize else { return }
        page = page * pageSize / size
        appSettings.contentPageSize = size
        Task { await load() }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            if typedWhere {
                Text("WHERE").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                TextField("status = 'active' AND created_at > '2025-01-01'", text: $filterText)
                    .accessibilityIdentifier("content.filter")
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .onSubmit { applyFilter() }
            } else {
                Picker("Column", selection: $ruleColumn) {
                    ForEach(columns, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("content.filterColumn")
                Picker("Operator", selection: $ruleOp) {
                    ForEach(ContentFilter.Op.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("content.filterOperator")
                if ruleOp.takesValue {
                    TextField(ruleOp == .isIn ? "a, b, c" : "value", text: $ruleValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyRule() }
                        .accessibilityIdentifier("content.filterValue")
                    if ruleOp == .between {
                        Text("and").foregroundColor(.secondary)
                        TextField("value", text: $ruleValue2)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyRule() }
                            .accessibilityIdentifier("content.filterValue2")
                    }
                } else {
                    Spacer()
                }
            }
            Button("Apply") { typedWhere ? applyFilter() : applyRule() }
                .accessibilityIdentifier("content.apply")
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(typedWhere ? filterText == appliedFilter : (ruleCondition == nil || ruleCondition == appliedFilter))
            if !appliedFilter.isEmpty {
                Button("Clear") {
                    filterText = ""; appliedFilter = ""; page = 0; Task { await load() }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .foregroundColor(.red)
            }
            // The rule, written out, can be adjusted by hand; a typed WHERE takes any condition.
            Button(typedWhere ? "Use a rule" : "Type WHERE") { typedWhere.toggle() }
                .buttonStyle(.borderless).controlSize(.small)
                .help(typedWhere ? "Pick a column, an operator and a value" : "Type the WHERE condition yourself")
                .accessibilityIdentifier("content.filterMode")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.04))
        .overlay(Divider(), alignment: .bottom)
        // A rule's column is kept until the columns are known: a followed key sets it first.
        .onAppear { if let first = columns.first, !columns.contains(ruleColumn) { ruleColumn = first } }
        .onChange(of: columns) { _, now in if let first = now.first, !now.contains(ruleColumn) { ruleColumn = first } }
    }

    /// The rule as the WHERE condition of whichever server reads the page; nil until it is whole.
    private var ruleCondition: String? {
        ContentFilter.condition(column: ruleColumn, op: ruleOp, value: ruleValue, value2: ruleValue2,
                                dialect: ContentFilter.dialect(engine: conn.engine, passthrough: passthroughEligible))
    }

    /// Applies the rule; the typed WHERE then shows it, to adjust by hand.
    private func applyRule() {
        guard !ruleColumn.isEmpty, let condition = ruleCondition else { return }
        filterText = condition
        appliedFilter = condition; page = 0; Task { await load() }
    }

    // MARK: - No-PK warning

    @ViewBuilder
    private var noPKWarning: some View {
        if pkColumns.isEmpty && !columns.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("No primary key: rows can't be edited or deleted here, since a row can't be told apart from its duplicates")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.08))
            .overlay(Divider(), alignment: .bottom)
        }
    }

    // MARK: - Data loading

    private func applyFilter() {
        appliedFilter = filterText; page = 0; Task { await load() }
    }

    private func load() async {
        isLoading = true; error = nil
        let db  = session.selectedDatabase[conn.alias] ?? conn.database
        // ClickHouse is native: its SQL addresses "db"."table" directly on its own
        // connection, not a three-part DuckDB path.
        let isNative = conn.engine.isNative
        // MySQL/Postgres read the page server-side via the passthrough, fully qualified
        // by "db.table" — so the server applies LIMIT/OFFSET/WHERE/ORDER BY instead of
        // DuckDB's scanner fetching the entire table. Correct for ANY database.
        let usePassthrough = passthroughEligible
        var baseSql = isNative
            ? "FROM \"\(db)\".\"\(table.name)\""
            : "FROM \"\(conn.alias)\".\"\(db)\".\"\(table.name)\""
        if !appliedFilter.isEmpty { baseSql += " WHERE \(appliedFilter)" }
        let orderSql = SQLBuilder.orderBy(column: sortColumn, ascending: sortAscending)
        let dataSql  = "SELECT * \(baseSql)\(orderSql) LIMIT \(pageSize) OFFSET \(page * pageSize)"
        let countSql = "SELECT COUNT(*) \(baseSql)"
        do {
            // 1) Fetch and show the page FIRST — never block the grid on a COUNT.
            //    Through DuckDB's scanner a COUNT(*) is a full table scan (~20s on a
            //    20M-row table), which also occupies the query actor and can make a
            //    concurrent connect appear to hang.
            let result: QueryResult
            if usePassthrough {
                result = try await manager.queryEngine.serverContentPage(
                    alias: conn.alias, database: db, table: table.name,
                    filter: appliedFilter, sortColumn: sortColumn, sortAscending: sortAscending,
                    limit: pageSize, offset: page * pageSize)
            } else if isNative {
                result = try await manager.queryEngine.clickhouseQuery(alias: conn.alias, sql: dataSql)
            } else {
                result = try await manager.queryEngine.query(dataSql, lane: .content)
            }
            columns = result.columns
            columnTypes = result.columnTypes
            rows    = result.rows
            nullMask = result.nullMask

            let cached = session.sidebarTrees[conn.alias]?.first(where: { $0.id == table.id })
            let colInfo: [ColumnInfo] = (cached?.columns.isEmpty == false)
                ? cached!.columns
                : ((try? await manager.queryEngine.fetchColumns(
                    alias: conn.alias, database: db, table: table.name)) ?? [])
            pkColumns = colInfo.filter { $0.isPrimaryKey }.map { $0.name }
            generatedColumns = ContentPaging.generatedColumns(colInfo, engine: conn.engine)
            emptyFieldHints = Dictionary(colInfo.map { ($0.name, ContentPaging.placeholder(for: $0, generated: generatedColumns.contains($0.name))) },
                                         uniquingKeysWith: { first, _ in first })
            isLoading = false

            // 2) Total row count, resolved AFTER the grid is on screen.
            await loadRowCount(baseSql: baseSql, countSql: countSql, db: db, isNative: isNative)
        } catch { isLoading = false; if !QueryEngine.isCancellation(error) { self.error = QueryEngine.extractReason(from: error) } }
    }

    /// Populates `totalRows`. For an unfiltered relational table it uses the
    /// instant row estimate from table metadata (SHOW TABLE STATUS) instead of a
    /// slow scanner COUNT(*). A filtered view needs an exact count, run without
    /// blocking the grid and ignored if the filter changes meanwhile.
    private func loadRowCount(baseSql: String, countSql: String, db: String, isNative: Bool) async {
        if appliedFilter.isEmpty && !isNative {
            if let meta = try? await manager.queryEngine.fetchTableMeta(
                    alias: conn.alias, database: db, table: table.name),
               meta.count > 6, let est = Int(meta[6]), est > 0 {
                totalRows = est; rowCountIsEstimate = true
            } else {
                totalRows = nil
            }
            return
        }
        rowCountIsEstimate = false
        totalRows = nil
        let filterAtStart = appliedFilter, pageAtStart = table.id
        let usePassthrough = passthroughEligible
        let n: Int?
        if usePassthrough {
            // Exact filtered count on the server — pushes the WHERE down instead of a
            // scanner full-table scan.
            n = try? await manager.queryEngine.serverContentCount(
                alias: conn.alias, database: db, table: table.name, filter: appliedFilter)
        } else {
            let cr = isNative
                ? try? await manager.queryEngine.clickhouseQuery(alias: conn.alias, sql: countSql)
                : try? await manager.queryEngine.query(countSql, lane: .content)
            n = cr?.rows.first?.first.flatMap { Int($0) }
        }
        // Discard if the user moved on to a different filter/table while counting.
        guard filterAtStart == appliedFilter, pageAtStart == table.id else { return }
        if let n { totalRows = n }
    }

    // MARK: - Row operations

    private func deleteSelectedRows() async {
        guard !pkColumns.isEmpty else { return }
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        let sortedIndices = selectedRowIndices.sorted().reversed()
        var opError: String? = nil
        for idx in sortedIndices {
            guard idx < rows.count else { continue }
            let key = primaryKeyValues(rowIndex: idx)
            guard !key.isEmpty else { continue }
            let sql = SQLBuilder.delete(alias: conn.alias, database: db, table: table.name, primaryKey: key)
            do {
                try await manager.queryEngine.executeWrite(sql, alias: conn.alias)
            } catch {
                if QueryEngine.isCancellation(error) { break }
                opError = QueryEngine.extractReason(from: error)
                break
            }
        }
        selectedRowIndices = []
        await load()
        // load() clears `error` on entry, so re-apply the operation error afterwards —
        // otherwise a failed delete would vanish silently while the grid refreshed.
        if let opError { self.error = opError }
    }

    /// Opens the row a key's cell points at: the referenced table's Content tab, filtered to
    /// it. A key of a table to itself filters this tab.
    private func followForeignKey(row: Int, col: Int) {
        guard col < columns.count, row < rows.count, let target = foreignKeyTargets[columns[col]] else { return }
        var values: [String: String] = [:]
        for (i, name) in columns.enumerated() where i < rows[row].count {
            let isNull = row < nullMask.count && i < nullMask[row].count && nullMask[row][i]
            if !isNull { values[name] = rows[row][i] }
        }
        let dialect = ContentFilter.dialect(engine: conn.engine, passthrough: passthroughEligible)
        guard let condition = ForeignKeyFollow.condition(target, values: values, dialect: dialect) else { return }
        let follow = target.columns.count == 1
            ? ContentFollow(condition: condition, column: target.referenced[0], value: values[target.columns[0]])
            : ContentFollow(condition: condition)
        if target.table == table.name { apply(follow); page = 0; Task { await load() }; return }
        guard let referenced = session.sidebarTrees[conn.alias]?.first(where: { $0.name == target.table }) else {
            let alert = NSAlert()
            alert.messageText = "\(target.table) isn't in this database's tables"
            alert.informativeText = "Pick the database it is in, then open it from the left panel."
            alert.runModal()
            return
        }
        session.contentFollows[referenced.id] = follow
        session.selectedTable = referenced
    }

    /// Shows the filter a followed key asks for, as a rule when it has one column.
    private func apply(_ follow: ContentFollow) {
        showFilter = true
        if let column = follow.column, let value = follow.value {
            typedWhere = false; ruleColumn = column; ruleOp = .equals; ruleValue = value
        } else {
            typedWhere = true
        }
        filterText = follow.condition
        appliedFilter = follow.condition
    }

    private func duplicateSelectedRow() {
        guard selectedRowIndices.count == 1, let i = selectedRowIndices.first, i < rows.count else { return }
        rowSheet = RowSheetRequest(
            title: "Duplicate Row",
            initial: ContentPaging.duplicateValues(row: rows[i], nulls: i < nullMask.count ? nullMask[i] : [],
                                                   columns: columns, generated: generatedColumns))
    }

    private func insertRow(_ values: [String: String]) async {
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        let sql = SQLBuilder.insert(alias: conn.alias, database: db, table: table.name, values: values)
        var opError: String? = nil
        do {
            try await manager.queryEngine.executeWrite(sql, alias: conn.alias)
        } catch {
            if !QueryEngine.isCancellation(error) { opError = QueryEngine.extractReason(from: error) }
        }
        await load()
        if let opError { self.error = opError }   // survive load()'s error reset
    }

    /// Saves one cell. Returns nil on success, else the reason, which the popup shows:
    /// a refused or failed write must never look like it went through.
    private func handleCellEdit(rowIndex: Int, colIndex: Int, newValue: String?) async -> String? {
        if let reason = CellEditability.reason(engine: conn.engine, readOnly: conn.readOnly,
                                               hasPrimaryKey: !pkColumns.isEmpty) { return reason }
        guard colIndex < columns.count, rowIndex < rows.count else { return "That row is no longer on this page." }
        let db  = session.selectedDatabase[conn.alias] ?? conn.database
        let col = columns[colIndex]
        let key = primaryKeyValues(rowIndex: rowIndex)
        guard !key.isEmpty else { return "The row's primary key isn't on this page, so it can't be updated." }
        let sql = SQLBuilder.update(alias: conn.alias, database: db, table: table.name,
                                    column: col, newValue: newValue, primaryKey: key)
        do {
            try await manager.queryEngine.executeWrite(sql, alias: conn.alias)
        } catch {
            return QueryEngine.extractReason(from: error)
        }
        // Keep display rows and the null mask in sync with the write: nil -> NULL,
        // any string (including "") -> that literal value. The revision redraws the row.
        if rowIndex < rows.count && colIndex < rows[rowIndex].count {
            rows[rowIndex][colIndex] = newValue ?? "NULL"
            if rowIndex < nullMask.count && colIndex < nullMask[rowIndex].count {
                nullMask[rowIndex][colIndex] = (newValue == nil)
            }
        }
        editRevision += 1
        return nil
    }

    /// Pairs each primary-key column with its value for a WHERE clause. A NULL cell
    /// (per the null mask) yields nil so the clause uses `IS NULL`, and a genuine
    /// "NULL" string is matched as the literal value.
    private func primaryKeyValues(rowIndex: Int) -> [(column: String, value: String?)] {
        guard rowIndex < rows.count else { return [] }
        let row = rows[rowIndex]
        return pkColumns.compactMap { pk in
            guard let ci = columns.firstIndex(of: pk), ci < row.count else { return nil }
            let isNull = rowIndex < nullMask.count && ci < nullMask[rowIndex].count && nullMask[rowIndex][ci]
            return (column: pk, value: isNull ? nil : row[ci])
        }
    }
}

// MARK: - Row buttons

/// One size for the icons of the row buttons (−, duplicate, +, refresh): a taller symbol,
/// arrow.clockwise, made its button taller than the others.
private struct RowButtonIcon: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 11, weight: .medium)).frame(width: 14, height: 14)
    }
}

// MARK: - Page options (⌘J)

/// A page to jump to, and the rows a page shows. Its own view, reading the typed page
/// itself: built inside the panel, Go stayed off whatever was typed.
private struct PageOptions: View {
    @Binding var typedPage: String
    let pageCount: Int?
    let estimated: Bool
    @Binding var pageSize: Int
    let go: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Page")
                TextField("", text: $typedPage)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .onSubmit(go)
                    .accessibilityIdentifier("content.pageField")
                if let pageCount {
                    Text("of \(estimated ? "~" : "")\(pageCount)").foregroundColor(.secondary).monospacedDigit()
                }
                Button("Go", action: go)
                    .disabled(ContentPaging.page(typed: typedPage, pageCount: nil) == nil)
                    .accessibilityIdentifier("content.pageGo")
            }
            Divider()
            HStack(spacing: 6) {
                Text("Rows per page")
                Picker("Rows per page", selection: $pageSize) {
                    ForEach(ContentPaging.pageSizes, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("content.pageSize")
            }
        }
        .font(.system(size: 12))
        .padding(14)
    }
}

// MARK: - Row sheet

private struct RowSheetRequest: Identifiable {
    let id = UUID()
    let title: String
    let initial: [String: String]
}

private struct InsertRowSheet: View {
    var title = "Add Row"
    let columns: [String]
    /// The values the fields start with: a duplicated row's.
    var initial: [String: String] = [:]
    /// Columns the server fills in itself, left empty.
    var generated: Set<String> = []
    /// What an empty field gets, by column.
    var hints: [String: String] = [:]
    let onInsert: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title2).bold()
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(columns, id: \.self) { col in
                        HStack(spacing: 8) {
                            Text(col)
                                .font(Theme.mono(12))
                                .frame(width: 160, alignment: .trailing)
                                .foregroundColor(.secondary)
                            TextField(hints[col] ?? (generated.contains(col) ? "set by the server" : "value or NULL"), text: Binding(
                                get: { values[col] ?? "" },
                                set: { values[col] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .accessibilityIdentifier("rowSheet.field.\(col)")
                        }
                    }
                }
                .padding(20)
            }

            Text("An empty field gets what its hint says. Type NULL for NULL.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 10)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Insert") {
                    onInsert(values.filter { !$0.value.isEmpty })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(values.values.allSatisfy { $0.isEmpty })
                .accessibilityIdentifier("rowSheet.insert")
            }
            .padding(20)
        }
        .frame(width: 440, height: min(CGFloat(columns.count) * 44 + 140, 560))
        .onAppear {
            values = Dictionary(uniqueKeysWithValues: columns.map { ($0, initial[$0] ?? "") })
        }
    }
}
