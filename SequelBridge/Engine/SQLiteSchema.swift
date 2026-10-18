//
//  SQLiteSchema.swift
//  SequelBridge
//
//  SQLite keeps no queryable catalog of constraints — sqlite_master stores the
//  original CREATE statement text and nothing else. DuckDB's own views are not a
//  substitute here: duckdb_constraints() reports constraint types with NULL column
//  names, and duckdb_indexes() reports is_unique = false even for a UNIQUE index.
//  So primary keys, indexes and foreign keys are read from the DDL itself.
//

import Foundation

enum SQLiteSchema {

    struct ParsedColumn {
        var name: String
        var type: String
        var notNull: Bool
        var defaultValue: String
        var isPrimaryKey: Bool
    }

    struct ParsedIndex {
        var name: String
        var table: String
        var unique: Bool
        var columns: [String]
    }

    /// Splits the body of a CREATE TABLE on top-level commas, so that a comma
    /// inside `NUMERIC(10,2)` or a multi-column `PRIMARY KEY (a, b)` does not
    /// split a definition in half.
    static func splitDefinitions(_ body: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for ch in body {
            switch ch {
            case "(": depth += 1; current.append(ch)
            case ")": depth -= 1; current.append(ch)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            default: current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts.filter { !$0.isEmpty }
    }

    /// The text between the outermost parentheses of a CREATE statement.
    static func tableBody(_ ddl: String) -> String {
        guard let open = ddl.firstIndex(of: "("),
              let close = ddl.lastIndex(of: ")"), open < close else { return "" }
        return String(ddl[ddl.index(after: open)..<close])
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (l, r) in [("\"", "\""), ("`", "`"), ("[", "]"), ("'", "'")] {
            if t.hasPrefix(l) && t.hasSuffix(r) && t.count >= 2 {
                t = String(t.dropFirst().dropLast())
                break
            }
        }
        return t
    }

    /// True when the definition is a table-level constraint rather than a column.
    private static func isConstraintClause(_ def: String) -> Bool {
        let u = def.uppercased()
        for kw in ["PRIMARY KEY", "FOREIGN KEY", "UNIQUE", "CHECK", "CONSTRAINT"] where u.hasPrefix(kw) {
            return true
        }
        return false
    }


    /// Reads the leading identifier, honouring quoting — a plain space split would
    /// cut `"odd name"` in half. Returns the token and whatever follows it.
    static func firstToken(_ def: String) -> (String, String)? {
        let t = def.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return nil }
        let closers: [Character: Character] = ["\"": "\"", "`": "`", "[": "]", "'": "'"]
        if let closer = closers[first] {
            var idx = t.index(after: t.startIndex)
            while idx < t.endIndex {
                if t[idx] == closer {
                    let token = String(t[t.startIndex...idx])
                    let rest = String(t[t.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                    return (token, rest)
                }
                idx = t.index(after: idx)
            }
            return (t, "")
        }
        if let space = t.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            return (String(t[t.startIndex..<space]),
                    String(t[space...]).trimmingCharacters(in: .whitespaces))
        }
        return (t, "")
    }

    static func parseColumns(fromCreateTable ddl: String) -> [ParsedColumn] {
        let defs = splitDefinitions(tableBody(ddl))
        // A table-level PRIMARY KEY (a, b) names columns declared elsewhere.
        var tablePK: Set<String> = []
        for def in defs where def.uppercased().hasPrefix("PRIMARY KEY") {
            let cols = splitDefinitions(tableBody(def)).map { unquote($0) }
            tablePK.formUnion(cols)
        }

        return defs.compactMap { def -> ParsedColumn? in
            guard !isConstraintClause(def) else { return nil }
            guard let (rawName, remainder) = firstToken(def) else { return nil }
            let name = unquote(rawName)
            guard !name.isEmpty else { return nil }

            let rest = remainder
            let upper = rest.uppercased()

            // The type is everything up to the first constraint keyword.
            var type = rest
            for kw in ["PRIMARY KEY", "NOT NULL", "DEFAULT", "UNIQUE", "REFERENCES",
                       "CHECK", "COLLATE", "GENERATED", "AS ", "AUTOINCREMENT"] {
                if let r = upper.range(of: kw) {
                    let prefix = String(rest[rest.startIndex..<r.lowerBound])
                    if prefix.count < type.count { type = prefix }
                }
            }

            var defaultValue = ""
            if let r = upper.range(of: "DEFAULT") {
                let after = rest[r.upperBound...].trimmingCharacters(in: .whitespaces)
                // Stop at the next constraint keyword.
                var value = after
                for kw in ["NOT NULL", "PRIMARY KEY", "UNIQUE", "REFERENCES", "CHECK", "COLLATE"] {
                    if let k = value.uppercased().range(of: kw) {
                        value = String(value[value.startIndex..<k.lowerBound])
                    }
                }
                defaultValue = unquote(value.trimmingCharacters(in: .whitespaces))
            }

            return ParsedColumn(
                name: name,
                type: type.trimmingCharacters(in: .whitespacesAndNewlines),
                notNull: upper.contains("NOT NULL"),
                defaultValue: defaultValue,
                isPrimaryKey: upper.contains("PRIMARY KEY") || tablePK.contains(name)
            )
        }
    }

    static func parseIndex(fromCreateIndex ddl: String) -> ParsedIndex? {
        let pattern = #"(?is)CREATE\s+(UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?([^\s(]+)\s+ON\s+([^\s(]+)\s*\((.*)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: ddl, range: NSRange(ddl.startIndex..., in: ddl))
        else { return nil }
        func group(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: ddl) else { return "" }
            return String(ddl[r])
        }
        let cols = splitDefinitions(group(4)).map { col -> String in
            // Strip a trailing ASC/DESC or COLLATE clause.
            var c = col
            for kw in [" ASC", " DESC", " COLLATE"] {
                if let r = c.uppercased().range(of: kw) { c = String(c[c.startIndex..<r.lowerBound]) }
            }
            return unquote(c)
        }
        return ParsedIndex(name: unquote(group(2)), table: unquote(group(3)),
                           unique: !group(1).trimmingCharacters(in: .whitespaces).isEmpty,
                           columns: cols.filter { !$0.isEmpty })
    }

    /// Returns [name, column, referencedTable, referencedColumn, onDelete, onUpdate]
    /// to match the shape the Relations panel already consumes.
    static func parseForeignKeys(fromCreateTable ddl: String) -> [[String]] {
        var out: [[String]] = []

        func actions(_ text: String) -> (String, String) {
            let u = text.uppercased()
            func action(_ kw: String) -> String {
                guard let r = u.range(of: kw) else { return "NO ACTION" }
                let after = u[r.upperBound...].trimmingCharacters(in: .whitespaces)
                for a in ["CASCADE", "SET NULL", "SET DEFAULT", "RESTRICT", "NO ACTION"]
                where after.hasPrefix(a) { return a }
                return "NO ACTION"
            }
            return (action("ON DELETE"), action("ON UPDATE"))
        }

        for def in splitDefinitions(tableBody(ddl)) {
            let u = def.uppercased()

            // Table-level: [CONSTRAINT name] FOREIGN KEY (col) REFERENCES tbl (col) ...
            if u.contains("FOREIGN KEY") {
                let pattern = #"(?is)(?:CONSTRAINT\s+(\S+)\s+)?FOREIGN\s+KEY\s*\(([^)]*)\)\s*REFERENCES\s+([^\s(]+)\s*(?:\(([^)]*)\))?"#
                if let re = try? NSRegularExpression(pattern: pattern),
                   let m = re.firstMatch(in: def, range: NSRange(def.startIndex..., in: def)) {
                    func g(_ i: Int) -> String {
                        guard let r = Range(m.range(at: i), in: def) else { return "" }
                        return String(def[r])
                    }
                    let (del, upd) = actions(def)
                    let name = unquote(g(1))
                    let col = unquote(g(2))
                    out.append([name.isEmpty ? "fk_\(col)" : name, col,
                                unquote(g(3)), unquote(g(4)), del, upd])
                }
                continue
            }

            // Column-level: col TYPE REFERENCES tbl(col) ...
            if u.contains("REFERENCES"), !isConstraintClause(def) {
                let pattern = #"(?is)^(\S+).*?REFERENCES\s+([^\s(]+)\s*(?:\(([^)]*)\))?"#
                if let re = try? NSRegularExpression(pattern: pattern),
                   let m = re.firstMatch(in: def, range: NSRange(def.startIndex..., in: def)) {
                    func g(_ i: Int) -> String {
                        guard let r = Range(m.range(at: i), in: def) else { return "" }
                        return String(def[r])
                    }
                    let (del, upd) = actions(def)
                    let col = unquote(g(1))
                    out.append(["fk_\(col)", col, unquote(g(2)), unquote(g(3)), del, upd])
                }
            }
        }
        return out
    }
}
