//
//  SQLBuilder.swift
//  SequelBridge
//
//  SQL construction shared by the workspace panels.
//
//  Two dialects are in play and they must not be mixed:
//
//  • DuckDB — statements sent to `queryEngine.query()`. DuckDB's parser rejects
//    backtick identifiers, so tables and columns are double-quoted. Used for DML
//    against ATTACH'd MySQL tables, which DuckDB executes natively.
//
//  • MySQL — statements handed to `queryEngine.mysqlExecute()`, which passes them
//    through to the server verbatim. These use backtick identifiers and are
//    qualified by database only: the server has never heard of the local
//    connection alias.
//
//  DDL must go through the MySQL side. DuckDB cannot parse MySQL DDL, and routing
//  it through the `mysql_query()` table function is fatal to the connection.
//

import Foundation

nonisolated enum SQLBuilder {

    // MARK: - Read-only classification (for safe mode)

    /// Statements whose leading keyword means "this only reads".
    private static let readLeadKeywords: Set<String> =
        ["SELECT", "WITH", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "PRAGMA", "VALUES", "USE", "TABLE"]

    /// True only if EVERY statement in `sql` is read-only. Fail-closed: anything whose
    /// leading keyword isn't a known read verb (INSERT/UPDATE/DELETE/DDL/unknown) counts
    /// as a write. A leading CTE (`WITH …`) that contains a data-modifying verb is a write.
    /// Used by safe mode to decide whether to let a statement run on a read-only connection.
    static func isReadOnly(_ sql: String) -> Bool {
        for stmt in splitStatements(sql) {
            let body = stripLeadingNoise(stmt)
            guard let kw = firstWord(body)?.uppercased() else { continue }   // empty → ignore
            guard readLeadKeywords.contains(kw) else { return false }
            if kw == "WITH", containsWriteVerb(body) { return false }         // WITH … INSERT/UPDATE/DELETE
        }
        return true
    }

    private static func splitStatements(_ sql: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inS = false, inD = false, inBack = false, line = false, block = false
        let c = Array(sql)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if line { cur.append(ch); if ch == "\n" { line = false }; i += 1; continue }
            if block { cur.append(ch); if ch == "*", i+1 < c.count, c[i+1] == "/" { cur.append("/"); i += 2; block = false; continue }; i += 1; continue }
            if inS { cur.append(ch); if ch == "'" { inS = false }; i += 1; continue }
            if inD { cur.append(ch); if ch == "\"" { inD = false }; i += 1; continue }
            if inBack { cur.append(ch); if ch == "`" { inBack = false }; i += 1; continue }
            if ch == "-", i+1 < c.count, c[i+1] == "-" { line = true; cur.append(ch); i += 1; continue }
            if ch == "/", i+1 < c.count, c[i+1] == "*" { block = true; cur.append(ch); i += 1; continue }
            if ch == "'" { inS = true; cur.append(ch); i += 1; continue }
            if ch == "\"" { inD = true; cur.append(ch); i += 1; continue }
            if ch == "`" { inBack = true; cur.append(ch); i += 1; continue }
            if ch == ";" { out.append(cur); cur = ""; i += 1; continue }
            cur.append(ch); i += 1
        }
        out.append(cur)
        return out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Drop leading whitespace and -- / /* */ comments so firstWord sees the real verb.
    private static func stripLeadingNoise(_ s: String) -> String {
        var t = Substring(s)
        while true {
            let before = t
            t = t.drop(while: { $0.isWhitespace })
            if t.hasPrefix("--") { if let nl = t.firstIndex(of: "\n") { t = t[t.index(after: nl)...] } else { t = Substring() } }
            else if t.hasPrefix("/*"), let end = t.range(of: "*/") { t = t[end.upperBound...] }
            if t == before { break }
        }
        return String(t)
    }

    private static func firstWord(_ s: String) -> String? {
        let w = s.drop(while: { !($0.isLetter || $0 == "_") }).prefix(while: { $0.isLetter || $0 == "_" })
        return w.isEmpty ? nil : String(w)
    }

    private static func containsWriteVerb(_ s: String) -> Bool {
        // Blank out 'string literals' first, so a write verb inside a literal
        // (e.g. WITH x AS (SELECT 'please update me') …) isn't mistaken for a write.
        let stripped = s.replacingOccurrences(of: "'[^']*'", with: "''", options: .regularExpression)
        let u = " " + stripped.uppercased() + " "
        for v in ["INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE"] where u.range(of: "\\b\(v)\\b", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - Identifier / literal quoting

    /// Double-quoted identifier for DuckDB. DuckDB's parser rejects backticks.
    static func duckIdent(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Backtick-quoted identifier for SQL passed through to MySQL.
    static func mysqlIdent(_ s: String) -> String {
        "`\(s.replacingOccurrences(of: "`", with: "``"))`"
    }

    /// Single-quoted string literal, valid in both dialects.
    static func literal(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "''"))'"
    }

    static func duckTable(alias: String, database: String, table: String) -> String {
        "\(duckIdent(alias)).\(duckIdent(database)).\(duckIdent(table))"
    }

    /// MySQL never sees the local connection alias, so it is deliberately absent.
    static func mysqlTable(database: String, table: String) -> String {
        "\(mysqlIdent(database)).\(mysqlIdent(table))"
    }

    /// Removes a DuckDB connection-alias prefix from table references so the SQL can
    /// be sent to the server itself (which knows nothing about the alias). Turns
    /// `alias.table` into `table`, case-insensitively, at word boundaries, skipping
    /// quoted identifiers and string literals. Used for server-native EXPLAIN.
    static func stripAliasPrefix(_ sql: String, alias: String) -> String {
        rewriteAliasPrefix(sql, alias: alias, replacement: "")
    }

    /// The statement a multi-server workspace sends to its ClickHouse server when it
    /// names only that server. ClickHouse runs on its native client, outside DuckDB's
    /// catalog, so `alias.table` becomes `` `database`.table `` — the database the
    /// sidebar has picked for that server — or plain `table` (the server's default
    /// database) when none is known.
    static func clickhouseSoleServerSQL(_ sql: String, alias: String, database: String) -> String {
        let prefix = database.isEmpty ? "" : "`\(database.replacingOccurrences(of: "`", with: "\\`"))`."
        return rewriteAliasPrefix(sql, alias: alias, replacement: prefix)
    }

    /// `alias.` → `replacement` wherever it starts a word, case-insensitively, copying
    /// quoted identifiers and string literals verbatim.
    private static func rewriteAliasPrefix(_ sql: String, alias: String, replacement: String) -> String {
        let aliasLower = Array(alias.lowercased())
        let aliasLen = aliasLower.count
        guard aliasLen > 0 else { return sql }
        let chars = Array(sql)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" {          // copy quoted spans verbatim
                let q = c; out.append(c); i += 1
                while i < chars.count { out.append(chars[i]); if chars[i] == q { i += 1; break }; i += 1 }
                continue
            }
            if c.lowercased().first == aliasLower.first {
                let prevIsWord = i > 0 && (chars[i-1].isLetter || chars[i-1].isNumber || chars[i-1] == "_" || chars[i-1] == ".")
                if !prevIsWord && i + aliasLen < chars.count {
                    var matched = true
                    for k in 0..<aliasLen where chars[i+k].lowercased().first != aliasLower[k] { matched = false; break }
                    if matched && chars[i+aliasLen] == "." {
                        // alias.database.table — the user named the database, so only
                        // the alias goes; the replacement is for the two-part form.
                        var j = i + aliasLen + 1
                        while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                        let threePart = j > i + aliasLen + 1 && j < chars.count && chars[j] == "."
                        if !threePart { out.append(contentsOf: replacement) }
                        i += aliasLen + 1        // past "alias."
                        continue
                    }
                }
            }
            out.append(c); i += 1
        }
        return String(out)
    }

    /// ORDER BY clause for the Content browser's server-side paged sort. Empty
    /// when no column is chosen. The column is double-quoted, which is valid on
    /// both the DuckDB scanner path and ClickHouse's native SQL.
    static func orderBy(column: String?, ascending: Bool) -> String {
        guard let column, !column.isEmpty else { return "" }
        return " ORDER BY \(duckIdent(column)) \(ascending ? "ASC" : "DESC")"
    }

    /// Engine-appropriate qualified table reference for a DDL statement sent through
    /// `executeDDL`. MySQL uses backticks and the database; Postgres uses the schema
    /// (which is what this app models as the selected "database" for PG).
    static func ddlTable(engine: DatabaseEngine, database: String, table: String) -> String {
        switch engine {
        case .mysql:      return mysqlTable(database: database, table: table)   // `db`.`tbl`
        case .postgres:   return pgTable(schema: database, table: table)        // "schema"."tbl"
        case .clickhouse: return "\(duckIdent(database)).\(duckIdent(table))"   // native "db"."tbl"
        case .sqlite:     return duckIdent(table)
        }
    }

    static func dropTable(engine: DatabaseEngine, database: String, table: String) -> String {
        "DROP TABLE \(ddlTable(engine: engine, database: database, table: table))"
    }

    static func truncateTable(engine: DatabaseEngine, database: String, table: String) -> String {
        "TRUNCATE TABLE \(ddlTable(engine: engine, database: database, table: table))"
    }

    // MARK: - Statement shape

    /// True when the statement touches tables — the multi-server alias rule only
    /// applies then. Keywords inside string literals are ignored.
    static func referencesTables(_ sql: String) -> Bool {
        // Blank out single-quoted literals so their contents cannot match.
        var cleaned = ""
        var inString = false
        for ch in sql {
            if ch == "'" { inString.toggle(); continue }
            if !inString { cleaned.append(ch) }
        }
        let upper = " " + cleaned.uppercased() + " "
        for kw in [" FROM ", " JOIN ", " INTO ", " UPDATE ", " DELETE ", " TABLE "] {
            if upper.contains(kw) { return true }
        }
        return false
    }

    /// True when the statement's leading keyword produces a result set. These are the
    /// shapes that can be pushed to the server via the `mysql_query`/`postgres_query`
    /// passthrough (a SELECT wrapper). Writes and DDL are deliberately excluded — they
    /// need the execute() path (mysql_execute) or DuckDB's scanner DML, not a table
    /// function that must bind an output column.
    static func isRowReturning(_ sql: String) -> Bool {
        var s = Substring(sql)
        // Skip leading whitespace, line/block comments and opening parens so
        // "(SELECT …)", "-- note\nSELECT …" and "/* */ WITH …" all classify correctly.
        loop: while true {
            s = s.drop(while: { $0.isWhitespace || $0 == "(" })
            if s.hasPrefix("--") {
                if let nl = s.firstIndex(of: "\n") { s = s[s.index(after: nl)...]; continue }
                return false
            }
            if s.hasPrefix("/*") {
                if let end = s.range(of: "*/") { s = s[end.upperBound...]; continue }
                return false
            }
            break loop
        }
        let first = s.prefix(while: { $0.isLetter }).uppercased()
        switch first {
        case "SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "VALUES", "TABLE", "PRAGMA":
            return true
        default:
            return false
        }
    }

    /// The statement a typed `EXPLAIN …` asks about — what follows the leading EXPLAIN
    /// keyword (after comments and whitespace; case-insensitive; a whole word) — or nil
    /// when the statement doesn't start with one, or nothing follows it. Modifiers such
    /// as `FORMAT=JSON` stay with the statement; `QueryEngine.explain` re-adds the
    /// keyword. The Query tab routes a typed EXPLAIN through the Explain button's
    /// server-native path: through the passthrough it fails on MariaDB, since
    /// mysql_query prepares every statement to learn its result types and EXPLAIN
    /// isn't preparable ("Failed to fetch return types").
    static func strippedExplain(_ sql: String) -> String? {
        let body = stripLeadingNoise(sql)
        let word = body.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        guard word.uppercased() == "EXPLAIN" else { return nil }
        let inner = body[word.endIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// `SELECT *` of a two-table query spelled out as `first.*, second.*`, so the output
    /// columns keep the user's table order when the rebuilt FROM…JOIN lists the tables
    /// the other way round. An explicit select list (incl. `y.*, x.*` or `COUNT(*)`) is
    /// returned unchanged — its order never depended on the FROM order.
    static func explicitStarColumns(_ sql: String, first: String, second: String) -> String {
        let pattern = #"(?is)^((?:\s|--[^\n]*\n|/\*.*?\*/)*select\s+(?:distinct\s+)?)\*(\s+from\b)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return sql }
        let ns = sql as NSString
        guard let m = re.firstMatch(in: sql, range: NSRange(location: 0, length: ns.length)) else { return sql }
        let head = ns.substring(with: m.range(at: 1))
        let tail = ns.substring(with: m.range(at: 2))
        return head + "\(first).*, \(second).*" + tail + ns.substring(from: m.range.location + m.range.length)
    }

    /// The user's two-server join with each side replaced by what fetches it —
    /// `bigRef`/`probeRef` are ready-made table references: a parenthesized passthrough
    /// subquery, or a scanner ref — the BIG side listed first. The statement runs with
    /// its join order pinned (see QueryEngine.openStreamingQuery), so DuckDB probes
    /// with the big side and builds its hash table on the probe side: the big side
    /// streams through, and the first joined rows appear as the server sends them.
    /// Only the FROM…JOIN…ON clause changes, so the aliases, the WHERE and the rest of
    /// the statement still resolve; a `SELECT *` whose tables swapped is spelled out
    /// per side (explicitStarColumns) so the output columns keep the user's order.
    static func crossJoinRewrite(_ baseSQL: String, join cj: CrossJoin, bigIsA: Bool,
                                 bigRef: String, probeRef: String) -> String {
        let big = bigIsA ? cj.a : cj.b
        let probe = bigIsA ? cj.b : cj.a
        let clause = "FROM \(bigRef) \(big.tableAlias) JOIN \(probeRef) \(probe.tableAlias) ON \(big.tableAlias).\(big.key) = \(probe.tableAlias).\(probe.key)"
        let source = bigIsA ? baseSQL : explicitStarColumns(baseSQL, first: cj.a.tableAlias, second: cj.b.tableAlias)
        return source.replacingOccurrences(of: cj.fromJoinClause, with: clause)
    }

    /// Identifier quoting for SQL that will run on the server itself (through the
    /// passthrough), where dialect matters: MySQL uses backticks, everything else
    /// uses ANSI double quotes.
    static func serverIdent(_ engine: DatabaseEngine, _ s: String) -> String {
        switch engine {
        case .mysql: return mysqlIdent(s)   // `s`
        default:     return duckIdent(s)    // "s"
        }
    }

    /// `db`.`table` (MySQL) or "schema"."table" (Postgres) for server-native SQL.
    static func serverTable(_ engine: DatabaseEngine, database: String, table: String) -> String {
        "\(serverIdent(engine, database)).\(serverIdent(engine, table))"
    }

    /// Maps a ClickHouse column type to the DuckDB type for a materialized bridge
    /// table (ClickHouse is native-HTTP and can't be ATTACH'd, so a cross-join side
    /// is copied into a DuckDB TEMP table — see QueryEngine.materializeClickHouse).
    /// Conservative: numeric and temporal types that are common join keys get a real
    /// DuckDB type so joins/comparisons line up; everything else is VARCHAR, which is
    /// always safe because ClickHouse values arrive as strings. Nullable()/
    /// LowCardinality() wrappers are peeled; parameters (Decimal(…), DateTime64(…),
    /// FixedString(…)) are ignored.
    static func clickhouseToDuckType(_ chType: String) -> String {
        var t = chType.trimmingCharacters(in: .whitespaces)
        // Peel wrappers that don't change the storage we care about, repeatedly, so a
        // nested wrap like LowCardinality(Nullable(Int32)) unwraps to Int32.
        var peeled = true
        while peeled {
            peeled = false
            for wrapper in ["Nullable(", "LowCardinality("] where t.hasPrefix(wrapper) && t.hasSuffix(")") {
                t = String(t.dropFirst(wrapper.count).dropLast()).trimmingCharacters(in: .whitespaces)
                peeled = true
            }
        }
        // Base name without any (parameters).
        let base = String(t.prefix { $0 != "(" })
        switch base {
        case "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32":
            return "BIGINT"                     // fits in signed 64-bit
        case "Float32", "Float64":
            return "DOUBLE"
        case "Bool", "Boolean":
            return "BOOLEAN"
        case "Date", "Date32":
            return "DATE"
        case "DateTime", "DateTime64":
            return "TIMESTAMP"
        default:
            // UInt64/(U)Int128/256, Decimal, UUID, String, FixedString, Enum*, IPv4/6,
            // Array/Map/Tuple, JSON, … — all safe as text and display as ClickHouse sent them.
            return "VARCHAR"
        }
    }

    // MARK: - DML (DuckDB dialect)

    /// Renders a cell value: NULL and CURRENT_TIMESTAMP pass through as keywords,
    /// everything else becomes a quoted literal.
    private static func value(_ v: String) -> String {
        switch v.uppercased() {
        case "NULL":              return "NULL"
        case "CURRENT_TIMESTAMP": return "CURRENT_TIMESTAMP"
        default:                  return literal(v)
        }
    }

    /// `WHERE` clause matching a row by its primary key columns. A nil value means
    /// the key column is SQL NULL (`IS NULL`) — distinct from the literal "NULL".
    private static func whereClause(_ primaryKey: [(column: String, value: String?)]) -> String {
        primaryKey.map { pk in
            if let v = pk.value {
                return "\(duckIdent(pk.column)) = \(literal(v))"
            } else {
                return "\(duckIdent(pk.column)) IS NULL"
            }
        }.joined(separator: " AND ")
    }

    static func insert(alias: String, database: String, table: String,
                       values: [String: String]) -> String {
        let cols = values.keys.sorted()
        let colList = cols.map(duckIdent).joined(separator: ", ")
        let valList = cols.map { value(values[$0] ?? "") }.joined(separator: ", ")
        return "INSERT INTO \(duckTable(alias: alias, database: database, table: table)) (\(colList)) VALUES (\(valList))"
    }

    /// `newValue == nil` sets the column to SQL NULL; a non-nil value (including the
    /// empty string) is written as a literal — so clearing a cell stores '' rather
    /// than silently turning it into NULL.
    static func update(alias: String, database: String, table: String,
                       column: String, newValue: String?,
                       primaryKey: [(column: String, value: String?)]) -> String {
        let set = newValue == nil
            ? "\(duckIdent(column)) = NULL"
            : "\(duckIdent(column)) = \(literal(newValue!))"
        return "UPDATE \(duckTable(alias: alias, database: database, table: table)) SET \(set) WHERE \(whereClause(primaryKey))"
    }

    static func delete(alias: String, database: String, table: String,
                       primaryKey: [(column: String, value: String?)]) -> String {
        "DELETE FROM \(duckTable(alias: alias, database: database, table: table)) WHERE \(whereClause(primaryKey))"
    }

    // MARK: - DDL (MySQL dialect)

    /// `SHOW FULL COLUMNS` reports absent metadata as SQL NULL — no collation on a
    /// numeric column, no default on a column that never had one — and that reaches
    /// ColumnInfo as the literal string "NULL". Emitting it back is a server error:
    /// `CHARACTER SET NULL` is a syntax error, and `NOT NULL DEFAULT NULL` is
    /// rejected as an invalid default.
    private static func isAbsent(_ s: String) -> Bool {
        s.isEmpty || s.uppercased() == "NULL"
    }

    static func columnDefinition(_ edit: ColumnEdit) -> String {
        var def = edit.fullType
        if !isAbsent(edit.encoding)  { def += " CHARACTER SET \(edit.encoding)" }
        if !isAbsent(edit.collation) { def += " COLLATE \(edit.collation)" }
        def += edit.nullable ? " NULL" : " NOT NULL"
        if !edit.defaultValue.isEmpty {
            let upper = edit.defaultValue.uppercased()
            if upper == "NULL" {
                // Only a nullable column may carry an explicit NULL default.
                if edit.nullable { def += " DEFAULT NULL" }
            } else if upper.hasPrefix("CURRENT_") || upper.hasSuffix(")") {
                def += " DEFAULT \(edit.defaultValue)"
            } else if Int(edit.defaultValue) != nil || Double(edit.defaultValue) != nil {
                def += " DEFAULT \(edit.defaultValue)"
            } else {
                def += " DEFAULT \(literal(edit.defaultValue))"
            }
        }
        if !edit.extra.isEmpty   { def += " \(edit.extra.uppercased())" }
        if !edit.comment.isEmpty { def += " COMMENT \(literal(edit.comment))" }
        return def
    }

    /// Renders a DEFAULT clause value: keywords and numbers bare, everything else quoted.
    private static func defaultClause(_ value: String, nullable: Bool) -> String {
        guard !value.isEmpty else { return "" }
        let upper = value.uppercased()
        if upper == "NULL" { return nullable ? " DEFAULT NULL" : "" }
        if upper.hasPrefix("CURRENT_") || upper.hasSuffix(")") { return " DEFAULT \(value)" }
        if Int(value) != nil || Double(value) != nil { return " DEFAULT \(value)" }
        return " DEFAULT \(literal(value))"
    }

    /// A standalone INSERT for the clipboard, pairing only the cells the row actually has.
    static func insertStatement(table: String, columns: [String], row: [String]) -> String {
        let pairs = zip(columns, row)
        let cols = pairs.map { mysqlIdent($0.0) }.joined(separator: ", ")
        let vals = pairs.map { $0.1 == "NULL" ? "NULL" : literal($0.1) }.joined(separator: ", ")
        return "INSERT INTO \(mysqlIdent(table)) (\(cols)) VALUES (\(vals));"
    }

    /// Multi-row, batched INSERT statements for a MySQL/MariaDB SQL dump. NULL is
    /// resolved from the parallel null mask (so a real NULL and the literal string
    /// "NULL" don't collapse), and every non-NULL value is emitted as an escaped
    /// string literal — which MySQL coerces into the target column type.
    static func dumpInsertStatements(table: String, columns: [String], rows: [[String]],
                                     nullMask: [[Bool]], batchSize: Int = 100) -> [String] {
        guard !columns.isEmpty, !rows.isEmpty else { return [] }
        let colList = columns.map(mysqlIdent).joined(separator: ", ")
        let prefix = "INSERT INTO \(mysqlIdent(table)) (\(colList)) VALUES"
        var out: [String] = []
        var i = 0
        while i < rows.count {
            let end = min(i + max(1, batchSize), rows.count)
            var tuples: [String] = []
            for ri in i..<end {
                let row = rows[ri]
                let vals = (0..<columns.count).map { ci -> String in
                    let isNull = ri < nullMask.count && ci < nullMask[ri].count && nullMask[ri][ci]
                    if isNull { return "NULL" }
                    return literal(ci < row.count ? row[ci] : "")
                }
                tuples.append("(\(vals.joined(separator: ", ")))")
            }
            out.append(prefix + "\n" + tuples.joined(separator: ",\n") + ";")
            i = end
        }
        return out
    }

    /// Batched, engine-quoted INSERTs for a CSV import. An empty field becomes NULL
    /// (so numeric/date columns accept blanks); any other value is emitted as an
    /// escaped string literal, which the server coerces to the column type. Rows are
    /// padded/truncated to `columns.count`. MySQL uses backticks, Postgres double
    /// quotes; both go through executeDDL's per-engine execute path.
    static func insertRows(engine: DatabaseEngine, database: String, table: String,
                           columns: [String], rows: [[String]], batchSize: Int = 200) -> [String] {
        guard !columns.isEmpty, !rows.isEmpty else { return [] }
        let ident: (String) -> String = engine == .postgres ? { duckIdent($0) } : { mysqlIdent($0) }
        let ref = ddlTable(engine: engine, database: database, table: table)
        let colList = columns.map(ident).joined(separator: ", ")
        let prefix = "INSERT INTO \(ref) (\(colList)) VALUES"
        var out: [String] = []
        var i = 0
        while i < rows.count {
            let end = min(i + max(1, batchSize), rows.count)
            var tuples: [String] = []
            for ri in i..<end {
                let row = rows[ri]
                let vals = (0..<columns.count).map { ci -> String in
                    let v = ci < row.count ? row[ci] : ""
                    return v.isEmpty ? "NULL" : literal(v)
                }
                tuples.append("(\(vals.joined(separator: ", ")))")
            }
            out.append(prefix + "\n" + tuples.joined(separator: ",\n"))
            i = end
        }
        return out
    }

    /// Guess a column type for "create table from CSV" by sampling the values:
    /// all non-empty values integer → INT; all numeric → DOUBLE; a value longer than
    /// 255 chars → TEXT; otherwise VARCHAR(255). An all-empty column defaults to VARCHAR.
    static func inferCSVColumnType(_ values: [String]) -> (base: String, length: String) {
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if trimmed.isEmpty { return ("VARCHAR", "255") }
        // A zero-padded integer (zip code, phone, "007") must stay text or it loses
        // its leading zeros on import — so such columns are never numeric.
        func leadingZeroInt(_ v: String) -> Bool {
            let d = v.hasPrefix("-") ? String(v.dropFirst()) : v
            return d.count > 1 && d.first == "0" && d.allSatisfy(\.isNumber)
        }
        let anyLeadingZero = trimmed.contains(where: leadingZeroInt)
        if !anyLeadingZero, trimmed.allSatisfy({ Int64($0) != nil }) { return ("INT", "") }
        if !anyLeadingZero, trimmed.allSatisfy({ Double($0)?.isFinite == true }) { return ("DOUBLE", "") }
        if trimmed.contains(where: { $0.count > 255 }) { return ("TEXT", "") }
        return ("VARCHAR", "255")
    }

    /// Sanitize a CSV header cell into a safe SQL column identifier.
    static func sanitizeColumnName(_ raw: String, fallback: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
            .map { ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
        if s.isEmpty { s = fallback }
        if let first = s.first, first.isNumber { s = "c_" + s }
        return s
    }

    static func createTable(database: String, table: String, columns: [NewColumnDef],
                            engine: String, charset: String) -> String {
        var colDefs: [String] = []
        var pkCols:  [String] = []

        for col in columns {
            var def = "  \(mysqlIdent(col.name)) \(col.fullType)"
            if !col.nullable     { def += " NOT NULL" }
            if col.autoIncrement { def += " AUTO_INCREMENT" }
            def += defaultClause(col.defaultValue, nullable: col.nullable)
            colDefs.append(def)
            if col.isPrimaryKey { pkCols.append(mysqlIdent(col.name)) }
        }
        if !pkCols.isEmpty {
            colDefs.append("  PRIMARY KEY (\(pkCols.joined(separator: ", ")))")
        }

        return """
            CREATE TABLE \(mysqlTable(database: database, table: table)) (
            \(colDefs.joined(separator: ",\n"))
            ) ENGINE=\(engine) DEFAULT CHARSET=\(charset)
            """
    }

    /// Reconstructs a CREATE TABLE statement for display from fetched metadata.
    /// Panels render "—" for a metadata row that came back empty; those are skipped.
    static func showCreateTable(table: String, columns: [ColumnInfo], indexes: [IndexInfo],
                                engine: String, collation: String, autoIncrement: String,
                                comment: String) -> String {
        func present(_ s: String) -> Bool { !s.isEmpty && s != "—" }

        var lines: [String] = []
        for col in columns {
            var line = "  \(mysqlIdent(col.name)) \(col.dataType)"
            if !col.nullable { line += " NOT NULL" }
            line += defaultClause(col.defaultValue, nullable: col.nullable)
            if !col.extra.isEmpty   { line += " \(col.extra.uppercased())" }
            if !col.comment.isEmpty { line += " COMMENT \(literal(col.comment))" }
            lines.append(line)
        }
        for idx in indexes {
            let cols = idx.columns.map(mysqlIdent).joined(separator: ", ")
            if idx.name.uppercased() == "PRIMARY" {
                lines.append("  PRIMARY KEY (\(cols))")
            } else if idx.unique {
                lines.append("  UNIQUE KEY \(mysqlIdent(idx.name)) (\(cols)) USING \(idx.indexType)")
            } else {
                lines.append("  KEY \(mysqlIdent(idx.name)) (\(cols)) USING \(idx.indexType)")
            }
        }

        var sql = "CREATE TABLE \(mysqlIdent(table)) (\n" + lines.joined(separator: ",\n") + "\n)"
        var opts: [String] = []
        if present(engine) { opts.append("ENGINE=\(engine)") }
        if let ai = Int(autoIncrement), ai > 0 { opts.append("AUTO_INCREMENT=\(ai)") }
        let charset = collation.components(separatedBy: "_").first ?? ""
        if present(charset) {
            opts.append("DEFAULT CHARSET=\(charset)")
            if present(collation) { opts.append("COLLATE=\(collation)") }
        }
        if present(comment) { opts.append("COMMENT=\(literal(comment))") }
        if !opts.isEmpty { sql += "\n  " + opts.joined(separator: " ") }
        return sql + ";"
    }

    static func addForeignKey(database: String, table: String, name: String, column: String,
                              referencedTable: String, referencedColumn: String,
                              onDelete: String, onUpdate: String) -> String {
        "ALTER TABLE \(mysqlTable(database: database, table: table)) "
        + "ADD CONSTRAINT \(mysqlIdent(name)) FOREIGN KEY (\(mysqlIdent(column))) "
        + "REFERENCES \(mysqlIdent(referencedTable)) (\(mysqlIdent(referencedColumn))) "
        + "ON DELETE \(onDelete) ON UPDATE \(onUpdate)"
    }

    static func dropForeignKey(database: String, table: String, name: String) -> String {
        "ALTER TABLE \(mysqlTable(database: database, table: table)) DROP FOREIGN KEY \(mysqlIdent(name))"
    }

    static func createTrigger(database: String, table: String, name: String,
                              timing: String, event: String, body: String) -> String {
        // Qualified by database: mysql_execute runs in the server's own session,
        // whose default schema is not necessarily the one selected in the sidebar.
        "CREATE TRIGGER \(mysqlIdent(name)) \(timing) \(event) "
        + "ON \(mysqlTable(database: database, table: table)) FOR EACH ROW \(body)"
    }

    static func dropTrigger(database: String, name: String) -> String {
        "DROP TRIGGER IF EXISTS \(mysqlTable(database: database, table: name))"
    }

    static func alterStatements(database: String, table: String,
                                columnEdits: [ColumnEdit],
                                originalColumns: [ColumnInfo],
                                deletedColumnNames: Set<String>,
                                indexEdits: [IndexEdit],
                                deletedIndexNames: Set<String>) -> [String] {
        let tbl = mysqlTable(database: database, table: table)
        var stmts: [String] = []

        for name in deletedColumnNames.sorted() {
            stmts.append("ALTER TABLE \(tbl) DROP COLUMN \(mysqlIdent(name))")
        }

        for edit in columnEdits where !deletedColumnNames.contains(edit.originalName ?? "") {
            let def = columnDefinition(edit)
            if edit.isNew {
                stmts.append("ALTER TABLE \(tbl) ADD COLUMN \(mysqlIdent(edit.name)) \(def)")
            } else if let orig = originalColumns.first(where: { $0.name == edit.originalName }),
                      edit.hasChanges(from: orig) {
                let origName = edit.originalName ?? edit.name
                if edit.name != origName {
                    stmts.append("ALTER TABLE \(tbl) CHANGE \(mysqlIdent(origName)) \(mysqlIdent(edit.name)) \(def)")
                } else {
                    stmts.append("ALTER TABLE \(tbl) MODIFY COLUMN \(mysqlIdent(edit.name)) \(def)")
                }
            }
        }

        for name in deletedIndexNames.sorted() {
            if name == "PRIMARY" {
                stmts.append("ALTER TABLE \(tbl) DROP PRIMARY KEY")
            } else {
                stmts.append("DROP INDEX \(mysqlIdent(name)) ON \(tbl)")
            }
        }

        for edit in indexEdits where edit.isNew {
            let cols = edit.columns.map(mysqlIdent).joined(separator: ", ")
            switch edit.indexType {
            case "PRIMARY KEY":
                stmts.append("ALTER TABLE \(tbl) ADD PRIMARY KEY (\(cols))")
            case "UNIQUE":
                stmts.append("ALTER TABLE \(tbl) ADD UNIQUE INDEX \(mysqlIdent(edit.name)) (\(cols))")
            default:
                stmts.append("ALTER TABLE \(tbl) ADD INDEX \(mysqlIdent(edit.name)) (\(cols))")
            }
        }

        return stmts
    }
}

// MARK: - Cross-server semi-join reduction
//
// A query like `SELECT … FROM a.big WHERE k IN (SELECT k FROM b.small WHERE …)` spans
// two servers, so DuckDB's scanner drags both whole tables to the client and joins
// locally — catastrophic when a.big has hundreds of millions of rows. Instead we can
// run the subquery on b first, inline its (few) values, and run the outer query on a
// through the fast passthrough — the "semi-join reduction" a distributed engine does.
// Detection is deliberately conservative: only a single, non-correlated `IN (SELECT …)`
// that touches exactly one OTHER server. Anything else returns nil and the caller uses
// the scanner, so this can only make queries faster, never change their results.

nonisolated extension SQLBuilder {

    struct SemiJoin: Equatable {
        let subAlias: String       // server the subquery runs on
        let outerAlias: String     // server the outer query runs on
        let subquery: String       // subquery text, still carrying its alias
        let outerPrefix: String    // outer SQL up to and including the "IN ("
        let outerSuffix: String    // outer SQL from the matching ")" onward
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    /// The one connection a Query-tab statement runs on: the server it names, or, when it
    /// names none, the connection picked at the top of the left panel (the only one, or
    /// the active tab's), as in Sequel Ace, where each window has one connection. Nil
    /// when it names several servers: that is a cross-server query.
    static func soleTarget(of sql: String, connections: [Connection], active: String?) -> Connection? {
        let named = connections.filter { referencesAlias(sql, $0.alias) }
        if named.count == 1 { return named[0] }
        guard named.isEmpty else { return nil }
        if connections.count == 1 { return connections[0] }
        return connections.first { $0.alias == active }
    }

    /// True when `alias` appears as an `alias.` qualifier at a word boundary, outside
    /// string/identifier quotes.
    static func referencesAlias(_ sql: String, _ alias: String) -> Bool {
        let a = Array(alias.lowercased()); let n = a.count
        guard n > 0 else { return false }
        let chars = Array(sql); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" {
                let q = c; i += 1
                while i < chars.count { if chars[i] == q { i += 1; break }; i += 1 }
                continue
            }
            if c.lowercased().first == a.first {
                let prevWord = i > 0 && (isWordChar(chars[i-1]) || chars[i-1] == ".")
                if !prevWord && i + n < chars.count {
                    var matched = true
                    for k in 0..<n where chars[i+k].lowercased().first != a[k] { matched = false; break }
                    if matched && chars[i+n] == "." { return true }
                }
            }
            i += 1
        }
        return false
    }

    /// Index of the ')' matching the '(' at `open`, skipping quoted spans; nil if none.
    private static func matchingParen(_ chars: [Character], from open: Int) -> Int? {
        var depth = 0; var i = open
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" {
                let q = c; i += 1
                while i < chars.count { if chars[i] == q { i += 1; break }; i += 1 }
                continue
            }
            if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    /// Detects a reducible cross-server `IN (SELECT …)`. See the section note.
    static func detectSemiJoin(_ sql: String, aliases: [String]) -> SemiJoin? {
        let chars = Array(sql)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" {
                let q = c; i += 1
                while i < chars.count { if chars[i] == q { i += 1; break }; i += 1 }
                continue
            }
            // A standalone word "IN"
            if (c == "i" || c == "I"),
               (i == 0 || !isWordChar(chars[i-1])),
               i + 1 < chars.count, (chars[i+1] == "n" || chars[i+1] == "N"),
               (i + 2 >= chars.count || !isWordChar(chars[i+2])) {
                var j = i + 2
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j < chars.count && chars[j] == "(", let close = matchingParen(chars, from: j) {
                    let inner = String(chars[(j+1)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if inner.lowercased().hasPrefix("select") {
                        let prefix = String(chars[0...j])       // "… IN ("
                        let suffix = String(chars[close...])     // ") …"
                        let subA = aliases.filter { referencesAlias(inner, $0) }
                        let outerA = Set(aliases.filter { referencesAlias(prefix, $0) || referencesAlias(suffix, $0) })
                        if subA.count == 1, outerA.count == 1,
                           let s = subA.first, let o = outerA.first, s != o {
                            return SemiJoin(subAlias: s, outerAlias: o,
                                            subquery: inner, outerPrefix: prefix, outerSuffix: suffix)
                        }
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// `'v1', 'v2', …` from a result column (NULLs dropped). "NULL" when empty, which
    /// makes `IN (NULL)` — valid SQL that matches nothing.
    static func inValueList(_ values: [String], mask: [Bool]) -> String {
        var out: [String] = []
        for (idx, v) in values.enumerated() where !(idx < mask.count && mask[idx]) {
            out.append(literal(v))
        }
        return out.isEmpty ? "NULL" : out.joined(separator: ", ")
    }

    // MARK: - Cross-server INNER join reduction
    //
    // A two-table INNER join across servers — `… FROM a.big x JOIN b.small y ON x.k = y.k …`
    // — can be sped up by a semi-join reduction: fetch the distinct join keys from the
    // smaller side and fetch only the matching rows of the bigger side (pushed to its
    // server), then let DuckDB join the reduced inputs. This is PROVABLY equivalent for
    // an INNER join: rows of the big side whose key isn't among the small side's keys
    // could never have joined, so dropping them can't change the result — regardless of
    // the WHERE clause (which DuckDB still applies, unchanged). Only inner joins qualify;
    // LEFT/RIGHT/FULL/CROSS and 3+-table queries return nil and use the scanner.

    struct CrossJoin: Equatable {
        struct Side: Equatable {
            let server: String      // connection alias
            let table: String       // table name
            let tableAlias: String  // alias used in the query (the table name when none)
            let key: String         // bare join column on this side
        }
        let a: Side
        let b: Side
        let fromJoinClause: String  // exact "FROM … JOIN … ON …" substring (to be replaced)
    }

    enum CrossJoinStrategy: Equatable { case reduce, fetchWhole }

    /// How to bring the big side of a cross-server inner join over. Pushing the probe's
    /// distinct keys down as `WHERE key IN (…)` wins when the list is selective. When it
    /// matches most of the table it loses badly even with an index: measured on a real server, a
    /// key list covering 2.6M of 2.6M rows took the server 300s to return through the
    /// index, versus 30s for a plain whole-table fetch. The server's optimizer estimates
    /// the match count instantly (EXPLAIN); at 40% or more of the table, fetch the whole
    /// table and let the join filter it as it streams in. No estimate keeps the reduction.
    static func crossJoinStrategy(estimatedMatchedRows: Int?, bigRowEstimate: Int?) -> CrossJoinStrategy {
        guard let matched = estimatedMatchedRows, let big = bigRowEstimate, big > 0 else { return .reduce }
        return Double(matched) >= 0.4 * Double(big) ? .fetchWhole : .reduce
    }

    /// Which side of a two-table cross-server join is the BIG side — the one that comes
    /// from its server through the passthrough and streams through the join — true for
    /// A. It must have a passthrough: with a local SQLite table on the other side, the
    /// MySQL/Postgres side is big whatever the row estimates say. When both sides have
    /// one, the larger estimate is big, an unknown estimate counting as the largest
    /// (a tie makes A the probe). nil when neither side has a passthrough: no plan.
    static func crossJoinBigSide(estA: Int?, estB: Int?, canA: Bool, canB: Bool) -> Bool? {
        switch (canA, canB) {
        case (false, false): return nil
        case (true, false):  return true
        case (false, true):  return false
        case (true, true):   return (estA ?? Int.max) > (estB ?? Int.max)
        }
    }

    /// Estimated rows a statement will produce, from MySQL/MariaDB `EXPLAIN` output: the
    /// sum over plan rows of `rows` × `filtered`/100 (`filtered` defaults to 100 when the
    /// column is absent). nil when there is no `rows` column or a value isn't a number.
    static func explainEstimatedRows(columns: [String], rows: [[String]]) -> Int? {
        let lower = columns.map { $0.lowercased() }
        guard let ri = lower.firstIndex(of: "rows") else { return nil }
        let fi = lower.firstIndex(of: "filtered")
        var total = 0.0
        for row in rows {
            guard ri < row.count, let n = Double(row[ri]) else { return nil }
            let pct = fi.flatMap { $0 < row.count ? Double(row[$0]) : nil } ?? 100
            total += n * pct / 100
        }
        return Int(total.rounded())
    }

    private static let joinKeywords: Set<String> =
        ["left", "right", "full", "outer", "inner", "cross", "natural", "join", "on",
         "where", "group", "order", "limit", "using", "as", "having", "union"]

    /// Detects a reducible two-table cross-server inner join. Conservative: exactly one
    /// JOIN, both tables `alias.table` on different connected servers, a single
    /// `x.k = y.k` ON condition with both sides qualified — or the comma form of the
    /// same join, `FROM a.t x, b.u y WHERE x.k = y.k AND …` (see detectCommaJoin).
    /// Anything else → nil.
    static func detectCrossJoin(_ sql: String, aliases: [String]) -> CrossJoin? {
        // Match on a copy with string literals blanked (length preserved) so the pattern
        // can't match inside a quoted value; ranges still map to the original text.
        let scan = Array(sql)
        var blanked = scan
        var inStr = false
        for i in blanked.indices {
            if blanked[i] == "'" { inStr.toggle(); continue }
            if inStr { blanked[i] = " " }
        }
        let scanStr = String(blanked)

        // Reject 3+-table queries (more than one JOIN) — reduction logic only covers two.
        // Counted as a word, so a JOIN at the start of a line is seen too.
        let joinCount = scanStr.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            .filter { $0 == "join" }.count
        if joinCount == 0 { return detectCommaJoin(sql, scanStr: scanStr, aliases: aliases) }
        guard joinCount == 1 else { return nil }

        let pattern = #"(?i)\bFROM\s+(\w+)\.(\w+)(?:\s+(?:AS\s+)?(\w+))?\s+(?:INNER\s+)?JOIN\s+(\w+)\.(\w+)(?:\s+(?:AS\s+)?(\w+))?\s+ON\s+([\w.]+)\s*=\s*([\w.]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = scanStr as NSString
        guard let m = re.firstMatch(in: scanStr, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func grp(_ i: Int) -> String? {
            let r = m.range(at: i); return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let sA = grp(1), let tA = grp(2), let sB = grp(4), let tB = grp(5),
              let onL = grp(7), let onR = grp(8) else { return nil }
        let aliasA = grp(3) ?? tA
        let aliasB = grp(6) ?? tB
        // Reject if an "alias" is actually a SQL keyword (e.g. a LEFT/RIGHT/CROSS join
        // slipped into the alias slot) — only plain inner joins are equivalence-safe.
        guard !joinKeywords.contains(aliasA.lowercased()),
              !joinKeywords.contains(aliasB.lowercased()),
              aliases.contains(sA), aliases.contains(sB), sA != sB else { return nil }

        func sideOf(_ ref: String) -> Int? {            // 0 = A, 1 = B
            let parts = ref.split(separator: ".")
            guard parts.count == 2 else { return nil }  // require a qualified key
            let p = String(parts[0])
            if p == aliasA || p == tA { return 0 }
            if p == aliasB || p == tB { return 1 }
            return nil
        }
        func bareKey(_ ref: String) -> String { String(ref.split(separator: ".").last ?? "") }
        guard let lSide = sideOf(onL), let rSide = sideOf(onR), lSide != rSide else { return nil }
        let aKey = lSide == 0 ? bareKey(onL) : bareKey(onR)
        let bKey = lSide == 1 ? bareKey(onL) : bareKey(onR)
        let clause = (sql as NSString).substring(with: m.range)   // from the ORIGINAL sql
        return CrossJoin(a: .init(server: sA, table: tA, tableAlias: aliasA, key: aKey),
                         b: .init(server: sB, table: tB, tableAlias: aliasB, key: bKey),
                         fromJoinClause: clause)
    }

    /// The comma form of the two-table inner join — `FROM a.t x, b.u y WHERE x.k = y.k
    /// AND …` — just as common as JOIN … ON and the same join. Exactly two tables, both
    /// `alias.table` on different servers, directly followed by WHERE, and the key
    /// equality is one of the WHERE's top-level AND conjuncts (one under an OR, or
    /// inside parentheses, is not the join). `fromJoinClause` is the FROM list alone;
    /// the WHERE keeps the equality, which is harmless beside the rebuilt ON.
    private static func detectCommaJoin(_ sql: String, scanStr: String, aliases: [String]) -> CrossJoin? {
        let pattern = #"(?i)\bFROM\s+(\w+)\.(\w+)(?:\s+(?:AS\s+)?(\w+))?\s*,\s*(\w+)\.(\w+)(?:\s+(?:AS\s+)?(\w+))?(?=\s+WHERE\b)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = scanStr as NSString
        guard let m = re.firstMatch(in: scanStr, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func grp(_ i: Int) -> String? {
            let r = m.range(at: i); return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let sA = grp(1), let tA = grp(2), let sB = grp(4), let tB = grp(5) else { return nil }
        let aliasA = grp(3) ?? tA
        let aliasB = grp(6) ?? tB
        guard !joinKeywords.contains(aliasA.lowercased()), !joinKeywords.contains(aliasB.lowercased()),
              aliases.contains(sA), aliases.contains(sB), sA != sB,
              let whereText = analyzeSelect(sql, aliases: aliases)?.whereClause else { return nil }

        func sideOf(_ parts: [String]) -> Int? {            // 0 = A, 1 = B; a qualified ref only
            guard parts.count == 2 else { return nil }
            if parts[0] == aliasA || parts[0] == tA { return 0 }
            if parts[0] == aliasB || parts[0] == tB { return 1 }
            return nil
        }
        for conj in SQLTok.conjuncts(whereText) where conj.count == 3 {
            let t = Array(conj)
            guard case .ident(let l, _) = t[0].kind, case .op("=") = t[1].kind, case .ident(let r, _) = t[2].kind,
                  let lSide = sideOf(l), let rSide = sideOf(r), lSide != rSide else { continue }
            let aKey = lSide == 0 ? l[1] : r[1]
            let bKey = lSide == 1 ? l[1] : r[1]
            let clause = (sql as NSString).substring(with: m.range)   // from the ORIGINAL sql
            return CrossJoin(a: .init(server: sA, table: tA, tableAlias: aliasA, key: aKey),
                             b: .init(server: sB, table: tB, tableAlias: aliasB, key: bKey),
                             fromJoinClause: clause)
        }
        return nil
    }
}

// MARK: - Cross-engine scanner fallback: materialize remote tables via passthrough
//
// When a multi-server query matches none of the fast reductions (a 3+-table join, a
// non-equi join, a constant-filter "join", a UNION …) the planner falls back to
// DuckDB's raw ATTACH scanner spanning the servers. That scanner does NOT push work
// to MySQL/Postgres: it drags each remote table across the wire row by row, which
// over a VPN is ~130x slower than the mysql_query/postgres_query passthrough that
// bulk-fetches server-side. planFallback rewrites such a query so every remote
// (MySQL/Postgres) table is read from a DuckDB TEMP table the caller fills through
// the fast passthrough instead. Local SQLite references are left untouched — they
// are a fast local-file scan already, and the caller's expandAliases turns them into
// the 3-part form DuckDB needs. The scanner remains the backstop if materialization
// fails, so results can only get faster, never change.

nonisolated extension SQLBuilder {

    struct FallbackPlan: Equatable {
        /// One remote table to copy, via passthrough, into `temp`.
        struct Materialization: Equatable {
            let alias: String   // canonical connection alias (the passthrough target)
            let table: String   // table name exactly as written in the query
            let temp: String    // DuckDB-quoted temp identifier it is materialized into
        }
        let materializations: [Materialization]   // first-appearance order, deduped
        let rewrittenSQL: String                  // reads the temp tables in their place
    }

    /// Finds every remote `alias.table` reference in `sql` (alias ∈ `remoteAliases`,
    /// matched case-insensitively) and rewrites each to the temp identifier returned by
    /// `tempName`, called once per distinct (canonical alias, table). References whose
    /// alias is not remote — and already-3-part `a.b.c` forms — are left verbatim for
    /// the caller's expandAliases pass. Quoted identifiers and string literals are
    /// skipped so an alias inside them is never matched.
    static func planFallback(_ sql: String,
                             remoteAliases: Set<String>,
                             tempName: (_ alias: String, _ table: String) -> String) -> FallbackPlan {
        guard !remoteAliases.isEmpty else { return FallbackPlan(materializations: [], rewrittenSQL: sql) }
        var canonicalByLower: [String: String] = [:]
        for a in remoteAliases { canonicalByLower[a.lowercased()] = a }

        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        let chars = Array(sql)
        var out: [Character] = []
        out.reserveCapacity(chars.count + 32)
        var materializations: [FallbackPlan.Materialization] = []
        var tempByKey: [String: String] = [:]      // "alias\0table" → temp ident
        var i = 0

        while i < chars.count {
            let c = chars[i]
            // Copy quoted spans ('…' and "…") verbatim.
            if c == "'" || c == "\"" {
                let q = c; out.append(c); i += 1
                while i < chars.count { out.append(chars[i]); if chars[i] == q { i += 1; break }; i += 1 }
                continue
            }
            // A word that starts an identifier (not preceded by a word char or a dot —
            // so a column tail like `o.cid` or a 3-part middle never starts a match).
            let prevIsWordOrDot = i > 0 && (isWord(chars[i-1]) || chars[i-1] == ".")
            if isWord(c), !prevIsWordOrDot {
                var j = i
                while j < chars.count && isWord(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                if let canonical = canonicalByLower[word.lowercased()],
                   j < chars.count, chars[j] == "." {
                    var k = j + 1
                    let tStart = k
                    while k < chars.count && isWord(chars[k]) { k += 1 }
                    let table = String(chars[tStart..<k])
                    // Two-part only: a following "." means it is already 3-part.
                    if !table.isEmpty, (k == chars.count || chars[k] != ".") {
                        let key = canonical + "\u{0}" + table
                        let temp: String
                        if let existing = tempByKey[key] {
                            temp = existing
                        } else {
                            temp = tempName(canonical, table)
                            tempByKey[key] = temp
                            materializations.append(.init(alias: canonical, table: table, temp: temp))
                        }
                        out += Array(temp)
                        i = k
                        continue
                    }
                }
                // Not a remote 2-part reference — copy the whole word verbatim.
                out += chars[i..<j]
                i = j
                continue
            }
            out.append(c); i += 1
        }
        return FallbackPlan(materializations: materializations, rewrittenSQL: String(out))
    }
}
