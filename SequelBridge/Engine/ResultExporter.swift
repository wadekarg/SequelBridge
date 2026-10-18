//
//  ResultExporter.swift
//  SequelBridge
//
//  Pure formatting for query-result export, separate from the save panel so it
//  can be tested without a file dialog.
//

import Foundation

nonisolated enum ResultExporter {

    /// RFC-4180-ish CSV: a field is quoted when it contains a comma, quote or
    /// newline, and embedded quotes are doubled. NULL becomes an empty field —
    /// CSV has no null.
    static func csv(_ result: QueryResult) -> String {
        var lines: [String] = []
        lines.append(result.columns.map(csvEscape).joined(separator: ","))
        for ri in 0..<result.rowCount {
            // Only an actual SQL NULL becomes an empty field; a real string value
            // "NULL" is written literally (tracked nullability keeps them distinct).
            let fields = result.row(ri).enumerated().map { ci, val in
                csvEscape(result.isNull(ri, ci) ? "" : val)
            }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// A JSON array of row objects. NULL is a real JSON null — JSON, unlike CSV,
    /// can carry it, and a consumer should see it as absent rather than "".
    /// Numeric columns are emitted as numbers so the file round-trips as data.
    static func json(_ result: QueryResult) throws -> Data {
        let objects: [[String: Any]] = (0..<result.rowCount).map { ri in
            let row = result.row(ri)
            var obj: [String: Any] = [:]
            for (idx, col) in result.columns.enumerated() {
                let raw = idx < row.count ? row[idx] : "NULL"
                if result.isNull(ri, idx) {
                    obj[col] = NSNull()
                } else if QueryResult.isNumericType(idx < result.columnTypes.count ? result.columnTypes[idx] : ""),
                          let num = numeric(raw) {
                    obj[col] = num
                } else {
                    obj[col] = raw
                }
            }
            return obj
        }
        return try JSONSerialization.data(withJSONObject: objects,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// A GitHub-flavored Markdown table. NULL renders as an empty cell; pipes and
    /// newlines inside values are escaped so the table stays well-formed.
    static func markdown(_ result: QueryResult) -> String {
        guard !result.columns.isEmpty else { return "" }
        let header = result.columns.map(mdEscape)
        var lines = ["| " + header.joined(separator: " | ") + " |",
                     "| " + header.map { _ in "---" }.joined(separator: " | ") + " |"]
        for ri in 0..<result.rowCount {
            let row = result.row(ri)
            let cells = (0..<result.columns.count).map { ci -> String in
                let v = ci < row.count ? row[ci] : ""
                return mdEscape(result.isNull(ri, ci) ? "" : v)
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    static func mdEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// One `INSERT` per row. NULL is the literal NULL, numeric columns are written
    /// unquoted, everything else is single-quoted with quotes doubled. Column and
    /// table identifiers are emitted bare (portable for ordinary names; the user can
    /// adjust the table name, which defaults to a placeholder for an ad-hoc query).
    static func sqlInserts(_ result: QueryResult, table: String = "exported_data") -> String {
        guard result.rowCount > 0 else { return "" }
        let colList = result.columns.joined(separator: ", ")
        let numeric = (0..<result.columns.count).map { ci in
            ci < result.columnTypes.count && QueryResult.isNumericType(result.columnTypes[ci])
        }
        var out: [String] = []
        for ri in 0..<result.rowCount {
            let row = result.row(ri)
            let vals = (0..<result.columns.count).map { ci -> String in
                if result.isNull(ri, ci) { return "NULL" }
                let v = ci < row.count ? row[ci] : ""
                if numeric[ci], !v.isEmpty { return v }
                return "'" + v.replacingOccurrences(of: "'", with: "''") + "'"
            }.joined(separator: ", ")
            out.append("INSERT INTO \(table) (\(colList)) VALUES (\(vals));")
        }
        return out.joined(separator: "\n")
    }

    /// Returns a JSON-safe number, or nil to signal "emit the raw string instead".
    /// nil is returned for values that a JSON number can't represent faithfully:
    ///  - integers beyond Int64 (UBIGINT / HUGEINT) — a Double would lose precision;
    ///  - NaN / ±Infinity — JSONSerialization rejects them and the whole export
    ///    would throw, producing no file at all.
    private static func numeric(_ s: String) -> NSNumber? {
        if let i = Int64(s) { return NSNumber(value: i) }
        // Integer-looking but out of Int64 range: keep the exact digits as a string.
        let body = s.hasPrefix("-") ? String(s.dropFirst()) : s
        if !body.isEmpty && body.allSatisfy(\.isNumber) { return nil }
        if let d = Double(s), d.isFinite { return NSNumber(value: d) }
        return nil
    }
}
