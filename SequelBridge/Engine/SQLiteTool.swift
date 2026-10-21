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
        _ = try await script([sql], file: file, busyTimeout: busyTimeout)
    }

    /// Runs `sql` (one statement, in SQLite's own SQL) on the file and returns its columns
    /// and rows (NULL → nil); none for a statement that returns no rows. `readOnly` opens
    /// the file read-only, so nothing can change it.
    static func query(_ sql: String, file: String, busyTimeout: TimeInterval, readOnly: Bool = false) async throws
        -> (columns: [String], rows: [[String?]]) {
        try await script([sql], file: file, busyTimeout: busyTimeout, readOnly: readOnly)
    }

    /// Runs `statements` one after another in one run of the tool, as the sqlite3 shell
    /// would, and returns the last one's result (none when it returns no rows). A failure
    /// stops there and says which statement it was when there are several.
    static func script(_ statements: [String], file: String, busyTimeout: TimeInterval, readOnly: Bool = false) async throws
        -> (columns: [String], rows: [[String?]]) {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<(columns: [String], rows: [[String?]]), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try scriptWaiting(statements, file: file, busyTimeout: busyTimeout, readOnly: readOnly) })
            }
        }
    }

    /// Printed after each statement, so each result is known to be whose. A line of its own.
    private static let marker = "@@sequelbridge-end-of-statement@@"

    private static func scriptWaiting(_ statements: [String], file: String, busyTimeout: TimeInterval, readOnly: Bool) throws
        -> (columns: [String], rows: [[String?]]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        // The SQL goes in on stdin: as an argument, one starting with "-- a comment" was
        // read as an option, and a long one was too big for the command line.
        p.arguments = ["-batch", "-bail", "-init", "/dev/null", "-json"] + (readOnly ? ["-readonly"] : [])
            + ["-cmd", ".timeout \(Int(busyTimeout * 1000))", file]
        // Each statement ends on a line of its own (a trailing -- comment can't take its
        // semicolon), then the marker.
        var input = ""
        for statement in statements { input += statement + "\n;\n.print " + marker + "\n" }
        let stdin = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = stdin
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch {
            throw SequelBridgeError.attachFailed("macOS's sqlite3 tool couldn't run: \(error.localizedDescription)")
        }
        // Written, read and drained at once: a big script or result would fill a pipe and stall the tool.
        let group = DispatchGroup()
        var out = Data(), err = Data()
        // sqlite3 stops reading at a failure (-bail): the rest of a big script then can't be
        // written, and that write fails here instead of ending the app (SIGPIPE).
        let writer = stdin.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        group.enter()
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data(input.utf8))
            try? writer.close()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async { out = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        p.waitUntilExit()

        // The output of each statement, in order: what came before each marker.
        let text = String(decoding: out, as: UTF8.self)
        var segments: [String] = [], current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == marker { segments.append(current); current = "" } else { current += line + "\n" }
        }
        let message = String(decoding: err, as: UTF8.self)
        if p.terminationStatus != 0 || !message.isEmpty {
            let reasonText = reason(message)
            let failed = segments.count                     // the statements before it all finished
            throw SequelBridgeError.attachFailed(statements.count > 1 && failed < statements.count
                ? "Statement \(failed + 1) of \(statements.count): \(reasonText)" : reasonText)
        }
        guard let last = segments.last else { return ([], []) }
        return parseJSON(last).last ?? ([], [])
    }

    /// The tool's -json output: an array of objects per statement that returned rows,
    /// keys in column order. Read in that order (a dictionary would lose it); a number
    /// keeps the digits SQLite wrote.
    static func parseJSON(_ text: String) -> [(columns: [String], rows: [[String?]])] {
        var results: [(columns: [String], rows: [[String?]])] = []
        let c = Array(text.unicodeScalars)
        var i = 0
        func skipSpace() { while i < c.count, c[i] == " " || c[i] == "\n" || c[i] == "\r" || c[i] == "\t" || c[i] == "," { i += 1 } }
        func string() -> String {
            var s = String.UnicodeScalarView()
            i += 1                                                  // the opening quote
            while i < c.count, c[i] != "\"" {
                if c[i] == "\\", i + 1 < c.count {
                    i += 1
                    switch c[i] {
                    case "n": s.append("\n"); case "t": s.append("\t"); case "r": s.append("\r")
                    case "b": s.append("\u{08}"); case "f": s.append("\u{0C}")
                    case "u":
                        var code: UInt32 = 0
                        var k = 0
                        while k < 4, i + 1 < c.count, let d = UInt32(String(c[i + 1]), radix: 16) { code = code * 16 + d; i += 1; k += 1 }
                        // A pair of \u escapes for a character beyond the first plane.
                        if code >= 0xD800, code < 0xDC00, i + 6 < c.count, c[i + 1] == "\\", c[i + 2] == "u",
                           let low = UInt32(String(String.UnicodeScalarView(c[(i + 3)...(i + 6)])), radix: 16), low >= 0xDC00, low < 0xE000 {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00); i += 6
                        }
                        s.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: s.append(c[i])
                    }
                } else {
                    s.append(c[i])
                }
                i += 1
            }
            i += 1                                                  // the closing quote
            return String(s)
        }
        func value() -> String? {
            if c[i] == "\"" { return string() }
            var s = String.UnicodeScalarView()
            while i < c.count, c[i] != ",", c[i] != "}", c[i] != " ", c[i] != "\n" { s.append(c[i]); i += 1 }
            let word = String(s)
            if word == "null" { return nil }
            // A real as SQLite shows it: the tool writes 20 digits (0.1 as 0.10000000000000000555).
            if word.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let d = Double(word) { return String(d) }
            return word
        }
        while i < c.count {
            skipSpace()
            guard i < c.count, c[i] == "[" else { i += 1; continue }
            i += 1
            var columns: [String] = [], rows: [[String?]] = []
            while true {
                skipSpace()
                guard i < c.count, c[i] == "{" else { if i < c.count, c[i] == "]" { i += 1 }; break }
                i += 1
                var row: [String?] = [], keys: [String] = []
                while true {
                    skipSpace()
                    guard i < c.count, c[i] == "\"" else { if i < c.count, c[i] == "}" { i += 1 }; break }
                    keys.append(string())
                    skipSpace()
                    if i < c.count, c[i] == ":" { i += 1 }
                    skipSpace()
                    guard i < c.count else { break }
                    row.append(value())
                }
                if columns.isEmpty { columns = keys }
                rows.append(row)
            }
            results.append((columns, rows))
        }
        return results
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
