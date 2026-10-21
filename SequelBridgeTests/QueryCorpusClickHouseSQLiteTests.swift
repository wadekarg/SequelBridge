//
//  QueryCorpusClickHouseSQLiteTests.swift
//  SequelBridgeTests
//
//  The query corpus (QueryCorpusTests.swift) on ClickHouse (its types, ARRAY JOIN,
//  LIMIT BY, FINAL, mutations, materialized views, system tables, its own FORMAT and
//  SETTINGS clauses), over TCP and the SSH tunnel; and on a SQLite file (its own
//  functions, PRAGMA, INSERT OR REPLACE, upserts, RETURNING, triggers, WITHOUT ROWID,
//  rowid numbering).
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Query corpus: ClickHouse", .enabled(if: CorpusEnv.e["SB_CH_VERIFY"] == "1"))
struct ClickHouseCorpusTests {
    nonisolated static var transports: [CorpusTransport] { CorpusEnv.ssh ? [.tcp, .ssh] : [.tcp] }

    @Test("every kind of statement, the way the Query tab runs it", arguments: transports)
    func corpus(_ transport: CorpusTransport) async throws {
        let run = try await CorpusRun(transport, entry: CorpusEnv.entry(
            transport, engine: "clickhouse", alias: "ch\(transport.rawValue)", host: CorpusEnv.v("SB_CH_HOST", "127.0.0.1"),
            port: Int(CorpusEnv.v("SB_CH_PORT", "8123")) ?? 8123, user: CorpusEnv.v("SB_CH_USER", "sbuser"),
            password: CorpusEnv.v("SB_CH_PASS", ""), database: "default"))
        let version = try await run.run("SELECT version()").rows.first?.first ?? ""
        await run.check(Self.cases, on: CorpusServer(kind: "ClickHouse", versionString: version), name: "clickhouse")
        await run.close()
    }

    static let cases: [CorpusCase] = [
        CorpusCase(sql: "DROP TABLE IF EXISTS {p}events", expect: .ok),
        CorpusCase(sql: "DROP TABLE IF EXISTS {p}latest", expect: .ok),
        CorpusCase(sql: "DROP TABLE IF EXISTS {p}mem", expect: .ok),
        CorpusCase(sql: "DROP TABLE IF EXISTS {p}mem2", expect: .ok),
        CorpusCase(sql: "DROP VIEW IF EXISTS {p}v", expect: .ok),
        CorpusCase(sql: "DROP VIEW IF EXISTS {p}mv", expect: .ok),
        CorpusCase(sql: """
            CREATE TABLE {p}events (id UInt64, ts DateTime, ts64 DateTime64(3), user String, kind LowCardinality(String),
              amount Decimal(18,4), tags Array(String), attrs Map(String, String), maybe Nullable(Int32), ip IPv4, u UUID,
              e Enum8('a' = 1, 'b' = 2), t Tuple(Int32, String)) ENGINE = MergeTree ORDER BY id
            """, expect: .ok),
        CorpusCase(sql: """
            INSERT INTO {p}events VALUES
              (1, '2026-10-20 10:00:00', '2026-10-20 10:00:00.123', 'ada', 'click', 10.5, ['a','b'], {'k':'v'}, NULL,
               '10.0.0.1', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'a', (1, 'x')),
              (2, '2026-10-21 11:00:00', '2026-10-21 11:00:00.456', 'grace', 'view', 2.25, [], {}, 7,
               '10.0.0.2', '00000000-0000-0000-0000-000000000000', 'b', (2, 'y'))
            """, expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}events (id, ts, user, kind, amount) SELECT number + 100, now(), 'bulk', 'view', number FROM numbers(1000)", expect: .ok),

        CorpusCase(sql: "SELECT 1", expect: .value("1")),
        CorpusCase(sql: "SELECT version()", expect: .rows(1)),
        CorpusCase(sql: "SELECT now(), today(), toStartOfMonth(today())", expect: .rows(1)),
        CorpusCase(sql: "SELECT count() FROM {p}events", expect: .value("1002")),
        CorpusCase(sql: "SELECT * FROM {p}events WHERE id = 1", expect: .rows(1)),
        CorpusCase(sql: "SELECT * FROM {p}events ORDER BY id LIMIT 5", expect: .rows(5)),
        CorpusCase(sql: "SELECT user FROM {p}events WHERE id = 2", expect: .value("grace")),
        CorpusCase(sql: "SELECT uniq(user), uniqExact(user), quantile(0.5)(amount), groupArray(id) FROM {p}events WHERE id < 10", expect: .rows(1)),
        CorpusCase(sql: "SELECT arrayJoin(tags) FROM {p}events WHERE id = 1", expect: .rows(2)),
        CorpusCase(sql: "SELECT id, tag FROM {p}events ARRAY JOIN tags AS tag WHERE id = 1", expect: .rows(2)),
        CorpusCase(sql: "SELECT has(tags, 'a'), attrs['k'], tupleElement(t, 2), toTypeName(amount) FROM {p}events WHERE id = 1", expect: .value("1")),
        CorpusCase(sql: "SELECT if(amount > 5, 'big', 'small'), multiIf(id = 1, 'one', id = 2, 'two', 'many') FROM {p}events WHERE id < 3", expect: .rows(2)),
        CorpusCase(sql: "SELECT kind, count() FROM {p}events GROUP BY kind WITH TOTALS", expect: .atLeast(2)),
        CorpusCase(sql: "SELECT user, id FROM {p}events ORDER BY id LIMIT 1 BY user", expect: .rows(3)),
        CorpusCase(sql: "SELECT count() FROM {p}events SETTINGS max_threads = 1", expect: .value("1002")),
        CorpusCase(sql: "SELECT * FROM {p}events WHERE id = 1 FORMAT JSON", expect: .ok),
        CorpusCase(sql: "WITH 2 AS x SELECT x * 3", expect: .value("6")),
        CorpusCase(sql: "SELECT id, sum(amount) OVER (ORDER BY id) FROM {p}events WHERE id < 3", expect: .rows(2)),
        CorpusCase(sql: "SELECT * FROM numbers(10)", expect: .rows(10)),
        CorpusCase(sql: "SELECT toDate('2026-10-20') + INTERVAL 1 DAY", expect: .value("2026-10-21")),
        CorpusCase(sql: "SELECT 'quote''s'", expect: .value("quote's")),
        CorpusCase(sql: "SELECT NULL", expect: .rows(1)),
        CorpusCase(sql: "SELECT CAST(NULL AS Nullable(Int32))", expect: .rows(1)),
        CorpusCase(sql: "SELECT 18446744073709551615", expect: .value("18446744073709551615")),
        CorpusCase(sql: "SELECT toInt128('170141183460469231731687303715884105727')", expect: .value("170141183460469231731687303715884105727")),
        CorpusCase(sql: "SELECT nan, inf, -inf", expect: .rows(1)),
        CorpusCase(sql: "SELECT toDateTime('2026-10-20 10:00:00', 'Asia/Kolkata')", expect: .rows(1)),
        CorpusCase(sql: "SELECT ts64 FROM {p}events WHERE id = 1", expect: .contains("10:00:00.123")),
        CorpusCase(sql: "SELECT amount FROM {p}events WHERE id = 1", expect: .contains("10.5")),
        CorpusCase(sql: "SELECT ip, u, e, t, maybe, tags, attrs FROM {p}events WHERE id = 1", expect: .value("10.0.0.1")),
        CorpusCase(sql: "SELECT * FROM system.tables WHERE database = currentDatabase()", expect: .atLeast(1)),
        CorpusCase(sql: "SELECT * FROM system.columns WHERE table = '{p}events'", expect: .atLeast(13)),
        CorpusCase(sql: "SELECT * FROM system.parts WHERE table = '{p}events'", expect: .atLeast(1)),
        CorpusCase(sql: "SELECT * FROM system.processes", expect: .atLeast(1)),
        CorpusCase(sql: "SELECT name, value FROM system.settings WHERE name = 'max_threads'", expect: .rows(1)),
        CorpusCase(sql: "SHOW TABLES", expect: .atLeast(1)),
        CorpusCase(sql: "SHOW DATABASES", expect: .atLeast(1)),
        CorpusCase(sql: "SHOW CREATE TABLE {p}events", expect: .contains("MergeTree")),
        CorpusCase(sql: "DESCRIBE TABLE {p}events", expect: .atLeast(13)),
        CorpusCase(sql: "DESC {p}events", expect: .atLeast(13)),
        CorpusCase(sql: "EXISTS TABLE {p}events", expect: .value("1")),
        CorpusCase(sql: "EXPLAIN SELECT count() FROM {p}events", expect: .atLeast(1)),
        CorpusCase(sql: "EXPLAIN SYNTAX SELECT 1", expect: .atLeast(1)),
        CorpusCase(sql: "SHOW PROCESSLIST", expect: .atLeast(1)),

        // Changes: mutations, lightweight delete, engines, views.
        CorpusCase(sql: "ALTER TABLE {p}events UPDATE amount = 0 WHERE id = 1 SETTINGS mutations_sync = 1", expect: .ok),
        CorpusCase(sql: "SELECT toString(amount) FROM {p}events WHERE id = 1", expect: .value("0")),
        CorpusCase(sql: "ALTER TABLE {p}events DELETE WHERE id = 2 SETTINGS mutations_sync = 1", expect: .ok),
        CorpusCase(sql: "SELECT count() FROM {p}events", expect: .value("1001")),
        CorpusCase(sql: "DELETE FROM {p}events WHERE id = 100", expect: .ok),
        CorpusCase(sql: "SELECT count() FROM {p}events", expect: .value("1000")),
        CorpusCase(sql: "OPTIMIZE TABLE {p}events FINAL", expect: .ok),
        CorpusCase(sql: "CREATE TABLE {p}latest (id UInt64, v String, ver UInt32) ENGINE = ReplacingMergeTree(ver) ORDER BY id", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}latest VALUES (1, 'old', 1)", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}latest VALUES (1, 'new', 2)", expect: .ok),
        CorpusCase(sql: "SELECT v FROM {p}latest FINAL WHERE id = 1", expect: .value("new")),
        CorpusCase(sql: "CREATE TABLE {p}mem (x Int32) ENGINE = Memory", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}mem VALUES (1), (2), (3)", expect: .ok),
        CorpusCase(sql: "SELECT sum(x) FROM {p}mem", expect: .value("6")),
        CorpusCase(sql: "CREATE VIEW {p}v AS SELECT id FROM {p}events WHERE id < 10", expect: .ok),
        CorpusCase(sql: "SELECT count() FROM {p}v", expect: .value("1")),
        CorpusCase(sql: "CREATE MATERIALIZED VIEW {p}mv ENGINE = SummingMergeTree ORDER BY kind AS SELECT kind, count() AS n FROM {p}events GROUP BY kind", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}events (id, ts, user, kind, amount) VALUES (5000, now(), 'x', 'mv', 1)", expect: .ok),
        CorpusCase(sql: "SELECT sum(n) FROM {p}mv WHERE kind = 'mv'", expect: .value("1")),
        CorpusCase(sql: "RENAME TABLE {p}mem TO {p}mem2", expect: .ok),
        CorpusCase(sql: "TRUNCATE TABLE {p}mem2", expect: .ok),
        CorpusCase(sql: "CREATE DATABASE IF NOT EXISTS {p}db", expect: .ok),
        CorpusCase(sql: "DROP DATABASE {p}db", expect: .ok),
        CorpusCase(sql: "KILL QUERY WHERE query_id = 'sb-corpus-nothing'", expect: .ok),
        CorpusCase(sql: "SET max_threads = 2", expect: .ok),

        // Comments, scripts and errors.
        CorpusCase(sql: "-- a comment\nSELECT 1", expect: .value("1")),
        CorpusCase(sql: "/* a comment */ SELECT 3", expect: .value("3")),
        CorpusCase(sql: "SELECT 1; SELECT 2;", expect: .value("2")),
        CorpusCase(sql: "SELEC 1", expect: .error("syntax")),
        CorpusCase(sql: "SELECT * FROM {p}nope", expect: .error("{p}nope")),
        CorpusCase(sql: "SELECT toInt32('abc')", expect: .error("parse")),

        CorpusCase(sql: "DROP VIEW IF EXISTS {p}mv", expect: .ok),
        CorpusCase(sql: "DROP VIEW IF EXISTS {p}v", expect: .ok),
        CorpusCase(sql: "DROP TABLE IF EXISTS {p}events", expect: .ok),
        CorpusCase(sql: "DROP TABLE IF EXISTS {p}latest", expect: .ok),
        CorpusCase(sql: "DROP TABLE IF EXISTS {p}mem2", expect: .ok),
    ]
}

@MainActor
@Suite("Query corpus: SQLite")
struct SQLiteCorpusTests {
    @Test("every kind of statement, the way the Query tab runs it")
    func corpus() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-corpus-lite-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("corpus.sqlite").path
        try await SQLiteTool.run("CREATE TABLE seed (id INTEGER PRIMARY KEY)", file: file, busyTimeout: 5)
        let run = try await CorpusRun(.tcp, entry: [
            "id": UUID().uuidString, "name": "Corpus lite", "alias": "lite", "color": "#3A9AA8", "host": "", "port": 0,
            "username": "", "password": "", "database": file, "engine": "sqlite", "folder": "", "readOnly": false,
            "connectionType": "TCP/IP",
        ])
        let version = (try? await run.run("SELECT sqlite_version()"))?.rows.first?.first ?? "3"
        await run.check(Self.cases, on: CorpusServer(kind: "SQLite", versionString: version), name: "sqlite")
        await run.close()
    }

    static let cases: [CorpusCase] = [
        CorpusCase(sql: "CREATE TABLE {p}customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, city TEXT DEFAULT 'Pune', vip INTEGER NOT NULL DEFAULT 0, created TEXT DEFAULT CURRENT_TIMESTAMP)", expect: .ok),
        CorpusCase(sql: "CREATE TABLE {p}orders (id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER NOT NULL REFERENCES {p}customers(id), total REAL NOT NULL, placed DATE, note TEXT)", expect: .ok),
        CorpusCase(sql: "CREATE TABLE {p}log (id INTEGER PRIMARY KEY, msg TEXT)", expect: .ok),
        CorpusCase(sql: #"""
            INSERT INTO {p}customers (name, email, city, vip) VALUES ('Ada Lovelace', 'ada@example.com', 'London', 1),
              ('Alan Turing', 'alan@example.com', 'Wilmslow', 0), ('Grace Hopper', NULL, 'New York', 1),
              ('Linus "The" Penguin', 'linus@example.com', NULL, 0), ('Zoë Ünïcode 🚀', 'zoe@example.com', 'Zürich', 0)
            """#, expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}orders (customer_id, total, placed, note) VALUES (1, 10.5, '2026-01-02', 'first'), (1, 99.99, '2026-02-03', NULL), (2, 0.01, '2026-03-04', 'it''s quoted'), (3, 12345678.9, '2025-12-31', 'x')", expect: .ok),

        // rowid numbering and the column types the table was made with.
        CorpusCase(sql: "SELECT id FROM {p}customers WHERE name = 'Ada Lovelace'", expect: .value("1")),
        CorpusCase(sql: "SELECT max(id) FROM {p}orders", expect: .value("4")),
        CorpusCase(sql: "SELECT type FROM pragma_table_info('{p}customers') WHERE name = 'id'", expect: .value("INTEGER")),
        CorpusCase(sql: "SELECT sql FROM sqlite_master WHERE name = '{p}orders'", expect: .contains("AUTOINCREMENT")),

        CorpusCase(sql: "SELECT 1", expect: .value("1")),
        CorpusCase(sql: "SELECT * FROM {p}customers", expect: .rows(5)),
        CorpusCase(sql: "SELECT name FROM {p}customers WHERE id = 5", expect: .value("Zoë Ünïcode 🚀")),
        CorpusCase(sql: "SELECT note FROM {p}orders WHERE id = 3", expect: .value("it's quoted")),
        CorpusCase(sql: "SELECT c.name, o.total FROM {p}customers c JOIN {p}orders o ON o.customer_id = c.id", expect: .rows(4)),
        CorpusCase(sql: "SELECT city, count(*) FROM {p}customers GROUP BY city", expect: .rows(5)),
        CorpusCase(sql: "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100) SELECT count(*) FROM n", expect: .value("100")),
        CorpusCase(sql: "SELECT id, row_number() OVER (ORDER BY total DESC) FROM {p}orders", expect: .rows(4)),
        CorpusCase(sql: "SELECT name FROM {p}customers WHERE name GLOB 'A*'", expect: .rows(2)),
        CorpusCase(sql: "SELECT 9223372036854775807", expect: .value("9223372036854775807")),

        // SQLite's own functions.
        CorpusCase(sql: "SELECT datetime('now')", expect: .rows(1)),
        CorpusCase(sql: "SELECT date('2026-10-20', '+1 day')", expect: .value("2026-10-21")),
        CorpusCase(sql: "SELECT strftime('%Y', '2026-10-20')", expect: .value("2026")),
        CorpusCase(sql: "SELECT julianday('2026-10-20') > 0", expect: .value("1")),
        CorpusCase(sql: "SELECT printf('%05d', 42)", expect: .value("00042")),
        CorpusCase(sql: "SELECT instr('abc', 'b'), substr('abc', 2), ifnull(NULL, 1)", expect: .value("2")),
        CorpusCase(sql: "SELECT group_concat(name, '|') FROM (SELECT name FROM {p}customers WHERE vip = 1 ORDER BY name)", expect: .value("Ada Lovelace|Grace Hopper")),
        CorpusCase(sql: "SELECT typeof(1.5), typeof('x'), typeof(NULL)", expect: .value("real")),
        CorpusCase(sql: "SELECT json_extract('{\"a\":1}', '$.a')", expect: .value("1")),
        CorpusCase(sql: "SELECT iif(1, 'a', 'b')", expect: .value("a")),
        CorpusCase(sql: "SELECT hex(randomblob(4)) IS NOT NULL", expect: .value("1")),
        CorpusCase(sql: "SELECT x'DEADBEEF'", expect: .rows(1)),
        CorpusCase(sql: "SELECT sqlite_version()", expect: .rows(1)),
        CorpusCase(sql: "PRAGMA table_info({p}customers)", expect: .atLeast(6)),
        CorpusCase(sql: "PRAGMA foreign_keys", expect: .rows(1)),
        CorpusCase(sql: "PRAGMA integrity_check", expect: .value("ok")),
        CorpusCase(sql: "PRAGMA user_version", expect: .rows(1)),
        CorpusCase(sql: "EXPLAIN QUERY PLAN SELECT * FROM {p}customers WHERE id = 1", expect: .atLeast(1)),

        // Writes in SQLite's own syntax.
        CorpusCase(sql: "INSERT OR REPLACE INTO {p}customers (id, name) VALUES (2, 'Alan M. Turing')", expect: .ok),
        CorpusCase(sql: "SELECT name FROM {p}customers WHERE id = 2", expect: .value("Alan M. Turing")),
        CorpusCase(sql: "INSERT OR IGNORE INTO {p}customers (id, name) VALUES (1, 'ignored')", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}customers (name, email, city) VALUES ('Ada Again', 'ada@example.com', 'Paris') ON CONFLICT(email) DO UPDATE SET city = excluded.city", expect: .ok),
        CorpusCase(sql: "SELECT city FROM {p}customers WHERE email = 'ada@example.com'", expect: .value("Paris")),
        CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES ('returning') RETURNING id, msg", expect: .contains("returning")),
        CorpusCase(sql: "UPDATE {p}orders SET note = c.name FROM {p}customers c WHERE c.id = {p}orders.customer_id AND c.vip = 1", expect: .ok),
        CorpusCase(sql: "DELETE FROM {p}log WHERE msg = 'returning'", expect: .ok),
        CorpusCase(sql: "BEGIN; INSERT INTO {p}log (msg) VALUES ('kept'); COMMIT", expect: .ok),
        CorpusCase(sql: "SELECT count(*) FROM {p}log WHERE msg = 'kept'", expect: .value("1")),

        // DDL in SQLite's own syntax.
        CorpusCase(sql: "ALTER TABLE {p}customers ADD COLUMN phone TEXT", expect: .ok),
        CorpusCase(sql: "ALTER TABLE {p}customers RENAME COLUMN phone TO mobile", expect: .ok),
        CorpusCase(sql: "ALTER TABLE {p}customers DROP COLUMN mobile", expect: .ok),
        CorpusCase(sql: "CREATE INDEX {p}idx_city ON {p}customers (city) WHERE vip = 1", expect: .ok),
        CorpusCase(sql: "CREATE VIEW {p}vip AS SELECT id, name FROM {p}customers WHERE vip = 1", expect: .ok),
        CorpusCase(sql: "SELECT count(*) FROM {p}vip", expect: .value("2")),
        CorpusCase(sql: "CREATE TABLE {p}kv (k TEXT PRIMARY KEY, v) WITHOUT ROWID", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}kv VALUES ('a', 1)", expect: .ok),
        CorpusCase(sql: "CREATE TRIGGER {p}trg AFTER INSERT ON {p}customers BEGIN INSERT INTO {p}log (msg) VALUES (NEW.name); END", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}customers (name) VALUES ('Triggered')", expect: .ok),
        CorpusCase(sql: "SELECT count(*) FROM {p}log WHERE msg = 'Triggered'", expect: .value("1")),
        CorpusCase(sql: "DROP TRIGGER {p}trg", expect: .ok),
        CorpusCase(sql: "ANALYZE", expect: .ok),
        CorpusCase(sql: "VACUUM", expect: .ok),

        // What macOS's SQLite has: a full-text table read back, a generated column, a STRICT
        // table, and syntax newer than the SQLite reads stream through (3.38): RIGHT JOIN
        // (3.39), concat and string_agg (3.44).
        CorpusCase(sql: "CREATE VIRTUAL TABLE {p}docs USING fts5(title, body)", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}docs VALUES ('Engines', 'the quick brown fox'), ('Other', 'lazy dogs')", expect: .ok),
        CorpusCase(sql: "SELECT title FROM {p}docs WHERE {p}docs MATCH 'quick'", expect: .value("Engines")),
        CorpusCase(sql: "SELECT count(*) FROM {p}docs", expect: .value("2")),
        CorpusCase(sql: "DROP TABLE {p}docs", expect: .ok),
        CorpusCase(sql: "CREATE TABLE {p}gen (a INTEGER, b INTEGER GENERATED ALWAYS AS (a * 2) STORED)", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}gen (a) VALUES (21)", expect: .ok),
        CorpusCase(sql: "SELECT b FROM {p}gen", expect: .value("42")),
        CorpusCase(sql: "CREATE TABLE {p}strict (id INTEGER PRIMARY KEY, n INTEGER) STRICT", expect: .ok),
        CorpusCase(sql: "INSERT INTO {p}strict VALUES (1, 'x')", expect: .error("cannot store TEXT")),
        CorpusCase(sql: "SELECT '{\"a\":{\"b\":2}}' ->> '$.a.b'", expect: .value("2")),
        CorpusCase(sql: "SELECT c.name FROM {p}orders o RIGHT JOIN {p}customers c ON c.id = o.customer_id WHERE o.id IS NULL", expect: .atLeast(1)),
        CorpusCase(sql: "SELECT concat('a', 'b', 1)", expect: .value("ab1")),
        CorpusCase(sql: "SELECT string_agg(name, '|') FROM (SELECT name FROM {p}customers WHERE vip = 1 ORDER BY name)", expect: .value("Ada Lovelace|Grace Hopper")),

        // A statement that starts with a comment; a script's last statement, rows or not; reals.
        CorpusCase(sql: "-- a note first\nINSERT INTO {p}log (msg) VALUES ('commented')", expect: .ok),
        CorpusCase(sql: "SELECT count(*) FROM {p}log WHERE msg = 'commented'", expect: .value("1")),
        CorpusCase(sql: "SELECT count(*) FROM {p}log; DELETE FROM {p}log WHERE msg = 'commented'", expect: .value("Done")),
        CorpusCase(sql: "SELECT count(*) FROM {p}log WHERE msg = 'commented'", expect: .value("0")),
        CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES ('real') RETURNING 0.1 AS r", expect: .value("0.1")),
        CorpusCase(sql: "SELECT 1; SELEC 2", expect: .error("Statement 2 of 2")),

        // Errors.
        CorpusCase(sql: "SELEC 1", expect: .error("syntax")),
        CorpusCase(sql: "SELECT * FROM {p}nope", expect: .error("{p}nope")),
        CorpusCase(sql: "INSERT INTO {p}customers (id, name) VALUES (1, 'dup')", expect: .error("UNIQUE")),

        CorpusCase(sql: "DROP VIEW {p}vip", expect: .ok),
        CorpusCase(sql: "DROP TABLE {p}kv", expect: .ok),
    ]
}
