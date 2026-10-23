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
at them, and runs all 855 tests in 172 suites (about three minutes of tests after the build).
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
at one of them. `--arch x86_64` builds and tests for Intel (under Rosetta on Apple
Silicon); the database suites have run on Intel only so far. PostgreSQL 16 runs twice: `sb-postgres` (5433) without SSL, and
`sb-postgres-ssl` (5434) with it, on the image's own snakeoil certificate. MariaDB 10.0
also holds `sbbig`, 3,275 MyISAM tables the size of a real production database
(`scripts/fixtures/bigschema.py`), for timing a Content edit against it.

Besides the database containers, the script runs an SSH server container (`sb-sshd`,
`scripts/fixtures/ssh/sshd-setup.sh`) with a throwaway test key in `.build/ssh/`: port
2224 with today's defaults, port 2225 behaving like an old server that offers only
`ssh-rsa` (run as sshd's PAM build, with an account that logs in with a one-time code
from google-authenticator's module). The app's tunnel accepts each server's host key into your
`~/.ssh/known_hosts` once, as it would for any server; the host keys are generated
once and kept, so those entries stay valid. For socket connections it relays MariaDB
and PostgreSQL to Unix sockets in `/tmp/sb-sock` while the tests run
(`scripts/fixtures/socket-relay.py`).

On GitHub, every push to `main` and every pull request builds the app on Apple Silicon,
on macOS 15 and macOS 26 (`.github/workflows/test.yml`), and runs the tests that need no
database server, then the UI tests (`SequelBridgeUITests`, scheme `SequelBridgeUITests`).
A third job builds the app on macOS 15 and starts it on macOS 14, the oldest macOS it
supports (`scripts/launch-smoke.sh`: it starts, shows its window and stays up), since
Xcode 26, which the app needs, doesn't run on macOS 14.
The UI tests click the workspace's tab strips and + buttons, check that six connection
tabs all stay on screen with the + above the database menu, run a statement that names
no server on the active tab, and close the active query tab with ⌘W.
`MySQLWorkflowUITests` walks the everyday flows on a MariaDB the job installs with
Homebrew and seeds from `scripts/fixtures/mysql.sql`: pick a database, `USE`, several
statements, Run Current, filter tables, edit a cell in place and set it to NULL, rename
and duplicate a table, ⌘/, Table Info's `CREATE TABLE`, ⌘1–⌘6, the Console, MySQL's
own syntax run as typed, ⌘R on the table on screen after another was opened, and the
Content tab's ⌘J (page and rows per page), ⌘D (duplicate a row), its column-operator-value filter, and following a foreign key, a saved query loaded back into a tab, Add Database with an encoding and Delete Database, Table Maintenance's answer, `SHOW CREATE TABLE` and `SHOW FULL PROCESSLIST` typed in the Query tab.
`PostgresWorkflowUITests` (with `SB_UI_PG_PORT`) picks a schema, shows Content and
Structure, Explain's plan and a typed `SHOW`, edits a cell in place, edits a result in
another schema in its popup, and runs the statement under the caret past a `#>>`;
`PostgresWorkflowOverSSHUITests` and `PostgresWorkflowOverSocketUITests` do it all again
through the SSH tunnel and a Unix socket (`SB_UI_PG_SOCKET_DIR`);
`ClickHouseWorkflowUITests` (with `SB_UI_CH_PORT`) shows Content and why a cell can't be
edited there, runs a query and finds it in the Server tab's insights, and
`ClickHouseWorkflowOverSSHUITests` does it through the tunnel;
`SSHLoginUITests` (with `SB_UI_SSH_KEY`) types a one-time code and a password straight
into the login dialog, without clicking its field; `MySQLActionsUITests` deletes rows,
adds a row, truncates and drops a table, drops a foreign key and a trigger (each asks
first, Cancel keeps it), adds a column in Structure (Save, then Revert of an unsaved
one), adds an index, a foreign key and a trigger through their sheets, edits a result
cell in its popup, makes a table with Create Table, stops a long query, and leaves the
database picked when a script fails before its `USE`;
`MySQLActionsOverSSHUITests` and `MySQLActionsOverSocketUITests` (`SB_UI_MYSQL_SOCKET`)
do it all again through the SSH tunnel and a Unix socket; `WorkspaceServersUITests` adds a server with + and
checks that New Connection… then Cancel opens none; `HomeFavoritesUITests` removes a
favorite, asked first; `HomeConnectionSheetUITests` adds a connection with New
Connection (Cancel adds none), edits one and connects from its sheet;
`SSHHostKeyUITests` (with `SB_UI_SSH_KEY`, the test SSH server's key) connects through
SSH to a server met for the first time (its fingerprint shown, Cancel, then Trust and
Connect) and to one whose key changed (the plain message, Forget the Old Key refused
then confirmed, from Home and from Test Connection). On GitHub none of the three has a
server, so they are skipped there;
`MySQLRefreshUITests` refreshes one connection after a change through another, by
the button, by ⇧⌘R and by ⌃⌘R, and checks ⌘R (the statement under the cursor) against
⌥⌘R (all). `UpdatesUITests` finds **Check for Updates…** in the SequelBridge menu and
Settings → Updates (both off in a copy launched for the tests); `HelpMenuUITests` finds
the Help menu's eight items, opens Settings on its Shortcuts tab from **Keyboard
Shortcuts** and the licenses' window from **Acknowledgements**. `VisualTourUITests` takes a screenshot of every screen and sheet in light and
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
the built-in drivers, the acknowledgements, sort order, write-path SQL, panel logic, stores, the
query-conventions note, the demo fixture store, the App Store build's grants and sandbox
hooks, the privacy manifest. Together with the gated suites below: 855 tests across 130
files.

**Gated real-DB suites** (run by the script against seeded containers):

| Suite | Gate | Covers |
|---|---|---|
| `MySQLCorpusTests`, `PostgresCorpusTests`, `ClickHouseCorpusTests`, `SQLiteCorpusTests` | `SB_MYSQL_VERIFY` (on each MySQL-family server), `SB_PG_VERIFY`, `SB_CH_VERIFY`, always (SQLite) | the query corpus: some 200 statements per engine run the way the Query tab runs them (QueryRoute, then its engine call): reads and writes, DDL of every object, joins, subqueries, CTEs, window functions, transactions, variables and temporary tables in a script, SHOW/DESCRIBE/EXPLAIN, procedures, functions, triggers and events (with and without `DELIMITER`), each engine's own syntax and types (MySQL's mysqldump file, zero dates, `FOUND_ROWS()`, full-text and spatial, optimizer hints, MariaDB's `BEGIN NOT ATOMIC`; PostgreSQL arrays, jsonb, $$ and `BEGIN ATOMIC` bodies, `MERGE`, `COPY`, an extension, VACUUM; ClickHouse arrays, FINAL, mutations; SQLite functions, PRAGMA, upserts, RETURNING, FTS5, generated columns, STRICT, and syntax newer than DuckDB's SQLite), odd names and values, and the errors; MySQL and PostgreSQL over TCP/IP, SSH and the socket, ClickHouse over TCP/IP and SSH. With `SB_CORPUS_REPORT` set, every statement's outcome is written there |
| `MySQLIntegrationTests` | `SB_MYSQL_VERIFY` | live MySQL/MariaDB attach, query, metadata, FK relations; Import SQL file, a mysqldump file whole on one connection (a table that refers ahead, the settings put back) |
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
| `PostgresNativeTests`, `PostgresNativeSSLTests` | `SB_PG_VERIFY`, `SB_PG_SSL_PORT` | PostgreSQL's own client on a real server: the Explain button's plan, a typed `SHOW` in the schema picked (the role's own `search_path` after it), a server error's message, a read-only session, a Unix socket, `COPY … TO STDOUT`'s rows and `COPY … FROM STDIN` refused at once, a schema picked by a role whose own `search_path` is empty; over SSL with Use SSL and without it (encrypted when the server offers it, as libpq does), and Use SSL refused against a server without SSL before any password is sent; a statement longer than the 10 s a connect may take still comes back, and Cancel ends one at once |
| `MySQLNativeStatementTests` | `SB_MYSQL_VERIFY` | `SHOW CREATE TABLE`, `SHOW FULL PROCESSLIST`, `SHOW GRANTS`, `SHOW WARNINGS`, `CHECK TABLE`, `CHECKSUM TABLE` typed in the Query tab, on the app's own client, in the database picked (on all four MySQL-family servers) |
| `PostgresWorkspaceTests` | `SB_PG_VERIFY` | what the guide promises for PostgreSQL, the way the panels run it: Import SQL file of a pg_dump file on one connection, the picker's schemas and their tables (the connection stays on its database), Content's filter and sort, following a foreign key, Routines, the Server tab and Kill ending a running statement, export, CSV import, a row added with its serial key left to the server and deleted, triggers listed and dropped |
| `SQLitePromisesTests` | always | what the guide promises for a SQLite file, on one: Create Table (the types picked, an integer key that numbers rows), Structure's add, rename and drop of columns and indexes and its refusals, Content, following a foreign key, export, triggers added, fired, listed (timing and event from the header, not the body) and dropped, a busy file |
| `DatabaseDumpTests` | `SB_MYSQL_VERIFY` | whole-database SQL dump (all tables, schema + data) |
| `PostgresTests` | `SB_PG_VERIFY` | PostgreSQL attach, query, joins |
| `CrossEngineBenchmark` | `SB_BENCH` | timing (not correctness) for the MySQL×Postgres JOIN |
| `SSHTunnelTests` | always (ports, arguments) / `SB_SSH_VERIFY` (tunnels) | port allocation, failure paths, MySQL through the tunnel on a current and an `ssh-rsa`-only server; the login prompts on a real ssh: a password (`pwuser`), a key with a passphrase, a one-time code from google-authenticator's PAM module answered with the TOTP an authenticator app shows (`otpuser`), Cancel stopping at once, a wrong password asked three times; a key in a private ssh-agent with no key file set; a server met for the first time asks to be trusted (trusted: remembered; not: stopped at once, nothing remembered), a changed key stops the login and is read out of ssh's warning, and once forgotten the confirmed new key connects unasked, from Test Connection and Connect too; each on a known-hosts file of its own; switching a MySQL connection's database keeps its tunnel (ssh asks once, not at every pick); a dropped tunnel is reported and Reconnect brings it back, as does picking another database; no ControlMaster sharing; an IPv6 database host bracketed in the forward |
| `SSHLoginTests` | always | what ssh asks (password, passphrase, one-time code, also one that calls itself a "One-time password", while ssh's own `user@host's password:` stays a password whatever the host is called, whether to trust a new server's key, in older and newer OpenSSH's wording), a changed key read out of ssh's warning (the host, the key sent, the line holding the old one), when a saved answer is used, and the askpass script's round trip to the app: the answer back, a wrong token refused, Cancel failing the attempt |
| `PostgresScannerCacheTests`, `MySQLScannerCacheTests` | `SB_PG_VERIFY`, `SB_MYSQL_VERIFY` | a Content edit of a table made after DuckDB read the server's catalog: a schema and table made in the app on PostgreSQL, and a table another connection made on either server, once the app lists it |
| `MySQLRowWriteSQLTests`, `ResultEditingPickedConnectionTests` | always | a Content or result edit in MySQL's own SQL (true and false as 1 and 0 for TINYINT(1) and BIT, a BIT as a number, backslashes escaped, NULL and CURRENT_TIMESTAMP as the row sheet means them); a result edited on the connection picked in the left panel when two are open |
| `MySQLRowWriteTests` | `SB_MYSQL_VERIFY` (`SB_MYSQL_BIG_DB` for the last) | those writes on the real servers, each type stored as meant, a row added with its key left to the server and deleted; an edit on a database of 3,275 tables (`sbbig`, MariaDB 10.0) done in under 2 s, where DuckDB took 16 |
| `BuiltInDriversTests` | always | the MySQL, PostgreSQL and SQLite drivers are built in and loaded when DuckDB starts; DuckDB installs nothing (auto-install off, its extension folder the app's own, still empty after a SQLite file is attached) and loads no unsigned extension; the app keeps library validation; `sqlite_attach` typed in DuckDB runs again and again (two drivers' types of one name shared one vtable: `scripts/check-driver-symbols.sh` now stops the DuckDB build on such a name) |
| `AcknowledgementsTests` | always | Help → Acknowledgements: every component built into the app is named with its license, and so is each library in DuckDB's source (ICU, Thrift…) with an Apache NOTICE where one comes with it; MariaDB Connector/C's LGPL section says where its source is and how to relink it, and the window shows the whole file, to read and copy, not to edit |
| `ClickHouseContentTests` | `SB_CH_VERIFY` | ClickHouse's Content tab on the real server: pages sorted and paged, every filter operator on a number column with its value quoted, and a `%`, `_` or backslash matching as itself |
| `QueryRouteTests` | always | which path a Query-tab statement takes (QueryRoute): refused on a read-only target only, Explain's path, USE and SET search_path (quoted, folded, not DEFAULT or a list), as typed, the app's own client, ClickHouse, the passthrough, SQLite itself, DuckDB's catalog; one server named among several; inside a Query-tab transaction nothing runs on a connection of its own (a `SET` joins it, a `CALL` is refused there, a PostgreSQL read in another schema joins it too, the schema first on the transaction's `search_path`); a script that leaves a transaction open isn't run on one that closes; MariaDB's `BEGIN NOT ATOMIC` opens no transaction; MySQL 8's `WITH … DELETE` runs as typed, a `WITH` whose strings or names say DELETE reads |
| `DefaultContextTests` | always | DuckDB's one default database follows the connection a statement is for, after another connection's statement or a detach |
| `ConnectionLifecycleTests` | always | a Connect that fails part-way leaves none of its connections attached; a server added in the workspace closes with the next Connect from Home; saving a SQLite connection writes nothing to the Keychain |
| `HelpLinksTests` | always | where the Help menu and the About window point: the guide's pages (which must exist in the repo), the releases, the issue form, the website and the source; the About window's credits link the website and GitHub, in the window's own text color |
| `AppUpdaterTests` | always | the updater (Sparkle): not started in a test run, a copy launched with files of its own (UI tests, screenshots) or a Debug build, unless `-SBUpdateFeed` names a feed; Info.plist's feed on GitHub Releases and its Ed25519 update key |
| `DistributionTests` | always | which build this is: the unit tests run in the DMG build; the App Store build offers no socket or ssh-agent and needs grants |
| `PathsTests` | always | `~` in a typed key path or SQLite file is the user's home, from the user database, not `$HOME` (the sandbox points it at the container) |
| `SSHAskpassHelperTests` | always | the askpass helper is in the app, executable, and nothing is written at run time; run as ssh runs it, it asks the app the question and prints the app's answer |
| `GrantsTests` | always | what the user let the App Store build reach: a granted folder covers what it holds and nothing else, grants kept for the next launch, a moved, renamed or deleted folder forgotten (and asked for again), a folder other than the one asked for doesn't meet the need, a folder reached through a symbolic link is that folder, `~`; SSH gets `~/.ssh` itself when a folder holding it is granted, a folder of the app's own on a Mac without `~/.ssh` (nothing asked), and the folder picked when asked |
| `SSHSandboxTests` | always | SSH in the App Store build: ssh reads the granted folder's config (or none) and known_hosts and never asks ssh-agent; a test's own known_hosts still wins; no `~/.ssh` granted, or a key ssh can't read, stops before ssh runs, saying which; a key that isn't there says so and isn't asked for; a config ssh refuses gives ssh's own reason |
| `SQLiteSandboxTests` | always | a SQLite file in the App Store build: with no folder granted the connection says which and why and nothing is attached; a file that isn't there (moved, renamed) says so and no folder is asked for; with the folder granted, the file is opened and written |
| `SocketSandboxTests` | always | the App Store build's form offers no socket, and a socket connection that reaches it is refused, saying to use TCP/IP to 127.0.0.1; the DMG build's offers them |
| `PrivacyManifestTests` | always | the privacy manifest Apple requires: no tracking, nothing collected, a reason for each kind of required-reason API the app calls (DuckDB included) |
| `ReadFallbackTests` | always | where a Query-tab read that failed through DuckDB runs again: two columns of one name and a value the MySQL driver can't convert on the app's own client, SQLite newer than DuckDB's in macOS's `sqlite3`; never a read the user stopped, nor one inside a Query-tab transaction |
| `SQLiteToolScriptTests` | always | `sqlite3` reading a script on its standard input: a big script that fails early says which statement, and the app stays up; it runs without copying its log records to stderr (a run from Xcode or a test), where macOS 15's sqlite3 logged each error |
| `RelationsTableLayoutTests` | always | the Relations table in a pane narrower than its columns (the window a 1024×768 screen opens): it takes no more width than the pane has and scrolls, and its name column fits the longest name |
| `ContentPagingTests` | always | Content's pages, duplicating a row, and on MySQL its dates read as the server keeps them (invisible columns left out) and sorted on the table's own column |
| `ConnectionTypeTests` | always (what each engine offers) / `SB_SSH_VERIFY`, `SB_SOCKET_VERIFY` | every engine × connection type: PostgreSQL and ClickHouse over SSH, MySQL and PostgreSQL over sockets, EXPLAIN on both, ClickHouse socket refused, Test Connection and quitting close their tunnels |
| `ContentEditTests` | always (SQLite) / `SB_PG_VERIFY` (PostgreSQL) | a Content-tab cell edit and set-to-NULL reach the database, run the way the panel runs them (`executeWrite`) |
| `CellEditorTests` | always | the Query tab popup's rules: Save needs Edit and a change, NULL is a change, a cell that can't be edited says why |
| `InlineCellEditTests` | always | the Content tab's in-cell edit: what Return, Esc and no change do, and readable text on a selected row (it was white on white) |
| `QueryEffectsTests` | always | what a Query-tab run changes in the left panel, Sequel Ace's rules ported with its cases: `USE` (comments, quoted names), `DROP DATABASE` of the picked one, scripts in order, which statements refresh the table and database lists; whether a script needs one connection (an `@` in a string or a quoted name is no variable) and leaves a transaction open (`SET autocommit = 0` opens one, `ROLLBACK TO` a savepoint ends none, `AND CHAIN` opens the next) |
| `SoleTargetTests` | always | which connection a statement runs on: the server it names, else the one picked at the top of the left panel; none for a cross-server query |
| `WrappingHStackTests` | always | where the connection tabs wrap onto a new row, so none slides out of sight |
| `ContentBrowseTests` | `SB_MYSQL_VERIFY` | the Content tab: pages in order, a typed filter and one the server can't read, Set to NULL stores NULL, zero dates and a zero month or day shown as the server keeps them |
| `ServerToolsTests` | `SB_MYSQL_VERIFY` | Test Connection (the server's reason, never the password), Kill ending a running statement, views listed as views |
| `TableListFilterTests`, `SQLCompletionTests`, `SQLHighlighterTests`, `RowCopyTests` | always | the table filter, the editor's completion and highlighting (strings, `--` `#` `/* */` comments, backticks), Copy Row's text |
| `SQLScriptTests` | always | a script split into statements as written: quotes, comments, comment-only pieces, `DELIMITER`, `$$` bodies, `#` and `--` by engine, `DELIMITER $$` against a name or an `END`, a `BEGIN … END` body (trigger, routine, `ALTER EVENT`, `BEGIN ATOMIC`, `BEGIN NOT ATOMIC`) kept whole while a transaction's `BEGIN` still ends at its `;`, not fooled by `@end`, a column or parameter called end/begin, or a `CASE … END`; Run Current's statement by engine |
| `StatementTextTests` | always | a statement's text before it is sent: `--` comments made `/* */` for PostgreSQL's passthrough (nested comments and `E'…'` strings kept), ClickHouse's own `FORMAT` told from a column called format, `sqlite3`'s JSON reals as SQLite shows them |
| `FeatureTabShortcutTests` | always | ⌘1–⌘6 as in Sequel Ace, ⌘7–⌘9 for the rest |
| `EditorEditsTests`, `EditorCommandTests` | always | ⌘/ ⌘] ⌘[ on the caret and on selected lines, reaching the Query tab's text; the find bar |
| `SQLFileTests`, `OpenSQLTabTests` | always | .sql files: UTF-8 or Latin-1, saving, where an opened file goes, an import skipping LOCK TABLES and psql's `\restrict` and `\connect` lines |
| `RenameDuplicateTableTests` | always | Rename and Duplicate Table on MySQL, PostgreSQL and SQLite |
| `ResultEditingSourceTests`, `ResultEditTargetTests` | always | when a Query-tab result can be edited: one table's rows, each result column matched to a table column, the primary key in the result; the `UPDATE` keyed by the row |
| `QueryResultEditTests` | always (SQLite) / `SB_PG_VERIFY`, `SB_MYSQL_VERIFY` | a Query-tab result edit end to end: the engine's check, the `UPDATE`, read back |

**Releases and updates.** `scripts/test-release-feed.sh` (run by `run-all-tests.sh`)
checks the files a release writes beside its DMG: the update feed (`appcast.xml`: build
and version, the oldest macOS, the download and its signature, the release notes from
this file's section) and the Homebrew cask. `scripts/acknowledgements.py --check` (run by
`run-all-tests.sh`, `build-release.sh` and CI) fails when `Acknowledgements.txt` isn't
what the installed DuckDB package's license files give. `scripts/test-update-e2e.sh APP` (run by
`build-release.sh` on the build it is releasing) updates an older copy of the app to a
newer one through Sparkle, headless, from a feed on 127.0.0.1, and checks that an update
whose file doesn't match its signature is refused; it uses a throwaway key and a test
bundle id, never the release key or the app's own settings.

**The App Store build.** `scripts/test-appstore-build.sh` (run by `run-all-tests.sh` and
CI) builds the `SequelBridgeAppStore` target and checks what it made: sandboxed, with the
App Store entitlements and no exception; no Sparkle (framework, code or Info.plist keys);
the App Store Info.plist keys; macOS 14; the privacy manifest; and the DMG build still
with Sparkle. `scripts/check-appstore-sandbox.sh` (run by `run-all-tests.sh` without
`--hermetic`, against the test SSH server; with `--ci` and an sshd of its own on CI) runs
it truly sandboxed: built under a bundle id of its own, it is opened with an `~/.ssh`
stand-in (reached through a symbolic link, as a symlinked `~/.ssh` is) and a folder
holding a SQLite file, which grants them as an open panel would, and runs its own code
there, on those paths only (`-SBSandboxCheck`; never the user's own `~/.ssh`): a key login
and a passphrase key answered through the shipped askpass helper, through to the server,
with the server's key remembered in the granted folder; a SQLite write by DuckDB and by
macOS's `sqlite3`; no socket offered; no Sparkle. A second launch does it all again from
the saved grants alone, and the container is removed after. `test-appstore-build.sh` also
checks that both builds carry one version and build number, which
`scripts/project-version.sh` (run by `build-release.sh`) requires of every target.

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
