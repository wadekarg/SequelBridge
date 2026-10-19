# Querying in SequelBridge

The rules the planner follows, in full. The note above the editor is the short
version of this page.

## One server

A statement that names one server runs on that server, in that server's own SQL,
whether that server is the only connection or one of several. Write it as you would
in the server's own client.

| Engine | Where it runs | EXPLAIN |
|---|---|---|
| MySQL / MariaDB | On the server, through the passthrough | The Explain button, or a typed `EXPLAIN …`: the server's own plan (run by the built-in MySQL client, since the scanner can't prepare it) |
| PostgreSQL | On the server, through the passthrough | The Explain button, or a typed `EXPLAIN …`: the server's own plan |
| ClickHouse | On the server, over its HTTP interface | A typed `EXPLAIN …` runs on ClickHouse like any statement; the Explain button is for MySQL and PostgreSQL only |
| SQLite file | Read by DuckDB, so write DuckDB SQL | A typed `EXPLAIN …` shows DuckDB's plan; the Explain button is for MySQL and PostgreSQL only |

A connection marked read-only refuses every write (INSERT, UPDATE, DELETE, DDL), and
while one is open in the workspace a typed statement that writes is refused whichever
server it names.

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

Rows stream in as they arrive and keep streaming, with no row cap; the status bar counts
them. Cancel stops the app's work: DuckDB stops pulling rows and the ClickHouse request
is dropped. A statement a MySQL, PostgreSQL or ClickHouse server is already running
finishes there on its own; the app does not kill it. The Console tab lists every
statement the app sent on your behalf, including the reduced server queries behind a
cross-server join.
