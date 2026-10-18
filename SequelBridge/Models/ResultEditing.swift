//
//  ResultEditing.swift
//  SequelBridge
//
//  When a Query-tab result can be edited, and where a value is written: Sequel Ace's
//  rule. A value is editable when it is one column of one table, and its row can be
//  found again by that table's primary key, which must be in the result. Sequel Ace
//  reads a column's table from the MySQL protocol's column metadata; our results come
//  through DuckDB, which keeps none, so it is read from the statement: a plain SELECT
//  of one table, and which select-list item each result column is. Joins, GROUP BY,
//  DISTINCT, set operations, CTEs and derived tables are declined, with the reason.
//

import Foundation

/// Where a Query-tab result's values are written back.
nonisolated struct ResultEditTarget: Equatable {
    struct KeyPart: Equatable {
        let column: String       // a primary-key column of the table
        let resultIndex: Int     // the result column that carries it
    }
    let alias: String            // the connection
    let database: String         // what DuckDB's catalog path wants: MySQL database, PostgreSQL schema, SQLite "main"
    let table: String
    /// Result column index → the table column it shows. Computed columns are absent.
    let columns: [Int: String]
    let primaryKey: [KeyPart]

    /// Why result column `i` can't be edited, or nil when it can.
    func reason(forColumn i: Int) -> String? {
        columns[i] == nil ? ResultEditing.computedColumn : nil
    }

    /// The UPDATE that sets one cell of `result` (the rows as shown), keyed by that row's
    /// primary-key values. nil for a computed column.
    func update(row: Int, column: Int, value: String?, in result: QueryResult) -> String? {
        guard let name = columns[column] else { return nil }
        let key = primaryKey.map { k -> (column: String, value: String?) in
            (k.column, result.isNull(row, k.resultIndex) ? nil : result.cells.value(row, k.resultIndex))
        }
        return SQLBuilder.update(alias: alias, database: database, table: table,
                                 column: name, newValue: value, primaryKey: key)
    }
}

nonisolated enum ResultEditing {
    /// What a single-table SELECT reads, from its text alone.
    struct Source: Equatable {
        let alias: String?       // the connection alias as written; nil for a table named without one
        let database: String?    // an explicit database (schema) part
        let table: String
        let queryAlias: String   // what the select list may qualify columns with
        let items: [Item]
    }

    /// One select-list item.
    enum Item: Equatable {
        case all                             // * or t.*
        case column(String, output: String)  // a column, and the name the result gives it
        case computed                        // anything else
    }

    static let notOneTable = "This result isn't one table's rows (a join, GROUP BY, UNION or similar), so its values can't be traced back and edited."
    static let computedColumn = "This column is computed by the query, so there is no stored value to change."
    static let unmatchedColumns = "The result's columns couldn't be matched to the table's, so they aren't edited from here."
    static let checking = "Checking whether this result can be edited…"
    static func missingKey(table: String, key: [String]) -> String {
        "Add the primary key of \(table) (\(key.joined(separator: ", "))) to the SELECT to edit these values."
    }

    // MARK: - Reading the statement

    /// Words that may follow the table: the clauses that keep its rows one-to-one.
    private static let afterTable: Set<String> = ["WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH"]
    /// Words that, at the top level after the FROM, make the result something else.
    private static let declined: Set<String> = [
        "GROUP", "HAVING", "WINDOW", "QUALIFY", "FOR", "INTO", "LOCK", "PROCEDURE",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "STRAIGHT_JOIN", "USING", "ON",
    ]
    /// A bare word after the table that is a clause, not the table's alias.
    private static let clauseWords = afterTable.union(declined).union(["UNION", "INTERSECT", "EXCEPT", "MINUS", "AS"])

    /// The one table a plain SELECT reads and its select list; nil for anything else.
    /// `aliases` are the open connections' aliases: `alias.table` and `alias.db.table`
    /// name a connection, and with one connection `table` and `db.table` do too.
    static func source(of sql: String, aliases: [String]) -> Source? {
        let chars = Array(sql)
        var toks = SQLTok.tokenize(chars)
        func text(_ t: SQLTok) -> String { String(chars[t.start..<t.end]) }
        while let last = toks.last, case .other = last.kind, text(last) == ";" { toks.removeLast() }
        guard let first = toks.first, first.isKeyword("SELECT") else { return nil }

        // The top-level FROM; a set operation anywhere at the top level declines.
        var depth = 0
        var fromIdx: Int? = nil
        for (i, t) in toks.enumerated() {
            switch t.kind {
            case .lparen: depth += 1
            case .rparen: depth -= 1
            default:
                guard depth == 0 else { continue }
                if let k = t.keyword, ["UNION", "INTERSECT", "EXCEPT", "MINUS"].contains(k) { return nil }
                if fromIdx == nil, t.isKeyword("FROM") { fromIdx = i }
            }
        }
        guard let from = fromIdx else { return nil }

        // FROM <table> [[AS] alias]
        var i = from + 1
        guard i < toks.count, case .ident(let parts, _) = toks[i].kind, (1...3).contains(parts.count) else { return nil }
        i += 1
        if i < toks.count, case .lparen = toks[i].kind { return nil }      // a table function: read_csv(…)
        let aliasSet = Set(aliases.map { $0.lowercased() })
        let table = parts[parts.count - 1]
        var alias: String? = nil
        var database: String? = nil
        if parts.count >= 2, aliasSet.contains(parts[0].lowercased()) {
            alias = parts[0]
            database = parts.count == 3 ? parts[1] : nil
        } else if parts.count == 3 {
            return nil                                                       // not one of the app's connections
        } else if parts.count == 2 {
            database = parts[0]
        }
        var queryAlias = table
        if i < toks.count, toks[i].isKeyword("AS") {
            guard i + 1 < toks.count, case .ident(let p, _) = toks[i + 1].kind, p.count == 1 else { return nil }
            queryAlias = p[0]
            i += 2
        } else if i < toks.count, case .ident(let p, let q) = toks[i].kind, p.count == 1,
                  q[0] || !clauseWords.contains(p[0].uppercased()) {
            queryAlias = p[0]
            i += 1
        }

        // Then nothing, or WHERE / ORDER BY / LIMIT / OFFSET / FETCH — and never a join,
        // grouping or locking clause later on (a word followed by "(" is a function).
        if i < toks.count {
            guard let k = toks[i].keyword, afterTable.contains(k) else { return nil }
        }
        var d = 0
        while i < toks.count {
            let t = toks[i]
            switch t.kind {
            case .lparen: d += 1
            case .rparen: d -= 1
            default:
                let call: Bool = {
                    guard i + 1 < toks.count, case .lparen = toks[i + 1].kind else { return false }
                    return true
                }()
                if d == 0, !call, let k = t.keyword, declined.contains(k) { return nil }
            }
            i += 1
        }

        // The select list, split at top-level commas.
        var start = 1
        if start < from, toks[start].isKeyword("ALL") { start += 1 }
        guard start < from else { return nil }
        if let k = toks[start].keyword, ["DISTINCT", "DISTINCTROW", "TOP"].contains(k) { return nil }
        func qualifies(_ q: String) -> Bool {
            q.lowercased() == queryAlias.lowercased() || q.lowercased() == table.lowercased()
        }
        func item(_ t: ArraySlice<SQLTok>) -> Item {
            let t = Array(t)
            if t.count == 1, case .op("*") = t[0].kind { return .all }
            if t.count == 3, case .ident(let p, _) = t[0].kind, p.count == 1, qualifies(p[0]),
               case .other = t[1].kind, text(t[1]) == ".", case .op("*") = t[2].kind { return .all }
            guard case .ident(let p, _) = t[0].kind else { return .computed }
            let column: String
            switch p.count {
            case 1: column = p[0]
            case 2 where qualifies(p[0]): column = p[1]
            case 3 where p[1].lowercased() == table.lowercased(): column = p[2]
            default: return .computed
            }
            var rest = t.dropFirst()
            if rest.isEmpty { return .column(column, output: column) }
            if rest.first!.isKeyword("AS") { rest = rest.dropFirst() }
            guard rest.count == 1, case .ident(let a, _) = rest.first!.kind, a.count == 1 else { return .computed }
            return .column(column, output: a[0])
        }
        var items: [Item] = []
        var segment = start
        d = 0
        for j in start...from {
            if j == from || (d == 0 && toks[j].kind == .comma) {
                guard j > segment else { return nil }
                items.append(item(toks[segment..<j]))
                segment = j + 1
                continue
            }
            if case .lparen = toks[j].kind { d += 1 } else if case .rparen = toks[j].kind { d -= 1 }
        }
        return Source(alias: alias, database: database, table: table, queryAlias: queryAlias, items: items)
    }

    // MARK: - Matching the result to the table

    /// Which result column is which table column, and where the primary key is, given
    /// the table's columns; or why the result can't be edited.
    static func target(source: Source, alias: String, database: String, resultColumns: [String],
                       tableColumns: [ColumnInfo]) -> (target: ResultEditTarget?, reason: String?) {
        func find(_ name: String) -> String? {
            tableColumns.first { $0.name == name }?.name
                ?? tableColumns.first { $0.name.lowercased() == name.lowercased() }?.name
        }
        // Per result column: the table column it shows and the name it should carry; nil when computed.
        var shown: [(column: String, output: String)?] = []
        for item in source.items {
            switch item {
            case .all: shown += tableColumns.map { ($0.name, $0.name) }
            case .column(let name, let output): shown.append(find(name).map { ($0, output) })
            case .computed: shown.append(nil)
            }
        }
        // The result must line up with the statement as read; otherwise it was read wrong.
        guard shown.count == resultColumns.count else { return (nil, unmatchedColumns) }
        var columns: [Int: String] = [:]
        for (i, s) in shown.enumerated() {
            guard let s else { continue }
            guard resultColumns[i].lowercased() == s.output.lowercased() else { return (nil, unmatchedColumns) }
            columns[i] = s.column
        }
        let key = tableColumns.filter(\.isPrimaryKey).map(\.name)
        guard !key.isEmpty else { return (nil, CellEditability.noPrimaryKey) }
        var parts: [ResultEditTarget.KeyPart] = []
        for k in key {
            guard let idx = columns.keys.sorted().first(where: { columns[$0] == k }) else {
                return (nil, missingKey(table: source.table, key: key))
            }
            parts.append(.init(column: k, resultIndex: idx))
        }
        return (ResultEditTarget(alias: alias, database: database, table: source.table,
                                 columns: columns, primaryKey: parts), nil)
    }
}

extension QueryEngine {
    /// Whether a Query-tab result can be edited, and where: ResultEditing's rule with the
    /// table's columns and key read from its server. `database` gives the database
    /// (schema) each alias's unqualified table names meant when the statement ran.
    func resultEditing(sql: String, resultColumns: [String], connections: [Connection],
                       database: (String) -> String) async -> (target: ResultEditTarget?, reason: String?) {
        guard let source = ResultEditing.source(of: sql, aliases: connections.map(\.alias)) else {
            return (nil, ResultEditing.notOneTable)
        }
        // A table named without an alias belongs to the only connection there is.
        let conn: Connection? = source.alias.map { a in connections.first { $0.alias.lowercased() == a.lowercased() } }
            ?? (connections.count == 1 ? connections[0] : nil)
        guard let conn else { return (nil, ResultEditing.notOneTable) }
        if let reason = CellEditability.reason(engine: conn.engine, readOnly: conn.readOnly, hasPrimaryKey: true) {
            return (nil, reason)
        }
        let db = source.database ?? database(conn.alias)
        var src = source
        var columns = (try? await fetchColumns(alias: conn.alias, database: db, table: source.table)) ?? []
        if columns.isEmpty, source.table != source.table.lowercased() {
            // PostgreSQL folds an unquoted name to lower case.
            let lower = source.table.lowercased()
            columns = (try? await fetchColumns(alias: conn.alias, database: db, table: lower)) ?? []
            src = ResultEditing.Source(alias: source.alias, database: source.database, table: lower,
                                       queryAlias: source.queryAlias, items: source.items)
        }
        guard !columns.isEmpty else { return (nil, ResultEditing.notOneTable) }
        return ResultEditing.target(source: src, alias: conn.alias, database: db,
                                    resultColumns: resultColumns, tableColumns: columns)
    }
}
