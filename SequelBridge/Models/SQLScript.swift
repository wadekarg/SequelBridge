//
//  SQLScript.swift
//  SequelBridge
//
//  The statements of a Query-tab script, each as written. The Query tab runs them one
//  at a time, as Sequel Ace does: a server prepares one statement at a time.
//

import Foundation

nonisolated enum SQLScript {
    /// One statement as written (its comments kept, trimmed), and where it sits in the
    /// text: from its first character to just past its delimiter, in UTF-16 offsets as
    /// the editor counts them.
    struct Piece: Equatable {
        let text: String
        let range: NSRange
    }

    /// The statements of `sql`, each as written.
    static func statements(_ sql: String) -> [String] { pieces(sql).map(\.text) }

    /// The statement the editor's caret is in, else the one just before it, else the
    /// first one after it.
    static func statement(at location: Int, in sql: String) -> String? {
        let all = pieces(sql)
        if let inside = all.first(where: { location >= $0.range.location && location <= NSMaxRange($0.range) }) {
            return inside.text
        }
        return all.last(where: { NSMaxRange($0.range) <= location })?.text
            ?? all.first(where: { $0.range.location >= location })?.text
    }

    /// Splits on `;` outside quotes and comments. A `DELIMITER x` line, as in the mysql
    /// client and Sequel Ace, makes `x` the separator until the next DELIMITER line, so
    /// a procedure body keeps its semicolons. A piece that is only whitespace and
    /// comments is dropped.
    static func pieces(_ sql: String) -> [Piece] {
        let s = sql as NSString
        let n = s.length
        var out: [Piece] = []
        var delimiter: [unichar] = [59]   // ;
        var start = 0
        var i = 0
        var atLineStart = true

        func at(_ k: Int) -> unichar { s.character(at: k) }
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func endOfLine(_ k: Int) -> Int { var j = k; while j < n && at(j) != 10 { j += 1 }; return j }
        func flush(end: Int, next: Int) {
            let raw = s.substring(with: NSRange(location: start, length: end - start))
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !QueryEffects.statements(text).isEmpty {
                var first = start
                while first < end && isSpace(at(first)) { first += 1 }
                out.append(Piece(text: text, range: NSRange(location: first, length: next - first)))
            }
            start = next
        }
        func delimiterAt(_ k: Int) -> Bool {
            guard k + delimiter.count <= n else { return false }
            for (m, d) in delimiter.enumerated() where at(k + m) != d { return false }
            return true
        }

        while i < n {
            let c = at(i)
            // DELIMITER x: a client command on a line of its own.
            if atLineStart, i + 10 <= n, s.substring(with: NSRange(location: i, length: 9)).uppercased() == "DELIMITER",
               isSpace(at(i + 9)) {
                let end = endOfLine(i)
                let rest = s.substring(with: NSRange(location: i + 9, length: end - i - 9)).trimmingCharacters(in: .whitespaces)
                if let token = rest.split(separator: " ").first, !token.isEmpty {
                    flush(end: i, next: end)
                    delimiter = Array(String(token).utf16)
                    i = end
                    continue
                }
            }
            if c == 10 { atLineStart = true } else if c != 32 && c != 9 { atLineStart = false }

            if c == 39 || c == 34 || c == 96 {                       // ' " `
                var j = i + 1
                while j < n {
                    let d = at(j)
                    if c != 96 && d == 92 { j += 2; continue }        // \' in a string
                    if d == c {
                        if j + 1 < n && at(j + 1) == c { j += 2; continue }
                        break
                    }
                    j += 1
                }
                i = min(j + 1, n)
                continue
            }
            if c == 35 || (c == 45 && i + 1 < n && at(i + 1) == 45 && (i + 2 == n || isSpace(at(i + 2)))) {
                i = endOfLine(i)                                       // # or -- to the end of the line
                continue
            }
            if c == 47, i + 1 < n, at(i + 1) == 42 {                   // /* … */
                var j = i + 2
                while j + 1 < n && !(at(j) == 42 && at(j + 1) == 47) { j += 1 }
                i = min(j + 2, n)
                continue
            }
            if delimiterAt(i) {
                flush(end: i, next: i + delimiter.count)
                i += delimiter.count
                continue
            }
            i += 1
        }
        flush(end: n, next: n)
        return out
    }
}
