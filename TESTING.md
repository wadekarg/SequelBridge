# Testing SequelBridge

**The rule: every feature ships with tests, and the whole matrix is green before it merges.**

When you add or change a feature, you add or update the tests that cover it, then run the
*entire* suite from scratch. Nothing merges on a partial run. The suite is the contract:
if a behaviour matters, there is a test that fails when it breaks.

## Run it

```bash
scripts/run-all-tests.sh --provision     # from scratch: fresh containers, seed, full matrix  ← before every merge
scripts/run-all-tests.sh                 # reuse running containers, full matrix              ← fast iteration
scripts/run-all-tests.sh --hermetic      # no-DB unit tests only (no Docker)                  ← quickest inner loop
scripts/run-all-tests.sh --release       # same, in Release (DuckDB 20-100x faster)
scripts/run-all-tests.sh --bench --release   # also the cross-engine timing benchmark
scripts/run-all-tests.sh --down          # tear the containers down
```

`--provision` is the canonical "A to Z from scratch" run: it drops and recreates the
Docker containers, seeds every fixture from `scripts/fixtures/`, points every gated suite
at them, and runs all 724 tests in 144 suites (about three minutes of tests after the build).
Then every MySQL suite runs three more times, with its server pointed at MySQL 8.4,
MariaDB 11.4 and MySQL 8.0 in turn.
That is the run that gates a merge. Even then two tests stay skipped on purpose: the
benchmark (`--bench`), and `QueryCancelTests.interruptStopsServerStatement`, the spec
for a server-side cancel the app does not do yet.

The MySQL family has four servers: MariaDB 10.0 (`sb-mariadb10`, port 3309); MySQL 8.4
(`sb-mysql8`, port 3311), which logs in with `caching_sha2_password` and keeps one account
on `mysql_native_password` (`scripts/fixtures/mysql8.sql`); MariaDB 11.4 (`sb-mariadb11`,
port 3312), which reports a timestamp's default as `current_timestamp()`; and MySQL 8.0
(`sb-mysql80`, port 3313), which marks such a column `DEFAULT_GENERATED`. Each pass's log
is `.build/run-all-tests-<server>.log`. `--mysql-port N --only "…"` points a targeted run
at one of them. PostgreSQL 16 runs twice: `sb-postgres` (5433) without SSL, and
`sb-postgres-ssl` (5434) with it, on the image's own snakeoil certificate.

Besides the database containers, the script runs an SSH server container (`sb-sshd`,
`scripts/fixtures/ssh/sshd-setup.sh`) with a throwaway test key in `.build/ssh/`: port
2224 with today's defaults, port 2225 behaving like an old server that offers only
`ssh-rsa`. The app's tunnel accepts each server's host key into your
`~/.ssh/known_hosts` once, as it would for any server; the host keys are generated
once and kept, so those entries stay valid. For socket connections it relays MariaDB
and PostgreSQL to Unix sockets in `/tmp/sb-sock` while the tests run
(`scripts/fixtures/socket-relay.py`).

On GitHub, every push to `main` and every pull request builds the app on Apple Silicon,
on macOS 15 and macOS 26 (`.github/workflows/test.yml`), and runs the tests that need no
database server, then the UI tests (`SequelBridgeUITests`, scheme `SequelBridgeUITests`).
The UI tests click the workspace's tab strips and + buttons, check that six connection
tabs all stay on screen with the + above the database menu, run a statement that names
no server on the active tab, and close the active query tab with ⌘W.
`MySQLWorkflowUITests` walks the everyday flows on a MariaDB the job installs with
Homebrew and seeds from `scripts/fixtures/mysql.sql`: pick a database, `USE`, several
statements, Run Current, filter tables, edit a cell in place and set it to NULL, rename
and duplicate a table, ⌘/, Table Info's `CREATE TABLE`, ⌘1–⌘6, the Console, MySQL's
own syntax run as typed, ⌘R on the table on screen after another was opened, and the
Content tab's ⌘J (page and rows per page), ⌘D (duplicate a row), its column-operator-value filter, and following a foreign key, Add Database with an encoding and Delete Database, Table Maintenance's answer;
`MySQLRefreshUITests` refreshes one connection after a change through another, by
the button, by ⇧⌘R and by ⌃⌘R, and checks ⌘R (the statement under the cursor) against
⌥⌘R (all). `VisualTourUITests` takes a screenshot of every screen and sheet in light and
dark mode, of the app's window only, for a person to look over. A copy launched for the
UI tests keeps its settings apart from the owner's. The UI tests take over the screen
while they run, so `scripts/run-all-tests.sh` leaves them out.

## What's in the suite

**Hermetic (always run, no Docker)** — DuckDB engine, SQL builders (`SQLBuilderTests`,
including cross-join detection, ClickHouse→DuckDB type mapping, the **read-only
classifier**, and **CSV type inference**), the **SQL formatter** (`SQLFormatterTests`),
result streaming and caps (`RowCapTests` — the "big query" coverage), the **result text
filter** (`QueryResultFilterTests`), **chart data extraction** (`ChartDataTests`), result
export incl. **Markdown/SQL-INSERT** (`ResultExporterTests`), parsers,
extension bundling/download, sort order, write-path SQL, panel logic, stores, the
query-conventions note, the demo fixture store. Together with the gated suites below:
724 tests across 107 files.

**Gated real-DB suites** (run by the script against seeded containers):

| Suite | Gate | Covers |
|---|---|---|
| `MySQLIntegrationTests` | `SB_MYSQL_VERIFY` | live MySQL/MariaDB attach, query, metadata, FK relations |
| `DatabaseSwitchTests` | `SB_MYSQL_VERIFY` | the database picked at the top of the left panel: its tables are listed and queries run there; two picks close together end on the second; one that can't be opened says why and the connection stays on its database; `USE` in the Query tab moves the pick; CREATE/DROP of tables and databases refresh the lists, and dropping the picked database goes back to the connection's own |
| `MySQLRelationsTests` | `SB_MYSQL_VERIFY` | the Relations tab's foreign-key lookup: the server's plan reads only that table's constraints (no "Scanned all databases"); a two-column key and a second key listed once each, columns in key order; the same names in another database stay out |
| `MySQLAuthTests` | always | the app's own MySQL client's login pieces: both password scrambles against reference values, the RSA password exchange |
| `SSLConnectionTests` | `SB_SSL_VERIFY` | Use SSL: MySQL 8.4 connects encrypted; MariaDB 10.0 and PostgreSQL 16 without TLS are refused with the reason and no password; the app's own MySQL client switches to TLS after the greeting (its `Ssl_cipher`), so EXPLAIN, the server's `CREATE TABLE` and Table Maintenance work on an SSL connection, and refuses a server without SSL |
| `ConnectionErrorTests` | always | a driver's connection error keeps its reason and loses the connection string and every password |
| `MySQL8Tests` | `SB_MYSQL8_VERIFY` | MySQL 8.4: that client's `caching_sha2_password` login (full and cached), a switch to `mysql_native_password`, a wrong password, EXPLAIN, a dump's `CREATE TABLE` with its foreign keys |
| `QueryEngineDDLTests` | `SB_MYSQL_VERIFY` | DDL via `mysqlExecute` (not the fatal `mysql_query` path) |
| `PanelWritePathTests` | `SB_MYSQL_VERIFY` | panel-generated writes run end-to-end on a live server |
| `RealSchemaTests` | `SB_MYSQL_VERIFY` + `SB_MYSQL_REAL_DB` | production shapes: MyISAM, zero-dates, `ON UPDATE`, latin1 |
| `MultiServerTests` | `SB_MYSQL_VERIFY` + `SB_MYSQL_PORT2` | several servers in one workspace; cross-server JOIN + UNION |
| `DestructiveDDLVerifyTests` | `SB_DDL_VERIFY` | drop/truncate builders + server-side ORDER BY |
| `CrossJoinReductionTests` | `SB_XJOIN_VERIFY` | **cross-server JOIN reduction == scanner, row for row** |
| `ClickHouseBridgeTests` | `SB_CHBRIDGE_VERIFY` | **ClickHouse cross-join bridge** (materialize + reduce, lossless) |
| `ClickHouseTests` | `SB_CH_VERIFY` | ClickHouse native HTTP: connect, browse, typed rows, DDL |
| `ClickHouseInsightsTests` | `SB_CH_VERIFY` | ClickHouse Query Insights over `system.query_log` (recent/slow/by-type) |
| `ReadOnlyModeTests` | `SB_MYSQL_VERIFY` | safe mode refuses every write path, Content-tab edits included; reads still work |
| `ReadOnlyStatementTests`, `ReadOnlySQLiteTests` | always | `EXPLAIN ANALYZE` of a write counts as a write; on a read-only SQLite file a statement through DuckDB, a typed one, a Content edit and Structure are all refused, the file is unchanged, and reads still work |
| `ReadOnlyPostgresTests`, `ReadOnlyMySQLTests`, `ReadOnlyClickHouseTests` | `SB_PG_VERIFY`, `SB_MYSQL_VERIFY`, `SB_CH_VERIFY` | read-only below the interface: a statement through DuckDB, `mysql_execute`, the native client, `EXPLAIN ANALYZE` of a `DELETE`, `nextval()` and a stored function that inserts called from a `SELECT`, Kill, a ClickHouse `INSERT` or `DROP`, all refused with the rows unchanged; an account ClickHouse already holds read-only still reads |
| `NativeRoutingTests`, `PostgresLoginTests` | always | which typed statements go to the app's own client (MySQL's SHOW, HELP, CHECK; PostgreSQL's SHOW, EXPLAIN); the PostgreSQL client's MD5 and SCRAM-SHA-256 logins against reference values (RFC 7677's example), a server that can't prove the password, an error's message |
| `PostgresNativeTests`, `PostgresNativeSSLTests` | `SB_PG_VERIFY`, `SB_PG_SSL_PORT` | PostgreSQL's own client on a real server: the Explain button's plan, a typed `SHOW` in the schema picked, a server error's message, a read-only session, a Unix socket; over SSL with Use SSL and without it (encrypted when the server offers it, as libpq does), and Use SSL refused against a server without SSL before any password is sent |
| `MySQLNativeStatementTests` | `SB_MYSQL_VERIFY` | `SHOW CREATE TABLE`, `SHOW FULL PROCESSLIST`, `SHOW GRANTS`, `SHOW WARNINGS`, `CHECK TABLE`, `CHECKSUM TABLE` typed in the Query tab, on the app's own client, in the database picked (on all four MySQL-family servers) |
| `SQLitePromisesTests` | always | what the guide promises for a SQLite file, on one: Create Table (the types picked, an integer key that numbers rows), Structure's add, rename and drop of columns and indexes and its refusals, Content, export, triggers added, fired and dropped, a busy file |
| `DatabaseDumpTests` | `SB_MYSQL_VERIFY` | whole-database SQL dump (all tables, schema + data) |
| `PostgresTests` | `SB_PG_VERIFY` | PostgreSQL attach, query, joins |
| `CrossEngineBenchmark` | `SB_BENCH` | timing (not correctness) for the MySQL×Postgres JOIN |
| `SSHTunnelTests` | always (ports, arguments) / `SB_SSH_VERIFY` (tunnels) | port allocation, failure paths, MySQL through the tunnel on a current and an `ssh-rsa`-only server; the login prompts on a real ssh: a password (`pwuser`), a key with a passphrase, Cancel stopping at once, a wrong password asked three times |
| `SSHLoginTests` | always | what ssh asks (password, passphrase, one-time code), when a saved answer is used, and the askpass script's round trip to the app: the answer back, a wrong token refused, Cancel failing the attempt |
| `ConnectionTypeTests` | always (what each engine offers) / `SB_SSH_VERIFY`, `SB_SOCKET_VERIFY` | every engine × connection type: PostgreSQL and ClickHouse over SSH, MySQL and PostgreSQL over sockets, EXPLAIN on both, ClickHouse socket refused, Test Connection and quitting close their tunnels |
| `ContentEditTests` | always (SQLite) / `SB_PG_VERIFY` (PostgreSQL) | a Content-tab cell edit and set-to-NULL reach the database, run the way the panel runs them (`executeWrite`) |
| `CellEditorTests` | always | the Query tab popup's rules: Save needs Edit and a change, NULL is a change, a cell that can't be edited says why |
| `InlineCellEditTests` | always | the Content tab's in-cell edit: what Return, Esc and no change do, and readable text on a selected row (it was white on white) |
| `QueryEffectsTests` | always | what a Query-tab run changes in the left panel, Sequel Ace's rules ported with its cases: `USE` (comments, quoted names), `DROP DATABASE` of the picked one, scripts in order, which statements refresh the table and database lists |
| `SoleTargetTests` | always | which connection a statement runs on: the server it names, else the one picked at the top of the left panel; none for a cross-server query |
| `WrappingHStackTests` | always | where the connection tabs wrap onto a new row, so none slides out of sight |
| `ContentBrowseTests` | `SB_MYSQL_VERIFY` | the Content tab: pages in order, a typed filter and one the server can't read, Set to NULL stores NULL |
| `ServerToolsTests` | `SB_MYSQL_VERIFY` | Test Connection (the server's reason, never the password), Kill ending a running statement, views listed as views |
| `TableListFilterTests`, `SQLCompletionTests`, `SQLHighlighterTests`, `RowCopyTests` | always | the table filter, the editor's completion and highlighting (strings, `--` `#` `/* */` comments, backticks), Copy Row's text |
| `SQLScriptTests` | always | a script split into statements as written: quotes, comments, comment-only pieces, `DELIMITER` |
| `FeatureTabShortcutTests` | always | ⌘1–⌘6 as in Sequel Ace, ⌘7–⌘9 for the rest |
| `EditorEditsTests`, `EditorCommandTests` | always | ⌘/ ⌘] ⌘[ on the caret and on selected lines, reaching the Query tab's text; the find bar |
| `SQLFileTests`, `OpenSQLTabTests` | always | .sql files: UTF-8 or Latin-1, saving, where an opened file goes, an import skipping LOCK TABLES |
| `RenameDuplicateTableTests` | always | Rename and Duplicate Table on MySQL, PostgreSQL and SQLite |
| `ResultEditingSourceTests`, `ResultEditTargetTests` | always | when a Query-tab result can be edited: one table's rows, each result column matched to a table column, the primary key in the result; the `UPDATE` keyed by the row |
| `QueryResultEditTests` | always (SQLite) / `SB_PG_VERIFY`, `SB_MYSQL_VERIFY` | a Query-tab result edit end to end: the engine's check, the `UPDATE`, read back |

The headline features — the cross-server JOIN reduction and the ClickHouse bridge — each
have a suite that proves the optimized plan returns **exactly** the same rows as the naive
plan. A reduction may only make a query faster; it may never change the answer.

> **Gotcha:** Xcode strips the `TEST_RUNNER_` prefix from env vars before the test process
> sees them. The script sets `TEST_RUNNER_SB_*`; the suites read `SB_*`. Pass them the same
> way on the command line if you run `xcodebuild` by hand.

## Fixtures

Seeded idempotently from committed SQL — no external data files, no hand-seeding:

- `scripts/fixtures/mysql.sql` — `sbtest` (`big_events` 500 tails × 400 rows, `small_fleet`
  10 ⊂ those tails, `customers`/`orders`/`order_items`), `sbwrite` (empty; write suites make
  their own tables), `sbreal.legacy_notes` (MyISAM, zero-date).
- `scripts/fixtures/postgres.sql` — `sbtest` (`big_metrics` 500 × 200, `small_fleet`,
  `customers`/`orders`/`order_items`).
- `scripts/fixtures/clickhouse.sql` — `sbtest.fleet_meta` (10 typed rows exercising
  IPv4/IPv6/UUID/DateTime64/Decimal/Int256/LowCardinality/Nullable/Array/Enum), `default.events`.

The join keys line up across engines (`N000SB`…: `small_fleet`/`fleet_meta` ⊂ `big_events`
⊂ `big_metrics`) so cross-server and bridge joins have real matches to find.

## Adding a feature — the A-to-Z checklist

1. Write the test first (or alongside) in the suite that owns the behaviour. Correctness
   tests go in a gated real-DB suite when they touch a live engine; everything else hermetic.
2. If it needs data, add it to the right `scripts/fixtures/*.sql` (keep it idempotent and
   deterministic — seeded RAND/`setseed`, fixed rows — so comparisons are stable).
3. For an optimization (a faster plan), add an **equivalence** test: optimized output ==
   naive output, row for row. That is the only thing that makes a rewrite safe to ship.
4. `scripts/run-all-tests.sh --provision` and get it green — the whole matrix, from scratch.
5. Only then merge.

## A note on production

The gated suites run against **local throwaway containers**, never production. Production
servers are read-only and some tables are billions of rows — a cross-join there
can trigger an enormous fetch. Validate cross-join and big-query behaviour here, in the
suite, against controlled fixtures; use production only for read-only spot checks.
