//
//  SQLiteTool.swift
//  SequelBridge
//
//  Runs a statement in SQLite itself, on a file DuckDB has attached. DuckDB writing a
//  SQLite file's schema puts its own types there (DATE becomes VARCHAR, an INTEGER key
//  BIGINT, which no longer numbers rows), looks a bare table name up in its own catalog
//  and has no CREATE TRIGGER. macOS's sqlite3 tool runs the statement in a process of
//  its own: a second copy of SQLite inside the app would share the file's POSIX locks
//  with DuckDB's copy, which SQLite warns can corrupt the file.
//

import Foundation

nonisolated enum SQLiteTool {
    static let executable = "/usr/bin/sqlite3"

    /// Runs `sql` on the file at `file`, waiting up to `busyTimeout` seconds for a lock
    /// another connection holds. Throws SQLite's own message, or a plain one when the
    /// file stays busy.
    static func run(_ sql: String, file: String, busyTimeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try runWaiting(sql, file: file, busyTimeout: busyTimeout) })
            }
        }
    }

    private static func runWaiting(_ sql: String, file: String, busyTimeout: TimeInterval) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        // -init /dev/null: a ~/.sqliterc of the user's own doesn't run first. The statement
        // goes as an argument, so nothing is written to a pipe the tool may have closed.
        p.arguments = ["-batch", "-bail", "-init", "/dev/null",
                       "-cmd", ".timeout \(Int(busyTimeout * 1000))", file, sql]
        let errors = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        do {
            try p.run()
        } catch {
            throw SequelBridgeError.attachFailed("macOS's sqlite3 tool, which changes a SQLite file's tables, couldn't run: \(error.localizedDescription)")
        }
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus != 0 || !text.isEmpty else { return }
        throw SequelBridgeError.attachFailed(reason(text))
    }

    /// SQLite's message without the tool's framing: "Parse error near line 1: near "X":
    /// syntax error", then the statement and a caret, becomes `near "X": syntax error`.
    static func reason(_ stderr: String) -> String {
        let first = stderr.split(separator: "\n").first.map(String.init) ?? ""
        let message = first.replacingOccurrences(
            of: #"^(Parse error|Runtime error|Error)( near line \d+)?:\s*(in prepare, |stepping, )?"#,
            with: "", options: .regularExpression)
        if message.contains("database is locked") || message.contains("database table is locked") {
            return "The file is busy: another connection to it is in the middle of a change, such as a "
                + "transaction begun in the Query tab, or another app. COMMIT or ROLLBACK that "
                + "transaction, then try again."
        }
        return message.isEmpty ? "SQLite refused the statement." : message
    }
}
