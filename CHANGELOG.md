# Changelog

Notable changes, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/).

## 1.2.2 — 2026-10-19

### Fixed
- On MySQL, a Query-tab statement that returns no rows runs on the server as typed, as
  in Sequel Ace, and says how many rows it changed. DuckDB used to read it first: it
  refused MySQL's own syntax (`AUTO_INCREMENT`, `UNSIGNED`, `TINYINT(1)`, backticks,
  "double-quoted" strings, `ON DUPLICATE KEY UPDATE`, `REPLACE`, `INSERT IGNORE`,
  `MODIFY`, `AFTER`, `SET @x`, `DATE_FORMAT`, `CREATE INDEX`) and changed some of what
  it accepted: a `VARCHAR(40)` column was made `TEXT`. Inside a `BEGIN` typed in the
  Query tab, these statements wait for its `COMMIT` or `ROLLBACK`. `LOCK TABLES` and
  `SET autocommit` are refused, saying why: SequelBridge's statements don't share one
  server connection, so they would stay on a connection the app reuses.
- Keyboard shortcuts could act on the wrong table or connection: a button's shortcut
  kept the action from when it was first drawn. ⌘R in the Structure tab reloaded the
  first table opened there, under the name of the table on screen; ⇧⌘R and ⌃⌘R
  refreshed the first connection shown, not the one picked. Each table and connection
  gets its own panel now, and ⌘W closes the query tab you're on (it closed another).
- Picking another database left the table from the one before open: the Content tab
  kept its rows while reads and edits went to the newly picked database. Another
  database now closes it, as in Sequel Ace.
- The Structure tab could sit on "loading" on MariaDB, and on MySQL before 8. The
  Relations tab's foreign-key lookup made the server open every table in every database
  to answer for one table, and Structure waits behind it on the same connection. The
  lookup now reads that one table's constraints: on a test server with 3,051 tables it
  opens 1 table instead of 3,104, in about 1 ms instead of 260 ms.
- Picking another database at the top of the left panel could show no tables. Each
  pick detached the connection and attached it again on its own, so two picks close
  together interleaved: the second list failed and the connection was left on the
  first database. A database that couldn't be opened left no working connection. Now
  one switch runs at a time and the last pick wins; a database that can't be opened
  says why, with Try Again, and the connection stays on the one it had. The list says
  "Loading tables…" while it loads and "No tables in …" when there are none. Found by
  a tester coming from Sequel Pro and Sequel Ace.
- `USE other_db` in the Query tab picks that database at the top of the left panel, and
  the statements after it run there; before, the next statement went back to the picked
  database. CREATE, ALTER, DROP and RENAME refresh the table list, and creating or
  dropping a database refreshes the database list; dropping the picked database goes
  back to the connection's own. These are Sequel Ace's rules.
- With several servers open, a statement that names no server (`SHOW TABLES`,
  `SELECT * FROM orders`) runs on the one picked at the top of the left panel; before,
  it was refused. Explain follows the same rule.
- A connection whose database was dropped on the server failed every statement and
  couldn't switch to another database; it switches now.
- An SSH tunnel could only log in with a key file without a passphrase: ssh ran in
  BatchMode, so a server that asked for a password, a key's passphrase or a one-time
  code from an RSA token got no answer and the login failed. Each question now opens
  a dialog with the server's own words; Remember in Keychain saves a password or a
  passphrase (never a one-time code). Cancel on a password or a code stops the login
  at once; on a key's passphrase it skips that key, as ssh does. Reported by a tester
  who logs in with an RSA token.
- Several statements run at once on a MySQL or PostgreSQL connection, such as
  `SELECT 1; SELECT 2`, failed with a syntax error: a read went to the server as one
  prepared statement. Now each statement runs in turn, as in Sequel Ace; the first
  that fails stops the run and says which it was, and `DELIMITER` works for procedure
  bodies.
- Copy as SQL INSERT turned a text value that reads NULL into a real NULL.
- Highlighting: `--` inside a string greyed out the rest of it, `#` and `/* */`
  comments weren't marked, and a backticked name such as `from` showed as a keyword.

### Changed
- The left panel's **+** sits at its top right, above the database menu's **…**, and a
  connection's engine badge (MY, PG, LITE, CH) stays on one line beside a long alias.
- The connection tabs at the top of the left panel wrap onto more rows instead of
  scrolling sideways, so with several servers open none slides out of sight. A tab's
  tooltip shows the connection's name and the database picked on it.
- The table filter ignores spaces around what you type.
- ⌘1–⌘6 switch the main tabs as in Sequel Ace (Structure, Content, Relations, Triggers,
  Table Info, Query), and ⌘7–⌘9 open Routines, Server and Console.

### Added
- In the Content tab, ⌘J jumps to a page and sets the rows a page shows (100 to 5,000,
  kept across launches); ⌘D duplicates the selected row in the row sheet, its
  auto-increment key left to the server. Both as in Sequel Ace.
- Refresh beside the database picker: ⇧⌘R re-reads the databases and tables, ⌃⌘R the
  tables, for changes made outside the app. ⌘R refreshes the Content and Structure tabs.
- Table Info shows the server's own `CREATE TABLE` on MySQL and ClickHouse, and the file's
  own on SQLite, foreign keys and options included. PostgreSQL keeps none, so it is rebuilt
  there and says so.
- Rename Table… and Duplicate Table… (with or without its rows) on a table's context menu,
  for MySQL and PostgreSQL.
- Run Current (⌘R, as in Sequel Ace) runs the statement under the cursor, or the
  selection; ⌥⌘R runs them all.
- In the editor: ⌘/ comments or uncomments the selected lines, ⌘] and ⌘[ indent and
  outdent them, and ⌘F opens the find bar.
- Open and save `.sql` files in the Query tab (⌘O, ⌘S, ⇧⌘S), and Import SQL file… in the
  database menu: the file's statements run in order, with progress and Stop, and the first
  that fails stops the import and says which. MySQL's `/*! … */` statements run; a
  pg_dump made without `--inserts` (its `COPY … FROM stdin`) is refused with that advice.
- A Sequel Ace checklist in the guide: each of its features, whether SequelBridge has it,
  and the test that proves it.

## 1.2.1 — 2026-10-19

### Fixed
- macOS 15: the left panel's connection tabs and its **+**, and the query tab bar's tabs
  and **+**, did nothing when clicked. Both strips are scroll views at the top of their
  pane; on macOS 15 a scroll view touching the window's top edge grows up under the
  toolbar, and its buttons draw in place but stop taking clicks. macOS 26 was not
  affected. Found by a tester on an Apple Silicon Mac, reproduced and verified on macOS
  15 by the new UI tests.
- macOS 15: a grid showing a NULL value could crash the app.
- A query tab takes a click anywhere on it, not only on its title.

### Added
- UI tests that click the workspace's tab strips and **+** buttons, run on GitHub's
  Apple Silicon machines with macOS 15 and 26 for every change.

## 1.2.0 — 2026-10-13

### Added
- Cross-server joins stream server to server: the smaller side's keys filter the bigger
  side on its own server, the server's own EXPLAIN decides between a key list and the
  whole table, and both sides stream through the join as they arrive. Works for
  `JOIN … ON` and the comma form, and for a SQLite file on one side.
- WHERE conditions a server can be trusted with are pushed to it; the statement is bound
  against the table shapes before any row is fetched.
- ClickHouse joins are planned like every other cross-server join (the ClickHouse side
  is copied, reduced to the other side's keys when it is the bigger one); `Enum8`/`Enum16`
  conditions are pushed.
- A statement naming only the ClickHouse server runs on its native client even when
  other servers are connected.
- Query-tab results can be edited: a double-click opens the value in a popup with Copy,
  Cancel, Edit and Save, and Save writes it when the result is one table's rows with
  that table's primary key in it (Sequel Ace's rule). Otherwise the popup says why.
- Results stream out of DuckDB as they are produced, into a compact columnar store; no
  row cap. A typed `EXPLAIN …` takes the Explain button's path on MySQL and PostgreSQL.
- A collapsible note above the editor explains how queries are written for the servers
  you have open.
- Demo and screenshot instances: `-SBConnectionsFile` (a fixture connection list with
  inline passwords) and `-SBSupportDir` (their own history and saved queries).
- The README and the guide (`guide/`), with screenshots regenerated by
  `scripts/capture-screenshots.sh` on synthetic data.

### Fixed
- Content-tab edits work in the cell, as in Sequel Ace: Return or a click elsewhere
  saves, Esc cancels. The text being typed was drawn white on the editor's white
  background, and a save the server refused failed silently while the cell kept the
  typed text; now the old value comes back with the server's message, and Edit Again
  or Discard. A cell that can't be edited says why.
- A cell edit, insert or delete on a connection marked read-only is refused; the
  Content tab's writes used a path without the read-only check.
- MySQL 8 and later: EXPLAIN works, table and database dumps keep the server's own
  `CREATE TABLE` with its foreign keys, and the join planner gets the server's row
  estimates again. The app's own MySQL client, which runs those statements, now logs in
  with `caching_sha2_password` (the MySQL 8 default) and follows a server's request to
  switch login methods; before, it spoke only `mysql_native_password`.
- **Use SSL** works. On MySQL the option was sent in a form DuckDB's driver doesn't
  read, so every connection with it ticked failed with "Connection query failed";
  PostgreSQL ignored it. It now makes both require an encrypted session.
- A failed connection says why, in the server's words (a wrong password, SSL required
  but not offered), instead of "Connection query failed". The drivers' messages carry
  the connection string with the password; the app removes both before showing or
  logging a message.
- The app's own MySQL client no longer waits forever when a server refuses the
  connection, or on a connection with Use SSL: it fails at once and says why.
- SSH connects to old servers that offer only the `ssh-rsa` host key type, which
  current macOS `ssh` refuses by default ("no matching host key type found").
- ClickHouse connections use their SSH tunnel; before, an SSH ClickHouse connection
  went straight to the server address. A ClickHouse socket, which cannot work over
  HTTP, is no longer offered.
- PostgreSQL connects over a Unix socket, given as the directory or the socket file.
- EXPLAIN works on MySQL connections over a Unix socket.
- A ClickHouse server reached by host name over plain HTTP connects; App Transport
  Security used to refuse it.
- SSH tunnels close when the app quits instead of running on in the background.
- A SQLite connection no longer needs a stored password to connect.
- PostgreSQL row estimates for tables never analyzed fall back to the live count, so
  the join planner picks the right side.
- Query time in the toolbar and the status bar come from one clock.
- A re-saved connection password persists even when the Keychain item cannot be updated.

### Changed
- Cancel is described honestly: it stops the app's work, not a statement a server is
  already running.

## 1.1.0 — 2026-10-07

- DuckDB upgraded from 1.1 to 1.5.6, linked statically from vendored libraries with a
  streaming result type and bulk column readers (see `vendor/DuckDB/README.md`).
- Server-side table metadata and statistics, faster on large schemas.
- Removed the ER diagram, schema diff, Content-tab paste-rows and column statistics to
  keep the app focused.
- Zero compiler warnings in the app and the tests; the full local suite green.
