//
//  ConsoleExporter.swift
//  SequelBridge
//
//  Turns the console's statement history into a re-runnable .sql file — the
//  "save all the queries from the console" export. Pure and testable; the view
//  just writes the string to disk.
//

import Foundation

enum ConsoleExporter {
    /// A .sql dump of the console history in execution order. Each statement is
    /// terminated with a semicolon; blank statements are dropped. A header comment
    /// records how many statements were exported.
    static func sqlDump(_ entries: [WorkspaceSession.ConsoleEntry]) -> String {
        let statements = entries
            .map { $0.sql.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
        var out = "-- SequelBridge console history — \(Plural.count(statements.count, "statement"))\n\n"
        out += statements.joined(separator: "\n\n")
        return out.hasSuffix("\n") ? out : out + "\n"
    }

    /// The most recent distinct statements, newest first — backs the "Recent"
    /// section of the query tab's bookmark menu.
    static func recent(_ entries: [WorkspaceSession.ConsoleEntry], limit: Int = 10) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries.reversed() where entry.byApp != true {   // what you typed, not what the app ran
            let sql = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sql.isEmpty, !seen.contains(sql) else { continue }
            seen.insert(sql)
            out.append(sql)
            if out.count >= max(1, limit) { break }
        }
        return out
    }
}
