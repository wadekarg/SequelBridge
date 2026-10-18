//
//  CSVParser.swift
//  SequelBridge
//
//  A correct RFC-4180 CSV reader for the "Import CSV" feature: quoted fields,
//  embedded commas and newlines, and "" escaped quotes are all handled. Pure and
//  fully unit-tested; the import flow turns the rows into INSERTs.
//

import Foundation

enum CSVParser {
    /// Parses CSV `text` into rows of fields. A field may be double-quoted, in
    /// which case it can contain the delimiter, CR/LF, and doubled quotes (`""`)
    /// which decode to a single `"`. Rows are split on unquoted LF or CRLF. A
    /// trailing blank line is ignored.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var sawAnyField = false   // did the current row have at least one field started?

        let chars = Array(text)
        var i = 0
        func endField() {
            row.append(field); field = ""; sawAnyField = true
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []; sawAnyField = false
        }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\""); i += 2; continue   // escaped quote
                    }
                    inQuotes = false; i += 1; continue         // closing quote
                }
                field.append(c); i += 1; continue
            }
            switch c {
            case "\"":
                inQuotes = true; i += 1
            case delimiter:
                endField(); i += 1
            // Swift groups CRLF into a single Character, so "\r\n" is one grapheme;
            // a lone CR or LF is its own. All three end the row.
            case "\n", "\r\n", "\r":
                endRow(); i += 1
            default:
                field.append(c); i += 1
            }
        }
        // Flush the final field/row unless the text ended exactly on a row break
        // (endRow already pushed it) with nothing after.
        if inQuotes || !field.isEmpty || sawAnyField || !row.isEmpty {
            endRow()
        }
        // Drop a single trailing empty row produced by a final newline.
        if let last = rows.last, last == [""] { rows.removeLast() }
        return rows
    }
}
