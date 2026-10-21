# Querying in SequelBridge

The rules the planner follows, in full. The note above the editor is the short
version of this page.

## One server

A statement that names one server runs on that server, in that server's own SQL,
whether that server is the only connection or one of several. Write it as you would
in the server's own client.

| Engine | Where it runs | EXPLAIN |
|---|---|---|
| MySQL / MariaDB | A read on the server, through the passthrough; anything else on the server as typed. `SHOW`, `HELP`, `CHECK TABLE`, `CHECKSUM TABLE`, `CALL` and MariaDB's `BEGIN NOT ATOMIC … END` on the built-in MySQL client, since the scanner can't prepare them; so is a read whose result has two columns of one name, or a date the scanner can't read (a zero month or day) | The Explain button, or a typed `EXPLAIN …`: the server's own plan (on the built-in MySQL client too) |
| PostgreSQL | A read on the server: through the passthrough in `public`, on the built-in PostgreSQL client in another schema (with `search_path` set to it). A write on the built-in client, as psql runs it, so `VACUUM`, `CREATE INDEX CONCURRENTLY` and `CREATE DATABASE` work and `RETURNING` shows its rows; `COPY … TO STDOUT` shows its rows, and `COPY … FROM STDIN` is refused: use Import CSV. Inside a `BEGIN` typed in the Query tab, a read in any schema and a write run in that transaction, the schema picked first on its `search_path`. `SHOW` on the built-in client. `SET search_path TO x` picks the schema, as `USE` does on MySQL | The Explain button, or a typed `EXPLAIN …`: the server's own plan (on the built-in PostgreSQL client too) |
| ClickHouse | On the server, over its HTTP interface; a statement with its own `FORMAT` shows that text | A typed `EXPLAIN …` runs on ClickHouse like any statement; the Explain button is for MySQL and PostgreSQL only |
| SQLite file | In SQLite itself, in SQLite's own SQL: a read streams from the file (SQLite 3.38), and one that needs newer SQLite (`RIGHT JOIN`, `concat`, `string_agg`) runs in macOS's `sqlite3`, as does anything else; inside a `BEGIN` typed in the Query tab, in that transaction (DuckDB's) | A typed `EXPLAIN QUERY PLAN …` runs in SQLite; the Explain button is for MySQL and PostgreSQL only |

A script runs one statement at a time, each where the table says, and stops at the first
that fails, saying which. When one statement sets what a later one reads (a variable,
`SET @d = …`; a temporary table; `PREPARE` and `EXECUTE`; a session setting; a
transaction or a lock), the whole script runs on one connection of the server's own
client, as in Sequel Ace or psql. What it sets lasts for that run: run a `SET` together
with the statements it is for. On a SQLite file a script runs in one go, as in the
`sqlite3` shell. Inside a `BEGIN` typed in the Query tab, each statement joins that
transaction (on MySQL a `SET` too; on PostgreSQL in the schema picked, put first on the
transaction's `search_path`). On PostgreSQL write `SET LOCAL` there, which ends with the
transaction: any other `SET` or `RESET` is refused, since it would outlast the
transaction on a connection the app reuses (`SET search_path TO x` still picks the
schema). `SHOW` and `EXPLAIN` on MySQL and PostgreSQL are the exceptions: they run on a
connection of the built-in client, which doesn't see the transaction's changes. A `CALL`
is refused there (a procedure's rows would leave the transaction's connection out of
step): `COMMIT` first, or run `BEGIN; CALL …; COMMIT` as one script.

A procedure, function, trigger or event whose body is in `BEGIN … END` is one statement,
with or without a `DELIMITER` line, as `SHOW CREATE PROCEDURE` gives it and as SQLite
writes every trigger. A `DELIMITER //` line, as in the mysql client, works too.

MySQL keeps dates some servers allow and DuckDB can't hold: a zero date (`0000-00-00`)
and one with a zero month or day (`2026-00-15`). The Content tab shows them as the server
keeps them. In the Query tab, a read with a zero month or day runs on the built-in client
and shows them as kept; a zero date on its own reads as NULL there (the scanner's way, as
JDBC's `convertToNull`).

A connection marked read-only refuses every write (INSERT, UPDATE, DELETE, DDL, an
`EXPLAIN ANALYZE` of a write). A typed statement that writes to it is refused, while one
for a writable connection open beside it runs; a statement across servers that writes
into it is refused by DuckDB, which attaches it read-only. The server's own session is
read-only too, so a function a `SELECT` calls can't write either.

## Several servers: naming tables

A statement that names no server runs on the one picked at the top of the left panel.
To name a server, prefix each table with its connection alias:

```sql
SELECT o.id, c.full_name
FROM shop.orders o JOIN crm.customers c ON o.customer_id = c.id
```

The database is filled in for you: the one picked in the sidebar for that alias,
else the connection's own (for PostgreSQL the `public` schema, for a SQLite file
`main`). Write `alias.database.table` to be explicit.

## Two tables on one key: the streaming join

An inner join of two tables on one key, in either form

```sql
FROM shop.orders o JOIN crm.customers c ON o.customer_id = c.id
FROM shop.orders o, crm.customers c WHERE o.customer_id = c.id AND …
```

streams server to server:

1. The smaller table (by the servers' row estimates) is the *probe*; the other is the
   *big* side. A side with no server passthrough (a SQLite file) is always the probe.
2. The probe's distinct join keys are fetched (its own WHERE conditions applied on its
   server first).
3. The big side's server is asked, with its own `EXPLAIN`, how much of the table those
   keys select. Below 40% the big side comes over reduced to them (`WHERE key IN (…)`);
   at 40% or more, or with more than 10,000 keys, the whole side comes over instead,
   because scanning the table beats pulling most of it through an index.
4. Both sides stream into DuckDB through their servers' passthroughs and are joined as
   they arrive, big side first with the join order pinned, so the first rows appear
   while the big side is still crossing the wire. Nothing is copied into a temp table.

In the comma form the key equality must be a top-level `AND` conjunct; an equality
under an `OR`, or inside parentheses, is not a join key. Three or more tables, outer
joins and anything else fall through to the DuckDB path below.

## What runs on the servers

Conditions from your WHERE that touch one table are pushed to that table's server,
and a condition on a join key is carried to the other side of the join. Only
conditions that give the same answer on the server and in DuckDB are pushed:

| Column type | Pushed | Not pushed, and why |
|---|---|---|
| Strings | `=`, `IN (…)`, `LIKE`, `IS [NOT] NULL` | `<>`, `<`, `>`, `NOT IN`, `NOT …`: a case-insensitive server collation would drop rows DuckDB keeps |
| Numbers, dates, timestamps | all comparisons, `BETWEEN`, `NOT`, `IS [NOT] NULL`; date literals as `'YYYY-MM-DD'` or `'YYYY-MM-DD HH:MM[:SS]'` | other literal shapes |
| ClickHouse `Enum8` / `Enum16` | `=`, `IN (…)`, `IS [NOT] NULL` | `LIKE`: ClickHouse has none for enums |
| Any | — | functions, arithmetic, subqueries, a branch of an `OR`, a bare column name that two tables share, a string literal containing a backslash |

Everything that is not pushed still applies: DuckDB evaluates it on the rows that come
back.

`WHERE x IN (SELECT … FROM other.table)` across servers is a semi-join: the subquery
runs on its server first, its values (up to 10,000) are inlined, and the outer
statement runs on its own server.

## Everything else across servers

Three or more tables, `LEFT`/`RIGHT`/`FULL` joins, `UNION`, subqueries in the FROM
clause: the statement runs on DuckDB. Write DuckDB SQL for it (double-quoted
identifiers, `::` casts, DuckDB functions). Each remote MySQL or PostgreSQL table is
copied into a temp table through its server's passthrough, with its own pushed
conditions, after a bind check that catches a misspelled column before any row crosses
the wire. A SQLite file is read in place.

## ClickHouse

ClickHouse is reached over HTTP, outside DuckDB, so a join with one other server copies
the ClickHouse side into DuckDB first: whole (with its own WHERE applied in ClickHouse)
when it is the smaller side, reduced to the other side's join keys when it is the
bigger one. Keep the ClickHouse side the smaller one. Joining ClickHouse with ClickHouse,
or with three or more tables, is not supported.

## Results

Rows stream in as they arrive and keep streaming, with no row cap, when DuckDB reads
them: the passthrough, a SQLite read, a join across servers. A result that comes from the
built-in MySQL or PostgreSQL client, a script run on one connection, or ClickHouse
arrives whole. The status bar counts the rows. Cancel stops the app's work: DuckDB stops
pulling rows, the ClickHouse request is dropped, and the built-in client closes its
connection. A statement a MySQL, PostgreSQL or ClickHouse server is already running
finishes there on its own; the app does not kill it. The Console tab lists every
statement the app sent on your behalf, including the reduced server queries behind a
cross-server join.
