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
            if let picked = identifier(useStatement, in: statement) {
                if picked != outcome.database { outcome.database = picked; outcome.reloadDatabases = true }
            } else if let dropped = identifier(dropDatabase, in: statement), let current = outcome.database,
                      dropped == current || (!caseSensitive && dropped.caseInsensitiveCompare(current) == .orderedSame) {
                outcome.database = nil
            }
        }
        return outcome
    }

    /// The database `sql` picks when it is a lone `USE` statement.
    static func soleUse(_ sql: String) -> String? {
        let all = statements(sql)
        guard all.count == 1 else { return nil }
        return identifier(useStatement, in: all[0])
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
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i = min(i + 2, c.count)
                current.append(" "); continue
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
