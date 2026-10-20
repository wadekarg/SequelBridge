//
//  SQLFile.swift
//  SequelBridge
//
//  .sql files: opened into and saved from the Query tab, or imported into a database.
//

import Foundation

nonisolated enum SQLFile {
    /// The text of a .sql file: UTF-8, else Latin-1, which reads any bytes, so an old dump
    /// still opens.
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The statements an import runs: the file's own, less LOCK TABLES and UNLOCK TABLES.
    /// They only speed a dump up, and the statements between them may reach the server on
    /// another of the driver's connections, which would wait on that lock for good.
    static func importStatements(_ sql: String) -> [String] {
        SQLScript.statements(sql).filter { statement in
            let words = (QueryEffects.statements(statement).first ?? "").uppercased()
                .split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
            return words != "LOCK TABLES" && words != "UNLOCK TABLES"
        }
    }
}
