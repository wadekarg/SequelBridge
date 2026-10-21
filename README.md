# SequelBridge

A native macOS database client that runs one SQL statement across MySQL/MariaDB,
PostgreSQL, SQLite and ClickHouse, joins included, and streams the result in as it
arrives.

![SequelBridge running one query across MySQL, PostgreSQL and SQLite](guide/images/hero.png)

```sql
SELECT c.full_name, r.name AS region, COUNT(o.id) AS orders, SUM(i.qty) AS items
FROM crm.customers c
JOIN shop.orders o ON o.customer_id = c.id
JOIN shop.order_items i ON i.order_id = o.id
JOIN ref.regions r ON r.code = c.region_code
GROUP BY c.full_name, r.name
ORDER BY orders DESC
LIMIT 200
```

Customers in PostgreSQL, orders in MySQL, a lookup table in a SQLite file: one
statement. No ETL, no staging tables, no exporting CSVs between systems.

## What is different

- **Joins across servers stream.** Two tables on one key are joined server to server:
  the smaller side's keys filter the bigger side on its own server, and rows appear
  while the rest is still crossing the wire.
  [One query, traced](guide/ARCHITECTURE.md#one-query-traced)
- **Each server keeps its own SQL.** A statement that names one server runs there as
  written, EXPLAIN included. Only a query that spans servers needs the alias prefixes.
  [The rules](guide/QUERYING.md)
- **No row cap.** Results stream into a compact grid. A 4.7-million-row join over a VPN
  shows its first rows after about twelve seconds.
- **Nothing hidden.** The Console tab shows every statement the app runs: yours, the
  ones it builds for you (an edit, a page of rows), and its own reads of your tables,
  columns and keys, marked as the app's. Read-only mode is enforced by the engine, not
  the interface. Passwords live in your Keychain.

## Install

Download the signed, notarized build from the [Releases](../../releases) page, open the
`.dmg` and drag SequelBridge to Applications. Or with Homebrew:

```bash
brew install --cask wadekarg/tap/sequelbridge
```

The app keeps itself up to date: it checks once a day (it asks you first) and offers
each new version, which it installs only when the update is signed with the project's
key. **SequelBridge → Check for Updates…** checks at once.

On the first connection to a MySQL, PostgreSQL or SQLite server the app downloads the
matching DuckDB scanner extension once and keeps it; that first connect needs internet.

## Compatibility

| | |
|---|---|
| macOS | 14 (Sonoma) or later, Apple Silicon and Intel |
| MySQL / MariaDB | tested with MySQL 8.0 and 8.4, MariaDB 10.0 and 11.4 |
| PostgreSQL | tested with 16 |
| SQLite | version 3 files |
| ClickHouse | tested with 26.9, over the HTTP interface |

Newer versions are expected to work. If yours does not, please open an issue.

## Learn more

- [Features](guide/FEATURES.md): what each part of the app does, by task, with a table
  of what works on which engine.
- [Querying](guide/QUERYING.md): the rules a query follows, in full, with examples.
- [Architecture](guide/ARCHITECTURE.md): how it is built and why, with one query traced
  statement by statement.
- [Coming from Sequel Ace](guide/SEQUEL-ACE.md): each Sequel Ace feature, whether
  SequelBridge has it, and the test that proves it.

## Build from source

```bash
git clone https://github.com/wadekarg/SequelBridge.git
cd SequelBridge
scripts/fetch-duckdb.sh          # the DuckDB static libraries (once)
open SequelBridge.xcodeproj      # Build & Run in Xcode
```

`scripts/run-all-tests.sh --hermetic` runs the unit tests; the full matrix against local
containers is in [TESTING.md](TESTING.md). [CONTRIBUTING.md](CONTRIBUTING.md) has the
rest.

## License

[MIT](LICENSE) © 2026 Gajanan Wadekar. Built with [DuckDB](https://duckdb.org) and its
MySQL, PostgreSQL and SQLite scanner extensions.
