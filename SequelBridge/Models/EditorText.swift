//
//  EditorText.swift
//  SequelBridge
//
//  What the left panel's table filter shows, what the SQL editor completes and
//  highlights, and how a results row copies.
//

import Foundation

nonisolated enum TableListFilter {
    /// The tables and views listed for `filter`: part of the name, ignoring case and the
    /// spaces around it; no filter lists everything. Tables and views apart.
    static func listed(_ all: [TableInfo], filter: String) -> (tables: [TableInfo], views: [TableInfo]) {
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = f.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(f) }
        return (shown.filter { $0.type == .table }, shown.filter { $0.type == .view })
    }
}

nonisolated enum SQLCompletion {
    /// What the editor offers for a word being typed: SQL keywords and the connection's
    /// table and column names that start with it, ignoring case, once each, in order.
    static func candidates(for partial: String, items: [String]) -> [String] {
        let p = partial.lowercased()
        guard !p.isEmpty else { return [] }
        return Array(Set(SQLKeywords.all + items))
            .filter { $0.lowercased().hasPrefix(p) }
            .sorted { $0.lowercased() < $1.lowercased() }
    }
}

nonisolated enum SQLHighlighter {
    enum Kind: Equatable { case keyword, string, comment }
    struct Span: Equatable { let range: NSRange; let kind: Kind }

    static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR",
        "NOT", "IN", "LIKE", "AS", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "INSERT",
        "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "INDEX",
        "VIEW", "DISTINCT", "UNION", "ALL", "CASE", "WHEN", "THEN", "ELSE", "END", "IS", "NULL",
        "BETWEEN", "EXISTS", "WITH",
    ]

    /// Keywords, 'strings' and comments (--, #, /* */) in one pass over the text, so a
    /// comment marker inside a string, or a keyword inside backticks or double quotes
    /// (identifiers), is left alone. Ranges are UTF-16, as NSTextStorage counts.
    static func spans(in text: String) -> [Span] {
        let s = text as NSString
        let n = s.length
        var spans: [Span] = []
        func at(_ k: Int) -> unichar { s.character(at: k) }
        func isWord(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
        }
        /// The end of a quoted run opened at `start` (`q` doubled inside stays in it).
        func quoted(_ start: Int, _ q: unichar, backslash: Bool) -> Int {
            var j = start + 1
            while j < n {
                let d = at(j)
                if backslash && d == 92 { j += 2; continue }
                if d == q {
                    if j + 1 < n && at(j + 1) == q { j += 2; continue }
                    return j + 1
                }
                j += 1
            }
            return n
        }
        var i = 0
        while i < n {
            let c = at(i)
            if c == 35 || (c == 45 && i + 1 < n && at(i + 1) == 45) {          // # or --
                var j = i
                while j < n && at(j) != 10 { j += 1 }
                spans.append(Span(range: NSRange(location: i, length: j - i), kind: .comment)); i = j
            } else if c == 47 && i + 1 < n && at(i + 1) == 42 {               // /*
                var j = i + 2
                while j + 1 < n && !(at(j) == 42 && at(j + 1) == 47) { j += 1 }
                j = min(j + 2, n)
                spans.append(Span(range: NSRange(location: i, length: j - i), kind: .comment)); i = j
            } else if c == 39 {                                                // 'string'
                let j = min(quoted(i, 39, backslash: true), n)
                spans.append(Span(range: NSRange(location: i, length: j - i), kind: .string)); i = j
            } else if c == 96 || c == 34 {                                     // `name` or "name"
                i = min(quoted(i, c, backslash: c == 34), n)
            } else if isWord(c) {
                var j = i
                while j < n && isWord(at(j)) { j += 1 }
                let afterDot = i > 0 && at(i - 1) == 46
                if !afterDot, keywords.contains(s.substring(with: NSRange(location: i, length: j - i)).uppercased()) {
                    spans.append(Span(range: NSRange(location: i, length: j - i), kind: .keyword))
                }
                i = j
            } else {
                i += 1
            }
        }
        return spans
    }
}

nonisolated enum RowCopy {
    /// One row as tab-separated values; a NULL copies as an empty value.
    static func tabbed(_ values: [String], nulls: [Bool]) -> String {
        values.enumerated().map { i, v in i < nulls.count && nulls[i] ? "" : v }.joined(separator: "\t")
    }

    /// Rows under a header line of column names.
    static func withColumnNames(_ columns: [String], rows: [String]) -> String {
        ([columns.joined(separator: "\t")] + rows).joined(separator: "\n")
    }
}

nonisolated enum EditorEdits {
    struct Edit: Equatable { let text: String; let selection: NSRange }

    /// ⌘/: puts "-- " before each selected line that has text, or, when every one of them
    /// already starts with "--", takes it off. A selection that ends at the start of a
    /// line leaves that line alone.
    static func toggleComment(_ text: String, selection: NSRange) -> Edit {
        let lines = selectedLines(text, selection)
        let filled = lines.lines.filter { !isBlank($0) }
        let uncomment = !filled.isEmpty && filled.allSatisfy { $0.drop(while: isIndent).hasPrefix("--") }
        return rewrite(text, selection, lines) { line in
            guard !isBlank(line) else { return (line, 0) }
            guard uncomment else { return ("-- " + line, 3) }
            let lead = line.prefix(while: isIndent)
            var rest = line.dropFirst(lead.count).dropFirst(2)
            var removed = 2
            if rest.first == " " { rest = rest.dropFirst(); removed = 3 }
            return (String(lead) + rest, -removed)
        }
    }

    /// ⌘] indents each selected line with text by `width` spaces; ⌘[ takes off up to
    /// `width` leading spaces, or one tab.
    static func shift(_ text: String, selection: NSRange, right: Bool, width: Int) -> Edit {
        rewrite(text, selection, selectedLines(text, selection)) { line in
            if right { return isBlank(line) ? (line, 0) : (String(repeating: " ", count: width) + line, width) }
            if line.hasPrefix("\t") { return (String(line.dropFirst()), -1) }
            let spaces = line.prefix { $0 == " " }.count
            let removed = min(spaces, width)
            return (String(line.dropFirst(removed)), -removed)
        }
    }

    // MARK: - The lines a selection touches

    private struct Lines { let range: NSRange; let lines: [String]; let endsWithNewline: Bool }

    private static func isIndent(_ c: Character) -> Bool { c == " " || c == "\t" }
    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(isIndent) }

    private static func selectedLines(_ text: String, _ selection: NSRange) -> Lines {
        let s = text as NSString
        let safe = NSRange(location: min(selection.location, s.length),
                           length: min(selection.length, s.length - min(selection.location, s.length)))
        let range = s.lineRange(for: safe)
        let body = s.substring(with: range)
        var lines = body.components(separatedBy: "\n")
        let endsWithNewline = body.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        return Lines(range: range, lines: lines, endsWithNewline: endsWithNewline)
    }

    /// Rewrites each line; the caret moves with its line's text, a selection covers the lines.
    private static func rewrite(_ text: String, _ selection: NSRange, _ lines: Lines,
                                _ change: (String) -> (String, Int)) -> Edit {
        var shift = 0
        let changed = lines.lines.map { line -> String in
            let (out, delta) = change(line)
            if shift == 0 { shift = delta }
            return out
        }
        let body = changed.joined(separator: "\n") + (lines.endsWithNewline ? "\n" : "")
        let newText = (text as NSString).replacingCharacters(in: lines.range, with: body)
        let bodyLength = (body as NSString).length
        let selected: NSRange = selection.length == 0
            ? NSRange(location: max(lines.range.location, selection.location + shift), length: 0)
            : NSRange(location: lines.range.location, length: bodyLength - (lines.endsWithNewline ? 1 : 0))
        return Edit(text: newText, selection: selected)
    }
}
