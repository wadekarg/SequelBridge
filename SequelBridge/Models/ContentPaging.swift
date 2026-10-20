//
//  ContentPaging.swift
//  SequelBridge
//
//  The Content tab's pages, and the values a duplicated row starts from.
//

import Foundation

nonisolated enum ContentPaging {
    /// The page sizes the Content tab offers.
    static let pageSizes = [100, 200, 500, 1000, 5000]

    /// How many pages `total` rows make; an empty table is one empty page. Nil while
    /// the total isn't known.
    static func pageCount(total: Int?, pageSize: Int) -> Int? {
        guard let total else { return nil }
        return max(1, (total + max(pageSize, 1) - 1) / max(pageSize, 1))
    }

    /// The page (counted from 0) a typed page number (counted from 1) asks for, kept
    /// within the pages that exist; nil when it isn't a number.
    static func page(typed: String, pageCount: Int?) -> Int? {
        guard let n = Int(typed.trimmingCharacters(in: .whitespaces)) else { return nil }
        let page = max(n, 1) - 1
        guard let pageCount else { return page }
        return min(page, max(pageCount, 1) - 1)
    }

    /// The values a duplicate of `row` starts from: every column except the ones the
    /// server fills in itself, a NULL as NULL (the row sheet reads a typed NULL as NULL).
    static func duplicateValues(row: [String], nulls: [Bool], columns: [String],
                                generated: Set<String>) -> [String: String] {
        var values: [String: String] = [:]
        for (i, column) in columns.enumerated() where i < row.count && !generated.contains(column) {
            values[column] = i < nulls.count && nulls[i] ? "NULL" : row[i]
        }
        return values
    }

    /// What an empty field of the row sheet gets: an insert leaves the column out, so the
    /// server fills it in, puts its default there, NULL, or refuses the row.
    static func placeholder(for column: ColumnInfo, generated: Bool) -> String {
        if generated { return "set by the server" }
        let fallback = column.defaultValue.trimmingCharacters(in: .whitespaces)
        if !fallback.isEmpty, fallback.uppercased() != "NULL" { return "default: \(fallback)" }
        return column.nullable ? "NULL" : "required"
    }

    /// The columns the server fills in itself, which an insert leaves out: an
    /// auto-increment key, a generated column (MySQL refuses a value for one), and
    /// SQLite's INTEGER PRIMARY KEY, which numbers the rows when it is the whole key.
    static func generatedColumns(_ columns: [ColumnInfo], engine: DatabaseEngine) -> Set<String> {
        var generated = Set<String>()
        for c in columns {
            let extra = c.extra.lowercased()
            if extra.contains("auto_increment")
                || ["virtual generated", "stored generated", "persistent generated"].contains(where: extra.contains) {
                generated.insert(c.name)
            }
        }
        let key = columns.filter(\.isPrimaryKey)
        if engine == .sqlite, key.count == 1, key[0].dataType.uppercased() == "INTEGER" {
            generated.insert(key[0].name)
        }
        return generated
    }
}
