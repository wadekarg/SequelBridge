//
//  ForeignKeyFollow.swift
//  SequelBridge
//
//  Following a foreign key from the Content tab, as in Sequel Ace.
//

import Foundation

nonisolated enum ForeignKeyFollow {
    struct Target: Equatable {
        let table: String
        let columns: [String]
        let referenced: [String]
    }

    /// Each column of a key, to the table and columns the key references. From
    /// fetchRelations' rows: constraint, columns, referenced table, referenced columns, ….
    /// A key of several columns lists them comma-separated, in order.
    static func targets(_ relations: [[String]]) -> [String: Target] {
        var out: [String: Target] = [:]
        for row in relations where row.count >= 4 {
            let columns = split(row[1]), referenced = split(row[3])
            guard !row[2].isEmpty, !columns.isEmpty, columns.count == referenced.count else { continue }
            let target = Target(table: row[2], columns: columns, referenced: referenced)
            for column in columns where out[column] == nil { out[column] = target }
        }
        return out
    }

    /// The referenced row's condition: every column of the key equal to this row's value.
    /// Nil when one is NULL: such a key points at no row.
    static func condition(_ target: Target, values: [String: String], dialect: ContentFilter.Dialect) -> String? {
        var parts: [String] = []
        for (column, referenced) in zip(target.columns, target.referenced) {
            guard let value = values[column],
                  let part = ContentFilter.condition(column: referenced, op: .equals, value: value, dialect: dialect) else { return nil }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    private static func split(_ list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The filter a followed foreign key opens the referenced table's Content tab with: a rule
/// for a one-column key, the written-out condition for a key of several columns.
nonisolated struct ContentFollow: Equatable {
    let condition: String
    var column: String? = nil
    var value: String? = nil
}
