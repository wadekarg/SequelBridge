//
//  TableMaintenance.swift
//  SequelBridge
//
//  Table Maintenance, as in Sequel Ace.
//

import Foundation

nonisolated enum TableMaintenance: String, CaseIterable, Identifiable {
    case analyze = "Analyze", check = "Check", optimize = "Optimize", repair = "Repair", flush = "Flush", checksum = "Checksum"
    var id: String { rawValue }

    /// Check and Checksum read the table; the others change it.
    var changesTheTable: Bool { self != .check && self != .checksum }

    /// The task's statement for one table.
    func sql(database: String, table: String) -> String {
        let target = "\(SQLBuilder.mysqlIdent(database)).\(SQLBuilder.mysqlIdent(table))"
        return self == .flush ? "FLUSH TABLES \(target)" : "\(rawValue.uppercased()) TABLE \(target)"
    }

    /// The server's answer as lines: each message ("status: OK"), a checksum, or Done
    /// when it sent no rows (FLUSH).
    static func summary(columns: [String], rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "Done" }
        func cell(_ row: [String], _ i: Int) -> String { i < row.count ? row[i] : "" }
        if let sum = columns.firstIndex(of: "Checksum") {
            return rows.map { "Checksum: \(cell($0, sum))" }.joined(separator: "\n")
        }
        if let type = columns.firstIndex(of: "Msg_type"), let text = columns.firstIndex(of: "Msg_text") {
            return rows.map { "\(cell($0, type)): \(cell($0, text))" }.joined(separator: "\n")
        }
        return rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }
}
