//  ContentPanel.swift — Paginated, filterable, editable row browser (Sequel Ace style)

import SwiftUI
import AppKit

struct ContentPanel: View {
    let table: TableInfo
    let conn: Connection
    @ObservedObject var session: WorkspaceSession
    @EnvironmentObject private var manager: ConnectionManager

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
    @State private var selectedRowIndices: Set<Int> = []
    /// Bumped after each saved cell edit, so the grid redraws the changed row.
    @State private var editRevision = 0

    // Filter
    @State private var filterText    = ""
    @State private var appliedFilter = ""
    @State private var showFilter    = false

    // Insert row sheet
    @State private var showInsertSheet = false

    // Server-side sort: clicking a column header reloads the page with ORDER BY,
    // so sorting spans the whole table, not just the 200 rows currently on screen.
    @State private var sortColumn: String? = nil
    @State private var sortAscending = true

    private let pageSize = 200

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
            await load()
        }
        .sheet(isPresented: $showInsertSheet) {
            InsertRowSheet(
                columns: columns.isEmpty ? (session.sidebarTrees[conn.alias]?
                    .first(where: { $0.id == table.id })?.columns.map(\.name) ?? []) : columns
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
            }.disabled(page == 0 || isLoading)

            Text(totalRows.map { "Page \(page + 1) of \(rowCountIsEstimate ? "~" : "")\(max(1, Int(ceil(Double($0) / Double(pageSize)))))" } ?? "Page \(page + 1)")
                .font(.caption).monospacedDigit()

            Button { page += 1; Task { await load() } } label: {
                Image(systemName: "chevron.right")
            }.disabled(rows.count < pageSize || isLoading)

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

            Spacer()

            if isLoading {
                ProgressView().scaleEffect(0.7)
            } else if let total = totalRows {
                Text("\(rowCountIsEstimate ? "~" : "")\(total) total rows").font(.caption).monospacedDigit().foregroundColor(.secondary)
                    .help(rowCountIsEstimate ? "Estimated from table statistics (instant). Apply a filter for an exact count." : "")
            } else if !rows.isEmpty {
                Text("\(rows.count) rows").font(.caption).monospacedDigit().foregroundColor(.secondary)
            }

            Divider().frame(height: 14)

            // Delete selected rows
            Button {
                Task { await deleteSelectedRows() }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedRowIndices.isEmpty || pkColumns.isEmpty || isLoading || conn.engine.isNative || conn.readOnly)
            .help(conn.readOnly ? "Read-only connection" : (pkColumns.isEmpty ? "Need primary key to delete rows" : "Delete selected row(s)"))

            // Add new row
            Button {
                showInsertSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isLoading || conn.engine.isNative || conn.readOnly)
            .help(conn.readOnly ? "Read-only connection" : (conn.engine.isNative ? "ClickHouse rows are inserted with INSERT statements in the Query tab" : "Add new row"))

            // Reload
            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Text("WHERE").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            TextField("status = 'active' AND created_at > '2025-01-01'", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
                .onSubmit { applyFilter() }
            Button("Apply") { applyFilter() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(filterText == appliedFilter)
            if !appliedFilter.isEmpty {
                Button("Clear") {
                    filterText = ""; appliedFilter = ""; page = 0; Task { await load() }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.04))
        .overlay(Divider(), alignment: .bottom)
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

// MARK: - Insert row sheet

private struct InsertRowSheet: View {
    let columns: [String]
    let onInsert: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Insert Row").font(.title2).bold()
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
                            TextField("value or NULL", text: Binding(
                                get: { values[col] ?? "" },
                                set: { values[col] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        }
                    }
                }
                .padding(20)
            }

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
            }
            .padding(20)
        }
        .frame(width: 440, height: min(CGFloat(columns.count) * 44 + 140, 560))
        .onAppear {
            values = Dictionary(uniqueKeysWithValues: columns.map { ($0, "") })
        }
    }
}
