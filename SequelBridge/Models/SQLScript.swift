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

    /// The statements of `sql`, each as written. `engine` is the server they run on, for
    /// what counts as a comment there; nil reads them as MySQL does.
    static func statements(_ sql: String, engine: DatabaseEngine? = nil) -> [String] {
        pieces(sql, engine: engine).map(\.text)
    }

    /// The statement the editor's caret is in, else the one just before it, else the
    /// first one after it.
    static func statement(at location: Int, in sql: String, engine: DatabaseEngine? = nil) -> String? {
        let all = pieces(sql, engine: engine)
        if let inside = all.first(where: { location >= $0.range.location && location <= NSMaxRange($0.range) }) {
            return inside.text
        }
        return all.last(where: { NSMaxRange($0.range) <= location })?.text
            ?? all.first(where: { $0.range.location >= location })?.text
    }

    /// Splits on `;` outside quotes and comments. A `DELIMITER x` line, as in the mysql
    /// client and Sequel Ace, makes `x` the separator until the next DELIMITER line, so
    /// a procedure body keeps its semicolons. Without one, a trigger's or a routine's body
    /// in BEGIN … END keeps them too (SQLite's triggers are always written so, and SHOW
    /// CREATE PROCEDURE gives no DELIMITER), as does MariaDB's BEGIN NOT ATOMIC block. A
    /// piece that is only whitespace and comments is dropped.
    static func pieces(_ sql: String, engine: DatabaseEngine? = nil) -> [Piece] {
        let s = sql as NSString
        let n = s.length
        var out: [Piece] = []
        var delimiter: [unichar] = [59]   // ;
        // "#" starts a comment on MySQL and ClickHouse; on PostgreSQL it is an operator (#>>).
        let hashComments = engine != .postgres && engine != .sqlite
        var start = 0
        var i = 0
        var atLineStart = true
        // The statement's first words; whether it has a body (CREATE TRIGGER, PROCEDURE,
        // FUNCTION or EVENT, or BEGIN NOT ATOMIC), once its first words say; and how deep
        // in BEGIN … END and CASE … END that body is at the moment.
        var words: [String] = []
        var decided = false, body = false
        var depth = 0
        let bodyKinds: Set<String> = ["TRIGGER", "PROCEDURE", "FUNCTION", "EVENT"]
        let otherKinds: Set<String> = ["TABLE", "VIEW", "INDEX", "UNIQUE", "FULLTEXT", "SPATIAL", "DATABASE", "SCHEMA",
                                       "SEQUENCE", "USER", "ROLE", "TYPE", "DOMAIN", "EXTENSION", "MATERIALIZED",
                                       "TABLESPACE", "SERVER", "POLICY", "RULE", "PUBLICATION", "SUBSCRIPTION",
                                       "STATISTICS", "COLLATION", "CAST", "OPERATOR", "DICTIONARY", "PACKAGE"]

        func at(_ k: Int) -> unichar { s.character(at: k) }
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func isWordChar(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
        }
        func isWordStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
        func wordEnd(_ k: Int) -> Int { var j = k; while j < n && isWordChar(at(j)) { j += 1 }; return j }
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
            words = []; decided = false; body = false; depth = 0
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
            // $tag$ … $tag$ (PostgreSQL's dollar quoting): a function or DO body keeps its
            // semicolons. Not $1 (a parameter) nor the $ inside a name such as a$b.
            if c == 36, i == 0 || !isWordChar(at(i - 1)) {
                var j = i + 1
                while j < n, isWordChar(at(j)), at(j) != 36 { j += 1 }
                if j < n, at(j) == 36, j == i + 1 || !(at(i + 1) >= 48 && at(i + 1) <= 57) {
                    let tag = s.substring(with: NSRange(location: i, length: j - i + 1))
                    let close = s.range(of: tag, options: [], range: NSRange(location: j + 1, length: n - j - 1))
                    i = close.location == NSNotFound ? n : NSMaxRange(close)
                    continue
                }
            }
            if (c == 35 && hashComments) || (c == 45 && i + 1 < n && at(i + 1) == 45 && (i + 2 == n || isSpace(at(i + 2)))) {
                i = endOfLine(i)                                       // # or -- to the end of the line
                continue
            }
            if c == 47, i + 1 < n, at(i + 1) == 42 {                   // /* … */
                var j = i + 2
                while j + 1 < n && !(at(j) == 42 && at(j + 1) == 47) { j += 1 }
                i = min(j + 2, n)
                continue
            }
            if isWordStart(c), i == 0 || !isWordChar(at(i - 1)) {
                var j = wordEnd(i)
                if !decided || body {
                    let word = s.substring(with: NSRange(location: i, length: j - i)).uppercased()
                    if !decided {
                        words.append(word)
                        if words[0] == "CREATE" {
                            // The first kind of thing named decides: CREATE TABLE t (function …) has no body.
                            if bodyKinds.contains(word) { body = true; decided = true }
                            else if otherKinds.contains(word) || words.count >= 12 { decided = true }
                        } else if words[0] == "BEGIN" {
                            if words.count == 3 { decided = true; body = words[1] == "NOT" && words[2] == "ATOMIC"; depth = body ? 1 : 0 }
                        } else {
                            decided = true
                        }
                    } else if (i > 0 && at(i - 1) == 46) || (j < n && at(j) == 46) {
                        // NEW.end, t.begin: a column, not a block.
                    } else if word == "BEGIN" || word == "CASE" {
                        depth += 1
                    } else if word == "END" {
                        // END IF, END LOOP, END WHILE, END REPEAT and END FOR close blocks not
                        // counted here; END CASE closes a CASE, a plain END a BEGIN or a CASE.
                        var k = j
                        while k < n && isSpace(at(k)) { k += 1 }
                        let m = wordEnd(k)
                        let next = s.substring(with: NSRange(location: k, length: m - k)).uppercased()
                        if !["IF", "LOOP", "WHILE", "REPEAT", "FOR"].contains(next) {
                            depth = max(0, depth - 1)
                            if next == "CASE" { j = m }
                        }
                    }
                }
                i = j
                continue
            }
            if delimiterAt(i), !(depth > 0 && delimiter == [59]) {
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
