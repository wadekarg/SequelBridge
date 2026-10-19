//
//  QueryPanelView.swift
//  SequelBridge
//

import SwiftUI

struct QueryPanelView: View {
    @EnvironmentObject private var manager: ConnectionManager
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var session: WorkspaceSession

    @State private var runningTask: Task<Void, Never>?
    @State private var elapsed: TimeInterval = 0
    @State private var elapsedTimer: Timer?
    /// Started when Run is pressed; the toolbar counter and the result's executionTime
    /// (the status bar's query time) both come from it, so they always agree.
    @State private var runClock = RunClock()
    @State private var selectedSQL: String = ""  // tracks text selection in the editor
    @State private var showSaveSheet = false
    @State private var saveName = ""

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
                // How queries are written here — one line, expandable (see QueryConventions).
                if !session.connections.isEmpty {
                    QueryConventionsStrip(conventions: QueryConventions.make(for: session.connections))
                }

                VSplitView {
                    SQLEditorView(
                        text: Binding(
                            get: { session.tabs[idx].sql },
                            set: { session.tabs[idx].sql = $0 }
                        ),
                        selectedSQL: $selectedSQL,
                        fontSize: appSettings.editorFontSize,
                        onRun: { Task { await runQuery(tabIndex: idx) } },
                        completionItems: completionItems
                    )
                    .frame(minHeight: 80)

                    ResultsPanelView(
                        tab: session.tabs[idx],
                        writeCell: { sql, alias in try await manager.queryEngine.executeWrite(sql, alias: alias) },
                        applyCell: { [tabID = session.tabs[idx].id] row, col, value in
                            applySavedCell(tabID: tabID, row: row, column: col, value: value)
                        })
                        .frame(minHeight: 80)
                }
            }
        }
        .onDisappear {
            // Tear down the run-loop Timer and any in-flight/auto-cancel tasks when
            // the panel goes away (workspace closed, tab view recreated). Otherwise the
            // Timer keeps firing on a stale @State and the query task/watchdog leak.
            runningTask?.cancel()
            runningTask = nil
            stopElapsedTimer()
        }
        .sheet(isPresented: $showSaveSheet) {
            SaveQuerySheet(name: $saveName) { name in
                session.saveQuery(name: name, sql: session.activeTab?.sql ?? "")
            }
        }
    }

    // MARK: - Saved queries

    private var savedQueriesMenu: some View {
        Menu {
            savedQueriesMenuContent
        } label: {
            Image(systemName: "bookmark")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Saved queries")
    }

    @ViewBuilder
    private var savedQueriesMenuContent: some View {
        Button("Save Current Query…") {
            saveName = session.activeTab?.title ?? ""
            showSaveSheet = true
        }
        .disabled((session.activeTab?.sql ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        savedSection
        recentSection
    }

    @ViewBuilder
    private var savedSection: some View {
        if !session.savedQueries.isEmpty {
            Divider()
            ForEach(session.savedQueries) { q in
                savedQueryItem(q)
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let recents = ConsoleExporter.recent(session.consoleLog, limit: 10)
        if !recents.isEmpty {
            Divider()
            Section("Recent") {
                ForEach(recents, id: \.self) { sql in
                    Button(Self.recentLabel(sql)) { loadSQL(sql) }
                }
            }
        }
    }

    /// Loads a raw statement into the current tab (creating one if needed).
    private func loadSQL(_ sql: String) {
        if session.tabs.firstIndex(where: { $0.id == session.activeTabId }) == nil {
            session.addTab()
        }
        if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
            session.tabs[idx].sql = sql
        }
    }

    /// One-line, length-capped label for a recent statement in the menu.
    private static func recentLabel(_ sql: String) -> String {
        let flat = sql.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return flat.count > 50 ? String(flat.prefix(50)) + "…" : flat
    }

    @ViewBuilder
    private func savedQueryItem(_ q: SavedQuery) -> some View {
        Menu(q.name) {
            Button("Load into current tab") { loadSaved(q) }
            Button("Delete", role: .destructive) { session.deleteSavedQuery(q.id) }
        }
    }

    private func loadSaved(_ q: SavedQuery) {
        if session.tabs.firstIndex(where: { $0.id == session.activeTabId }) == nil {
            session.addTab()
        }
        if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
            session.tabs[idx].sql = q.sql
            session.tabs[idx].title = q.name
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(session.tabs) { tab in
                        tabButton(tab)
                        Divider().frame(height: 32)
                    }
                    Button { session.addTab() } label: {
                        Image(systemName: "plus").padding(.horizontal, 12).frame(height: 32)
                    }
                    .buttonStyle(.plain)
                    .help("New tab (⌘T)")
                    .accessibilityIdentifier("query.newTab")
                    .keyboardShortcut("t", modifiers: .command)
                }
            }
            .frame(height: 32)
            Spacer()
            HStack(spacing: 6) {
                savedQueriesMenu
                if session.activeTab?.isRunning == true || session.activeTab?.isStreaming == true {
                    // Elapsed time counter
                    Text(RunClock.tickerText(elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)

                    // Cancel button
                    Button {
                        cancelQuery()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button {
                        if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
                            session.tabs[idx].sql = SQLFormatter.format(session.tabs[idx].sql)
                        }
                    } label: {
                        Label("Format", systemImage: "text.alignleft")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("f", modifiers: [.control, .option])
                    .help("Reformat the query for readability (⌃⌥F)")

                    Button {
                        if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
                            Task { await explainQuery(tabIndex: idx) }
                        }
                    } label: {
                        Label("Explain", systemImage: "list.bullet.rectangle")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show the server's native query plan (EXPLAIN)")

                    Text("⌘↵").font(.caption2).foregroundColor(.secondary)
                    Button {
                        if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
                            Task { await runQuery(tabIndex: idx) }
                        }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        // Off the window's top edge: on macOS 15 a scroll view touching it grows up under
        // the toolbar, and its tabs and + draw in place but stop taking clicks.
        .padding(.top, 1)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func tabButton(_ tab: QueryTab) -> some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
            if session.tabs.count > 1 {
                Button {
                    session.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut("w", modifiers: .command)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(tab.id == session.activeTabId ?
            Color(NSColor.textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if tab.id == session.activeTabId {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())          // the whole tab, not only its title, takes the click
        .onTapGesture { session.activeTabId = tab.id }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query.tab")
        .accessibilityAddTraits(tab.id == session.activeTabId ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Autocomplete items

    private var completionItems: [String] {
        var items: [String] = []
        for conn in session.connections {
            items.append(conn.alias)
            if let tables = session.sidebarTrees[conn.alias] {
                for table in tables {
                    items.append(table.name)
                    items.append(contentsOf: table.columns.map(\.name))
                }
            }
            if let dbs = session.availableDatabases[conn.alias] {
                items.append(contentsOf: dbs)
            }
        }
        return items
    }

    // MARK: - Execution plans
    //
    // What runQuery decides before the task starts, one per shape of multi-server query.

    // Cross-server semi-join reduction: run the subquery on its server, inline its
    // values, push the outer query to its server (see SQLBuilder.detectSemiJoin).
    struct SemiJoinExec {
        let reduction: SQLBuilder.SemiJoin
        let subPassthrough: (alias: String, serverSQL: String)?   // run subquery server-side when eligible
        let subScannerSQL: String                                 // otherwise via the scanner
        let fallbackSQL: String                                   // whole query on the scanner
    }
    // Cross-server inner join: the two sides stream from their servers through the
    // passthrough and DuckDB joins them on arrival, the bigger side reduced to the
    // smaller side's join keys when that is selective (see QueryEngine.crossJoinPlan).
    // Provably equivalent for an inner join; a whole-query scanner fallback always
    // backs it.
    struct CrossJoinExec {
        let reduction: SQLBuilder.CrossJoin
        let fallbackSQL: String          // whole query on the scanner
    }
    // ClickHouse bridge: a two-table join with ONE ClickHouse side. ClickHouse is
    // native HTTP and can't be ATTACH'd, so its side is copied into a DuckDB TEMP
    // table and the join runs on DuckDB (see QueryEngine.clickHouseJoinPlan).
    struct ClickHouseBridgeExec {
        let reduction: SQLBuilder.CrossJoin
    }
    // Cross-engine scanner fallback: a multi-server query no reduction covers. Each
    // remote (MySQL/Postgres) table is materialized via the fast passthrough into a
    // DuckDB TEMP table, then the scanner joins locally — the raw ATTACH scan of a
    // remote table is ~130x slower over a VPN (see SQLBuilder.planFallback). The
    // plain scanner stays the backstop if materialization can't proceed.
    struct FallbackMaterializeExec {
        let materializations: [SQLBuilder.FallbackPlan.Materialization]
        let dbByAlias: [String: String]   // resolved database per remote alias
        let materializedSQL: String       // rewritten + expanded, reads the temp tables
        let scannerSQL: String            // whole-query scanner fallback
    }

    // MARK: - Query execution

    /// The database DuckDB's catalog path wants between `alias` and a table: the
    /// sidebar's selection, else Postgres's "public" schema, SQLite's "main", or the
    /// database the connection is attached with. Also what the metadata lookups and
    /// passthrough fetches of a cross-server query are qualified with.
    private func catalogDatabase(for alias: String) -> String {
        if let picked = session.selectedDatabase[alias] { return picked }
        switch session.connections.first(where: { $0.alias == alias })?.engine {
        case .postgres: return "public"
        case .sqlite:   return "main"
        default:        return manager.queryEngine.attachedDatabase(alias)
        }
    }

    /// Rewrites alias.table → "alias"."selected_db"."table" for every connected server.
    /// O(n) per connection — no string allocations inside the character loop.
    private func expandAliases(in sql: String) -> (expanded: String, error: String?) {
        var result = sql
        for conn in session.connections {
            // The inserted middle part is what DuckDB expects between alias and
            // table: MySQL's database, Postgres's schema, SQLite's single "main".
            // The DSN database is only a sensible fallback for MySQL — a Postgres
            // DSN names the database, but the catalog path wants the schema.
            let fallback: String
            switch conn.engine {
            case .mysql:    fallback = conn.database
            case .postgres: fallback = "public"
            case .sqlite:   fallback = "main"
            case .clickhouse:
                // Native connections are outside DuckDB's catalog — they cannot be
                // combined with other servers in one statement.
                if sql.range(of: conn.alias, options: .caseInsensitive) != nil {
                    return (sql, "\(conn.alias) is a ClickHouse connection — it runs on its own and can't be joined with other servers in one query. Connect only \(conn.alias) to query it.")
                }
                continue
            }
            let db = session.selectedDatabase[conn.alias] ?? fallback
            if db.isEmpty {
                if sql.range(of: conn.alias, options: .caseInsensitive) != nil {
                    return (sql, "Select a database for '\(conn.alias)' in the sidebar before running.")
                }
                continue
            }

            // Pre-compute lowercase alias chars once — avoids per-position allocations
            let aliasLower  = Array(conn.alias.lowercased())
            let aliasLen    = aliasLower.count
            let chars       = Array(result)   // work on a flat array for O(1) index access
            var out         = [Character]()
            out.reserveCapacity(chars.count + 64)
            var i = 0

            while i < chars.count {
                // Skip double-quoted identifiers verbatim
                if chars[i] == "\"" {
                    out.append(chars[i]); i += 1
                    while i < chars.count {
                        out.append(chars[i])
                        if chars[i] == "\"" { i += 1; break }
                        i += 1
                    }
                    continue
                }
                // Skip single-quoted string literals verbatim
                if chars[i] == "'" {
                    out.append(chars[i]); i += 1
                    while i < chars.count {
                        out.append(chars[i])
                        if chars[i] == "'" { i += 1; break }
                        i += 1
                    }
                    continue
                }
                // Fast O(1) first-char check before trying full alias match
                if chars[i].lowercased().first == aliasLower[0] {
                    let prevIsWord = i > 0 && (chars[i-1].isLetter || chars[i-1].isNumber || chars[i-1] == "_")
                    if !prevIsWord && i + aliasLen < chars.count {
                        // Try full alias match (case-insensitive)
                        var matched = true
                        for k in 0..<aliasLen {
                            if chars[i+k].lowercased().first != aliasLower[k] { matched = false; break }
                        }
                        // Must be followed by "." and then a word character (table name)
                        if matched && chars[i + aliasLen] == "." {
                            var j = i + aliasLen + 1
                            let tableStart = j
                            while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") {
                                j += 1
                            }
                            let tableName = String(chars[tableStart..<j])
                            // Only expand 2-part (not already 3-part — next char is not another ".")
                            if !tableName.isEmpty && (j == chars.count || chars[j] != ".") {
                                out += Array("\"\(conn.alias)\".\"\(db)\".\"\(tableName)\"")
                                i = j
                                continue
                            }
                        }
                    }
                }
                out.append(chars[i]); i += 1
            }
            result = String(out)
        }
        return (result, nil)
    }

    private func runQuery(tabIndex: Int) async {
        guard tabIndex < session.tabs.count else { return }
        // Address the tab by its stable id, not its position: a tab closed mid-query
        // shifts every later index, so using tabIndex across an await would write the
        // result into the wrong tab or crash with an out-of-range access.
        let tabID = session.tabs[tabIndex].id
        func setTab(_ body: (inout QueryTab) -> Void) {
            guard let i = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            body(&session.tabs[i])
        }
        let rawSQL = selectedSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSQL = rawSQL.isEmpty
            ? session.tabs[tabIndex].sql.trimmingCharacters(in: .whitespacesAndNewlines)
            : rawSQL
        guard !baseSQL.isEmpty else { return }

        // A typed `EXPLAIN …` takes the Explain button's path — server-native EXPLAIN,
        // on the native client for MySQL — when its one target is MySQL/MariaDB or
        // PostgreSQL. Through the passthrough it fails on MariaDB: mysql_query prepares
        // every statement to learn its result types, and EXPLAIN isn't preparable
        // ("Failed to fetch return types"). Other engines keep DuckDB's own EXPLAIN.
        if let inner = SQLBuilder.strippedExplain(baseSQL),
           let target = explainTarget(for: baseSQL).conn,
           target.engine == .mysql || target.engine == .postgres {
            await explainQuery(tabIndex: tabIndex, sql: inner)
            return
        }

        // Safe mode: refuse to run a write against a read-only connection.
        if !SQLBuilder.isReadOnly(baseSQL),
           let ro = session.connections.first(where: { manager.queryEngine.isReadOnly($0.alias) }) {
            setTab { $0.error = SequelBridgeError.readOnly(ro.name).errorDescription }
            return
        }

        // `USE db` picks that database at the top of the left panel, the way Sequel Ace's
        // database menu follows it, and the statements after it run there.
        if let db = QueryEffects.soleUse(baseSQL),
           let conn = SQLBuilder.soleTarget(of: baseSQL, connections: session.connections,
                                            active: session.activeConnectionAlias),
           conn.engine == .mysql {
            await runUse(baseSQL, database: db, on: conn, tabID: tabID)
            return
        }

        // Resolve SQL before starting the task.
        // Single server: record alias+db so the task can await the USE before querying.
        // Multi server: expand alias.table → "alias"."db"."table" now (no USE needed).
        struct ContextToSet { let alias: String; let db: String }
        var pendingContext: ContextToSet? = nil
        var semiJoin: SemiJoinExec? = nil
        var crossJoin: CrossJoinExec? = nil
        var clickhouseBridge: ClickHouseBridgeExec? = nil
        var fallbackMaterialize: FallbackMaterializeExec? = nil
        let sql: String

        var clickhouseAlias: String? = nil
        // Fast path: a read that targets ONE MySQL/Postgres server is pushed to that
        // server via the passthrough (server applies LIMIT/WHERE/indexes) instead of
        // DuckDB's scanner fetching the whole table. This applies whether that server
        // is the only one connected or one of several — a query that touches a single
        // server never needs the cross-engine scanner. See QueryEngine's "Server
        // passthrough" note. Returns nil (→ scanner path) unless every condition holds:
        // MySQL/PG, a row-returning statement, and the selected database is the
        // connection's DSN default (the passthrough pool ignores server-side USE, so
        // only then do unqualified names resolve correctly on the server).
        var passthrough: (alias: String, serverSQL: String)? = nil
        func passthroughIfEligible(_ conn: Connection) -> (alias: String, serverSQL: String)? {
            // Use the database the connection is actually ATTACHED with (the DSN default),
            // which the sidebar keeps in sync by re-attaching when you pick a database.
            // mysql_query/postgres_query fetch that default schema first, so it must be
            // non-empty and match the selected database; otherwise fall back to the
            // scanner (3-part path), which needs no default schema.
            let dsn = manager.queryEngine.attachedDatabase(conn.alias)
            let db = session.selectedDatabase[conn.alias] ?? dsn
            guard manager.queryEngine.hasServerPassthrough(conn.alias),
                  !dsn.isEmpty,
                  db == dsn,
                  SQLBuilder.isRowReturning(baseSQL) else { return nil }
            return (conn.alias, SQLBuilder.stripAliasPrefix(baseSQL, alias: conn.alias))
        }

        let referenced = session.connections.filter { SQLBuilder.referencesAlias(baseSQL, $0.alias) }
        if session.connections.count <= 1 || referenced.isEmpty {
            // One connection, or a statement that names no server (SHOW TABLES, SELECT *
            // FROM orders): it runs on the connection picked at the top of the left panel.
            if let conn = SQLBuilder.soleTarget(of: baseSQL, connections: session.connections,
                                                active: session.activeConnectionAlias) {
                if conn.engine == .clickhouse {
                    clickhouseAlias = conn.alias
                } else if let pt = passthroughIfEligible(conn) {
                    passthrough = pt
                } else {
                    // Writes/DDL and non-default databases: the scanner path resolves
                    // names via DuckDB's USE context.
                    let db = session.selectedDatabase[conn.alias] ?? conn.database
                    pendingContext = ContextToSet(alias: conn.alias, db: db)
                }
            }
            sql = baseSQL
        } else {
            if referenced.count == 1, referenced[0].engine == .clickhouse {
                // Only the ClickHouse server is named. It runs on its native client,
                // outside DuckDB's catalog, so neither the passthrough nor the scanner
                // can take it; the alias becomes the database the sidebar picked.
                clickhouseAlias = referenced[0].alias
                sql = SQLBuilder.clickhouseSoleServerSQL(baseSQL, alias: referenced[0].alias,
                                                         database: catalogDatabase(for: referenced[0].alias))
            } else if referenced.count == 1, let pt = passthroughIfEligible(referenced[0]) {
                // Only one server is referenced, so there is nothing to join across —
                // push it to that server for the same speed as a lone connection.
                passthrough = pt
                sql = baseSQL
            } else {
                // Two or more servers. Prefer a semi-join reduction — run the subquery
                // on its server, inline its values, push the outer query to its server —
                // over the cross-server scanner, which would drag whole tables to the
                // client. Requires the OUTER server to be passthrough-capable (MySQL/PG
                // with a database); the subquery (the small side) runs via the scanner.
                let connAliases = session.connections.map(\.alias)
                if let sj = SQLBuilder.detectSemiJoin(baseSQL, aliases: connAliases),
                   session.connections.contains(where: { $0.alias == sj.outerAlias }),
                   manager.queryEngine.hasServerPassthrough(sj.outerAlias),
                   !manager.queryEngine.attachedDatabase(sj.outerAlias).isEmpty {
                    let (subExpanded, subErr) = expandAliases(in: sj.subquery)
                    let (fallback, fallbackErr) = expandAliases(in: baseSQL)
                    if let err = fallbackErr { setTab { $0.error = err }; return }
                    if subErr == nil {
                        // Run the subquery through its server's passthrough when eligible
                        // (same conditions as any single-server read); otherwise the scanner.
                        var subPT: (alias: String, serverSQL: String)? = nil
                        let subDSN = manager.queryEngine.attachedDatabase(sj.subAlias)
                        if session.connections.contains(where: { $0.alias == sj.subAlias }),
                           manager.queryEngine.hasServerPassthrough(sj.subAlias),
                           !subDSN.isEmpty,
                           (session.selectedDatabase[sj.subAlias] ?? subDSN) == subDSN {
                            subPT = (sj.subAlias, SQLBuilder.stripAliasPrefix(sj.subquery, alias: sj.subAlias))
                        }
                        semiJoin = SemiJoinExec(reduction: sj, subPassthrough: subPT,
                                                subScannerSQL: subExpanded, fallbackSQL: fallback)
                    }
                    sql = fallback   // used only if the reduction can't proceed at run time
                } else if let cj = SQLBuilder.detectCrossJoin(baseSQL, aliases: connAliases),
                          let engA = session.connections.first(where: { $0.alias == cj.a.server })?.engine,
                          let engB = session.connections.first(where: { $0.alias == cj.b.server })?.engine,
                          (engA == .clickhouse) != (engB == .clickhouse) {
                    // Two-table join with exactly one ClickHouse side. ClickHouse is native
                    // HTTP (outside DuckDB's catalog), so the join can't run on the scanner
                    // — bridge it at run time (see QueryEngine.clickHouseJoinPlan).
                    clickhouseBridge = ClickHouseBridgeExec(reduction: cj)
                    sql = baseSQL   // the bridge rewrites it at run time
                } else if let cj = SQLBuilder.detectCrossJoin(baseSQL, aliases: connAliases),
                          session.connections.contains(where: { $0.alias == cj.a.server }),
                          session.connections.contains(where: { $0.alias == cj.b.server }),
                          manager.queryEngine.hasServerPassthrough(cj.a.server)
                            || manager.queryEngine.hasServerPassthrough(cj.b.server) {
                    // Two-table cross-server inner join with at least one MySQL/Postgres
                    // side: that side streams through the join from its server (run time
                    // picks the probe — see QueryEngine.crossJoinPlan); the other side may
                    // be a local SQLite table. The scanner fallback handles everything else.
                    let (fallback, fallbackErr) = expandAliases(in: baseSQL)
                    if let err = fallbackErr { setTab { $0.error = err }; return }
                    crossJoin = CrossJoinExec(reduction: cj, fallbackSQL: fallback)
                    sql = fallback   // used only if the plan can't proceed at run time
                } else {
                    // Cross-engine JOIN / anything not reducible: expand to 3-part
                    // "alias"."db"."table" so DuckDB's scanner can span the servers.
                    let (expanded, expandError) = expandAliases(in: baseSQL)
                    if let err = expandError { setTab { $0.error = err }; return }
                    // Speed the slow part up: materialize each remote (MySQL/Postgres)
                    // table via the passthrough into a DuckDB TEMP table instead of letting
                    // the scanner drag it over the wire row by row. SQLite refs are left as
                    // scanner refs (fast local scan). The plain scanner `expanded` stays the
                    // run-time backstop if any materialization fails.
                    var remoteAliases: Set<String> = []
                    var dbByAlias: [String: String] = [:]
                    for conn in session.connections where manager.queryEngine.canPassthrough(conn.alias) {
                        remoteAliases.insert(conn.alias)
                        dbByAlias[conn.alias] = catalogDatabase(for: conn.alias)
                    }
                    var seq = 0
                    let plan = SQLBuilder.planFallback(baseSQL, remoteAliases: remoteAliases) { _, _ in
                        defer { seq += 1 }; return SQLBuilder.duckIdent("__sb_mat_\(seq)")
                    }
                    if plan.materializations.isEmpty {
                        sql = expanded            // nothing remote to speed up
                    } else {
                        // Expand the SQLite refs in the rewritten SQL to 3-part; the quoted
                        // temp idents are skipped (expandAliases copies quoted spans verbatim).
                        let (matExpanded, matErr) = expandAliases(in: plan.rewrittenSQL)
                        if let err = matErr { setTab { $0.error = err }; return }
                        fallbackMaterialize = FallbackMaterializeExec(
                            materializations: plan.materializations, dbByAlias: dbByAlias,
                            materializedSQL: matExpanded, scannerSQL: expanded)
                        sql = expanded            // used only if materialization can't proceed
                    }
                }
            }
        }

        let runID = UUID()
        setTab {
            $0.isRunning = true; $0.error = nil; $0.result = nil
            $0.runID = runID; $0.editTarget = nil; $0.editBlockedReason = nil
        }
        // The database each alias's unqualified names mean for this run, for editing its result.
        let runDatabases = Dictionary(session.connections.map { ($0.alias, catalogDatabase(for: $0.alias)) },
                                      uniquingKeysWith: { first, _ in first })

        startElapsedTimer()

        let task = Task {
            var finished = false
            do {
                // Await USE before running the query — eliminates the race condition where
                // the query runs before setDefaultContext's USE completes on userSerial.
                if let ctx = pendingContext {
                    await manager.queryEngine.setDefaultContextAwaited(alias: ctx.alias, database: ctx.db)
                }
                if let chAlias = clickhouseAlias {
                    // ClickHouse runs on its own native client — no DuckDB streaming.
                    let result = try await manager.queryEngine.clickhouseQuery(alias: chAlias, sql: sql)
                    setTab { $0.result = runClock.stamped(result); $0.isRunning = false }
                    resolveResultEditing(tabID: tabID, runID: runID, sql: baseSQL,
                                         columns: result.columns, databases: runDatabases)
                } else {
                    // Progressive load: paint the first chunk instantly, then stream the
                    // remaining rows in the background so the whole result shows without a
                    // cap and without freezing the UI. A single-server MySQL/Postgres read
                    // goes through the passthrough (server does the work); everything else
                    // uses the scanner (cross-engine JOINs, writes, non-default databases).
                    let (first, stream): (QueryResult, QueryEngine.QueryStream)
                    // Bridge/materialized TEMP tables (a ClickHouse side copied into DuckDB,
                    // or remote tables materialized for the scanner fallback) to drop once
                    // the result has streamed.
                    var bridgeTempTables: [String] = []
                    if let chb = clickhouseBridge {
                        // Copy the ClickHouse side into a DuckDB TEMP table and join it with
                        // the other side as that streams from its server. No scanner fallback
                        // exists for ClickHouse, so an error surfaces.
                        let plan = try await manager.queryEngine.clickHouseJoinPlan(
                            chb.reduction, baseSQL: baseSQL, aliases: session.connections.map(\.alias)) { catalogDatabase(for: $0) }
                        bridgeTempTables = [plan.temp]
                        (first, stream) = try await manager.queryEngine.openStreamingQuery(
                            plan.sql, firstChunk: 2_000, logSQL: baseSQL, pinJoinOrder: true)
                    } else if let sj = semiJoin {
                        // Run the subquery on its server (small side), inline its values,
                        // then push the outer query to its server. Falls back to the
                        // cross-server scanner if the value list is too large to inline or
                        // the subquery can't run standalone (e.g. it turned out correlated).
                        do {
                            let subRes: QueryResult
                            if let spt = sj.subPassthrough {
                                subRes = try await manager.queryEngine.serverPassthroughQuery(alias: spt.alias, serverSQL: spt.serverSQL)
                            } else {
                                subRes = try await manager.queryEngine.query(sj.subScannerSQL)
                            }
                            let vals = subRes.rows.map { $0.first ?? "" }
                            let msk  = subRes.nullMask.map { $0.first ?? false }
                            let nonNull = zip(vals, msk).filter { !$0.1 }.count
                            if nonNull > QueryEngine.maxInlineKeys {
                                (first, stream) = try await manager.queryEngine.openStreamingQuery(sj.fallbackSQL, firstChunk: 2_000)
                            } else {
                                let inList = SQLBuilder.inValueList(vals, mask: msk)
                                let outerFull = sj.reduction.outerPrefix + inList + sj.reduction.outerSuffix
                                let outerSQL = SQLBuilder.stripAliasPrefix(outerFull, alias: sj.reduction.outerAlias)
                                (first, stream) = try await manager.queryEngine.openServerStreamingQuery(
                                    alias: sj.reduction.outerAlias, serverSQL: outerSQL, firstChunk: 2_000)
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            (first, stream) = try await manager.queryEngine.openStreamingQuery(sj.fallbackSQL, firstChunk: 2_000)
                        }
                    } else if let cjx = crossJoin {
                        (first, stream) = try await openCrossJoin(cjx, baseSQL: baseSQL)
                    } else if let fm = fallbackMaterialize {
                        let opened = try await openFallback(fm, baseSQL: baseSQL)
                        (first, stream) = (opened.first, opened.stream)
                        bridgeTempTables = opened.temps
                    } else if let pt = passthrough {
                        (first, stream) = try await manager.queryEngine.openServerStreamingQuery(
                            alias: pt.alias, serverSQL: pt.serverSQL, firstChunk: 2_000)
                    } else {
                        (first, stream) = try await manager.queryEngine.openStreamingQuery(sql, firstChunk: 2_000)
                    }
                    let hasMore = stream.hasMore
                    // Release the stream's cursor when we stop reading it — whether it
                    // drains, is cancelled, or throws — so an abandoned big query doesn't
                    // leave its result set held on the DB connection. Drop any bridge /
                    // materialized TEMP tables after the cursor is closed (same lane, ordered).
                    defer {
                        let temps = bridgeTempTables
                        Task {
                            await manager.queryEngine.closeStream(stream)
                            for t in temps { await manager.queryEngine.dropTempTable(t) }
                        }
                    }
                    // The result's executionTime is the run's wall time so far (planning,
                    // materializing, first rows), not the engine's per-statement time —
                    // it's what the status bar shows, and it must match the counter.
                    setTab { $0.result = runClock.stamped(first); $0.isRunning = false; $0.isStreaming = hasMore }
                    resolveResultEditing(tabID: tabID, runID: runID, sql: baseSQL,
                                         columns: first.columns, databases: runDatabases)
                    // Buffer the streamed chunks and publish them in batches. Every publish
                    // re-renders the workspace, so publishing each 20k chunk made a
                    // million rows cost fifty workspace renders. StreamBatcher's size/time
                    // cadence keeps the row counter moving while bounding publishes to a
                    // handful; appending a chunk never copies the cells already held. The
                    // tail is flushed on every exit — drained, cancelled, or thrown — so
                    // the rows already pulled are never lost.
                    var pending: [CellTable.Chunk] = []
                    var batcher = StreamBatcher(now: ProcessInfo.processInfo.systemUptime)
                    func flushPending() {
                        guard !pending.isEmpty else { return }
                        let chunks = pending
                        pending.removeAll(keepingCapacity: true)
                        setTab {
                            for c in chunks { $0.result?.cells.append(c) }
                            if let n = $0.result?.rowCount { $0.result?.totalRowCount = n }   // the total is only known at the end
                        }
                    }
                    defer { flushPending() }
                    while hasMore && !Task.isCancelled {
                        guard let chunk = try await manager.queryEngine.pullMore(stream, size: 20_000),
                              chunk.rowCount > 0 else { break }
                        pending.append(chunk)
                        if batcher.add(chunk.rowCount, now: ProcessInfo.processInfo.systemUptime) {
                            flushPending()
                        }
                    }
                }
                finished = true
            } catch is CancellationError {
                // Cancelling mid-stream keeps the rows already loaded; only show the
                // cancelled message when nothing was displayed yet.
                setTab { if $0.result == nil { $0.error = "Query cancelled after \(RunClock.tickerText(runClock.elapsed()))" } }
            } catch {
                setTab { $0.error = QueryEngine.extractReason(from: error) }
            }
            // Console logging happens in the engine's onStatement hook — logging
            // here as well produced every statement twice.
            // A streamed result's time becomes the full run (the counter's last value).
            // A non-streamed one was stamped on display, microseconds ago — leave it,
            // so the grid isn't reloaded for a change of nothing.
            setTab {
                if $0.isStreaming { $0.result?.executionTime = runClock.elapsed() }
                $0.isRunning = false; $0.isStreaming = false
            }
            stopElapsedTimer()
            if finished { await followRun(baseSQL) }
        }
        runningTask = task

        // No automatic timeout. Big cross-engine JOINs and scans — the whole point
        // of this app — legitimately run for minutes, and a 60s auto-cancel was
        // killing them ("INTERRUPT Error: Interrupted!"). The user stays in control
        // via the live elapsed timer and the Cancel button; nothing is ever stuck.
        await task.value
        runningTask = nil
    }


    /// Cross-server inner join: pick the smaller side as the probe, fetch its distinct
    /// join keys, bring the bigger side over through its server's passthrough filtered
    /// to them when that is selective (else whole), and let DuckDB join the two
    /// passthrough streams as they arrive — the big side listed first with the join
    /// order pinned, so it flows through a hash table of the probe side and the first
    /// joined rows paint while the server is still sending. Equivalent for an inner
    /// join; any obstacle (big side can't passthrough, an error) falls back to the
    /// whole-query scanner. Nothing is copied into a TEMP table.
    private func openCrossJoin(_ cjx: CrossJoinExec, baseSQL: String) async throws
        -> (result: QueryResult, stream: QueryEngine.QueryStream) {
        let engine = manager.queryEngine
        do {
            let plan = try await engine.crossJoinPlan(cjx.reduction, baseSQL: baseSQL,
                                                      aliases: session.connections.map(\.alias)) { catalogDatabase(for: $0) }
            // Big side first and the join order pinned: DuckDB builds its hash table on
            // the probe side and the big side streams through it, straight from the
            // server — nothing of it is copied into a temp table or a hash table first.
            return try await engine.openStreamingQuery(plan ?? cjx.fallbackSQL, firstChunk: 2_000, logSQL: baseSQL,
                                                       pinJoinOrder: plan != nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await engine.openStreamingQuery(cjx.fallbackSQL, firstChunk: 2_000, logSQL: baseSQL)
        }
    }

    /// Cross-engine fallback: materialize each remote table via the passthrough into a
    /// DuckDB TEMP table, then run the join on those local tables; the plain scanner,
    /// which spans the servers without them, stays the backstop — so results never
    /// change. Before a single row is fetched: (1) each table's own WHERE conjuncts —
    /// and those carried to it across the join key — are pushed into its passthrough
    /// SELECT, so a filter on an indexed column stays a server lookup instead of a
    /// whole-table transfer (measured: a 383M-row table for one key value); (2) the
    /// temps are created with their columns but no rows and the rewritten query is
    /// bound, so a misspelled or ambiguous column fails in milliseconds, not after the
    /// tables crossed the wire. Returns the opened stream and the temps to drop after it.
    private func openFallback(_ fm: FallbackMaterializeExec, baseSQL: String) async throws
        -> (first: QueryResult, stream: QueryEngine.QueryStream, temps: [String]) {
        let engine = manager.queryEngine
        let pushed = await engine.pushdownWhere(baseSQL: baseSQL, aliases: session.connections.map(\.alias)) { alias in
            fm.dbByAlias[alias] ?? catalogDatabase(for: alias)
        }
        func extra(_ m: SQLBuilder.FallbackPlan.Materialization) -> String? {
            pushed[QueryEngine.pushdownKey(alias: m.alias, table: m.table)]
        }
        var temps: [String] = []
        func dropTemps() async {
            for t in temps { await engine.dropTempTable(t) }
            temps = []
        }
        do {
            for m in fm.materializations {
                guard let db = fm.dbByAlias[m.alias] else { continue }
                temps.append(try await engine.materializeViaPassthrough(
                    alias: m.alias, database: db, table: m.table, tempIdent: m.temp,
                    extraWhere: extra(m), shapeOnly: true))
            }
        } catch is CancellationError {
            await dropTemps()
            throw CancellationError()
        } catch {
            await dropTemps()   // can't even shape them: the scanner backstop below
        }
        if !temps.isEmpty {
            do {
                try await engine.bindCheck(fm.materializedSQL)
            } catch {
                await dropTemps()   // the query itself is wrong (or was cancelled): say so now
                throw error
            }
            do {
                for m in fm.materializations {
                    guard let db = fm.dbByAlias[m.alias] else { continue }
                    // Replaces the shape-only temp of the same name.
                    _ = try await engine.materializeViaPassthrough(
                        alias: m.alias, database: db, table: m.table, tempIdent: m.temp, extraWhere: extra(m))
                }
            } catch is CancellationError {
                await dropTemps()
                throw CancellationError()
            } catch {
                await dropTemps()   // couldn't materialize: the scanner backstop
            }
        }
        let planSQL = temps.isEmpty ? fm.scannerSQL : fm.materializedSQL
        let (first, stream) = try await engine.openStreamingQuery(planSQL, firstChunk: 2_000, logSQL: baseSQL)
        return (first, stream, temps)
    }

    /// The one server an EXPLAIN runs on: the only alias the SQL references, or the
    /// only connection when it references none; nil when that is ambiguous. Also
    /// returns how many aliases were referenced, for the error message.
    /// After a run that succeeded: what it changed (USE, CREATE/ALTER/DROP/RENAME) shows
    /// in the left panel of the connection it ran on, or of each server it named.
    private func followRun(_ sql: String) async {
        let targets: [Connection]
        if let conn = SQLBuilder.soleTarget(of: sql, connections: session.connections,
                                            active: session.activeConnectionAlias) {
            targets = [conn]
        } else {
            targets = session.connections.filter { SQLBuilder.referencesAlias(sql, $0.alias) }
        }
        for conn in targets { await session.followRun(sql, on: conn, manager: manager) }
    }

    /// A lone `USE db`: the same switch as picking `db` at the top of the left panel.
    private func runUse(_ sql: String, database db: String, on conn: Connection, tabID: UUID) async {
        func setTab(_ body: (inout QueryTab) -> Void) {
            guard let i = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            body(&session.tabs[i])
        }
        setTab {
            $0.isRunning = true; $0.error = nil; $0.result = nil
            $0.runID = UUID(); $0.editTarget = nil; $0.editBlockedReason = ResultEditing.notOneTable
        }
        let start = Date()
        await session.followRun(sql, on: conn, manager: manager)
        let took = Date().timeIntervalSince(start)
        let failure: String? = session.selectedDatabase[conn.alias] == db ? nil
            : (session.tableListError[conn.alias]?.message ?? "Couldn't open \(db)")
        setTab {
            if let failure { $0.error = failure }
            else { $0.result = QueryResult(columns: ["Result"], rows: [["Database changed to \(db)"]], executionTime: took) }
            $0.isRunning = false
        }
        session.appendConsole(sql: sql, rowsAffected: nil, error: failure, duration: took)
    }

    private func explainTarget(for sql: String) -> (conn: Connection?, referenced: Int) {
        let referenced = session.connections.filter { SQLBuilder.referencesAlias(sql, $0.alias) }
        let conn = SQLBuilder.soleTarget(of: sql, connections: session.connections, active: session.activeConnectionAlias)
        return (conn, referenced.count)
    }

    /// Server-native EXPLAIN for a single-server query. Resolves the one target
    /// server, strips its DuckDB alias prefix so the SQL is what the server sees,
    /// and shows the plan grid in the results panel. `sql` overrides the editor's
    /// text (a typed `EXPLAIN …` passes the statement after the keyword).
    private func explainQuery(tabIndex: Int, sql override: String? = nil) async {
        guard tabIndex < session.tabs.count else { return }
        let tabID = session.tabs[tabIndex].id
        func setTab(_ body: (inout QueryTab) -> Void) {
            guard let i = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            body(&session.tabs[i])
        }
        let rawSQL = selectedSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSQL = override ?? (rawSQL.isEmpty
            ? session.tabs[tabIndex].sql.trimmingCharacters(in: .whitespacesAndNewlines)
            : rawSQL)
        guard !baseSQL.isEmpty else { return }

        // EXPLAIN runs on ONE server: the one the query names, or, when it names none,
        // the connection picked at the top of the left panel.
        let (target, referencedCount) = explainTarget(for: baseSQL)
        guard let conn = target else {
            setTab { $0.error = "EXPLAIN runs on a single server, but this query references \(referencedCount). Explain it against one server at a time." }
            return
        }
        guard conn.engine == .mysql || conn.engine == .postgres else {
            setTab { $0.error = "EXPLAIN is available for MySQL/MariaDB and PostgreSQL connections." }
            return
        }
        let serverSQL = SQLBuilder.stripAliasPrefix(baseSQL, alias: conn.alias)

        setTab {
            $0.isRunning = true; $0.error = nil; $0.result = nil
            $0.runID = UUID(); $0.editTarget = nil; $0.editBlockedReason = ResultEditing.notOneTable
        }
        startElapsedTimer()
        let task = Task {
            do {
                let result = try await manager.queryEngine.explain(alias: conn.alias, serverSQL: serverSQL)
                setTab { $0.result = runClock.stamped(result) }
            } catch is CancellationError {
                setTab { $0.error = "Cancelled" }
            } catch {
                setTab { $0.error = QueryEngine.extractReason(from: error) }
            }
            setTab { $0.isRunning = false }
            stopElapsedTimer()
        }
        runningTask = task
        await task.value
        runningTask = nil
    }

    /// After a run's first rows are on screen: can its result be edited, and where to.
    /// The answer is dropped if the tab has run something else meanwhile.
    private func resolveResultEditing(tabID: UUID, runID: UUID, sql: String, columns: [String],
                                      databases: [String: String]) {
        let connections = session.connections
        Task {
            let check = await manager.queryEngine.resultEditing(sql: sql, resultColumns: columns,
                                                                connections: connections) { databases[$0] ?? "" }
            guard let i = session.tabs.firstIndex(where: { $0.id == tabID }), session.tabs[i].runID == runID else { return }
            session.tabs[i].editTarget = check.target
            session.tabs[i].editBlockedReason = check.target == nil ? (check.reason ?? ResultEditing.notOneTable) : nil
        }
    }

    /// A saved edit: the new value goes into the tab's result, and the grid redraws it.
    private func applySavedCell(tabID: UUID, row: Int, column: Int, value: String?) {
        guard let i = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        session.tabs[i].result?.cells.setValue(value, row: row, column: column)
        session.tabs[i].editRevision += 1
    }

    private func cancelQuery() {
        // Abort the statement inside DuckDB — cancelling only the Swift task
        // left the query running and every later statement queued behind it.
        manager.queryEngine.interruptUserQuery()
        for conn in session.connections where conn.engine == .clickhouse {
            manager.queryEngine.clickhouseClients[conn.alias]?.cancel()
        }
        runningTask?.cancel()
        runningTask = nil
        if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
            // Keep whatever rows already streamed in; just note the load stopped early.
            // Their time is how long the run went before it was stopped.
            if session.tabs[idx].isStreaming { session.tabs[idx].result?.executionTime = runClock.elapsed() }
            session.tabs[idx].isRunning = false
            session.tabs[idx].isStreaming = false
            if session.tabs[idx].result == nil { session.tabs[idx].error = "Query cancelled" }
        }
        stopElapsedTimer()
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        runClock = RunClock()
        elapsed = 0
        elapsedTimer?.invalidate()
        // Read the clock on each tick rather than counting ticks: a tick that fires
        // late (the main thread is busy painting a big batch) would otherwise leave
        // the counter behind the status bar's final total.
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed = runClock.elapsed()
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsed = 0
    }

}

// MARK: - Save-query sheet

private struct SaveQuerySheet: View {
    @Binding var name: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Query").font(.headline)
            Text("Give this query a name so you can reuse it later. Saving with an existing name replaces it.")
                .font(.caption).foregroundColor(.secondary)
            TextField("Query name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
