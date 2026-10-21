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
        SQLScript.statements(sql).compactMap { piece -> String? in
            // psql's own commands (\restrict, \connect: pg_dump writes them) stand on lines of
            // their own between statements, so they come before the code of the piece after
            // them, among its comments. A line inside the statement (a string's) stays.
            var lines = piece.components(separatedBy: "\n")
            var i = 0
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("\\") { lines.remove(at: i); continue }
                if t.isEmpty || t.hasPrefix("--") { i += 1; continue }
                break
            }
            let statement = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let code = QueryEffects.statements(statement).first else { return nil }
            let words = code.uppercased().split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
            return words == "LOCK TABLES" || words == "UNLOCK TABLES" ? nil : statement
        }
    }

    /// Why an import can't run `statement`, if it can't. `COPY … FROM stdin` (pg_dump's
    /// default) is followed in the file by its rows, which only psql streams to the server.
    static func unsupported(_ statement: String) -> String? {
        let code = (QueryEffects.statements(statement).first ?? "").uppercased()
        guard code.hasPrefix("COPY "),
              code.range(of: #"\bFROM\s+STDIN\b"#, options: .regularExpression) != nil else { return nil }
        return "COPY … FROM stdin needs psql to stream the rows after it; make the dump with pg_dump --inserts instead."
    }
}
