//
//  ContentFilter.swift
//  SequelBridge
//
//  The Content tab's filter, as in Sequel Ace: a column, an operator and a value, made
//  into the WHERE condition of whichever server reads the page.
//

import Foundation

nonisolated enum ContentFilter {
    enum Op: String, CaseIterable, Identifiable {
        case equals = "=", notEquals = "≠", greater = ">", less = "<", greaterOrEqual = "≥", lessOrEqual = "≤"
        case contains = "contains", notContains = "doesn't contain", beginsWith = "begins with", endsWith = "ends with"
        case isIn = "is in", between = "between", isNull = "is NULL", isNotNull = "isn't NULL"
        var id: String { rawValue }
        /// IS NULL and IS NOT NULL take no value.
        var takesValue: Bool { self != .isNull && self != .isNotNull }
    }

    /// How the server that reads the page writes SQL: MySQL (backticks; a backslash in a
    /// string is an escape), PostgreSQL and DuckDB (double quotes; standard strings), and
    /// ClickHouse (double quotes; a backslash is an escape).
    enum Dialect: Equatable { case mysql, standard, clickhouse }

    /// The server's own SQL when the page is read through it; DuckDB's otherwise.
    static func dialect(engine: DatabaseEngine, passthrough: Bool) -> Dialect {
        switch engine {
        case .clickhouse: return .clickhouse
        case .mysql:      return passthrough ? .mysql : .standard
        default:          return .standard
        }
    }

    /// The WHERE condition for one rule; nil while it isn't whole (an empty list, one end
    /// of a range, nothing to look for). Values are always quoted: MySQL compares a text
    /// column with a number as numbers, so `'05' = 5` would match.
    static func condition(column: String, op: Op, value: String, value2: String = "", dialect: Dialect) -> String? {
        let col = identifier(column, dialect)
        switch op {
        case .isNull:         return "\(col) IS NULL"
        case .isNotNull:      return "\(col) IS NOT NULL"
        case .equals:         return "\(col) = \(literal(value, dialect))"
        case .notEquals:      return "\(col) <> \(literal(value, dialect))"
        case .greater:        return "\(col) > \(literal(value, dialect))"
        case .less:           return "\(col) < \(literal(value, dialect))"
        case .greaterOrEqual: return "\(col) >= \(literal(value, dialect))"
        case .lessOrEqual:    return "\(col) <= \(literal(value, dialect))"
        case .contains, .notContains, .beginsWith, .endsWith:
            guard !value.isEmpty else { return nil }
            let v = likeEscaped(value)
            let pattern = op == .beginsWith ? v + "%" : op == .endsWith ? "%" + v : "%" + v + "%"
            let like = op == .notContains ? "NOT LIKE" : "LIKE"
            // MySQL and ClickHouse escape LIKE with a backslash already; the others are told.
            return "\(col) \(like) \(literal(pattern, dialect))" + (dialect == .standard ? " ESCAPE '\\'" : "")
        case .isIn:
            let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return "\(col) IN (\(items.map { literal($0, dialect) }.joined(separator: ", ")))"
        case .between:
            let low = value.trimmingCharacters(in: .whitespaces), high = value2.trimmingCharacters(in: .whitespaces)
            guard !low.isEmpty, !high.isEmpty else { return nil }
            return "\(col) BETWEEN \(literal(low, dialect)) AND \(literal(high, dialect))"
        }
    }

    private static func identifier(_ name: String, _ dialect: Dialect) -> String {
        dialect == .mysql
            ? "`\(name.replacingOccurrences(of: "`", with: "``"))`"
            : "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// A quoted value; MySQL and ClickHouse read a backslash in a string as an escape.
    private static func literal(_ value: String, _ dialect: Dialect) -> String {
        let unescaped = dialect == .standard ? value : value.replacingOccurrences(of: "\\", with: "\\\\")
        return "'\(unescaped.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// A value LIKE matches as itself: its backslash, % and _ escaped with a backslash.
    private static func likeEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
