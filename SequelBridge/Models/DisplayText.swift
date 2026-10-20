//
//  DisplayText.swift
//  SequelBridge
//
//  Words on screen: counts ("1 row", "3 rows"), and the table information the left
//  panel and the Table Info tab show, from one SHOW TABLE STATUS row.
//

import Foundation

nonisolated enum Plural {
    /// "1 row", "3 rows".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    /// "1 of 6 tables", "1 of 1 table": the noun agrees with the whole.
    static func part(_ shown: Int, of total: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(shown) of \(count(total, singular, plural))"
    }
}

nonisolated enum TableMeta {
    // fetchTableMeta's order: [0] engine [1] row format [2] auto-increment [3] collation
    // [4] create options [5] comment [6] rows [7] average row length [8] data length
    // [9] max data length [10] index length [11] data free [12] created [13] updated
    // [14] checked. The server's NULLs arrive as the text "NULL".

    /// Field `i`, nil when the server has none: missing, empty, or NULL.
    static func field(_ row: [String], _ i: Int) -> String? {
        guard i < row.count else { return nil }
        let value = row[i].trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "NULL" ? nil : value
    }

    /// A byte count in B, KB, MB and up; nothing, or zero, reads as a dash.
    static func bytes(_ value: String) -> String {
        guard let n = Int(value), n > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(n), unit = 0
        while size >= 1024 && unit < units.count - 1 { size /= 1024; unit += 1 }
        return String(format: "%.1f %@", size, units[unit])
    }

    /// The left panel's table information.
    static func summary(_ row: [String]) -> [(key: String, value: String)] {
        let data = Int(field(row, 8) ?? "") ?? 0, index = Int(field(row, 10) ?? "") ?? 0
        var info: [(key: String, value: String)] = [
            ("rows", field(row, 6) ?? "—"),
            ("data", bytes(String(data))),
            ("index", bytes(String(index))),
            ("total", bytes(String(data + index))),
            ("engine", field(row, 0) ?? "—"),
            ("collation", field(row, 3) ?? "—"),
        ]
        if let created = field(row, 12) { info.append(("created", created)) }
        if let updated = field(row, 13) { info.append(("updated", updated)) }
        if let comment = field(row, 5) { info.append(("comment", comment)) }
        return info
    }

    /// The Table Info tab's General, Storage and Timestamps rows.
    static func details(_ row: [String]) -> [(key: String, value: String)] {
        var info: [(key: String, value: String)] = [
            ("Engine", field(row, 0) ?? "—"),
            ("Row Format", field(row, 1) ?? "—"),
        ]
        if let next = Int(field(row, 2) ?? ""), next > 0 { info.append(("Auto Increment", String(next))) }
        info.append(("Collation", field(row, 3) ?? "—"))
        if let options = field(row, 4), options != "0" { info.append(("Create Options", options)) }
        info.append(("Comment", field(row, 5) ?? "—"))
        info.append(("Rows", field(row, 6) ?? "—"))
        let average = Int(field(row, 7) ?? "") ?? 0
        info.append(("Avg Row Length", average == 0 ? "—" : "\(average) B"))
        info.append(("Data Size", bytes(field(row, 8) ?? "")))
        info.append(("Max Data Size", bytes(field(row, 9) ?? "")))
        info.append(("Index Size", bytes(field(row, 10) ?? "")))
        info.append(("Data Free", bytes(field(row, 11) ?? "")))
        if let created = field(row, 12) { info.append(("Created", created)) }
        if let updated = field(row, 13) { info.append(("Updated", updated)) }
        if let checked = field(row, 14) { info.append(("Checked", checked)) }
        return info
    }
}
