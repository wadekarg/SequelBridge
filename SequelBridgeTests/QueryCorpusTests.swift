//
//  QueryCorpusTests.swift
//  SequelBridgeTests
//
//  Every kind of statement a person types in the Query tab, on every engine, through the
//  path the Query tab takes (QueryRoute, then the engine call QueryPanelView makes for
//  that route): reads and writes, DDL of every object, joins, subqueries, CTEs, window
//  functions, transactions, session variables, SHOW/DESCRIBE/EXPLAIN, procedures and
//  triggers, each engine's own syntax and types, odd names and values, and errors that
//  must come back said plainly. A failure lists every statement that failed, not just
//  the first. MySQL runs on each MySQL-family server scripts/run-all-tests.sh points it
//  at; each corpus also runs through the SSH tunnel and the Unix socket where the engine
//  has one. With SB_CORPUS_REPORT set, every statement's outcome is written there.
//

import Foundation
import Testing
@testable import SequelBridge

// MARK: - Cases

/// One statement, or a script split as the Query tab splits it, and what must come back.
/// `{p}` in the SQL is the run's table prefix, so runs on several transports don't meet.
@MainActor
struct CorpusCase {
    enum Expect {
        case ok                     // runs, whatever it returns
        case rows(Int)              // exactly n rows
        case atLeast(Int)           // n rows or more
        case value(String)          // the first row's first cell
        case contains(String)       // some cell of the first row contains it
        case length(Int)            // the first cell's length, in characters
        case error(String)          // fails, and the reason says this (any case)
    }
    let sql: String
    let expect: Expect
    /// Whether the server runs it (a CTE needs MariaDB 10.2 or MySQL 8.0).
    var when: (CorpusServer) -> Bool = { _ in true }

    /// The case with `{p}` replaced in what it expects too.
    func prefixed(_ prefix: String) -> CorpusCase {
        func p(_ s: String) -> String { s.replacingOccurrences(of: "{p}", with: prefix) }
        let e: Expect
        switch expect {
        case .value(let v): e = .value(p(v))
        case .contains(let v): e = .contains(p(v))
        case .error(let v): e = .error(p(v))
        default: e = expect
        }
        return CorpusCase(sql: p(sql), expect: e, when: when)
    }

    /// nil when `outcome` is what was expected; otherwise what went wrong.
    func verdict(_ outcome: Result<QueryResult, Error>) -> String? {
        switch (expect, outcome) {
        case (.error(let said), .failure(let error)):
            let reason = QueryEngine.extractReason(from: error)
            return reason.lowercased().contains(said.lowercased()) ? nil : "failed, but saying: \(reason)"
        case (.error(let said), .success(let r)):
            return "ran (\(r.rowCount) rows), but should fail saying \(said)"
        case (_, .failure(let error)):
            return "failed: \(QueryEngine.extractReason(from: error))"
        case (.ok, .success):
            return nil
        case (.rows(let n), .success(let r)):
            return r.rowCount == n ? nil : "\(r.rowCount) rows, not \(n): \(Self.firstRow(r))"
        case (.atLeast(let n), .success(let r)):
            return r.rowCount >= n ? nil : "\(r.rowCount) rows, not \(n) or more"
        case (.value(let v), .success(let r)):
            let got = r.rows.first?.first
            return got == v ? nil : "first cell \(got.map { "'\($0)'" } ?? "missing"), not '\(v)'"
        case (.contains(let v), .success(let r)):
            return (r.rows.first ?? []).contains { $0.contains(v) } ? nil : "no cell of \(Self.firstRow(r)) contains '\(v)'"
        case (.length(let n), .success(let r)):
            let got = r.rows.first?.first?.count ?? -1
            return got == n ? nil : "first cell is \(got) characters, not \(n)"
        }
    }

    static func firstRow(_ r: QueryResult) -> String {
        guard let row = r.rows.first else { return "no rows" }
        return "[" + row.prefix(6).map { $0.count > 40 ? String($0.prefix(37)) + "…" : $0 }.joined(separator: ", ") + "]"
    }
}

/// The server a corpus runs on: which kind, and its version.
nonisolated struct CorpusServer: CustomStringConvertible {
    let kind: String            // "MariaDB", "MySQL", "PostgreSQL", "ClickHouse", "SQLite"
    let version: [Int]
    var description: String { "\(kind) \(version.map(String.init).joined(separator: "."))" }

    init(kind: String, version: [Int]) { self.kind = kind; self.version = version }

    /// From a server's version string: "10.0.38-MariaDB-1~xenial", "8.4.3", "16.4 (Debian…)".
    init(kind: String, versionString: String) {
        let numbers = versionString.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        let isMariaDB = kind == "MySQL" && versionString.lowercased().contains("mariadb")
        self.init(kind: isMariaDB ? "MariaDB" : kind, version: numbers)
    }

    func atLeast(_ v: [Int]) -> Bool { !version.lexicographicallyPrecedes(v) }

    /// For the MySQL family: MariaDB from `mariadb`, MySQL from `mysql`; nil for never.
    func atLeast(mariadb: [Int]?, mysql: [Int]?) -> Bool {
        guard let min = kind == "MariaDB" ? mariadb : mysql else { return false }
        return atLeast(min)
    }
}

// MARK: - Transports and the run

/// How the corpus reaches the server, as a connection can.
nonisolated enum CorpusTransport: String, CaseIterable, CustomTestStringConvertible {
    case tcp, ssh, socket
    var prefix: String { ["tcp": "ct_", "ssh": "cs_", "socket": "cx_"][rawValue]! }
    var testDescription: String { rawValue }
}

nonisolated enum CorpusEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static func v(_ key: String, _ fallback: String) -> String {
        guard let value = e[key], !value.isEmpty else { return fallback }
        return value
    }
    static var ssh: Bool { e["SB_SSH_VERIFY"] == "1" && !(e["SB_SSH_KEY"] ?? "").isEmpty }
    static var sshPort: Int { Int(v("SB_SSH_PORT", "2224")) ?? 2224 }
    static var sshDBHost: String { v("SB_SSH_DB_HOST", "host.docker.internal") }

    /// A connection entry for a fixture file, reaching `host:port` through `transport`.
    static func entry(_ transport: CorpusTransport, engine: String, alias: String, host: String, port: Int,
                      user: String, password: String, database: String, socket: String = "") -> [String: Any] {
        var entry: [String: Any] = [
            "id": UUID().uuidString, "name": "Corpus \(alias)", "alias": alias, "color": "#3A9AA8",
            "host": host, "port": port, "username": user, "password": password, "database": database,
            "engine": engine, "folder": "", "readOnly": false, "connectionType": "TCP/IP",
        ]
        switch transport {
        case .tcp: break
        case .ssh:
            // The database as the SSH server sees it; the tunnel's end is the app's.
            entry["connectionType"] = "SSH"
            entry["host"] = sshDBHost
            entry["sshHost"] = "127.0.0.1"
            entry["sshPort"] = sshPort
            entry["sshUsername"] = "tunneluser"
            entry["sshKeyPath"] = v("SB_SSH_KEY", "")
        case .socket:
            entry["connectionType"] = "Socket"
            entry["socketPath"] = socket
        }
        return entry
    }
}

/// One connection, made the way Home makes it (ConnectionManager.connect), running
/// statements the way the Query tab runs them.
@MainActor
final class CorpusRun {
    let manager: ConnectionManager
    let conn: Connection
    let transport: CorpusTransport
    var engine: QueryEngine { manager.queryEngine }
    /// The database the left panel picked after connecting (WorkspaceSession.loadDatabases).
    private(set) var picked: String?
    private var lines: [String] = []

    init(_ transport: CorpusTransport, entry: [String: Any]) async throws {
        self.transport = transport
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-corpus-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        try JSONSerialization.data(withJSONObject: [entry]).write(to: fixture)
        manager = try ConnectionManager(arguments: ["app", "-SBConnectionsFile", fixture.path])
        guard let saved = manager.saved.first else { throw SequelBridgeError.attachFailed("no connection in the fixture") }
        conn = saved
        try await manager.connect([conn])
        // As the left panel does after connecting: the saved database, else PostgreSQL's
        // public, else the first; then the same switch as picking it there.
        if conn.engine != .clickhouse {
            let dbs = try await engine.fetchDatabases(alias: conn.alias)
            let pick = dbs.first(where: { $0 == conn.database })
                ?? (conn.engine == .postgres ? dbs.first(where: { $0 == "public" }) : nil) ?? dbs.first ?? ""
            if !pick.isEmpty { _ = try await manager.switchDatabase(alias: conn.alias, to: pick); picked = pick }
        }
    }

    /// Ends the connection, tunnel included, before the test returns.
    func close() async { try? await engine.detach(conn.alias) }

    private func facts(_ alias: String) -> QueryRoute.Facts {
        QueryRoute.Facts(isReadOnly: engine.isReadOnly(alias), hasServerPassthrough: engine.hasServerPassthrough(alias),
                         attachedDatabase: engine.attachedDatabase(alias), selectedDatabase: picked,
                         inTransaction: engine.inQueryTabTransaction)
    }

    /// `sql` as the Query tab runs it: split into statements, each on its route; the
    /// last statement's result.
    func run(_ sql: String) async throws -> QueryResult {
        let statements = SQLScript.statements(sql, engine: conn.engine)
        guard !statements.isEmpty else { throw SequelBridgeError.attachFailed("nothing to run") }
        // As QueryPanelView: a script whose statements share what each sets, on one connection.
        switch QueryRoute.sessionScript(statements, connections: [conn], active: conn.alias, facts: facts) {
        case .run(let alias, let all, let database)?:
            return try await engine.nativeScript(alias: alias, statements: all, database: database)
        case .refused(let reason)?:
            throw SequelBridgeError.attachFailed(reason)
        case nil:
            break
        }
        var last = QueryResult.empty
        for statement in statements { last = try await runOne(statement) }
        return last
    }

    func route(_ sql: String) -> QueryRoute {
        QueryRoute.plan(sql, connections: [conn], active: conn.alias, facts: facts)
    }

    /// One statement: QueryPanelView.runTypedQuery's engine call for its route.
    func runOne(_ sql: String) async throws -> QueryResult {
        switch route(sql) {
        case .refused(let reason):
            throw SequelBridgeError.attachFailed(reason)
        case .explain(let inner):
            return try await engine.explain(alias: conn.alias, serverSQL: SQLBuilder.stripAliasPrefix(inner, alias: conn.alias),
                                            database: QueryRoute.catalogDatabase(conn.alias, connections: [conn], facts: facts))
        case .use(let alias, let database):
            // As picking it in the left panel (WorkspaceSession.showDatabase).
            _ = try await manager.switchDatabase(alias: alias, to: database)
            picked = database
            return QueryResult(columns: ["Result"], rows: [["Database changed to \(database)"]], executionTime: 0)
        case .asTyped(let alias, let serverSQL):
            let changed = try await engine.runAsTyped(alias: alias, sql: serverSQL)
            return changed.map { QueryResult(columns: ["Affected rows"], rows: [["\($0)"]], executionTime: 0) }
                ?? QueryResult(columns: ["Result"], rows: [["Done"]], executionTime: 0)
        case .native(let alias, let serverSQL, let database):
            return try await engine.nativeQuery(alias: alias, sql: serverSQL, database: database)
        case .clickhouse(let alias, let chSQL):
            return try await engine.clickhouseQuery(alias: alias, sql: chSQL)
        case .passthrough(let alias, let serverSQL):
            let (first, stream) = try await engine.openServerRead(
                alias: alias, serverSQL: serverSQL,
                database: QueryRoute.catalogDatabase(alias, connections: [conn], facts: facts), firstChunk: 2_000)
            return try await drain(first, stream)
        case .scanner(let scannerSQL, let context):
            if let context { await engine.setDefaultContextAwaited(alias: context.alias, database: context.database) }
            let (first, stream) = try await engine.openStreamingQuery(scannerSQL, firstChunk: 2_000)
            return try await drain(first, stream)
        case .acrossServers:
            throw SequelBridgeError.attachFailed("names several servers")
        }
    }

    private func drain(_ first: QueryResult, _ stream: QueryEngine.QueryStream) async throws -> QueryResult {
        var result = first
        defer { Task { await engine.closeStream(stream) } }
        while stream.hasMore {
            guard let chunk = try await engine.pullMore(stream, size: 20_000), chunk.rowCount > 0 else { break }
            result.cells.append(chunk)
        }
        return result
    }

    /// Runs every case the server runs, in order; records an issue for each that failed.
    func check(_ cases: [CorpusCase], on server: CorpusServer, name: String) async {
        let prefix = transport.prefix
        var failed = 0, ran = 0
        let progress = CorpusEnv.e["SB_CORPUS_REPORT"].map { "\($0)/\(name)-\(transport.rawValue).progress" }
        for c in cases where c.when(server) {
            let sql = c.sql.replacingOccurrences(of: "{p}", with: prefix)
            let c = c.prefixed(prefix)
            if let progress { try? sql.write(toFile: progress, atomically: true, encoding: .utf8) }
            let started = Date()
            let outcome: Result<QueryResult, Error>
            do { outcome = .success(try await run(sql)) } catch { outcome = .failure(error) }
            let took = String(format: "%.2fs", Date().timeIntervalSince(started))
            ran += 1
            let routeName = SQLScript.statements(sql).last.map { "\(route($0))".prefix(while: { $0 != "(" }) } ?? "-"
            if let problem = c.verdict(outcome) {
                failed += 1
                Issue.record("\(server) over \(transport.rawValue): \(sql)\n  → \(problem)  [route \(routeName)]")
                lines.append("FAIL \(took) [\(routeName)] \(sql.replacingOccurrences(of: "\n", with: "⏎"))\n     → \(problem)")
            } else {
                let shown: String
                switch outcome {
                case .success(let r): shown = "\(r.rowCount) rows \(CorpusCase.firstRow(r))"
                case .failure(let e): shown = "error as expected: \(QueryEngine.extractReason(from: e))"
                }
                lines.append("ok   \(took) [\(routeName)] \(sql.replacingOccurrences(of: "\n", with: "⏎"))  → \(shown)")
            }
        }
        lines.insert("\(name) on \(server) over \(transport.rawValue): \(ran - failed) of \(ran) as expected", at: 0)
        if let dir = CorpusEnv.e["SB_CORPUS_REPORT"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(toFile: "\(dir)/\(name)-\(transport.rawValue)-\(server.kind)-\(server.version.map(String.init).joined(separator: "."))).txt",
                                                    atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - MySQL and MariaDB

@MainActor
@Suite("Query corpus: MySQL and MariaDB", .enabled(if: CorpusEnv.e["SB_MYSQL_VERIFY"] == "1"))
struct MySQLCorpusTests {
    nonisolated static var transports: [CorpusTransport] {
        var t: [CorpusTransport] = [.tcp]
        if CorpusEnv.ssh { t.append(.ssh) }
        if CorpusEnv.e["SB_SOCKET_VERIFY"] == "1", !(CorpusEnv.e["SB_MYSQL_SOCKET"] ?? "").isEmpty { t.append(.socket) }
        return t
    }

    @Test("every kind of statement, the way the Query tab runs it", arguments: transports)
    func corpus(_ transport: CorpusTransport) async throws {
        let port = Int(CorpusEnv.v("SB_MYSQL_PORT", "3309")) ?? 3309
        let run = try await CorpusRun(transport, entry: CorpusEnv.entry(
            transport, engine: "mysql", alias: "my\(transport.rawValue)", host: CorpusEnv.v("SB_MYSQL_HOST", "127.0.0.1"),
            port: port, user: CorpusEnv.v("SB_MYSQL_USER", "root"), password: CorpusEnv.v("SB_MYSQL_PASS", ""),
            database: CorpusEnv.v("SB_MYSQL_WRITE_DB", "sbwrite"), socket: CorpusEnv.v("SB_MYSQL_SOCKET", "")))
        let version = try await run.run("SELECT VERSION()").rows.first?.first ?? ""
        let server = CorpusServer(kind: "MySQL", versionString: version)
        await run.check(Self.cases(database: CorpusEnv.v("SB_MYSQL_WRITE_DB", "sbwrite")), on: server, name: "mysql")
        await run.close()
    }

    static func cases(database db: String) -> [CorpusCase] {
        let cte: (CorpusServer) -> Bool = { $0.atLeast(mariadb: [10, 2], mysql: [8, 0]) }
        let check: (CorpusServer) -> Bool = { $0.atLeast(mariadb: [10, 2, 1], mysql: [8, 0, 16]) }
        let setOps: (CorpusServer) -> Bool = { $0.atLeast(mariadb: [10, 3], mysql: [8, 0, 31]) }
        let json: (CorpusServer) -> Bool = { $0.atLeast(mariadb: [10, 2, 3], mysql: [5, 7]) }
        let users: (CorpusServer) -> Bool = { $0.atLeast(mariadb: [10, 1, 3], mysql: [5, 7]) }
        let explainJSON: (CorpusServer) -> Bool = { $0.atLeast(mariadb: [10, 1], mysql: [5, 6]) }
        return [
            // Setup: every common column type, keys, a foreign key, odd values.
            CorpusCase(sql: "DROP TABLE IF EXISTS {p}items, {p}orders, {p}customers, {p}types, {p}log, `{p}odd name`", expect: .ok),
            CorpusCase(sql: """
                CREATE TABLE {p}customers (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, name VARCHAR(80) NOT NULL,
                  email VARCHAR(120) UNIQUE, city VARCHAR(40) DEFAULT 'Pune', created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                  vip TINYINT(1) NOT NULL DEFAULT 0, KEY {p}idx_city (city)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """, expect: .ok),
            CorpusCase(sql: """
                CREATE TABLE {p}orders (id INT AUTO_INCREMENT PRIMARY KEY, customer_id INT UNSIGNED NOT NULL,
                  total DECIMAL(10,2) NOT NULL, status ENUM('new','paid','shipped') NOT NULL DEFAULT 'new', placed DATE, note TEXT,
                  CONSTRAINT {p}fk_cust FOREIGN KEY (customer_id) REFERENCES {p}customers(id) ON DELETE CASCADE)
                  ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """, expect: .ok),
            CorpusCase(sql: "CREATE TABLE {p}items (order_id INT NOT NULL, sku VARCHAR(20) NOT NULL, qty SMALLINT NOT NULL, price DOUBLE, PRIMARY KEY (order_id, sku))", expect: .ok),
            CorpusCase(sql: """
                CREATE TABLE {p}types (id INT PRIMARY KEY, b BIT(8), tiny TINYINT, small SMALLINT, med MEDIUMINT,
                  big BIGINT UNSIGNED, `dec` DECIMAL(20,6), f FLOAT, d DOUBLE, dt DATETIME, ts TIMESTAMP NULL DEFAULT NULL,
                  dd DATE, tt TIME, yy YEAR, ch CHAR(3), vc VARCHAR(255), tx LONGTEXT, bl BLOB, en ENUM('a','b'),
                  st SET('x','y','z'), js TEXT) DEFAULT CHARSET=utf8mb4
                """, expect: .ok),
            CorpusCase(sql: "CREATE TABLE {p}log (id INT AUTO_INCREMENT PRIMARY KEY, msg VARCHAR(200), at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)", expect: .ok),
            CorpusCase(sql: #"""
                INSERT INTO {p}customers (name, email, city, vip) VALUES ('Ada Lovelace', 'ada@example.com', 'London', 1),
                  ('Alan Turing', 'alan@example.com', 'Wilmslow', 0), ('Grace Hopper', NULL, 'New York', 1),
                  ('Linus "The" Penguin', 'linus@example.com', NULL, 0), ('Zoë Ünïcode 🚀', 'zoe@example.com', 'Zürich', 0)
                """#, expect: .ok),
            CorpusCase(sql: #"""
                INSERT INTO {p}orders (customer_id, total, status, placed, note) VALUES (1, 10.50, 'paid', '2026-01-02', 'first'),
                  (1, 99.99, 'shipped', '2026-02-03', NULL), (2, 0.01, 'new', '2026-03-04', 'it''s quoted'),
                  (3, 12345678.90, 'paid', '2025-12-31', 'back\\slash')
                """#, expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}items VALUES (1,'A-1',2,3.5),(1,'B-2',1,10),(2,'A-1',5,3.5),(4,'C-3',1,0.1)", expect: .ok),
            CorpusCase(sql: #"""
                INSERT INTO {p}types VALUES (1, b'10101010', -128, -32768, -8388608, 18446744073709551615,
                  12345678901234.123456, 1.5, 2.718281828459045, '2026-10-20 22:00:00', NULL, '2026-10-20', '23:59:59', 2026,
                  'abc', 'varchar', REPEAT('x', 70000), 0xDEADBEEF, 'b', 'x,z', '{"a":1}')
                """#, expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}types (id) VALUES (2)", expect: .ok),

            // Plain SELECTs.
            CorpusCase(sql: "SELECT 1", expect: .value("1")),
            CorpusCase(sql: "SELECT 1 + 1 AS two, 'text' AS t, NULL AS n", expect: .value("2")),
            CorpusCase(sql: "SELECT NOW(), CURDATE(), UNIX_TIMESTAMP(), RAND() < 2", expect: .rows(1)),
            CorpusCase(sql: "SELECT DATABASE()", expect: .value(db)),
            CorpusCase(sql: "SELECT DATABASE(), USER(), CURRENT_USER(), CONNECTION_ID(), @@version_comment", expect: .rows(1)),
            CorpusCase(sql: "SELECT * FROM {p}customers", expect: .rows(5)),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE city = 'London'", expect: .value("Ada Lovelace")),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE email IS NULL", expect: .value("Grace Hopper")),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}customers WHERE name LIKE 'A%'", expect: .value("2")),
            CorpusCase(sql: #"SELECT name FROM {p}customers WHERE name LIKE '%"The"%'"#, expect: .value(#"Linus "The" Penguin"#)),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}customers WHERE name REGEXP '^[AG]'", expect: .value("3")),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE id IN (1, 3) ORDER BY id", expect: .rows(2)),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE id BETWEEN 2 AND 4", expect: .rows(3)),
            CorpusCase(sql: "SELECT DISTINCT vip FROM {p}customers", expect: .rows(2)),
            CorpusCase(sql: "SELECT * FROM {p}customers ORDER BY id DESC LIMIT 2", expect: .rows(2)),
            CorpusCase(sql: "SELECT id FROM {p}customers ORDER BY id LIMIT 2 OFFSET 1", expect: .value("2")),
            CorpusCase(sql: "SELECT id FROM {p}customers ORDER BY id LIMIT 3, 2", expect: .value("4")),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE id = 5", expect: .value("Zoë Ünïcode 🚀")),
            CorpusCase(sql: "SELECT CHAR_LENGTH(name) FROM {p}customers WHERE id = 5", expect: .value("13")),
            CorpusCase(sql: "SELECT note FROM {p}orders WHERE id = 3", expect: .value("it's quoted")),
            CorpusCase(sql: "SELECT note FROM {p}orders WHERE id = 4", expect: .value(#"back\slash"#)),
            CorpusCase(sql: "SELECT total FROM {p}orders WHERE id = 4", expect: .value("12345678.90")),
            CorpusCase(sql: "SELECT vip FROM {p}customers WHERE id = 1", expect: .value("true")),

            // Aggregates, grouping, joins, subqueries, set operations.
            CorpusCase(sql: "SELECT COUNT(*), SUM(total), AVG(total), MIN(total), MAX(total) FROM {p}orders", expect: .value("4")),
            CorpusCase(sql: "SELECT SUM(total) FROM {p}orders", expect: .value("12345789.40")),
            CorpusCase(sql: "SELECT city, COUNT(*) AS n FROM {p}customers GROUP BY city ORDER BY city", expect: .rows(5)),
            CorpusCase(sql: "SELECT GROUP_CONCAT(name ORDER BY name SEPARATOR '|') FROM {p}customers WHERE vip = 1", expect: .value("Ada Lovelace|Grace Hopper")),
            CorpusCase(sql: "SELECT vip, COUNT(*) n FROM {p}customers GROUP BY vip HAVING COUNT(*) > 1", expect: .rows(2)),
            CorpusCase(sql: "SELECT c.name, o.total FROM {p}customers c JOIN {p}orders o ON o.customer_id = c.id ORDER BY o.id", expect: .rows(4)),
            CorpusCase(sql: "SELECT c.name, COUNT(o.id) FROM {p}customers c LEFT JOIN {p}orders o ON o.customer_id = c.id GROUP BY c.id, c.name", expect: .rows(5)),
            CorpusCase(sql: "SELECT o.id FROM {p}orders o RIGHT JOIN {p}customers c ON c.id = o.customer_id", expect: .rows(6)),
            CorpusCase(sql: "SELECT a.name, b.name FROM {p}customers a CROSS JOIN {p}customers b WHERE a.id < b.id", expect: .rows(10)),
            CorpusCase(sql: "SELECT i.sku, o.status, c.name FROM {p}items i JOIN {p}orders o ON o.id = i.order_id JOIN {p}customers c ON c.id = o.customer_id", expect: .rows(4)),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE id IN (SELECT customer_id FROM {p}orders WHERE total > 50)", expect: .rows(2)),
            CorpusCase(sql: "SELECT name FROM {p}customers c WHERE EXISTS (SELECT 1 FROM {p}orders o WHERE o.customer_id = c.id)", expect: .rows(3)),
            CorpusCase(sql: "SELECT name FROM {p}customers c WHERE NOT EXISTS (SELECT 1 FROM {p}orders o WHERE o.customer_id = c.id)", expect: .rows(2)),
            CorpusCase(sql: "SELECT (SELECT MAX(total) FROM {p}orders) AS top", expect: .value("12345678.90")),
            CorpusCase(sql: "SELECT t.city, t.n FROM (SELECT city, COUNT(*) n FROM {p}customers GROUP BY city) AS t WHERE t.n >= 1", expect: .rows(5)),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE vip = 1 UNION SELECT name FROM {p}customers WHERE city = 'London'", expect: .rows(2)),
            CorpusCase(sql: "SELECT city FROM {p}customers UNION ALL SELECT city FROM {p}customers", expect: .rows(10)),
            CorpusCase(sql: "SELECT CASE WHEN total > 100 THEN 'big' WHEN total > 10 THEN 'mid' ELSE 'small' END AS size, COUNT(*) FROM {p}orders GROUP BY size", expect: .rows(3)),
            CorpusCase(sql: "SELECT id FROM {p}customers INTERSECT SELECT customer_id FROM {p}orders", expect: .rows(3), when: setOps),
            CorpusCase(sql: "SELECT id FROM {p}customers EXCEPT SELECT customer_id FROM {p}orders", expect: .rows(2), when: setOps),

            // Functions.
            CorpusCase(sql: "SELECT IF(vip, 'yes', 'no'), IFNULL(email, '-'), COALESCE(city, 'unknown'), NULLIF(id, 1) FROM {p}customers", expect: .rows(5)),
            CorpusCase(sql: "SELECT CONCAT(name, ' <', IFNULL(email, ''), '>'), UPPER(name), LOWER(name), LENGTH(name), SUBSTRING(name, 1, 3), REPLACE(name, 'a', 'A'), TRIM('  x  '), REVERSE(name) FROM {p}customers", expect: .rows(5)),
            CorpusCase(sql: "SELECT LPAD(id, 5, '0') FROM {p}customers WHERE id = 3", expect: .value("00003")),
            CorpusCase(sql: "SELECT DATE_FORMAT(placed, '%Y/%m/%d') FROM {p}orders WHERE id = 1", expect: .value("2026/01/02")),
            CorpusCase(sql: "SELECT DATEDIFF('2026-12-31', placed) FROM {p}orders WHERE id = 1", expect: .value("363")),
            CorpusCase(sql: "SELECT DATE_ADD(placed, INTERVAL 1 MONTH) FROM {p}orders WHERE id = 1", expect: .value("2026-02-02")),
            CorpusCase(sql: "SELECT YEAR(placed), DAYNAME(placed), LAST_DAY(placed), STR_TO_DATE('20/10/2026', '%d/%m/%Y') FROM {p}orders", expect: .rows(4)),
            CorpusCase(sql: "SELECT ROUND(2.675, 2), FLOOR(-1.5), MOD(10, 3), POW(2, 10), SQRT(16)", expect: .value("2.68")),
            CorpusCase(sql: "SELECT CAST('42' AS UNSIGNED) + 1", expect: .value("43")),
            CorpusCase(sql: "SELECT CAST(total AS CHAR), CONVERT('7', SIGNED), CAST(placed AS DATETIME) FROM {p}orders", expect: .rows(4)),
            CorpusCase(sql: "SELECT 1/0", expect: .ok),
            CorpusCase(sql: "SELECT SLEEP(0)", expect: .value("0")),

            // Every type back as the server keeps it.
            CorpusCase(sql: "SELECT big FROM {p}types WHERE id = 1", expect: .value("18446744073709551615")),
            CorpusCase(sql: "SELECT `dec` FROM {p}types WHERE id = 1", expect: .value("12345678901234.123456")),
            CorpusCase(sql: "SELECT b + 0 FROM {p}types WHERE id = 1", expect: .value("170")),
            CorpusCase(sql: "SELECT b FROM {p}types WHERE id = 1", expect: .rows(1)),
            CorpusCase(sql: "SELECT tiny, small, med FROM {p}types WHERE id = 1", expect: .value("-128")),
            CorpusCase(sql: "SELECT f, d FROM {p}types WHERE id = 1", expect: .value("1.5")),
            CorpusCase(sql: "SELECT dt FROM {p}types WHERE id = 1", expect: .value("2026-10-20 22:00:00")),
            CorpusCase(sql: "SELECT tt FROM {p}types WHERE id = 1", expect: .value("23:59:59")),
            CorpusCase(sql: "SELECT yy FROM {p}types WHERE id = 1", expect: .value("2026")),
            CorpusCase(sql: "SELECT en, st FROM {p}types WHERE id = 1", expect: .value("b")),
            CorpusCase(sql: "SELECT st FROM {p}types WHERE id = 1", expect: .value("x,z")),
            CorpusCase(sql: "SELECT LENGTH(tx) FROM {p}types WHERE id = 1", expect: .value("70000")),
            CorpusCase(sql: "SELECT tx FROM {p}types WHERE id = 1", expect: .length(70000)),
            CorpusCase(sql: "SELECT HEX(bl) FROM {p}types WHERE id = 1", expect: .value("DEADBEEF")),
            CorpusCase(sql: "SELECT bl FROM {p}types WHERE id = 1", expect: .rows(1)),
            CorpusCase(sql: "SELECT * FROM {p}types ORDER BY id", expect: .rows(2)),
            CorpusCase(sql: "SELECT * FROM {p}types WHERE id = 2", expect: .rows(1)),
            CorpusCase(sql: "SELECT * FROM information_schema.COLUMNS", expect: .atLeast(100)),
            // Values an old server, or one in a lax sql_mode, keeps: zero dates, and a date
            // with a zero month or day. A read DuckDB's MySQL driver can't convert runs on the
            // app's own client, as the server keeps it; a lone zero date reads as NULL there
            // (the driver's way, as JDBC's convertToNull), where the Content tab shows it as kept.
            CorpusCase(sql: """
                SET SESSION sql_mode = ''; DROP TABLE IF EXISTS {p}legacy;
                CREATE TABLE {p}legacy (id INT PRIMARY KEY, d DATE, dt DATETIME, ts TIMESTAMP NULL DEFAULT NULL);
                INSERT INTO {p}legacy VALUES (1, '0000-00-00', '0000-00-00 00:00:00', '0000-00-00 00:00:00'),
                  (2, '2026-00-15', '2026-01-00 10:00:00', NULL), (3, '2026-10-20', '2026-10-20 22:00:00', '2026-10-20 22:00:00')
                """, expect: .ok),
            CorpusCase(sql: "SELECT * FROM {p}legacy ORDER BY id", expect: .rows(3)),
            CorpusCase(sql: "SELECT d FROM {p}legacy ORDER BY id", expect: .value("0000-00-00")),   // with 2026-00-15: the app's own client
            CorpusCase(sql: "SELECT d FROM {p}legacy WHERE id = 1", expect: .value("NULL")),
            CorpusCase(sql: "SELECT dt FROM {p}legacy WHERE id = 1", expect: .value("NULL")),
            CorpusCase(sql: "SELECT ts FROM {p}legacy WHERE id = 1", expect: .value("NULL")),
            CorpusCase(sql: "SELECT d, dt FROM {p}legacy WHERE id = 2", expect: .value("2026-00-15")),
            CorpusCase(sql: "SELECT dt FROM {p}legacy WHERE id = 2", expect: .value("2026-01-00 10:00:00")),
            CorpusCase(sql: "SELECT d FROM {p}legacy WHERE id = 3", expect: .value("2026-10-20")),
            CorpusCase(sql: "DROP TABLE {p}legacy", expect: .ok),

            // Session state the next statement relies on, and transactions.
            // A script's statements share one connection; a lone SET says it lasts its run.
            CorpusCase(sql: "SET @corpus_x := 42", expect: .contains("lasts for the run")),
            CorpusCase(sql: "SET @corpus_x := 42; SELECT @corpus_x", expect: .value("42")),
            CorpusCase(sql: "SET @corpus_d = '2026-01-01'; SELECT COUNT(*) FROM {p}orders WHERE placed > @corpus_d", expect: .value("3")),
            CorpusCase(sql: "CREATE TEMPORARY TABLE {p}tmp (id INT); INSERT INTO {p}tmp VALUES (1), (2); SELECT COUNT(*) FROM {p}tmp", expect: .value("2")),
            CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES ('id'); SELECT LAST_INSERT_ID() > 0", expect: .value("1")),
            CorpusCase(sql: "SELECT SQL_CALC_FOUND_ROWS id FROM {p}customers LIMIT 1; SELECT FOUND_ROWS()", expect: .value("5")),
            CorpusCase(sql: "SELECT COUNT(*) INTO @corpus_n FROM {p}customers; SELECT @corpus_n", expect: .value("5")),
            CorpusCase(sql: "LOCK TABLES {p}log WRITE; INSERT INTO {p}log (msg) VALUES ('locked'); UNLOCK TABLES", expect: .ok),
            CorpusCase(sql: "LOCK TABLES {p}log WRITE", expect: .error("LOCK TABLES")),
            CorpusCase(sql: "DELETE FROM {p}log", expect: .ok),
            CorpusCase(sql: "BEGIN", expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES ('rolled back')", expect: .ok),
            CorpusCase(sql: "ROLLBACK", expect: .ok),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}log WHERE msg = 'rolled back'", expect: .value("0")),
            CorpusCase(sql: "START TRANSACTION; INSERT INTO {p}log (msg) VALUES ('kept'); COMMIT", expect: .ok),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}log WHERE msg = 'kept'", expect: .value("1")),

            // Writes in MySQL's own syntax.
            CorpusCase(sql: "UPDATE {p}customers SET city = 'Cambridge' WHERE name = 'Alan Turing'", expect: .ok),
            CorpusCase(sql: "SELECT city FROM {p}customers WHERE id = 2", expect: .value("Cambridge")),
            CorpusCase(sql: "UPDATE {p}orders o JOIN {p}customers c ON c.id = o.customer_id SET o.note = CONCAT('for ', c.name) WHERE c.vip = 1", expect: .ok),
            CorpusCase(sql: "SELECT note FROM {p}orders WHERE id = 4", expect: .value("for Grace Hopper")),
            CorpusCase(sql: "UPDATE {p}customers SET vip = 1 ORDER BY id DESC LIMIT 1", expect: .ok),
            CorpusCase(sql: "SELECT vip + 0 FROM {p}customers WHERE id = 5", expect: .value("1")),
            CorpusCase(sql: "DELETE FROM {p}items WHERE qty > 4", expect: .ok),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}items", expect: .value("3")),
            CorpusCase(sql: "INSERT INTO {p}items VALUES (1, 'A-1', 9, 3.5) ON DUPLICATE KEY UPDATE qty = qty + VALUES(qty)", expect: .ok),
            CorpusCase(sql: "SELECT qty FROM {p}items WHERE order_id = 1 AND sku = 'A-1'", expect: .value("11")),
            CorpusCase(sql: "INSERT IGNORE INTO {p}items VALUES (1, 'A-1', 1, 1)", expect: .ok),
            CorpusCase(sql: "REPLACE INTO {p}items VALUES (1, 'B-2', 7, 1.25)", expect: .ok),
            CorpusCase(sql: "SELECT qty FROM {p}items WHERE order_id = 1 AND sku = 'B-2'", expect: .value("7")),
            CorpusCase(sql: "INSERT INTO {p}log (msg) SELECT name FROM {p}customers", expect: .ok),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}log", expect: .value("6")),
            CorpusCase(sql: "DELETE l FROM {p}log l WHERE l.msg = 'kept'", expect: .ok),
            CorpusCase(sql: "DELETE i FROM {p}items i JOIN {p}orders o ON o.id = i.order_id WHERE o.status = 'shipped'", expect: .ok),
            CorpusCase(sql: "TRUNCATE TABLE {p}log", expect: .ok),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}log", expect: .value("0")),

            // DDL.
            CorpusCase(sql: "ALTER TABLE {p}customers ADD COLUMN phone VARCHAR(20) NULL AFTER email", expect: .ok),
            CorpusCase(sql: "ALTER TABLE {p}customers MODIFY COLUMN phone VARCHAR(30)", expect: .ok),
            CorpusCase(sql: "ALTER TABLE {p}customers CHANGE phone mobile VARCHAR(30)", expect: .ok),
            CorpusCase(sql: "SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '{p}customers' AND COLUMN_NAME = 'mobile'", expect: .value("varchar(30)")),
            CorpusCase(sql: "ALTER TABLE {p}customers DROP COLUMN mobile", expect: .ok),
            CorpusCase(sql: "ALTER TABLE {p}customers ADD INDEX {p}idx_name (name(10))", expect: .ok),
            CorpusCase(sql: "CREATE INDEX {p}idx_total ON {p}orders (total)", expect: .ok),
            CorpusCase(sql: "DROP INDEX {p}idx_total ON {p}orders", expect: .ok),
            CorpusCase(sql: "ALTER TABLE {p}orders ADD CONSTRAINT {p}chk_total CHECK (total >= 0)", expect: .ok, when: check),
            CorpusCase(sql: "INSERT INTO {p}orders (customer_id, total) VALUES (1, -5)", expect: .error("chk_total"), when: check),
            CorpusCase(sql: "RENAME TABLE {p}log TO {p}log2", expect: .ok),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}log2", expect: .value("0")),
            CorpusCase(sql: "RENAME TABLE {p}log2 TO {p}log", expect: .ok),
            CorpusCase(sql: "CREATE VIEW {p}vip AS SELECT id, name FROM {p}customers WHERE vip = 1", expect: .ok),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}vip", expect: .value("3")),
            CorpusCase(sql: "SHOW CREATE VIEW {p}vip", expect: .rows(1)),
            CorpusCase(sql: "DROP VIEW {p}vip", expect: .ok),
            CorpusCase(sql: "CREATE TABLE {p}copy LIKE {p}customers", expect: .ok),
            CorpusCase(sql: "CREATE TABLE {p}copy2 AS SELECT * FROM {p}customers", expect: .ok),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}copy2", expect: .value("5")),
            CorpusCase(sql: "DROP TABLE {p}copy, {p}copy2", expect: .ok),
            CorpusCase(sql: "CREATE TABLE `{p}odd name` (`select` INT, `my col` VARCHAR(10), `ünï` INT)", expect: .ok),
            CorpusCase(sql: "INSERT INTO `{p}odd name` VALUES (1, 'a b', 2)", expect: .ok),
            CorpusCase(sql: "SELECT `select`, `my col`, `ünï` FROM `{p}odd name`", expect: .value("1")),
            CorpusCase(sql: "DROP TABLE `{p}odd name`", expect: .ok),
            CorpusCase(sql: "ALTER TABLE {p}customers ADD FULLTEXT INDEX {p}ft_name (name)", expect: .ok),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE MATCH(name) AGAINST('+Turing' IN BOOLEAN MODE)", expect: .value("Alan Turing")),
            CorpusCase(sql: "CREATE TABLE {p}geo (id INT PRIMARY KEY, g POINT NOT NULL)", expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}geo VALUES (1, POINT(1, 2))", expect: .ok),
            CorpusCase(sql: "SELECT ST_AsText(g) FROM {p}geo", expect: .value("POINT(1 2)")),
            CorpusCase(sql: "SELECT * FROM {p}geo", expect: .rows(1)),
            CorpusCase(sql: "DROP TABLE {p}geo", expect: .ok),
            CorpusCase(sql: "CREATE EVENT {p}ev ON SCHEDULE EVERY 1 DAY DO DELETE FROM {p}log WHERE 1 = 0", expect: .ok),
            CorpusCase(sql: "SHOW EVENTS LIKE '{p}ev'", expect: .rows(1)),
            CorpusCase(sql: "DROP EVENT {p}ev", expect: .ok),
            // A mysqldump file as it comes: executable comments, a table made before the one
            // it refers to (FOREIGN_KEY_CHECKS=0 lets it), LOCK TABLES around its rows.
            CorpusCase(sql: """
                /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
                /*!40101 SET NAMES utf8mb4 */;
                /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
                DROP TABLE IF EXISTS `{p}dchild`;
                /*!40101 SET @saved_cs_client     = @@character_set_client */;
                CREATE TABLE `{p}dchild` (
                  `id` int(11) NOT NULL,
                  `parent_id` int(11) DEFAULT NULL,
                  PRIMARY KEY (`id`),
                  KEY `{p}dchild_fk` (`parent_id`),
                  CONSTRAINT `{p}dchild_fk` FOREIGN KEY (`parent_id`) REFERENCES `{p}dparent` (`id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
                /*!40101 SET character_set_client = @saved_cs_client */;
                LOCK TABLES `{p}dchild` WRITE;
                /*!40000 ALTER TABLE `{p}dchild` DISABLE KEYS */;
                INSERT INTO `{p}dchild` VALUES (1,1),(2,2);
                /*!40000 ALTER TABLE `{p}dchild` ENABLE KEYS */;
                UNLOCK TABLES;
                DROP TABLE IF EXISTS `{p}dparent`;
                CREATE TABLE `{p}dparent` (
                  `id` int(11) NOT NULL,
                  `name` varchar(40) DEFAULT NULL,
                  PRIMARY KEY (`id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
                LOCK TABLES `{p}dparent` WRITE;
                INSERT INTO `{p}dparent` VALUES (1,'one'),(2,'it\\'s two');
                UNLOCK TABLES;
                /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
                /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
                """, expect: .ok),
            CorpusCase(sql: "SELECT p.name FROM {p}dchild c JOIN {p}dparent p ON p.id = c.parent_id WHERE c.id = 2", expect: .value("it's two")),
            CorpusCase(sql: "DROP TABLE {p}dchild, {p}dparent", expect: .ok),

            // Routines and triggers.
            CorpusCase(sql: "DROP PROCEDURE IF EXISTS {p}proc", expect: .ok),
            CorpusCase(sql: """
                DELIMITER //
                CREATE PROCEDURE {p}proc(IN p_city VARCHAR(40))
                BEGIN
                  SELECT name FROM {p}customers WHERE city = p_city;
                END //
                DELIMITER ;
                """, expect: .ok),
            CorpusCase(sql: "CALL {p}proc('London')", expect: .value("Ada Lovelace")),
            CorpusCase(sql: "SHOW CREATE PROCEDURE {p}proc", expect: .rows(1)),
            CorpusCase(sql: "DROP FUNCTION IF EXISTS {p}fn", expect: .ok),
            CorpusCase(sql: "CREATE FUNCTION {p}fn(x INT) RETURNS INT DETERMINISTIC RETURN x * 2", expect: .ok),
            CorpusCase(sql: "SELECT {p}fn(21)", expect: .value("42")),
            CorpusCase(sql: "CREATE TRIGGER {p}trg BEFORE INSERT ON {p}log FOR EACH ROW SET NEW.msg = UPPER(NEW.msg)", expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES ('hello')", expect: .ok),
            CorpusCase(sql: "SELECT msg FROM {p}log ORDER BY id DESC LIMIT 1", expect: .value("HELLO")),
            CorpusCase(sql: "SHOW TRIGGERS LIKE '{p}%'", expect: .atLeast(1)),
            CorpusCase(sql: "DROP TRIGGER {p}trg", expect: .ok),
            // A body in BEGIN … END without a DELIMITER line, as SHOW CREATE PROCEDURE gives it.
            CorpusCase(sql: "DROP PROCEDURE IF EXISTS {p}proc2", expect: .ok),
            CorpusCase(sql: "CREATE PROCEDURE {p}proc2()\nBEGIN\n  DECLARE n INT DEFAULT 20;\n  SET n = n + 1;\n  SELECT n * 2 AS v;\nEND", expect: .ok),
            CorpusCase(sql: "CALL {p}proc2()", expect: .value("42")),
            CorpusCase(sql: "CREATE TRIGGER {p}trg2 BEFORE INSERT ON {p}log FOR EACH ROW BEGIN IF NEW.msg IS NULL THEN SET NEW.msg = 'none'; END IF; END", expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES (NULL)", expect: .ok),
            CorpusCase(sql: "SELECT msg FROM {p}log ORDER BY id DESC LIMIT 1", expect: .value("none")),
            CorpusCase(sql: "DROP TRIGGER {p}trg2", expect: .ok),
            CorpusCase(sql: "DROP PROCEDURE {p}proc2", expect: .ok),
            // MariaDB's block of its own: its rows come back, and it opens no transaction.
            CorpusCase(sql: "BEGIN NOT ATOMIC DECLARE x INT DEFAULT 41; SELECT x + 1; END", expect: .value("42"),
                       when: { $0.atLeast(mariadb: [10, 1, 1], mysql: nil) }),
            CorpusCase(sql: "SELECT COUNT(*) FROM {p}log", expect: .value("2")),

            // What the server says about itself.
            CorpusCase(sql: "SHOW DATABASES", expect: .atLeast(2)),
            CorpusCase(sql: "SHOW TABLES", expect: .atLeast(5)),
            CorpusCase(sql: "SHOW FULL TABLES", expect: .atLeast(5)),
            CorpusCase(sql: "SHOW TABLE STATUS LIKE '{p}%'", expect: .atLeast(5)),
            CorpusCase(sql: "SHOW COLUMNS FROM {p}customers", expect: .atLeast(6)),
            CorpusCase(sql: "SHOW FULL COLUMNS FROM {p}customers", expect: .atLeast(6)),
            CorpusCase(sql: "SHOW INDEX FROM {p}customers", expect: .atLeast(3)),
            CorpusCase(sql: "SHOW CREATE TABLE {p}orders", expect: .contains("FOREIGN KEY")),
            CorpusCase(sql: "SHOW PROCESSLIST", expect: .atLeast(1)),
            CorpusCase(sql: "SHOW FULL PROCESSLIST", expect: .atLeast(1)),
            CorpusCase(sql: "SHOW VARIABLES LIKE 'version%'", expect: .atLeast(1)),
            CorpusCase(sql: "SHOW GLOBAL STATUS LIKE 'Uptime'", expect: .rows(1)),
            CorpusCase(sql: "SHOW STATUS", expect: .atLeast(10)),
            CorpusCase(sql: "SHOW GRANTS", expect: .atLeast(1)),
            CorpusCase(sql: "SHOW WARNINGS", expect: .ok),
            CorpusCase(sql: "SHOW ERRORS", expect: .ok),
            CorpusCase(sql: "SHOW ENGINES", expect: .atLeast(1)),
            CorpusCase(sql: "SHOW ENGINE INNODB STATUS", expect: .rows(1)),
            CorpusCase(sql: "SHOW CHARACTER SET LIKE 'utf8mb4'", expect: .rows(1)),
            CorpusCase(sql: "SHOW COLLATION LIKE 'utf8mb4_bin'", expect: .rows(1)),
            CorpusCase(sql: "SHOW PLUGINS", expect: .atLeast(1)),
            CorpusCase(sql: "SHOW PRIVILEGES", expect: .atLeast(1)),
            CorpusCase(sql: "SHOW EVENTS", expect: .ok),
            CorpusCase(sql: "SHOW OPEN TABLES", expect: .ok),
            CorpusCase(sql: "SHOW PROCEDURE STATUS WHERE Db = DATABASE()", expect: .atLeast(1)),
            CorpusCase(sql: "SHOW FUNCTION STATUS WHERE Db = DATABASE()", expect: .atLeast(1)),
            CorpusCase(sql: "DESCRIBE {p}customers", expect: .atLeast(6)),
            CorpusCase(sql: "DESC {p}orders", expect: .atLeast(6)),
            CorpusCase(sql: "EXPLAIN SELECT * FROM {p}orders WHERE id = 1", expect: .atLeast(1)),
            CorpusCase(sql: "EXPLAIN {p}orders", expect: .atLeast(6)),
            CorpusCase(sql: "EXPLAIN FORMAT=JSON SELECT * FROM {p}orders", expect: .rows(1), when: explainJSON),
            CorpusCase(sql: "ANALYZE TABLE {p}orders", expect: .ok),
            CorpusCase(sql: "CHECK TABLE {p}orders", expect: .atLeast(1)),
            CorpusCase(sql: "CHECKSUM TABLE {p}orders", expect: .rows(1)),
            CorpusCase(sql: "OPTIMIZE TABLE {p}items", expect: .ok),
            CorpusCase(sql: "REPAIR TABLE {p}items", expect: .ok),
            CorpusCase(sql: "HELP 'SELECT'", expect: .ok),
            CorpusCase(sql: "DO SLEEP(0)", expect: .ok),
            CorpusCase(sql: "SET NAMES utf8mb4", expect: .ok),
            CorpusCase(sql: "FLUSH TABLES", expect: .ok),
            CorpusCase(sql: "CREATE USER IF NOT EXISTS '{p}user'@'%' IDENTIFIED BY 'Pw-12345'", expect: .ok, when: users),
            CorpusCase(sql: "GRANT SELECT ON \(db).* TO '{p}user'@'%'", expect: .ok, when: users),
            CorpusCase(sql: "SHOW GRANTS FOR '{p}user'@'%'", expect: .atLeast(1), when: users),
            CorpusCase(sql: "REVOKE SELECT ON \(db).* FROM '{p}user'@'%'", expect: .ok, when: users),
            CorpusCase(sql: "DROP USER '{p}user'@'%'", expect: .ok, when: users),

            // CTEs, window functions, JSON.
            CorpusCase(sql: "WITH t AS (SELECT customer_id, SUM(total) s FROM {p}orders GROUP BY customer_id) SELECT c.name, t.s FROM t JOIN {p}customers c ON c.id = t.customer_id ORDER BY t.s DESC", expect: .rows(3), when: cte),
            CorpusCase(sql: "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100) SELECT COUNT(*) FROM n", expect: .value("100"), when: cte),
            CorpusCase(sql: "SELECT name, total, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY total DESC) rn, SUM(total) OVER (PARTITION BY customer_id) s, LAG(total) OVER (ORDER BY o.id) prev FROM {p}orders o JOIN {p}customers c ON c.id = o.customer_id", expect: .rows(4), when: cte),
            CorpusCase(sql: "SELECT JSON_EXTRACT(js, '$.a') FROM {p}types WHERE id = 1", expect: .value("1"), when: json),
            CorpusCase(sql: "SELECT JSON_OBJECT('id', id, 'name', name) FROM {p}customers LIMIT 1", expect: .rows(1), when: json),

            // Comments and scripts, split as the Query tab splits them.
            CorpusCase(sql: "-- a comment\nSELECT 1", expect: .value("1")),
            CorpusCase(sql: "# a comment\nSELECT 2", expect: .value("2")),
            CorpusCase(sql: "/* a comment */ SELECT 3", expect: .value("3")),
            CorpusCase(sql: "SELECT 4 -- trailing", expect: .value("4")),
            CorpusCase(sql: "SELECT /*+ MAX_EXECUTION_TIME(5000) */ COUNT(*) FROM {p}customers", expect: .value("5")),
            CorpusCase(sql: "SELECT /*!32302 DISTINCT */ vip FROM {p}customers", expect: .rows(2)),
            CorpusCase(sql: "SELECT 1; SELECT 2;", expect: .value("2")),

            // Errors said plainly.
            CorpusCase(sql: "SELEC 1", expect: .error("syntax")),
            CorpusCase(sql: "SELECT * FROM {p}nope", expect: .error("{p}nope")),
            CorpusCase(sql: "INSERT INTO {p}customers (id, name) VALUES (1, 'dup')", expect: .error("Duplicate")),
            CorpusCase(sql: "INSERT INTO {p}orders (customer_id, total) VALUES (999, 1)", expect: .error("foreign key")),
            CorpusCase(sql: "KILL QUERY 987654321", expect: .error("thread")),

            // Cleanup.
            CorpusCase(sql: "DROP PROCEDURE IF EXISTS {p}proc", expect: .ok),
            CorpusCase(sql: "DROP FUNCTION IF EXISTS {p}fn", expect: .ok),
            CorpusCase(sql: "DROP TABLE IF EXISTS {p}items, {p}orders, {p}customers, {p}types, {p}log, {p}tmp", expect: .ok),
        ]
    }
}
