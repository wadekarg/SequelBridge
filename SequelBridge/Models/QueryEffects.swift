//
//  QueryEffects.swift
//  SequelBridge
//
//  What a Query-tab run that succeeded changes in the left panel, by Sequel Ace's rules
//  (SPCustomQuery and SASQLDatabaseContext): `USE db` picks that database, dropping the
//  picked database leaves none, CREATE / ALTER / DROP / RENAME re-read the table list,
//  and creating, dropping or picking a database re-reads the database list.
//

import Foundation

nonisolated enum QueryEffects {
    struct Outcome: Equatable {
        /// The database picked after the run; nil when the run dropped the picked one.
        var database: String?
        var reloadTables = false
        var reloadDatabases = false
    }

    static func afterRun(_ sql: String, database: String?, caseSensitive: Bool = true) -> Outcome {
        var outcome = Outcome(database: database)
        for statement in statements(sql) {
            if tableDDLVerbs.contains(firstWord(statement)) { outcome.reloadTables = true }
            if matches(databaseDDL, statement) { outcome.reloadDatabases = true }
            if let picked = identifier(useStatement, in: statement) ?? identifier(setSearchPath, in: statement) {
                if picked != outcome.database { outcome.database = picked; outcome.reloadDatabases = true }
            } else if let dropped = identifier(dropDatabase, in: statement), let current = outcome.database,
                      dropped == current || (!caseSensitive && dropped.caseInsensitiveCompare(current) == .orderedSame) {
                outcome.database = nil
            }
        }
        return outcome
    }

    /// The database `sql` picks when it is a lone `USE` statement, or on PostgreSQL the
    /// schema a lone `SET search_path TO x` picks.
    static func soleUse(_ sql: String) -> String? {
        let all = statements(sql)
        guard all.count == 1 else { return nil }
        return identifier(useStatement, in: all[0]) ?? identifier(setSearchPath, in: all[0])
    }

    /// A lone SET or RESET: it changes only the connection that runs it, which here is
    /// the statement's own (a script's statements share one, needsOneSession).
    static func isSessionSetting(_ sql: String) -> Bool {
        let all = statements(sql)
        return all.count == 1 && matches(sessionSetting, all[0])
    }

    /// What a lone SET or RESET says it did.
    static let settingNote = "Done. A setting lasts for the run it is in: run it together with the statements it is for (SET …; SELECT …)."

    /// On MySQL, whether the Query tab runs `sql` on the server as typed, as Sequel Ace
    /// does: a statement that returns no rows. DuckDB refused MySQL's own syntax and
    /// changed what it accepted (a VARCHAR(40) column became TEXT). Reads already go to
    /// the server, `USE` has a path of its own, and transaction control stays DuckDB's,
    /// whose transaction keeps one server connection for the statements in it.
    /// On PostgreSQL likewise (DuckDB dropped a VARCHAR's length and divided integers
    /// as floats), except SET and RESET: on the server they'd change the session of a
    /// connection the app goes on to reuse, so they stay DuckDB's as before.
    static func runsAsTyped(_ sql: String, engine: DatabaseEngine = .mysql) -> Bool {
        guard engine == .mysql || engine == .postgres, let statement = statements(sql).first else { return false }
        if SQLBuilder.isRowReturning(statement) || soleUse(statement) != nil { return false }
        if engine == .postgres, matches(sessionSetting, statement) { return false }
        return !matches(transactionControl, statement)
    }

    /// Whether the Query tab runs `sql` on the app's own client for the server, since the
    /// passthrough can't: mysql_query prepares every statement, and MySQL can't prepare
    /// SHOW CREATE TABLE, SHOW PROCESSLIST, SHOW GRANTS, SHOW WARNINGS, HELP or CHECK
    /// TABLE; postgres_query nests every statement as a subquery, where PostgreSQL takes
    /// neither SHOW nor EXPLAIN. Their results are small, so they come back whole.
    static func runsOnNativeClient(_ sql: String, engine: DatabaseEngine) -> Bool {
        guard let statement = statements(sql).first else { return false }
        switch engine {
        // CALL too: run as typed, a procedure's rows left the scanner's connection out of
        // step ("Commands out of sync"), so it failed.
        case .mysql:               return ["SHOW", "HELP", "CHECK", "CHECKSUM", "CALL"].contains(firstWord(statement))
        case .postgres:            return ["SHOW", "EXPLAIN"].contains(firstWord(statement))
        case .sqlite, .clickhouse: return false
        }
    }

    /// Whether a script's statements must share one server connection: one sets what a
    /// later one reads (a variable, a temporary table, a prepared statement, a setting, a
    /// transaction, a lock, a cursor). One connection per statement lost it: SET @d =
    /// '2026-01-01'; SELECT … WHERE placed > @d counted nothing, without an error.
    static func needsOneSession(_ statements: [String], engine: DatabaseEngine) -> Bool {
        // A SQLite script runs in one go, as in the sqlite3 shell: a transaction, a temporary
        // table or a PRAGMA carries to the statements after it.
        if engine == .sqlite { return statements.count > 1 }
        guard statements.count > 1, engine == .mysql || engine == .postgres else { return false }
        let sessionWords: Set<String> = ["SET", "RESET", "PREPARE", "EXECUTE", "DEALLOCATE", "BEGIN", "START", "COMMIT",
                                         "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "LOCK", "UNLOCK", "LISTEN", "UNLISTEN",
                                         "DECLARE", "FETCH", "MOVE", "CLOSE", "DISCARD"]
        return statements.contains { raw in
            guard let s = Self.statements(raw).first else { return false }
            if sessionWords.contains(firstWord(s)) || matches(temporaryTable, s) { return true }
            guard engine == .mysql else { return false }
            let bare = s.replacingOccurrences(of: #"'(?:''|\\.|[^'])*'"#, with: "''", options: .regularExpression)
            return bare.range(of: #"(?<![@\w])@[A-Za-z_]"#, options: .regularExpression) != nil            // @var, not @@var
                || bare.range(of: #"(?i)\b(LAST_INSERT_ID|FOUND_ROWS|ROW_COUNT)\s*\("#, options: .regularExpression) != nil
        }
    }

    /// A WITH whose parts change rows (PostgreSQL's data-modifying CTE, "WITH moved AS
    /// (DELETE … RETURNING *) SELECT …"): a write, though it starts like a read, and one
    /// PostgreSQL refuses inside the subquery the passthrough wraps every read in.
    static func isDataModifyingWith(_ sql: String) -> Bool {
        guard let statement = statements(sql).first, firstWord(statement) == "WITH" else { return false }
        let bare = statement.replacingOccurrences(of: #"'(?:''|[^'])*'"#, with: "''", options: .regularExpression)
        return bare.range(of: #"(?i)\b(INSERT|UPDATE|DELETE|MERGE)\b"#, options: .regularExpression) != nil
    }

    /// BEGIN, START TRANSACTION, COMMIT, ROLLBACK or END.
    static func isTransactionControl(_ sql: String) -> Bool { transactionChange(sql) != nil }

    /// Whether `sql` begins a transaction (true) or ends one (false); nil for any other.
    static func transactionChange(_ sql: String) -> Bool? {
        guard let statement = statements(sql).first, matches(transactionControl, statement) else { return nil }
        return ["BEGIN", "START"].contains(firstWord(statement))
    }

    /// Why the Query tab won't run `sql` on MySQL, if it won't. The app's statements
    /// don't share one server connection, so a table lock, or autocommit turned off,
    /// would stay on a connection the app goes on to reuse.
    static func refusal(_ sql: String) -> String? {
        guard let statement = statements(sql).first else { return nil }
        if matches(lockTables, statement) {
            return "LOCK TABLES and UNLOCK TABLES aren't run here: SequelBridge's statements don't share "
                + "one server connection, so a lock would stay on a connection the app reuses."
        }
        if matches(autocommit, statement) {
            return "SET autocommit isn't run here: SequelBridge's statements don't share one server "
                + "connection. BEGIN … COMMIT keeps one connection for the statements between them."
        }
        return nil
    }

    /// Each statement of `sql` with its comments taken out (outside quotes), trimmed.
    static func statements(_ sql: String) -> [String] {
        var out: [String] = [], current = ""
        let c = Array(sql)
        var i = 0
        var quote: Character? = nil
        while i < c.count {
            let ch = c[i]
            if let q = quote {
                current.append(ch)
                if ch == q, i + 1 < c.count, c[i + 1] == q { current.append(c[i + 1]); i += 2; continue }   // doubled quote
                if ch == "\\", q != "`", i + 1 < c.count { current.append(c[i + 1]); i += 2; continue }   // \' in a string
                if ch == q { quote = nil }
                i += 1; continue
            }
            if ch == "'" || ch == "\"" || ch == "`" { quote = ch; current.append(ch); i += 1; continue }
            // MySQL comments: "#" and "-- " to the end of the line, "/* … */".
            if ch == "#" || (ch == "-" && i + 1 < c.count && c[i + 1] == "-" && (i + 2 == c.count || c[i + 2].isWhitespace)) {
                while i < c.count, c[i] != "\n" { i += 1 }
                current.append(" "); continue
            }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                // MySQL's executable comment, /*!NNNNN code */ (MariaDB: /*M!NNNNN code */),
                // runs its code: a mysqldump file is full of them.
                var j = i + 2
                var executable = false
                if j < c.count, c[j] == "!" { executable = true; j += 1 }
                else if j + 1 < c.count, c[j] == "M", c[j + 1] == "!" { executable = true; j += 2 }
                if executable { while j < c.count, c[j].isNumber { j += 1 } }
                var end = j
                while end + 1 < c.count, !(c[end] == "*" && c[end + 1] == "/") { end += 1 }
                if executable { current += " " + String(c[j..<min(end, c.count)]) + " " } else { current.append(" ") }
                i = min(end + 2, c.count)
                continue
            }
            if ch == ";" { out.append(current); current = ""; i += 1; continue }
            current.append(ch); i += 1
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: - Patterns (Sequel Ace's, applied to a statement with its comments taken out)

    private static let tableDDLVerbs: Set<String> = ["CREATE", "ALTER", "DROP", "RENAME"]
    private static let name = #"(`(?:``|[^`])*`|"(?:""|[^"])*"|[^\s;]+)"#
    private static let gap = #"(?:\s+|(?=[`"]))"#
    private static let useStatement = regex("^USE\(gap)\(name)\\s*$")
    private static let dropDatabase = regex("^DROP\\s+(?:DATABASE|SCHEMA)\(gap)(?:IF\\s+EXISTS\(gap))?\(name)\\s*$")
    private static let databaseDDL = regex("^(?:CREATE|DROP)\\s+(?:DATABASE|SCHEMA)\\b")
    private static let transactionControl = regex("^(?:BEGIN|START\\s+TRANSACTION|COMMIT|ROLLBACK|END)\\b")
    private static let sessionSetting = regex("^(?:SET|RESET)\\b")
    private static let lockTables = regex("^(?:UN)?LOCK\\s+TABLES?\\b")
    private static let setSearchPath = regex("^SET\\s+(?:SESSION\\s+)?search_path\\s*(?:TO|=)\\s*\(name)\\s*$")
    private static let temporaryTable = regex("^CREATE\\s+(?:GLOBAL\\s+|LOCAL\\s+)?TEMP(?:ORARY)?\\s+TABLE\\b")
    private static let autocommit = regex("^SET\\s+(?:(?:SESSION|LOCAL|GLOBAL)\\s+|@@(?:SESSION\\.|LOCAL\\.|GLOBAL\\.)?)?autocommit\\b")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The name the pattern captures, unquoted.
    private static func identifier(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let id = String(s[r])
        if id.count >= 2, id.hasPrefix("`"), id.hasSuffix("`") {
            return String(id.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
        }
        if id.count >= 2, id.hasPrefix("\""), id.hasSuffix("\"") {
            return String(id.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return id
    }

    private static func firstWord(_ s: String) -> String {
        String(s.prefix(while: { $0.isLetter || $0 == "_" })).uppercased()
    }
}
