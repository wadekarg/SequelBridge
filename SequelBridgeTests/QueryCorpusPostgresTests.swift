//
//  QueryCorpusPostgresTests.swift
//  SequelBridgeTests
//
//  The query corpus (QueryCorpusTests.swift) on PostgreSQL: its own syntax and types
//  (arrays, jsonb and its # operators, enums, domains, ranges, money, xml), RETURNING,
//  ON CONFLICT, UPDATE … FROM, data-modifying WITH, $$-quoted function bodies, DO,
//  sequences, materialized views, statements that can't run inside a transaction
//  (VACUUM, CREATE INDEX CONCURRENTLY, CREATE DATABASE), SHOW/EXPLAIN, and its errors.
//  Over TCP, the SSH tunnel and the Unix socket.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Query corpus: PostgreSQL", .enabled(if: CorpusEnv.e["SB_PG_VERIFY"] == "1"))
struct PostgresCorpusTests {
    nonisolated static var transports: [CorpusTransport] {
        var t: [CorpusTransport] = [.tcp]
        if CorpusEnv.ssh { t.append(.ssh) }
        if CorpusEnv.e["SB_SOCKET_VERIFY"] == "1", !(CorpusEnv.e["SB_PG_SOCKET_DIR"] ?? "").isEmpty { t.append(.socket) }
        return t
    }

    @Test("every kind of statement, the way the Query tab runs it", arguments: transports)
    func corpus(_ transport: CorpusTransport) async throws {
        let db = CorpusEnv.v("SB_PG_DB", "sbtest")
        let run = try await CorpusRun(transport, entry: CorpusEnv.entry(
            transport, engine: "postgres", alias: "pg\(transport.rawValue)", host: CorpusEnv.v("SB_PG_HOST", "127.0.0.1"),
            port: Int(CorpusEnv.v("SB_PG_PORT", "5433")) ?? 5433, user: CorpusEnv.v("SB_PG_USER", "sbuser"),
            password: CorpusEnv.v("SB_PG_PASS", ""), database: db, socket: CorpusEnv.v("SB_PG_SOCKET_DIR", "")))
        let version = try await run.run("SHOW server_version").rows.first?.first ?? ""
        await run.check(Self.cases(database: db), on: CorpusServer(kind: "PostgreSQL", versionString: version), name: "postgres")
        await run.close()
    }

    static func cases(database db: String) -> [CorpusCase] {
        [
            // Setup.
            CorpusCase(sql: "DROP TABLE IF EXISTS {p}items, {p}orders, {p}customers, {p}types, {p}log CASCADE", expect: .ok),
            CorpusCase(sql: "DROP TYPE IF EXISTS {p}mood", expect: .ok),
            CorpusCase(sql: "CREATE TYPE {p}mood AS ENUM ('sad', 'ok', 'happy')", expect: .ok),
            CorpusCase(sql: """
                CREATE TABLE {p}customers (id serial PRIMARY KEY, name varchar(80) NOT NULL, email text UNIQUE,
                  city text DEFAULT 'Pune', created_at timestamptz DEFAULT now(), vip boolean NOT NULL DEFAULT false,
                  tags text[], meta jsonb, mood {p}mood)
                """, expect: .ok),
            CorpusCase(sql: """
                CREATE TABLE {p}orders (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                  customer_id int NOT NULL REFERENCES {p}customers(id) ON DELETE CASCADE,
                  total numeric(12,2) NOT NULL CHECK (total >= 0), status text NOT NULL DEFAULT 'new', placed date, note text)
                """, expect: .ok),
            CorpusCase(sql: "CREATE TABLE {p}items (order_id bigint NOT NULL, sku text NOT NULL, qty smallint NOT NULL, price double precision, PRIMARY KEY (order_id, sku))", expect: .ok),
            CorpusCase(sql: """
                CREATE TABLE {p}types (id int PRIMARY KEY, b bytea, i2 smallint, i8 bigint, n numeric(30,10), r real,
                  dp double precision, ts timestamp, tz timestamptz, d date, t time, iv interval, u uuid, ip inet, mac macaddr,
                  j json, jb jsonb, arr int[], bits bit(8), m money, x xml, pt point, rng int4range, ch char(3))
                """, expect: .ok),
            CorpusCase(sql: "CREATE TABLE {p}log (id serial PRIMARY KEY, msg text, at timestamptz DEFAULT now())", expect: .ok),
            CorpusCase(sql: #"""
                INSERT INTO {p}customers (name, email, city, vip, tags, meta, mood) VALUES
                  ('Ada Lovelace', 'ada@example.com', 'London', true, '{math,engines}', '{"lang":"en","n":1}', 'happy'),
                  ('Alan Turing', 'alan@example.com', 'Wilmslow', false, '{math}', '{"lang":"en","n":2}', 'ok'),
                  ('Grace Hopper', NULL, 'New York', true, '{}', '{"lang":"en"}', 'happy'),
                  ('Linus "The" Penguin', 'linus@example.com', NULL, false, NULL, NULL, NULL),
                  ('Zoë Ünïcode 🚀', 'zoe@example.com', 'Zürich', false, '{x}', '{"lang":"de"}', 'sad')
                """#, expect: .ok),
            CorpusCase(sql: #"""
                INSERT INTO {p}orders (customer_id, total, status, placed, note) VALUES (1, 10.50, 'paid', '2026-01-02', 'first'),
                  (1, 99.99, 'shipped', '2026-02-03', NULL), (2, 0.01, 'new', '2026-03-04', 'it''s quoted'),
                  (3, 12345678.90, 'paid', '2025-12-31', 'back\slash')
                """#, expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}items VALUES (1,'A-1',2,3.5),(1,'B-2',1,10),(2,'A-1',5,3.5),(4,'C-3',1,0.1)", expect: .ok),
            CorpusCase(sql: #"""
                INSERT INTO {p}types VALUES (1, '\xdeadbeef', -32768, 9223372036854775807, 12345678901234567890.0123456789,
                  1.5, 2.718281828459045, '2026-10-20 22:00:00', '2026-10-20 22:00:00+05:30', '2026-10-20', '23:59:59',
                  '1 day 2 hours', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '203.0.113.7/24', '08:00:2b:01:02:03', '{"a":1}',
                  '{"b":[1,2]}', '{1,2,3}', B'10101010', 12.34, '<a>1</a>', '(1,2)', '[1,10)', 'abc')
                """#, expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}types (id) VALUES (2)", expect: .ok),

            // Plain SELECTs and PostgreSQL's own operators.
            CorpusCase(sql: "SELECT 1", expect: .value("1")),
            CorpusCase(sql: "SELECT 1 + 1 AS two, 'text' AS t, NULL AS n", expect: .value("2")),
            CorpusCase(sql: "SELECT now(), current_date, version()", expect: .rows(1)),
            CorpusCase(sql: "SELECT current_database()", expect: .value(db)),
            CorpusCase(sql: "SELECT current_user, current_schema()", expect: .rows(1)),
            CorpusCase(sql: "SELECT * FROM {p}customers", expect: .rows(5)),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE city = 'London'", expect: .value("Ada Lovelace")),
            CorpusCase(sql: "SELECT count(*) FROM {p}customers WHERE name ILIKE 'a%'", expect: .value("2")),
            CorpusCase(sql: "SELECT count(*) FROM {p}customers WHERE name ~ '^[AG]'", expect: .value("3")),
            CorpusCase(sql: "SELECT count(*) FROM {p}customers WHERE name SIMILAR TO '(Ada|Alan)%'", expect: .value("2")),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE id = 5", expect: .value("Zoë Ünïcode 🚀")),
            CorpusCase(sql: "SELECT length(name) FROM {p}customers WHERE id = 5", expect: .value("13")),
            CorpusCase(sql: "SELECT note FROM {p}orders WHERE id = 3", expect: .value("it's quoted")),
            CorpusCase(sql: "SELECT note FROM {p}orders WHERE id = 4", expect: .value(#"back\slash"#)),
            CorpusCase(sql: "SELECT total FROM {p}orders WHERE id = 4", expect: .value("12345678.90")),
            // A SUM of numeric is an unconstrained numeric, which DuckDB reads as a double:
            // PostgreSQL writes 12345789.40, the grid 12345789.4.
            CorpusCase(sql: "SELECT sum(total) FROM {p}orders", expect: .contains("12345789.4")),
            CorpusCase(sql: "SELECT vip FROM {p}customers WHERE id = 1", expect: .value("true")),
            CorpusCase(sql: "SELECT 7 / 2", expect: .value("3")),
            CorpusCase(sql: "SELECT tags FROM {p}customers WHERE id = 1", expect: .contains("math")),
            CorpusCase(sql: "SELECT meta->>'lang' FROM {p}customers WHERE id = 1", expect: .value("en")),
            CorpusCase(sql: "SELECT meta #>> '{lang}' FROM {p}customers WHERE id = 5", expect: .value("de")),
            CorpusCase(sql: "SELECT meta #>> '{lang}' FROM {p}customers WHERE id = 5; SELECT 'next'", expect: .value("next")),
            CorpusCase(sql: "SELECT count(*) FROM {p}customers WHERE tags @> ARRAY['math']", expect: .value("2")),
            CorpusCase(sql: "SELECT unnest(tags) FROM {p}customers WHERE id = 1", expect: .rows(2)),
            CorpusCase(sql: "SELECT 'math' = ANY(tags) FROM {p}customers WHERE id = 2", expect: .value("true")),
            CorpusCase(sql: "SELECT mood FROM {p}customers WHERE id = 1", expect: .value("happy")),
            CorpusCase(sql: "SELECT * FROM generate_series(1, 10) g", expect: .rows(10)),
            CorpusCase(sql: "SELECT string_agg(name, '|' ORDER BY name) FROM {p}customers WHERE vip", expect: .value("Ada Lovelace|Grace Hopper")),
            CorpusCase(sql: "SELECT array_agg(id ORDER BY id) FROM {p}customers", expect: .rows(1)),
            CorpusCase(sql: "SELECT count(*) FILTER (WHERE vip) FROM {p}customers", expect: .value("2")),
            CorpusCase(sql: "SELECT DISTINCT ON (customer_id) customer_id, total FROM {p}orders ORDER BY customer_id, total DESC", expect: .rows(3)),
            CorpusCase(sql: "SELECT jsonb_build_object('id', id, 'name', name) FROM {p}customers LIMIT 1", expect: .rows(1)),
            CorpusCase(sql: "SELECT jsonb_agg(name) FROM {p}customers", expect: .rows(1)),
            CorpusCase(sql: "SELECT c.name, o.total FROM {p}customers c JOIN {p}orders o ON o.customer_id = c.id ORDER BY o.id", expect: .rows(4)),
            CorpusCase(sql: "SELECT c.name, count(o.id) FROM {p}customers c LEFT JOIN {p}orders o ON o.customer_id = c.id GROUP BY c.id, c.name", expect: .rows(5)),
            CorpusCase(sql: "SELECT c.name, x.total FROM {p}customers c CROSS JOIN LATERAL (SELECT total FROM {p}orders o WHERE o.customer_id = c.id ORDER BY total DESC LIMIT 1) x", expect: .rows(3)),
            CorpusCase(sql: "SELECT name FROM {p}customers c WHERE EXISTS (SELECT 1 FROM {p}orders o WHERE o.customer_id = c.id)", expect: .rows(3)),
            CorpusCase(sql: "SELECT name FROM {p}customers WHERE vip UNION SELECT name FROM {p}customers WHERE city = 'London'", expect: .rows(2)),
            CorpusCase(sql: "SELECT id FROM {p}customers INTERSECT SELECT customer_id FROM {p}orders", expect: .rows(3)),
            CorpusCase(sql: "SELECT id FROM {p}customers EXCEPT SELECT customer_id FROM {p}orders", expect: .rows(2)),
            CorpusCase(sql: "SELECT status, count(*) FROM {p}orders GROUP BY ROLLUP (status)", expect: .rows(4)),
            CorpusCase(sql: "WITH t AS (SELECT customer_id, sum(total) s FROM {p}orders GROUP BY customer_id) SELECT c.name, t.s FROM t JOIN {p}customers c ON c.id = t.customer_id ORDER BY t.s DESC", expect: .rows(3)),
            CorpusCase(sql: "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100) SELECT count(*) FROM n", expect: .value("100")),
            CorpusCase(sql: "SELECT id, total, row_number() OVER (PARTITION BY customer_id ORDER BY total DESC), sum(total) OVER (), lag(total) OVER (ORDER BY id) FROM {p}orders", expect: .rows(4)),
            CorpusCase(sql: "SELECT * FROM {p}orders ORDER BY note NULLS LAST FETCH FIRST 2 ROWS ONLY", expect: .rows(2)),
            CorpusCase(sql: "SELECT * FROM {p}orders ORDER BY id LIMIT 2 OFFSET 1", expect: .rows(2)),

            // Functions.
            CorpusCase(sql: "SELECT to_char(placed, 'YYYY/MM/DD') FROM {p}orders WHERE id = 1", expect: .value("2026/01/02")),
            CorpusCase(sql: "SELECT date_trunc('month', placed)::date FROM {p}orders WHERE id = 2", expect: .value("2026-02-01")),
            CorpusCase(sql: "SELECT extract(year FROM placed) FROM {p}orders WHERE id = 1", expect: .value("2026")),
            CorpusCase(sql: "SELECT placed + interval '1 month' FROM {p}orders WHERE id = 1", expect: .contains("2026-02-02")),
            CorpusCase(sql: "SELECT age(date '2026-12-31', date '2026-01-02')", expect: .rows(1)),
            CorpusCase(sql: "SELECT format('%s-%s', 1, 'x'), split_part('a,b,c', ',', 2), regexp_replace('abc', 'b', 'X'), md5('x'), upper('ü'), left('hello', 2), lpad('7', 3, '0')", expect: .value("1-x")),
            CorpusCase(sql: "SELECT round(2.675, 2), floor(-1.5), 10 % 3, power(2, 10), sqrt(16)", expect: .value("2.68")),
            CorpusCase(sql: "SELECT '42'::int + 1, CAST('7' AS bigint), 3.14::numeric(5,1)", expect: .value("43")),
            CorpusCase(sql: "SELECT pg_sleep(0)", expect: .rows(1)),
            CorpusCase(sql: "SELECT pg_typeof(1.5)", expect: .value("numeric")),
            CorpusCase(sql: "SELECT current_setting('search_path')", expect: .rows(1)),
            CorpusCase(sql: "SELECT gen_random_uuid()", expect: .rows(1)),
            CorpusCase(sql: "SELECT * FROM pg_stat_activity", expect: .atLeast(1)),
            CorpusCase(sql: "SELECT * FROM information_schema.tables WHERE table_schema = 'public'", expect: .atLeast(5)),
            CorpusCase(sql: "SELECT * FROM pg_catalog.pg_tables", expect: .atLeast(5)),
            CorpusCase(sql: "SELECT ARRAY[1,2,3]", expect: .rows(1)),
            CorpusCase(sql: "SELECT '{\"a\":1}'::jsonb", expect: .rows(1)),
            CorpusCase(sql: "SELECT 'infinity'::timestamp, '-infinity'::date", expect: .rows(1)),
            CorpusCase(sql: "SELECT 'NaN'::float8, 'Infinity'::float8", expect: .rows(1)),
            CorpusCase(sql: "SELECT ''::text, NULL::int", expect: .rows(1)),
            CorpusCase(sql: #"SELECT E'tab\there'"#, expect: .contains("tab")),
            CorpusCase(sql: "SELECT $$dollar 'quoted'$$", expect: .value("dollar 'quoted'")),
            CorpusCase(sql: "SELECT $$semi;colon$$", expect: .value("semi;colon")),
            CorpusCase(sql: "SELECT $tag$x$tag$", expect: .value("x")),

            // Every type back as the server keeps it.
            CorpusCase(sql: "SELECT i8 FROM {p}types WHERE id = 1", expect: .value("9223372036854775807")),
            CorpusCase(sql: "SELECT n FROM {p}types WHERE id = 1", expect: .value("12345678901234567890.0123456789")),
            CorpusCase(sql: "SELECT encode(b, 'hex') FROM {p}types WHERE id = 1", expect: .value("deadbeef")),
            CorpusCase(sql: "SELECT b FROM {p}types WHERE id = 1", expect: .rows(1)),
            CorpusCase(sql: "SELECT tz FROM {p}types WHERE id = 1", expect: .rows(1)),
            CorpusCase(sql: "SELECT iv FROM {p}types WHERE id = 1", expect: .contains("1 day")),
            CorpusCase(sql: "SELECT u FROM {p}types WHERE id = 1", expect: .value("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")),
            CorpusCase(sql: "SELECT ip FROM {p}types WHERE id = 1", expect: .contains("203.0.113.7")),
            CorpusCase(sql: "SELECT mac FROM {p}types WHERE id = 1", expect: .contains("08:00:2b")),
            CorpusCase(sql: "SELECT j FROM {p}types WHERE id = 1", expect: .contains("\"a\"")),
            CorpusCase(sql: "SELECT jb FROM {p}types WHERE id = 1", expect: .contains("\"b\"")),
            CorpusCase(sql: "SELECT arr FROM {p}types WHERE id = 1", expect: .contains("2")),
            CorpusCase(sql: "SELECT bits FROM {p}types WHERE id = 1", expect: .contains("10101010")),
            CorpusCase(sql: "SELECT m FROM {p}types WHERE id = 1", expect: .contains("12.34")),
            CorpusCase(sql: "SELECT x FROM {p}types WHERE id = 1", expect: .contains("<a>1</a>")),
            CorpusCase(sql: "SELECT pt FROM {p}types WHERE id = 1", expect: .contains("1")),
            CorpusCase(sql: "SELECT rng FROM {p}types WHERE id = 1", expect: .contains("[1,10)")),
            CorpusCase(sql: "SELECT ch FROM {p}types WHERE id = 1", expect: .value("abc")),
            CorpusCase(sql: "SELECT * FROM {p}types ORDER BY id", expect: .rows(2)),

            // Session settings, SHOW, transactions, session state.
            CorpusCase(sql: "SHOW search_path", expect: .rows(1)),
            CorpusCase(sql: "SHOW server_version", expect: .rows(1)),
            CorpusCase(sql: "SHOW ALL", expect: .atLeast(100)),
            // SET search_path picks the schema, as the left panel does; another lone SET says
            // it lasts its run; a script's statements share one connection.
            CorpusCase(sql: "SET search_path TO public", expect: .contains("public")),
            CorpusCase(sql: "SET search_path TO 'public'", expect: .contains("public")),
            CorpusCase(sql: "COPY (SELECT 1 AS a UNION ALL SELECT 2) TO STDOUT", expect: .rows(2)),
            CorpusCase(sql: "COPY {p}log FROM STDIN", expect: .error("Import CSV")),
            CorpusCase(sql: "SET statement_timeout = '5s'", expect: .contains("lasts for the run")),
            CorpusCase(sql: "RESET statement_timeout", expect: .contains("lasts for the run")),
            CorpusCase(sql: "SET statement_timeout = '5s'; SHOW statement_timeout", expect: .value("5s")),
            CorpusCase(sql: "BEGIN", expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES ('rolled back')", expect: .ok),
            CorpusCase(sql: "ROLLBACK", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}log WHERE msg = 'rolled back'", expect: .value("0")),
            // A setting in a transaction: SET LOCAL holds in it and ends with it; a plain SET
            // would outlast it on a connection the app reuses, so it is refused.
            CorpusCase(sql: "BEGIN", expect: .ok),
            CorpusCase(sql: "SET LOCAL statement_timeout = '5s'", expect: .ok),
            CorpusCase(sql: "SELECT current_setting('statement_timeout')", expect: .value("5s")),
            CorpusCase(sql: "SET statement_timeout = '5s'", expect: .error("SET LOCAL")),
            CorpusCase(sql: "ROLLBACK", expect: .ok),
            CorpusCase(sql: "SELECT current_setting('statement_timeout')", expect: .value("0")),
            CorpusCase(sql: "BEGIN; INSERT INTO {p}log (msg) VALUES ('kept'); COMMIT", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}log WHERE msg = 'kept'", expect: .value("1")),
            CorpusCase(sql: "PREPARE {p}q AS SELECT $1::int + 1; EXECUTE {p}q(41)", expect: .value("42")),
            CorpusCase(sql: "CREATE TEMP TABLE {p}tmp (id int); INSERT INTO {p}tmp VALUES (1), (2); SELECT count(*) FROM {p}tmp", expect: .value("2")),
            CorpusCase(sql: "BEGIN; LOCK TABLE {p}orders IN SHARE MODE; COMMIT", expect: .ok),

            // Writes in PostgreSQL's own syntax.
            CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES ('returning') RETURNING id, msg", expect: .contains("returning")),
            CorpusCase(sql: "UPDATE {p}customers SET city = 'Cambridge' WHERE name = 'Alan Turing' RETURNING city", expect: .value("Cambridge")),
            CorpusCase(sql: "INSERT INTO {p}customers (name, email, city) VALUES ('Ada Again', 'ada@example.com', 'Paris') ON CONFLICT (email) DO UPDATE SET city = EXCLUDED.city", expect: .ok),
            CorpusCase(sql: "SELECT city FROM {p}customers WHERE email = 'ada@example.com'", expect: .value("Paris")),
            CorpusCase(sql: "INSERT INTO {p}customers (name, email) VALUES ('Dup', 'ada@example.com') ON CONFLICT DO NOTHING", expect: .ok),
            // MERGE (PostgreSQL 15), full-text search, an extension's function.
            CorpusCase(sql: """
                MERGE INTO {p}customers c USING (VALUES ('ada@example.com', 'Oxford')) AS v(email, city) ON c.email = v.email
                WHEN MATCHED THEN UPDATE SET city = v.city WHEN NOT MATCHED THEN INSERT (name, email, city) VALUES ('Merged', v.email, v.city)
                """, expect: .ok),
            CorpusCase(sql: "SELECT city FROM {p}customers WHERE email = 'ada@example.com'", expect: .value("Oxford")),
            CorpusCase(sql: "SELECT to_tsvector('english', 'The quick brown foxes') @@ to_tsquery('english', 'fox')", expect: .value("true")),
            CorpusCase(sql: "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"", expect: .ok),
            CorpusCase(sql: "SELECT uuid_generate_v4() IS NOT NULL", expect: .value("true")),
            CorpusCase(sql: "UPDATE {p}orders o SET note = 'for ' || c.name FROM {p}customers c WHERE c.id = o.customer_id AND c.vip", expect: .ok),
            CorpusCase(sql: "SELECT note FROM {p}orders WHERE id = 4", expect: .value("for Grace Hopper")),
            CorpusCase(sql: "DELETE FROM {p}items i USING {p}orders o WHERE o.id = i.order_id AND o.status = 'shipped'", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}items", expect: .value("3")),
            CorpusCase(sql: "WITH moved AS (DELETE FROM {p}log WHERE msg = 'kept' RETURNING *) SELECT count(*) FROM moved", expect: .value("1")),
            CorpusCase(sql: "INSERT INTO {p}log (msg) SELECT name FROM {p}customers", expect: .ok),
            CorpusCase(sql: "TRUNCATE {p}log RESTART IDENTITY", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}log", expect: .value("0")),
            CorpusCase(sql: "SELECT * FROM {p}orders WHERE id = 1 FOR UPDATE", expect: .rows(1)),

            // DDL.
            CorpusCase(sql: "ALTER TABLE {p}customers ADD COLUMN phone varchar(20)", expect: .ok),
            CorpusCase(sql: "ALTER TABLE {p}customers ALTER COLUMN phone TYPE varchar(30)", expect: .ok),
            CorpusCase(sql: "ALTER TABLE {p}customers RENAME COLUMN phone TO mobile", expect: .ok),
            CorpusCase(sql: "SELECT character_maximum_length FROM information_schema.columns WHERE table_name = '{p}customers' AND column_name = 'mobile'", expect: .value("30")),
            CorpusCase(sql: "ALTER TABLE {p}customers DROP COLUMN mobile", expect: .ok),
            CorpusCase(sql: "CREATE INDEX {p}idx_meta ON {p}customers USING gin (meta)", expect: .ok),
            CorpusCase(sql: "CREATE INDEX {p}idx_vip ON {p}customers (name) WHERE vip", expect: .ok),
            CorpusCase(sql: "CREATE INDEX CONCURRENTLY {p}idx_city ON {p}customers (city)", expect: .ok),
            CorpusCase(sql: "DROP INDEX {p}idx_meta", expect: .ok),
            CorpusCase(sql: "DROP INDEX CONCURRENTLY {p}idx_city", expect: .ok),
            CorpusCase(sql: "CREATE SCHEMA IF NOT EXISTS {p}s", expect: .ok),
            CorpusCase(sql: "CREATE TABLE {p}s.t (id int)", expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}s.t VALUES (1)", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}s.t", expect: .value("1")),
            // In a schema picked (not public), a transaction begun in the Query tab: its
            // write goes to that schema, its read sees the write, ROLLBACK undoes it.
            CorpusCase(sql: "CREATE TABLE {p}s.{p}tx (id int)", expect: .ok),
            CorpusCase(sql: "SET search_path TO {p}s", expect: .contains("{p}s")),
            CorpusCase(sql: "INSERT INTO {p}tx VALUES (1)", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}tx", expect: .value("1")),
            CorpusCase(sql: "BEGIN", expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}tx VALUES (2)", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}tx", expect: .value("2")),
            CorpusCase(sql: "ROLLBACK", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}tx", expect: .value("1")),
            CorpusCase(sql: "SET search_path TO public", expect: .contains("public")),
            CorpusCase(sql: "DROP SCHEMA {p}s CASCADE", expect: .ok),
            CorpusCase(sql: "CREATE SEQUENCE {p}seq START 100", expect: .ok),
            CorpusCase(sql: "SELECT nextval('{p}seq')", expect: .value("100")),
            CorpusCase(sql: "DROP SEQUENCE {p}seq", expect: .ok),
            CorpusCase(sql: "CREATE VIEW {p}vip AS SELECT id, name FROM {p}customers WHERE vip", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}vip", expect: .value("2")),
            CorpusCase(sql: "CREATE MATERIALIZED VIEW {p}mv AS SELECT count(*) AS n FROM {p}orders", expect: .ok),
            CorpusCase(sql: "REFRESH MATERIALIZED VIEW {p}mv", expect: .ok),
            CorpusCase(sql: "SELECT n FROM {p}mv", expect: .value("4")),
            CorpusCase(sql: "DROP MATERIALIZED VIEW {p}mv", expect: .ok),
            CorpusCase(sql: "DROP VIEW {p}vip", expect: .ok),
            CorpusCase(sql: "CREATE DOMAIN {p}pos AS int CHECK (VALUE > 0)", expect: .ok),
            CorpusCase(sql: "SELECT 5::{p}pos", expect: .value("5")),
            CorpusCase(sql: "DROP DOMAIN {p}pos", expect: .ok),
            CorpusCase(sql: "COMMENT ON TABLE {p}customers IS 'people'", expect: .ok),
            CorpusCase(sql: "SELECT obj_description('{p}customers'::regclass)", expect: .value("people")),

            // Functions, procedures, DO, triggers: bodies in $$ … $$.
            CorpusCase(sql: "CREATE OR REPLACE FUNCTION {p}fn(x int) RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN x * 2; END; $$", expect: .ok),
            CorpusCase(sql: "SELECT {p}fn(21)", expect: .value("42")),
            CorpusCase(sql: "CREATE OR REPLACE FUNCTION {p}sqlfn(x int) RETURNS int LANGUAGE sql AS 'SELECT x * 3'", expect: .ok),
            CorpusCase(sql: "SELECT {p}sqlfn(2)", expect: .value("6")),
            CorpusCase(sql: "CREATE OR REPLACE PROCEDURE {p}proc(p text) LANGUAGE plpgsql AS $$ BEGIN INSERT INTO {p}log (msg) VALUES (p); END $$", expect: .ok),
            CorpusCase(sql: "CALL {p}proc('from proc')", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}log WHERE msg = 'from proc'", expect: .value("1")),
            CorpusCase(sql: "DO $$ BEGIN INSERT INTO {p}log (msg) VALUES ('from do'); END $$", expect: .ok),
            CorpusCase(sql: "SELECT count(*) FROM {p}log WHERE msg = 'from do'", expect: .value("1")),
            CorpusCase(sql: "CREATE OR REPLACE FUNCTION {p}upper() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.msg := upper(NEW.msg); RETURN NEW; END $$", expect: .ok),
            CorpusCase(sql: "CREATE TRIGGER {p}trg BEFORE INSERT ON {p}log FOR EACH ROW EXECUTE FUNCTION {p}upper()", expect: .ok),
            CorpusCase(sql: "INSERT INTO {p}log (msg) VALUES ('hello')", expect: .ok),
            CorpusCase(sql: "SELECT msg FROM {p}log ORDER BY id DESC LIMIT 1", expect: .value("HELLO")),
            CorpusCase(sql: "DROP TRIGGER {p}trg ON {p}log", expect: .ok),
            // A SQL-standard body (PostgreSQL 14): BEGIN ATOMIC … END keeps its semicolons.
            CorpusCase(sql: "CREATE OR REPLACE FUNCTION {p}atomic() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 41 + 1; END", expect: .ok),
            CorpusCase(sql: "SELECT {p}atomic()", expect: .value("42")),
            CorpusCase(sql: "DROP FUNCTION {p}atomic()", expect: .ok),

            // Maintenance and server-wide statements, some of which can't run in a transaction.
            CorpusCase(sql: "VACUUM {p}log", expect: .ok),
            CorpusCase(sql: "VACUUM ANALYZE {p}orders", expect: .ok),
            CorpusCase(sql: "ANALYZE {p}orders", expect: .ok),
            CorpusCase(sql: "REINDEX TABLE {p}orders", expect: .ok),
            CorpusCase(sql: "CLUSTER {p}orders USING {p}orders_pkey", expect: .ok),
            CorpusCase(sql: "CREATE ROLE {p}role NOLOGIN", expect: .ok),
            CorpusCase(sql: "GRANT SELECT ON {p}customers TO {p}role", expect: .ok),
            CorpusCase(sql: "REVOKE SELECT ON {p}customers FROM {p}role", expect: .ok),
            CorpusCase(sql: "DROP ROLE {p}role", expect: .ok),
            CorpusCase(sql: "CREATE DATABASE {p}db", expect: .ok),
            CorpusCase(sql: "DROP DATABASE {p}db", expect: .ok),
            CorpusCase(sql: "LISTEN {p}chan", expect: .ok),
            CorpusCase(sql: "NOTIFY {p}chan, 'x'", expect: .ok),
            CorpusCase(sql: "LOCK TABLE {p}orders IN SHARE MODE", expect: .error("transaction")),

            // EXPLAIN in its forms.
            CorpusCase(sql: "EXPLAIN SELECT * FROM {p}orders", expect: .atLeast(1)),
            CorpusCase(sql: "EXPLAIN ANALYZE SELECT * FROM {p}orders", expect: .atLeast(1)),
            CorpusCase(sql: "EXPLAIN (FORMAT JSON) SELECT 1", expect: .rows(1)),
            CorpusCase(sql: "EXPLAIN (ANALYZE, BUFFERS) SELECT 1", expect: .atLeast(1)),
            CorpusCase(sql: "EXPLAIN ANALYZE DELETE FROM {p}items WHERE false", expect: .atLeast(1)),

            // Comments and scripts.
            CorpusCase(sql: "-- a comment\nSELECT 1", expect: .value("1")),
            CorpusCase(sql: "/* a comment */ SELECT 3", expect: .value("3")),
            CorpusCase(sql: "SELECT 4 --trailing", expect: .value("4")),
            CorpusCase(sql: "SELECT 1; SELECT 2;", expect: .value("2")),

            // Errors said plainly.
            CorpusCase(sql: "SELEC 1", expect: .error("syntax")),
            CorpusCase(sql: "SELECT * FROM {p}nope", expect: .error("{p}nope")),
            CorpusCase(sql: "INSERT INTO {p}customers (name, email) VALUES ('x', 'alan@example.com')", expect: .error("duplicate key")),
            CorpusCase(sql: "INSERT INTO {p}orders (customer_id, total) VALUES (999, 1)", expect: .error("foreign key")),
            CorpusCase(sql: "INSERT INTO {p}orders (customer_id, total) VALUES (1, -1)", expect: .error("check")),
            CorpusCase(sql: "INSERT INTO {p}orders (id, customer_id, total) VALUES (1, 1, 1)", expect: .error("non-DEFAULT")),
            CorpusCase(sql: "SELECT 'abc'::int", expect: .error("invalid input syntax")),
            CorpusCase(sql: "SELECT 1/0", expect: .error("division by zero")),

            // Cleanup.
            CorpusCase(sql: "DROP TABLE IF EXISTS {p}items, {p}orders, {p}customers, {p}types, {p}log, {p}tmp CASCADE", expect: .ok),
            CorpusCase(sql: "DROP FUNCTION IF EXISTS {p}fn(int), {p}sqlfn(int), {p}upper()", expect: .ok),
            CorpusCase(sql: "DROP PROCEDURE IF EXISTS {p}proc(text)", expect: .ok),
            CorpusCase(sql: "DROP TYPE IF EXISTS {p}mood", expect: .ok),
        ]
    }
}
