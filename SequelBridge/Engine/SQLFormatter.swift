//
//  SQLFormatter.swift
//  SequelBridge
//
//  A small, offline SQL beautifier for the query editor's "Format" button.
//  It is a PRESENTATION transform only — it never changes what a query does:
//  it uppercases keywords, puts each major clause and JOIN on its own line,
//  breaks a multi-column SELECT list and AND/OR conditions onto their own lines,
//  and normalizes spacing. String literals, quoted identifiers and comments are
//  preserved verbatim. Content inside parentheses (subqueries, function args) is
//  spacing-normalized but kept on its line — v1 does not re-indent nested blocks.
//

import Foundation

enum SQLFormatter {

    static let indentUnit = "    "   // 4 spaces

    // Words we uppercase, and whose presence drives line breaks. Built from the
    // editor's completion keyword list plus the structural words we key off.
    private static let keywordSet: Set<String> = {
        var s = Set(SQLKeywords.all.map { $0.uppercased() })
        s.formUnion(["LEFT","RIGHT","INNER","OUTER","FULL","CROSS","NATURAL","JOIN",
                     "ON","BY","GROUP","ORDER","ASC","DESC","UNION","EXCEPT","INTERSECT",
                     "RETURNING","OFFSET","USING","STRAIGHT_JOIN"])
        return s
    }()

    // Words we actually UPPERCASE. Deliberately narrower than the completion list:
    // it excludes words that are commonly column/table names (status, schema, date,
    // name, value, comment, …) so we don't shout a user's identifiers.
    private static let castUp: Set<String> = [
        "SELECT","FROM","WHERE","JOIN","LEFT","RIGHT","INNER","OUTER","FULL","CROSS","NATURAL",
        "ON","USING","AND","OR","NOT","IN","LIKE","AS","GROUP","BY","ORDER","HAVING","LIMIT","OFFSET",
        "INSERT","INTO","VALUES","UPDATE","SET","DELETE","CREATE","ALTER","DROP","TRUNCATE","RENAME",
        "DISTINCT","UNION","EXCEPT","INTERSECT","ALL","CASE","WHEN","THEN","ELSE","END","IS","NULL",
        "BETWEEN","EXISTS","WITH","ASC","DESC","RETURNING","PRIMARY","FOREIGN","REFERENCES","UNIQUE",
        "DEFAULT","BEGIN","COMMIT","ROLLBACK","TRANSACTION","TRUE","FALSE",
        "COUNT","SUM","AVG","MIN","MAX","COALESCE","IFNULL","CAST","CONVERT","NULLIF","ROUND",
    ]

    // Keywords that are function calls — no space before their "(".
    private static let functionKeywords: Set<String> = [
        "COUNT","SUM","AVG","MIN","MAX","COALESCE","IFNULL","IF","NOW","CURDATE",
        "DATE","YEAR","MONTH","DAY","CONCAT","SUBSTRING","TRIM","UPPER","LOWER",
        "LENGTH","REPLACE","CAST","CONVERT","ROUND","ABS","GROUP_CONCAT","NULLIF",
    ]

    // Multi-word clauses, longest first so "GROUP BY" wins over "GROUP".
    private static let clausePhrases: [[String]] = [
        ["INSERT","INTO"], ["DELETE","FROM"], ["GROUP","BY"], ["ORDER","BY"],
        ["UNION","ALL"],
        ["SELECT"], ["FROM"], ["WHERE"], ["HAVING"], ["LIMIT"], ["OFFSET"],
        ["VALUES"], ["UPDATE"], ["SET"], ["DELETE"], ["RETURNING"], ["WITH"],
        ["UNION"], ["EXCEPT"], ["INTERSECT"],
    ]

    private static let joinPhrases: [[String]] = [
        ["LEFT","OUTER","JOIN"], ["RIGHT","OUTER","JOIN"], ["FULL","OUTER","JOIN"],
        ["LEFT","JOIN"], ["RIGHT","JOIN"], ["INNER","JOIN"], ["CROSS","JOIN"],
        ["FULL","JOIN"], ["NATURAL","JOIN"], ["STRAIGHT_JOIN"], ["JOIN"],
    ]

    // MARK: - Public

    static func format(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sql }
        let toks = tokenize(trimmed)
        guard !toks.isEmpty else { return sql }
        return render(toks)
    }

    // MARK: - Tokenizer

    private enum Kind { case word, number, string, lineComment, blockComment, op, comma, semicolon, open, close, dot }
    private struct Tok { var kind: Kind; var text: String }

    private static func tokenize(_ s: String) -> [Tok] {
        let c = Array(s)
        let n = c.count
        var toks: [Tok] = []
        var i = 0
        func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" || ch == "$" || ch == "@" }
        let opChars = Set("=<>!+-*/%|&^~")

        while i < n {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }

            if ch == "-", i + 1 < n, c[i+1] == "-" {               // -- line comment
                var j = i
                while j < n && c[j] != "\n" { j += 1 }
                toks.append(Tok(kind: .lineComment, text: String(c[i..<j]).trimmingTrailing()))
                i = j; continue
            }
            if ch == "/", i + 1 < n, c[i+1] == "*" {               // /* block comment */
                var j = i + 2
                while j + 1 < n && !(c[j] == "*" && c[j+1] == "/") { j += 1 }
                j = min(n, j + 2)
                toks.append(Tok(kind: .blockComment, text: String(c[i..<j])))
                i = j; continue
            }
            if ch == "'" {                                          // 'string' ('' and \\ escapes)
                var j = i + 1
                while j < n {
                    if c[j] == "\\", j + 1 < n { j += 2; continue }
                    if c[j] == "'" {
                        if j + 1 < n && c[j+1] == "'" { j += 2; continue }
                        j += 1; break
                    }
                    j += 1
                }
                toks.append(Tok(kind: .string, text: String(c[i..<j]))); i = j; continue
            }
            if ch == "`" || ch == "\"" {                           // `quoted` / "quoted" identifier
                let q = ch
                var j = i + 1
                while j < n && c[j] != q { j += 1 }
                j = min(n, j + 1)
                toks.append(Tok(kind: .word, text: String(c[i..<j]))); i = j; continue  // opaque: never uppercased
            }
            if ch.isNumber || (ch == "." && i + 1 < n && c[i+1].isNumber) {
                var j = i
                while j < n && (c[j].isNumber || c[j] == "." || c[j] == "e" || c[j] == "E") { j += 1 }
                toks.append(Tok(kind: .number, text: String(c[i..<j]))); i = j; continue
            }
            if isWord(ch) {
                var j = i
                while j < n && isWord(c[j]) { j += 1 }
                toks.append(Tok(kind: .word, text: String(c[i..<j]))); i = j; continue
            }
            switch ch {
            case ",": toks.append(Tok(kind: .comma, text: ","))
            case ";": toks.append(Tok(kind: .semicolon, text: ";"))
            case "(": toks.append(Tok(kind: .open, text: "("))
            case ")": toks.append(Tok(kind: .close, text: ")"))
            case ".": toks.append(Tok(kind: .dot, text: "."))
            default:
                if opChars.contains(ch) {
                    var j = i
                    while j < n && opChars.contains(c[j]) { j += 1 }
                    toks.append(Tok(kind: .op, text: String(c[i..<j]))); i = j; continue
                } else {
                    toks.append(Tok(kind: .op, text: String(ch)))   // keep unknown punctuation as-is
                }
            }
            i += 1
        }
        return toks
    }

    // MARK: - Renderer

    private enum Clause { case none, select, cond, other }

    private static func render(_ toks: [Tok]) -> String {
        var out = ""
        var prev: Tok? = nil          // last emitted token; nil right after a line break
        var depth = 0
        var clause: Clause = .none
        var selectBreak = false       // break columns in the current SELECT

        func indent(_ level: Int) -> String { String(repeating: indentUnit, count: max(0, level)) }

        func newline(_ level: Int) {
            while out.hasSuffix(" ") { out.removeLast() }
            out += "\n" + indent(level)
            prev = nil
        }

        func separator(for kind: Kind) -> String {
            guard let p = prev else { return "" }
            switch kind {
            case .comma, .semicolon, .close, .dot: return ""
            case .open:
                if p.kind == .close || p.kind == .dot || p.kind == .open { return "" }
                if p.kind == .word {
                    let u = p.text.uppercased()
                    if functionKeywords.contains(u) { return "" }       // COUNT(*)
                    return keywordSet.contains(u) ? " " : ""             // IN (…) vs myfunc(…)
                }
                return " "
            default:
                return (p.kind == .open || p.kind == .dot) ? "" : " "
            }
        }

        func put(_ text: String, _ kind: Kind) {
            out += separator(for: kind) + text
            prev = Tok(kind: kind, text: text)
        }

        // Uppercase a word only if it's a keyword we cast AND it isn't a qualified
        // identifier part (adjacent to a dot, e.g. schema.table / t.date).
        func renderWord(_ j: Int) -> String {
            let t = toks[j]
            guard t.kind == .word else { return t.text }
            let u = t.text.uppercased()
            guard castUp.contains(u) else { return t.text }
            if j > 0, toks[j-1].kind == .dot { return t.text }
            if j + 1 < toks.count, toks[j+1].kind == .dot { return t.text }
            return u
        }

        func wordAt(_ j: Int, _ w: String) -> Bool {
            j < toks.count && toks[j].kind == .word && toks[j].text.uppercased() == w
        }
        func matches(_ j: Int, _ phrase: [String]) -> Bool {
            for (k, w) in phrase.enumerated() where !wordAt(j + k, w) { return false }
            return true
        }
        // Does the current SELECT list contain a top-level comma before the next clause?
        func selectHasList(from j: Int) -> Bool {
            var d = 0, k = j
            while k < toks.count {
                switch toks[k].kind {
                case .open: d += 1
                case .close: d -= 1
                case .semicolon: return false
                case .comma where d == 0: return true
                case .word where d == 0:
                    if joinPhrases.contains(where: { matches(k, $0) }) { return false }
                    for p in clausePhrases where p != ["SELECT"] && matches(k, p) { return false }
                default: break
                }
                k += 1
            }
            return false
        }

        var i = 0
        while i < toks.count {
            let t = toks[i]

            switch t.kind {
            case .semicolon:
                while out.hasSuffix(" ") { out.removeLast() }
                out += ";"
                prev = Tok(kind: .semicolon, text: ";")
                clause = .none; selectBreak = false
                // blank line before the next statement, if any real token remains
                if i + 1 < toks.count {
                    out += "\n\n"; prev = nil
                }
                i += 1; continue

            case .open:  depth += 1; put("(", .open);  i += 1; continue
            case .close: depth = max(0, depth - 1); put(")", .close); i += 1; continue

            case .comma:
                while out.hasSuffix(" ") { out.removeLast() }
                out += ","
                prev = Tok(kind: .comma, text: ",")
                if depth == 0 && clause == .select && selectBreak {
                    newline(1)
                }
                // else: leave prev = .comma; the next token's separator adds one space
                i += 1; continue

            case .lineComment:
                put(t.text, .lineComment); newline(clause == .none ? 0 : 1)
                i += 1; continue

            case .word:
                if depth == 0 {
                    // JOIN ... (own line, ON stays inline)
                    if let jp = joinPhrases.first(where: { matches(i, $0) }) {
                        if !out.isEmpty { newline(0) }
                        for w in jp { put(w, .word) }
                        clause = .other
                        i += jp.count; continue
                    }
                    // ON → condition context, but inline after the JOIN
                    if wordAt(i, "ON") {
                        put("ON", .word); clause = .cond; i += 1; continue
                    }
                    // AND / OR inside a condition → new line
                    if clause == .cond, (wordAt(i, "AND") || wordAt(i, "OR")) {
                        newline(1); put(renderWord(i), .word); i += 1; continue
                    }
                    // major clause keyword
                    if let cp = clausePhrases.first(where: { matches(i, $0) }) {
                        if !out.isEmpty { newline(0) }
                        for w in cp { put(w, .word) }
                        i += cp.count
                        switch cp {
                        case ["SELECT"]:
                            clause = .select
                            // keep a leading DISTINCT / ALL on the SELECT line
                            if i < toks.count, toks[i].kind == .word,
                               ["DISTINCT","ALL"].contains(toks[i].text.uppercased()) {
                                put(toks[i].text.uppercased(), .word); i += 1
                            }
                            selectBreak = selectHasList(from: i)
                            if selectBreak { newline(1) }
                        case ["WHERE"], ["HAVING"]:
                            clause = .cond
                        case ["FROM"]:
                            clause = .other
                        default:
                            clause = .other   // GROUP BY / ORDER BY / LIMIT / SET … inline
                        }
                        continue
                    }
                }
                put(renderWord(i), .word); i += 1; continue

            default:
                put(t.text, t.kind); i += 1; continue
            }
        }

        // tidy trailing whitespace on every line
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingTrailing() }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func trimmingTrailing() -> String {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }
}

private extension Substring {
    func trimmingTrailing() -> String { String(self).trimmingTrailing() }
}
