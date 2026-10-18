//
//  SQLPushdown.swift
//  SequelBridge
//
//  Predicate pushdown for cross-server queries. A query that no reducer covers is run
//  by copying each remote table through the passthrough and joining locally — and the
//  user's WHERE used to be applied only afterwards, so `… JOIN … WHERE key = 'x'` dragged
//  a 383M-row log table across the VPN to keep a few hundred thousand rows.
//  `analyzeSelect` reads the FROM/JOIN/ON/WHERE of a plain SELECT; `pushdownPredicates`
//  then gives each table the conjuncts it can take server-side — its own, plus those
//  carried to it across an inner-join key equality (t1.tail = t2.tail and
//  t1.tail = 'X' imply t2.tail = 'X').
//
//  Results can never change. DuckDB still evaluates the whole original WHERE and ON on
//  the rows that come back, so a pushed predicate only has to admit every row DuckDB
//  would keep: it may be a SUPERSET filter, never a stricter one. That rules the shapes:
//  • string columns get only =, IN, LIKE and IS [NOT] NULL — MySQL's case-insensitive
//    collations make those supersets of DuckDB's binary comparison, but turn <>, <, >,
//    NOT IN, NOT LIKE and BETWEEN into filters that DROP rows ('m' <> 'M' is false
//    there, true here);
//  • numeric and temporal columns take every comparison, BETWEEN, IN and NOT, with a
//    literal of their own kind (temporal only ISO dates/times, which both sides parse
//    alike);
//  • NOT is pushed only over an exact predicate, since NOT of a superset is a subset;
//  • functions, arithmetic, subqueries and anything else stay with DuckDB;
//  • a bare column is attributed to a table only when exactly one table has it; the
//    caller supplies the column metadata.
//  Inner joins only: analyzeSelect declines outer joins, derived tables and UNIONs.
//

import Foundation

nonisolated extension SQLBuilder {

    /// A base table in a query's FROM/JOIN list.
    struct TableRef: Equatable, Hashable {
        let server: String       // connection alias as written
        let database: String?    // the middle part of a 3-part reference, else nil
        let table: String
        let queryAlias: String   // alias used in the query (the table name when none)
    }

    /// What `pushdownPredicates` needs from a plain SELECT.
    struct SelectShape: Equatable {
        let tables: [TableRef]
        let onConditions: [String]   // the text after each ON, verbatim
        let whereClause: String?     // the text after WHERE up to GROUP/HAVING/ORDER/LIMIT…, verbatim
    }

    // MARK: - Shape

    private static let clauseStarters: Set<String> =
        ["WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH", "WINDOW", "QUALIFY", "UNION", "INTERSECT", "EXCEPT"]
    private static let joinStarters: Set<String> =
        ["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "STRAIGHT_JOIN", "OUTER", "USING", "ON"]

    /// The tables, ON conditions and WHERE of a plain `SELECT … FROM a.t [x] [, | JOIN] b.u [y] ON …
    /// WHERE …`. nil for anything the pushdown must not touch: outer joins, derived
    /// tables, CTEs, set operations, USING, or a table that isn't `alias.table`.
    static func analyzeSelect(_ sql: String, aliases: [String]) -> SelectShape? {
        let chars = Array(sql)
        let toks = SQLTok.tokenize(chars)
        guard let first = toks.first, first.isKeyword("SELECT") else { return nil }
        let aliasSet = Set(aliases.map { $0.lowercased() })

        // Locate the top-level FROM; reject set operations anywhere at depth 0.
        var depth = 0
        var fromIdx: Int? = nil
        for (i, t) in toks.enumerated() {
            switch t.kind {
            case .lparen: depth += 1
            case .rparen: depth -= 1
            default:
                if depth == 0 {
                    if let k = t.keyword, ["UNION", "INTERSECT", "EXCEPT"].contains(k) { return nil }
                    if fromIdx == nil, t.isKeyword("FROM") { fromIdx = i }
                }
            }
        }
        guard var i = fromIdx.map({ $0 + 1 }) else { return nil }

        var tables: [TableRef] = []
        var ons: [String] = []
        var whereText: String? = nil

        func text(_ from: Int, _ to: Int) -> String {
            guard from < to, from < toks.count else { return "" }
            let s = toks[from].start, e = toks[to - 1].end
            return String(chars[s..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func parseTable() -> Bool {
            guard i < toks.count, case .ident(let parts, _) = toks[i].kind, parts.count == 2 || parts.count == 3,
                  aliasSet.contains(parts[0].lowercased()) else { return false }
            let ref = parts.count == 2
                ? (server: parts[0], db: String?.none, table: parts[1])
                : (server: parts[0], db: String?.some(parts[1]), table: parts[2])
            i += 1
            var alias = ref.table
            if i < toks.count, toks[i].isKeyword("AS") {
                guard i + 1 < toks.count, case .ident(let p, _) = toks[i+1].kind, p.count == 1 else { return false }
                alias = p[0]; i += 2
            } else if i < toks.count, case .ident(let p, let q) = toks[i].kind, p.count == 1,
                      q[0] || !(clauseStarters.contains(p[0].uppercased()) || joinStarters.contains(p[0].uppercased())) {
                alias = p[0]; i += 1
            }
            tables.append(TableRef(server: ref.server, database: ref.db, table: ref.table, queryAlias: alias))
            return true
        }
        /// Tokens from `i` up to the next depth-0 token whose keyword is in `stops` (or a
        /// depth-0 comma when `commaStops`); leaves `i` on the stop.
        func collect(stops: Set<String>, commaStops: Bool) -> (Int, Int) {
            let from = i
            var d = 0
            while i < toks.count {
                let t = toks[i]
                switch t.kind {
                case .lparen: d += 1
                case .rparen: d -= 1
                case .comma: if d == 0, commaStops { return (from, i) }
                default: if d == 0, let k = t.keyword, stops.contains(k) { return (from, i) }
                }
                i += 1
            }
            return (from, i)
        }

        guard parseTable() else { return nil }
        loop: while i < toks.count {
            let t = toks[i]
            if case .comma = t.kind { i += 1; guard parseTable() else { return nil }; continue }
            guard let k = t.keyword else { return nil }
            switch k {
            case "JOIN", "INNER":
                if k == "INNER" { i += 1; guard i < toks.count, toks[i].isKeyword("JOIN") else { return nil } }
                i += 1
                guard parseTable() else { return nil }
                guard i < toks.count, toks[i].isKeyword("ON") else { return nil }   // USING / missing ON
                i += 1
                let (a, b) = collect(stops: joinStarters.union(clauseStarters), commaStops: true)
                let cond = text(a, b)
                guard !cond.isEmpty else { return nil }
                ons.append(cond)
            case "WHERE":
                i += 1
                let (a, b) = collect(stops: clauseStarters.subtracting(["WHERE"]), commaStops: false)
                let w = text(a, b)
                whereText = w.isEmpty ? nil : w
            case "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH", "WINDOW", "QUALIFY":
                break loop
            default:
                return nil   // LEFT/RIGHT/FULL/CROSS/NATURAL/USING… or an unexpected word
            }
        }
        return SelectShape(tables: tables, onConditions: ons, whereClause: whereText)
    }

    // MARK: - Pushdown

    /// Per query alias → the conjuncts (rendered with `render`) its server can apply.
    /// `columns` maps each query alias to its column names and declared types.
    static func pushdownPredicates(_ shape: SelectShape,
                                   columns: [String: [String: String]],
                                   render: @escaping (_ queryAlias: String, _ column: String) -> String) -> [String: [String]] {
        let resolver = ColumnResolver(shape: shape, columns: columns)
        let resolve: ([String]) -> ColumnRef? = { resolver.resolve($0) }
        var keys = JoinKeyClasses()
        var pushed: [String: [String]] = [:]
        var simples: [SimplePredicate] = []

        func add(_ alias: String, _ text: String) {
            if pushed[alias]?.contains(text) != true { pushed[alias, default: []].append(text) }
        }
        func take(_ condition: String) {
            for c in SQLTok.conjuncts(condition) {
                if let (a, b) = equiPair(c, resolve: resolve) { keys.union(a, b); continue }
                var p = PredicateParser(toks: c, resolve: resolve, render: render)
                guard let n = p.parseOr(), p.atEnd else { continue }
                add(n.alias, n.text)
                if let s = n.simple { simples.append(s) }
            }
        }
        shape.onConditions.forEach(take)
        if let w = shape.whereClause { take(w) }

        // Carry each simple predicate on a join key to the other keys of its class.
        for s in simples {
            for other in keys.others(of: s.ref) where s.carries(to: other.family) {
                add(other.alias, s.render(render(other.alias, other.column)))
            }
        }
        return pushed
    }

    /// `ref = ref` across two tables → the pair; nil otherwise.
    private static func equiPair(_ slice: ArraySlice<SQLTok>, resolve: ([String]) -> ColumnRef?) -> (ColumnRef, ColumnRef)? {
        guard slice.count == 3, case .ident(let a, _) = slice[slice.startIndex].kind,
              case .op("=") = slice[slice.startIndex + 1].kind,
              case .ident(let b, _) = slice[slice.startIndex + 2].kind,
              let ra = resolve(a), let rb = resolve(b), ra.alias != rb.alias else { return nil }
        return (ra, rb)
    }
}

// MARK: - Tokens

/// The tokens the shape analysis and the predicate parser work on.
nonisolated struct SQLTok: Equatable {
    enum Kind: Equatable {
        case ident([String], [Bool])  // dotted parts, and whether each was quoted
        case str(String)              // string literal, raw (with quotes)
        case num(String)
        case op(String)
        case lparen, rparen, comma
        case other
    }
    let kind: Kind
    let start: Int   // offsets into the Character array of the source
    let end: Int

    /// The unquoted keyword this token is, uppercased, if it is a plain word.
    var keyword: String? {
        if case .ident(let p, let q) = kind, p.count == 1, q[0] == false { return p[0].uppercased() }
        return nil
    }
    func isKeyword(_ k: String) -> Bool { keyword == k }

    static func tokenize(_ chars: [Character]) -> [SQLTok] {
        var out: [SQLTok] = []
        var i = 0
        let n = chars.count
        func isWordStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            // Comments are whitespace.
            if c == "-", i + 1 < n, chars[i+1] == "-" {
                while i < n, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < n, chars[i+1] == "*" {
                i += 2
                while i + 1 < n, !(chars[i] == "*" && chars[i+1] == "/") { i += 1 }
                i = Swift.min(i + 2, n)
                continue
            }
            let start = i
            if c == "'" {
                i += 1
                while i < n {
                    if chars[i] == "'" {
                        if i + 1 < n, chars[i+1] == "'" { i += 2; continue }
                        i += 1; break
                    }
                    i += 1
                }
                out.append(SQLTok(kind: .str(String(chars[start..<i])), start: start, end: i))
                continue
            }
            if c.isNumber || (c == "." && i + 1 < n && chars[i+1].isNumber) {
                while i < n, chars[i].isNumber || chars[i] == "." { i += 1 }
                if i < n, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < n, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    if j < n, chars[j].isNumber { i = j; while i < n, chars[i].isNumber { i += 1 } }
                }
                out.append(SQLTok(kind: .num(String(chars[start..<i])), start: start, end: i))
                continue
            }
            if isWordStart(c) || c == "`" || c == "\"" {
                var parts: [String] = []
                var quoted: [Bool] = []
                func readName() -> Bool {
                    guard i < n else { return false }
                    let q = chars[i]
                    if q == "`" || q == "\"" {
                        var j = i + 1
                        var name: [Character] = []
                        while j < n {
                            if chars[j] == q {
                                if j + 1 < n, chars[j+1] == q { name.append(q); j += 2; continue }
                                break
                            }
                            name.append(chars[j]); j += 1
                        }
                        guard j < n else { return false }
                        parts.append(String(name)); quoted.append(true)
                        i = j + 1
                        return true
                    }
                    guard isWordStart(q) else { return false }
                    var j = i
                    while j < n, isWord(chars[j]) { j += 1 }
                    parts.append(String(chars[i..<j])); quoted.append(false)
                    i = j
                    return true
                }
                guard readName() else { out.append(SQLTok(kind: .other, start: start, end: i + 1)); i += 1; continue }
                while i < n, chars[i] == ".", i + 1 < n, isWordStart(chars[i+1]) || chars[i+1] == "`" || chars[i+1] == "\"" {
                    i += 1
                    guard readName() else { break }
                }
                out.append(SQLTok(kind: .ident(parts, quoted), start: start, end: i))
                continue
            }
            if c == "(" { out.append(SQLTok(kind: .lparen, start: i, end: i + 1)); i += 1; continue }
            if c == ")" { out.append(SQLTok(kind: .rparen, start: i, end: i + 1)); i += 1; continue }
            if c == "," { out.append(SQLTok(kind: .comma, start: i, end: i + 1)); i += 1; continue }
            let two = i + 1 < n ? String(chars[i...i+1]) : ""
            if ["<=", ">=", "<>", "!="].contains(two) {
                out.append(SQLTok(kind: .op(two), start: i, end: i + 2)); i += 2; continue
            }
            if "=<>+-*/%".contains(c) {
                out.append(SQLTok(kind: .op(String(c)), start: i, end: i + 1)); i += 1; continue
            }
            out.append(SQLTok(kind: .other, start: i, end: i + 1)); i += 1
        }
        return out
    }

    /// Depth-0 AND-split of a condition's tokens. The AND inside `x BETWEEN a AND b`
    /// belongs to the BETWEEN, not to the conjunction.
    static func conjuncts(_ text: String) -> [ArraySlice<SQLTok>] {
        let toks = tokenize(Array(text))
        var out: [ArraySlice<SQLTok>] = []
        var d = 0, from = 0
        var betweenOpen = false
        for (k, t) in toks.enumerated() {
            switch t.kind {
            case .lparen: d += 1
            case .rparen: d -= 1
            default:
                guard d == 0 else { continue }
                if t.isKeyword("BETWEEN") { betweenOpen = true }
                else if t.isKeyword("AND") {
                    if betweenOpen { betweenOpen = false; continue }
                    out.append(toks[from..<k]); from = k + 1
                }
            }
        }
        out.append(toks[from..<toks.count])
        return out.filter { !$0.isEmpty }
    }
}

// MARK: - Columns and types

/// Type family of a column, the unit the pushdown rules are written in. `enumeration`
/// is a ClickHouse Enum8/Enum16: it compares with string literals like a string column
/// — so the same equality-only caution applies — but has no LIKE.
nonisolated enum ColumnFamily {
    case string, enumeration, numeric, temporal, other
    /// String-like comparison semantics: only equality-shaped predicates are pushed.
    var isText: Bool { self == .string || self == .enumeration }
}

/// A column reference resolved to the table that owns it.
nonisolated struct ColumnRef: Equatable {
    let alias: String
    let column: String
    let family: ColumnFamily

    /// Family of a declared type, as the servers and ClickHouse spell it: "varchar(10)",
    /// "int(11) unsigned", "timestamp without time zone", "Nullable(UInt32)".
    static func family(ofType type: String) -> ColumnFamily {
        var t = type.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("nullable("), t.hasSuffix(")") { t = String(t.dropFirst(9).dropLast()) }
        if t.hasPrefix("lowcardinality("), t.hasSuffix(")") { t = String(t.dropFirst(15).dropLast()) }
        let head = t.split(whereSeparator: { $0 == "(" || $0 == " " }).first.map(String.init) ?? t
        switch head {
        case "char", "varchar", "text", "tinytext", "mediumtext", "longtext", "enum", "set", "character",
             "nchar", "nvarchar", "string", "fixedstring", "uuid", "citext", "bpchar", "name":
            return .string
        case "enum8", "enum16":
            return .enumeration
        case "int", "integer", "tinyint", "smallint", "mediumint", "bigint", "decimal", "numeric", "float", "double",
             "real", "bit", "bool", "boolean", "serial", "bigserial", "smallserial", "int2", "int4", "int8",
             "float4", "float8", "number", "dec", "fixed",
             "uint8", "uint16", "uint32", "uint64", "int16", "int32", "int64", "float32", "float64":
            return .numeric
        case "date", "datetime", "timestamp", "time", "year", "timestamptz", "timetz", "datetime64", "date32":
            return .temporal
        default:
            return .other
        }
    }
}

/// Resolves column references against the query's tables: a qualified `t.col` by its
/// query alias, a bare `col` only when exactly one table has it. Names compare
/// case-insensitively; the canonical spelling from the metadata is returned.
nonisolated private struct ColumnResolver {
    private let tables: [SQLBuilder.TableRef]
    private let aliasByLower: [String: String]
    private let colsByAlias: [String: [String: (name: String, family: ColumnFamily)]]

    init(shape: SQLBuilder.SelectShape, columns: [String: [String: String]]) {
        tables = shape.tables
        aliasByLower = Dictionary(shape.tables.map { ($0.queryAlias.lowercased(), $0.queryAlias) }, uniquingKeysWith: { a, _ in a })
        var cols: [String: [String: (String, ColumnFamily)]] = [:]
        for t in shape.tables {
            var m: [String: (String, ColumnFamily)] = [:]
            for (name, type) in columns[t.queryAlias] ?? [:] { m[name.lowercased()] = (name, ColumnRef.family(ofType: type)) }
            cols[t.queryAlias] = m
        }
        colsByAlias = cols
    }

    func resolve(_ parts: [String]) -> ColumnRef? {
        if parts.count == 1 {
            let lower = parts[0].lowercased()
            let hits = tables.compactMap { t -> ColumnRef? in
                guard let c = colsByAlias[t.queryAlias]?[lower] else { return nil }
                return ColumnRef(alias: t.queryAlias, column: c.name, family: c.family)
            }
            return hits.count == 1 ? hits[0] : nil
        }
        if parts.count == 2, let alias = aliasByLower[parts[0].lowercased()],
           let c = colsByAlias[alias]?[parts[1].lowercased()] {
            return ColumnRef(alias: alias, column: c.name, family: c.family)
        }
        return nil
    }
}

/// Equivalence classes of join-key columns (union-find over `t1.k = t2.k` pairs).
nonisolated private struct JoinKeyClasses {
    private var parent: [String: String] = [:]
    private var refs: [String: ColumnRef] = [:]

    private static func key(_ r: ColumnRef) -> String { r.alias + "\u{0}" + r.column.lowercased() }

    private func find(_ k: String) -> String {
        var k = k
        while let p = parent[k], p != k { k = p }
        return k
    }

    mutating func union(_ a: ColumnRef, _ b: ColumnRef) {
        for r in [a, b] {
            let k = Self.key(r)
            if parent[k] == nil { parent[k] = k; refs[k] = r }
        }
        let ra = find(Self.key(a)), rb = find(Self.key(b))
        if ra != rb { parent[ra] = rb }
    }

    /// The other members of `r`'s class; empty when `r` is not a join key.
    func others(of r: ColumnRef) -> [ColumnRef] {
        let k = Self.key(r)
        guard parent[k] != nil else { return [] }
        let root = find(k)
        return parent.keys.filter { $0 != k && find($0) == root }.sorted().compactMap { refs[$0] }
    }
}

// MARK: - Predicates

/// A literal operand, kept in its source spelling.
nonisolated private enum Literal: Equatable {
    case str(String), num(String), bool(String), null

    var text: String {
        switch self {
        case .str(let s), .num(let s): return s
        case .bool(let b): return b.uppercased()
        case .null: return "NULL"
        }
    }

    private static let isoTemporal = try! NSRegularExpression(
        pattern: #"^'\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?)?'$"#)

    /// Whether a column of family `f` compares with this literal the same way on the
    /// server and in DuckDB.
    func fits(_ f: ColumnFamily) -> Bool {
        switch (self, f) {
        case (.str(let s), .string), (.str(let s), .enumeration):
            return !s.contains("\\")                                   // backslash escapes differ by server
        case (.str(let s), .temporal): return Self.isoTemporal.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        case (.num, .numeric), (.bool, .numeric): return true
        default: return false
        }
    }
}

/// One predicate on one column reference, re-renderable for another column (that is
/// how a filter is carried across a join key).
nonisolated private struct SimplePredicate {
    enum Form {
        case compare(String, Literal, refFirst: Bool)
        case inList(Bool, [Literal])
        case between(Bool, Literal, Literal)
        case like(Bool, Literal)
        case isNull(Bool)
    }
    let ref: ColumnRef
    let form: Form
    let exact: Bool

    func render(_ refText: String) -> String {
        switch form {
        case .compare(let op, let lit, let refFirst):
            return refFirst ? "\(refText) \(op) \(lit.text)" : "\(lit.text) \(op) \(refText)"
        case .inList(let not, let lits):
            return "\(refText) \(not ? "NOT IN" : "IN") (\(lits.map(\.text).joined(separator: ", ")))"
        case .between(let not, let a, let b):
            return "\(refText) \(not ? "NOT BETWEEN" : "BETWEEN") \(a.text) AND \(b.text)"
        case .like(let not, let lit):
            return "\(refText) \(not ? "NOT LIKE" : "LIKE") \(lit.text)"
        case .isNull(let not):
            return "\(refText) IS \(not ? "NOT NULL" : "NULL")"
        }
    }

    /// Whether the same predicate on an equal-valued column of family `f` is still a
    /// superset filter: IS NULL is not carried (a NULL key never joins anyway).
    func carries(to f: ColumnFamily) -> Bool {
        if case .isNull = form { return false }
        return f == ref.family
    }
}

/// A parsed boolean expression over one table: its rendered text (through the
/// caller's quoting), whether it is an exact filter, and the simple predicate when it
/// is just one.
nonisolated private struct PredicateNode {
    let alias: String
    let text: String
    let exact: Bool
    let simple: SimplePredicate?
}

/// Recursive-descent parser for one conjunct: AND/OR/NOT over the supported predicate
/// shapes, all on one table. Anything it doesn't recognize makes the conjunct stay local.
nonisolated private struct PredicateParser {
    private let toks: ArraySlice<SQLTok>
    private var i: Int
    private let resolve: ([String]) -> ColumnRef?
    private let render: (String, String) -> String

    init(toks: ArraySlice<SQLTok>, resolve: @escaping ([String]) -> ColumnRef?, render: @escaping (String, String) -> String) {
        self.toks = toks
        self.i = toks.startIndex
        self.resolve = resolve
        self.render = render
    }

    var atEnd: Bool { i == toks.endIndex }
    private var cur: SQLTok? { i < toks.endIndex ? toks[i] : nil }
    private mutating func take(_ k: String) -> Bool { if cur?.isKeyword(k) == true { i += 1; return true }; return false }

    private static let reserved: Set<String> = [
        "AND", "OR", "NOT", "IN", "IS", "NULL", "BETWEEN", "LIKE", "TRUE", "FALSE", "SELECT", "CASE", "WHEN",
        "EXISTS", "ANY", "ALL", "SOME", "CAST", "INTERVAL", "COLLATE", "BINARY", "DIV", "MOD", "XOR", "REGEXP",
        "RLIKE", "ILIKE", "SIMILAR", "ESCAPE", "GLOB"]
    private static let allOps: Set<String> = ["=", "<>", "!=", "<", ">", "<=", ">="]

    private mutating func literal() -> Literal? {
        guard let t = cur else { return nil }
        switch t.kind {
        case .str(let s): i += 1; return .str(s)
        case .num(let s): i += 1; return .num(s)
        case .op("-"):
            if i + 1 < toks.endIndex, case .num(let s) = toks[i+1].kind { i += 2; return .num("-" + s) }
            return nil
        default:
            if let k = t.keyword {
                if k == "TRUE" || k == "FALSE" { i += 1; return .bool(k) }
                if k == "NULL" { i += 1; return .null }
            }
            return nil
        }
    }

    private mutating func ref() -> ColumnRef? {
        guard let t = cur, case .ident(let parts, let quoted) = t.kind else { return nil }
        if parts.count == 1, !quoted[0], Self.reserved.contains(parts[0].uppercased()) { return nil }
        // A word followed by "(" is a function call, never a column.
        if i + 1 < toks.endIndex, case .lparen = toks[i+1].kind { return nil }
        guard let r = resolve(parts), r.family != .other else { return nil }
        i += 1
        return r
    }

    mutating func parseOr() -> PredicateNode? {
        guard var left = parseAnd() else { return nil }
        while take("OR") {
            guard let right = parseAnd(), right.alias == left.alias else { return nil }
            left = PredicateNode(alias: left.alias, text: "\(left.text) OR \(right.text)", exact: left.exact && right.exact, simple: nil)
        }
        return left
    }

    private mutating func parseAnd() -> PredicateNode? {
        guard var left = parseNot() else { return nil }
        while take("AND") {
            guard let right = parseNot(), right.alias == left.alias else { return nil }
            left = PredicateNode(alias: left.alias, text: "\(left.text) AND \(right.text)", exact: left.exact && right.exact, simple: nil)
        }
        return left
    }

    private mutating func parseNot() -> PredicateNode? {
        if take("NOT") {
            guard let inner = parseNot(), inner.exact else { return nil }
            return PredicateNode(alias: inner.alias, text: "NOT \(inner.text)", exact: true, simple: nil)
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> PredicateNode? {
        if case .lparen = cur?.kind {
            i += 1
            guard let inner = parseOr(), case .rparen = cur?.kind else { return nil }
            i += 1
            return PredicateNode(alias: inner.alias, text: "(\(inner.text))", exact: inner.exact, simple: nil)
        }
        return parsePredicate()
    }

    private mutating func parsePredicate() -> PredicateNode? {
        // literal op ref
        if let lit = literal() {
            guard let t = cur, case .op(let op) = t.kind, Self.allOps.contains(op) else { return nil }
            i += 1
            guard let r = ref() else { return nil }
            return compare(r, op, lit, refFirst: false)
        }
        guard let r = ref() else { return nil }
        let refText = render(r.alias, r.column)
        if take("IS") {
            let not = take("NOT")
            guard take("NULL") else { return nil }
            return node(SimplePredicate(ref: r, form: .isNull(not), exact: true), refText)
        }
        let not = take("NOT")
        if take("IN") {
            guard case .lparen = cur?.kind else { return nil }
            i += 1
            var lits: [Literal] = []
            while true {
                guard let l = literal(), l != .null, l.fits(r.family) else { return nil }
                lits.append(l)
                if case .comma = cur?.kind { i += 1; continue }
                break
            }
            guard case .rparen = cur?.kind else { return nil }
            i += 1
            if r.family.isText && not { return nil }     // NOT IN under a ci collation drops rows
            return node(SimplePredicate(ref: r, form: .inList(not, lits), exact: !r.family.isText), refText)
        }
        if take("BETWEEN") {
            guard !r.family.isText, let a = literal(), a != .null, a.fits(r.family), take("AND"),
                  let b = literal(), b != .null, b.fits(r.family) else { return nil }
            return node(SimplePredicate(ref: r, form: .between(not, a, b), exact: true), refText)
        }
        if take("LIKE") {
            guard r.family == .string, !not, let l = literal(), case .str = l, l.fits(.string) else { return nil }
            return node(SimplePredicate(ref: r, form: .like(false, l), exact: false), refText)
        }
        if not { return nil }
        guard let t = cur, case .op(let op) = t.kind, Self.allOps.contains(op) else { return nil }
        i += 1
        if let lit = literal() { return compare(r, op, lit, refFirst: true) }
        // ref op ref, same table and family (numeric/temporal exact; string only "=")
        guard let r2 = ref(), r2.alias == r.alias, r2.family == r.family else { return nil }
        if r.family.isText, op != "=" { return nil }
        return PredicateNode(alias: r.alias, text: "\(refText) \(op) \(render(r2.alias, r2.column))", exact: !r.family.isText, simple: nil)
    }

    private func compare(_ r: ColumnRef, _ op: String, _ lit: Literal, refFirst: Bool) -> PredicateNode? {
        guard lit != .null, lit.fits(r.family) else { return nil }
        if r.family.isText, op != "=" { return nil }   // ci collations: only equality is a superset
        return node(SimplePredicate(ref: r, form: .compare(op, lit, refFirst: refFirst), exact: !r.family.isText),
                    render(r.alias, r.column))
    }

    private func node(_ s: SimplePredicate, _ refText: String) -> PredicateNode {
        PredicateNode(alias: s.ref.alias, text: s.render(refText), exact: s.exact, simple: s)
    }
}
