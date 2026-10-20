//
//  SQLScript.swift
//  SequelBridge
//
//  The statements of a Query-tab script, each as written. The Query tab runs them one
//  at a time, as Sequel Ace does: a server prepares one statement at a time.
//

import Foundation

nonisolated enum SQLScript {
    /// The statements of `sql`, each as written (its comments kept), split on `;` outside
    /// quotes and comments. A `DELIMITER x` line, as in the mysql client and Sequel Ace,
    /// makes `x` the separator until the next DELIMITER line, so a procedure body keeps
    /// its semicolons. A piece that is only whitespace and comments is dropped.
    static func statements(_ sql: String) -> [String] {
        var out: [String] = []
        var delimiter: [Character] = [";"]
        var current = ""
        let c = Array(sql)
        var i = 0
        var atLineStart = true

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !QueryEffects.statements(piece).isEmpty { out.append(piece) }
            current = ""
        }
        func matches(_ word: [Character], at k: Int) -> Bool {
            guard k + word.count <= c.count else { return false }
            for (n, ch) in word.enumerated() where c[k + n] != ch { return false }
            return true
        }

        while i < c.count {
            let ch = c[i]
            // DELIMITER x: a client command on a line of its own.
            if atLineStart, i + 10 <= c.count, String(c[i..<i + 9]).uppercased() == "DELIMITER", c[i + 9].isWhitespace {
                var end = i + 9
                while end < c.count && c[end] != "\n" { end += 1 }
                let word = String(c[(i + 9)..<end]).trimmingCharacters(in: .whitespaces)
                if let token = word.split(separator: " ").first, !token.isEmpty {
                    flush()
                    delimiter = Array(token)
                    i = end
                    continue
                }
            }
            if ch == "\n" { atLineStart = true } else if !(ch == " " || ch == "\t") { atLineStart = false }

            if ch == "'" || ch == "\"" || ch == "`" {
                var j = i + 1
                while j < c.count {
                    if ch != "`" && c[j] == "\\" { j += 2; continue }
                    if c[j] == ch {
                        if j + 1 < c.count && c[j + 1] == ch { j += 2; continue }
                        break
                    }
                    j += 1
                }
                let stop = min(j + 1, c.count)
                current += String(c[i..<stop])
                i = stop
                continue
            }
            if ch == "#" || (ch == "-" && i + 1 < c.count && c[i + 1] == "-" && (i + 2 == c.count || c[i + 2].isWhitespace)) {
                var j = i
                while j < c.count && c[j] != "\n" { j += 1 }
                current += String(c[i..<j])
                i = j
                continue
            }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                var j = i + 2
                while j + 1 < c.count && !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                let stop = min(j + 2, c.count)
                current += String(c[i..<stop])
                i = stop
                continue
            }
            if matches(delimiter, at: i) {
                flush()
                i += delimiter.count
                continue
            }
            current.append(ch)
            i += 1
        }
        flush()
        return out
    }
}
