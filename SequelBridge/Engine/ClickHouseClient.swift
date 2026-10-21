//
//  ClickHouseClient.swift
//  SequelBridge
//
//  ClickHouse over its native HTTP interface. No DuckDB scanner can reach
//  ClickHouse — its MySQL-protocol shim cannot run the transactions the scanner
//  wraps every read in — so this engine is served by a native transport: one
//  POST per statement, results in TSVWithNamesAndTypes (line 1 names, line 2
//  types, then rows). Outside DuckDB's catalog, so no cross-engine joins.
//

import Foundation

final class ClickHouseClient {

    private let baseURL: URL
    private let user: String
    private let password: String
    /// Sends readonly=2 with every statement, so the server refuses a write (settings can
    /// still change). Off for an account the server already holds read-only, which would
    /// refuse the setting itself.
    var readOnly = false

    // `inflight` is written from the cooperative pool (post) and read from the
    // @MainActor (cancel), so every access goes through this lock to avoid a data race.
    private let inflightLock = NSLock()
    private var _inflight: Task<(Data, URLResponse), Error>?
    private var inflight: Task<(Data, URLResponse), Error>? {
        get { inflightLock.lock(); defer { inflightLock.unlock() }; return _inflight }
        set { inflightLock.lock(); defer { inflightLock.unlock() }; _inflight = newValue }
    }

    init(host: String, port: Int, user: String, password: String, useTLS: Bool) {
        var comps = URLComponents()
        comps.scheme = useTLS ? "https" : "http"
        comps.host = host
        comps.port = port
        self.baseURL = comps.url ?? URL(string: "http://127.0.0.1:8123")!
        self.user = user
        self.password = password
    }

    // MARK: - Statements

    /// The result format comes from the request (`default_format`), not from text added
    /// to the statement: appended to `INSERT … VALUES (…)` it was read as one more row
    /// ("Cannot parse input"), and `DELETE` and a statement with its own FORMAT refused it.
    /// A statement with its own FORMAT clause comes back as that text, a line per row.
    func query(_ sql: String) async throws -> QueryResult {
        let start = Date()
        let text = try await post(sql)
        var result: QueryResult
        if Self.hasOwnFormat(sql) {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last?.isEmpty == true { lines.removeLast() }
            result = QueryResult(columns: ["result"], rows: lines.map { [$0] }, executionTime: 0)
            result.totalRowCount = lines.count
        } else {
            result = Self.parseTSVWithNamesAndTypes(text)
        }
        result.executionTime = Date().timeIntervalSince(start)
        return result
    }

    /// Whether `sql` ends with a FORMAT clause of its own ("… FORMAT JSON"): one naming a
    /// format ClickHouse writes, not a column called format ("ORDER BY format DESC").
    static func hasOwnFormat(_ sql: String) -> Bool {
        let body = QueryEffects.statements(sql).last ?? sql
        guard let r = body.range(of: #"(?i)\bFORMAT\s+([A-Za-z0-9_]+)\s*;?\s*$"#, options: .regularExpression) else { return false }
        let name = body[r].split(whereSeparator: { $0.isWhitespace || $0 == ";" }).dropFirst().first.map(String.init) ?? ""
        let formats = ["TabSeparated", "TSV", "CSV", "JSON", "Pretty", "Values", "Vertical", "XML", "Markdown", "Parquet",
                       "Arrow", "Native", "RowBinary", "Null", "Template", "CustomSeparated", "ORC", "Avro", "Protobuf",
                       "CapnProto", "MsgPack", "SQLInsert", "LineAsString", "RawBLOB", "Prometheus", "Regexp", "BSON",
                       "Npy", "Form", "Raw", "PrettyCompact", "Buffers"]
        return formats.contains { name.lowercased().hasPrefix($0.lowercased()) }
    }

    /// DDL and anything else whose result body is irrelevant.
    func execute(_ sql: String) async throws {
        _ = try await post(sql)
    }

    /// Cancels the in-flight request. The server may briefly keep computing;
    /// the app's connection is free immediately.
    func cancel() {
        inflight?.cancel()
    }

    private func post(_ body: String) async throws -> String {
        var url = baseURL
        url.append(queryItems: [URLQueryItem(name: "default_format", value: "TSVWithNamesAndTypes")])
        if readOnly { url.append(queryItems: [URLQueryItem(name: "readonly", value: "2")]) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue(user, forHTTPHeaderField: "X-ClickHouse-User")
        request.setValue(password, forHTTPHeaderField: "X-ClickHouse-Key")
        request.timeoutInterval = 300

        let task = Task { try await URLSession.shared.data(for: request) }
        inflight = task
        defer { inflight = nil }
        let (data, response) = try await task.value

        let text = String(decoding: data, as: UTF8.self)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // ClickHouse puts "Code: NN. DB::Exception: …" in the body.
            let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SequelBridgeError.attachFailed(reason.isEmpty ? "ClickHouse request failed" : reason)
        }
        return text
    }

    // MARK: - TSV parsing

    /// Line 1: column names. Line 2: types. Rest: rows. Fields are tab-separated
    /// with backslash escapes; `\N` is NULL, which the app renders as "NULL".
    static func parseTSVWithNamesAndTypes(_ text: String) -> QueryResult {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing newline produces one empty last element; drop it.
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 2 else {
            return QueryResult(columns: [], rows: [], executionTime: 0)
        }
        let columns = splitFields(lines[0]).map { unescape($0) }
        let types = splitFields(lines[1]).map { unescape($0) }
        var rows: [[String]] = []
        var nullMask: [[Bool]] = []
        for line in lines.dropFirst(2) {
            let fields = splitFields(line)
            // \N is ClickHouse's NULL sentinel — track it in the mask so a genuine
            // "NULL" string stays distinct from an actual NULL.
            rows.append(fields.map { $0 == "\\N" ? "NULL" : unescape($0) })
            nullMask.append(fields.map { $0 == "\\N" })
        }
        var r = QueryResult(columns: columns, rows: rows, executionTime: 0)
        r.nullMask = nullMask
        r.columnTypes = types
        r.totalRowCount = rows.count
        return r
    }

    private static func splitFields(_ line: Substring) -> [Substring] {
        line.split(separator: "\t", omittingEmptySubsequences: false)
    }

    static func unescape(_ s: Substring) -> String {
        guard s.contains("\\") else { return String(s) }
        var out = ""
        out.reserveCapacity(s.count)
        var escaped = false
        for ch in s {
            if escaped {
                switch ch {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "\\": out.append("\\")
                case "'": out.append("'")
                case "0": out.append("\0")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
