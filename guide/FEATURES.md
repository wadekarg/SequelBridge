# Features

What SequelBridge does, organized by what you are trying to do. Every claim here
describes the app as it is; the table below says what works on which engine. The
rules a query follows are in [QUERYING.md](QUERYING.md), and how it all works inside
is in [ARCHITECTURE.md](ARCHITECTURE.md).

Screenshots come from a demo instance on synthetic data.

## What works where

| | MySQL / MariaDB | PostgreSQL | SQLite file | ClickHouse |
|---|:-:|:-:|:-:|:-:|
| Connect over TCP/IP | ✓ | ✓ | file | ✓ (HTTP) |
| Connect over a socket | ✓ | ✓ | | |
| Connect through an SSH tunnel | ✓ | ✓ | | ✓ |
| Read-only mode | ✓ | ✓ | ✓ | ✓ |
| Browse tables, Structure, Table Info | ✓ | ✓ | ✓ | ✓ |
| Content: browse, filter, sort | ✓ | ✓ | ✓ | ✓ |
| Content: edit, insert, delete rows | ✓ | ✓ | ✓ | |
| Query results: edit values | ✓ | ✓ | ✓ | |
| Add columns and indexes, Create Table | ✓ | ✓ | ✓ | type the `ALTER`/`CREATE` in the Query tab |
| Relations (foreign keys) | ✓ | ✓ | ✓ | |
| Triggers | ✓ | list, drop | ✓ | |
| Routines | ✓ | ✓ | | |
| Server: processes with Kill, variables, status | ✓ | ✓ | | |
| Server: query insights from the query log | | | | ✓ |
| Explain button, typed `EXPLAIN` on the server | ✓ | ✓ | | typed only |
| Export database as SQL | ✓ | ✓ | ✓ | |
| Export one table as SQL | ✓ | | | |
| Import CSV into an existing table | ✓ | ✓ | | |
| Import CSV into a new table | ✓ | | | |
| One side of a cross-server join | ✓ | ✓ | ✓ (probe side) | ✓ (copied) |
| Follow a foreign key from Content | ✓ | ✓ | ✓ | |
| Add and delete a database | ✓ | | | |
| Table Maintenance | ✓ | | | |
| Results: streaming grid, filter, charts, export | ✓ | ✓ | ✓ | ✓ |

Row editing needs a primary key on the table; a query result is edited when it is one
table's rows with that key in it. A typed `EXPLAIN` on a SQLite file shows DuckDB's plan.

## Connecting

![Home](images/home.png)

Home lists your saved connections. Tick one or more and press **Connect**: they open
together in one workspace, which is what lets a query name tables from several of
them. Each connection has a name, an alias (the prefix you use in queries), a colour
that follows it through the workspace, and an optional folder that groups the list.

A connection is TCP/IP, a local socket or an SSH tunnel; a SQLite connection is just
the file. The form offers only what the engine supports: ClickHouse, reached over
HTTP, has no socket. For a socket, MySQL takes the socket file and PostgreSQL its
directory, or the `.s.PGSQL.<port>` file itself. An SSH tunnel logs in with your key
file, also on old servers that only offer the `ssh-rsa` key type, or, with no key file
set, with the keys in your ssh-agent and `~/.ssh`, as ssh does in Terminal. It closes
when you disconnect or quit the app. When the SSH server asks for something (a password, the
key's passphrase, or a one-time code from an RSA token or an authenticator app), a
dialog shows its question; **Remember in Keychain** saves a password or passphrase,
never a one-time code. A server met for the first time shows its key's fingerprint and
asks to be trusted. If a server's key has changed, the connection stops before anything
is sent and says so; **Forget the Old Key and Connect…** removes the old key once you
have confirmed the new one. When a tunnel closes on its own (the Mac slept, the network
dropped), the workspace says so and offers **Reconnect**. **Test Connection** on the form tries the connection,
tunnel included, before saving. Passwords go into your Keychain, never into the
connection file. A failed connection says why, in the server's words: a wrong
password, an unknown host, SSL required but not offered.

**Use SSL** makes a MySQL or PostgreSQL connection require an encrypted session, and
fail if the server doesn't offer one; the server's certificate isn't checked. It is on
the SSH form too, for an SSL-only server (Amazon RDS, Azure) behind an SSH server. Without
it the connection is still encrypted when the server offers TLS, as MySQL 8 does by
default. On ClickHouse it switches to HTTPS. The app's own MySQL client, which runs
EXPLAIN, reads a table's `CREATE TABLE` and runs Table Maintenance, follows Use SSL the
same way.

**Read-only (safe mode)** is a switch on the form. It shows as a badge on Home, and
from then on the engine refuses every write against that connection: typed statements,
cell edits, column DDL, imports, Kill, an `EXPLAIN ANALYZE` of a write (which runs it).
Below that, DuckDB attaches the connection read-only and the server's own session is
read-only (ClickHouse's `readonly=2`), so even a stored function a `SELECT` calls can't
write. While a read-only connection is open in a workspace, a typed statement that
writes is refused whichever server it names. Use it for production servers.

## Finding your way around

![Workspace](images/hero.png)

The sidebar has one tab per connected server, a database picker, a filter box for the
table list with a **+** beside it that creates a table, and a strip at the bottom with
the selected table's rows, data and index size, engine, collation and timestamps. The
"…" button beside the picker holds the database-level actions: on MySQL, **Add
Database…** (a name, and an encoding and collation from the server's lists, each
starting at its default) and **Delete Database…**, which asks first; export as SQL;
**Import SQL file…** on MySQL and PostgreSQL; on MySQL, import a CSV into a new table.
A table's context menu has the table-level ones: `SELECT *` and copy name; on MySQL and
PostgreSQL, import a CSV, **Rename Table…**, **Duplicate Table…** (with or without its
rows), Truncate and Drop; and on MySQL, export as SQL and **Table Maintenance**:
Analyze, Check, Optimize, Repair, Flush and Checksum, each showing the server's answer.

Picking a database lists its tables; one that can't be opened says why, with
**Try Again**, and the connection stays on the database it had. Another database closes
the table open from the one before. The ↻ beside the picker re-reads the databases and
the picked one's tables (⇧⌘R), or the tables alone (⌃⌘R), for changes made outside the
app.

The toolbar tabs switch the main area: **Structure, Content, Relations, Triggers,
Table Info** for the selected table; **Routines, Server, Query, Console** for the
connection. Clicking a table in the sidebar inserts its name at the cursor in the
editor; double-clicking opens `SELECT * … LIMIT 200` in a new query tab.

## Looking at a table

![Structure](images/structure.png)

**Structure** lists the columns with type, length, nullability, key and default, and
the table's indexes. Add a column or an index from here; the DDL is written in the
server's dialect and shown in the Console. A generated column can't be changed here,
since its expression isn't shown: change it with `ALTER TABLE` in the Query tab. On a
SQLite file, Structure adds, renames and drops columns and adds and drops indexes, run
by SQLite itself; changing a column's type, NULL or default says why it can't: SQLite
would need the table made again. Create Table there makes the types you pick, and a
single integer key numbers new rows itself.

![Content](images/content.png)

**Content** is a paginated browser of the rows. ⌘J jumps to a page and sets the rows a
page shows (100 to 5,000, kept across launches). **Filter** picks a column, an operator
(=, ≠, <, >, ≤, ≥, contains, doesn't contain, begins with, ends with, is in, between,
is NULL, isn't NULL) and a value, as in Sequel Ace; a `%`, `_`, quote or backslash in
the value matches as itself. **Type WHERE** shows the rule as SQL, to adjust or
replace. Click a column header to sort, which reruns the page on the server with an
`ORDER BY`. A cell of a foreign key's column leads to the row it points at:
its right-click menu has **Go to customers where id = 2**, which opens that table's
Content tab filtered to the row.

Double-click a cell to edit it in place, as in Sequel Ace. Type the new value, then
press Return or click elsewhere to save it to the server; Esc leaves it as it was. If
the server refuses the value, the old one comes back and the server's message is shown,
with **Edit Again** to fix the value or **Discard**. **Set to NULL** is on the cell's
right-click menu. A cell that can't be edited says why instead: the connection is
read-only, the table has no primary key, or it is ClickHouse, where a row write is an
asynchronous table mutation. Rows can also be inserted and deleted, on the same terms;
deleting asks first, saying how many rows go.
⌘D duplicates the selected row: the copy opens in the row sheet without what the server
fills in itself (an auto-increment key), and each empty field says what it will get (a
default, NULL, the server's own number) or that it is required.

**Relations** shows the table's foreign keys: the referencing column, the table and
column it points to, the ON DELETE and ON UPDATE rules, the constraint name.
**Triggers** shows timing, event and body; **+** adds one and **−** drops the selected
one. On PostgreSQL a trigger runs a trigger function that has to exist first, so one is
added in the Query tab. **Table Info** shows the storage engine, row
estimate, sizes, collation, comment, timestamps and the `CREATE TABLE` statement.
**Routines** lists the database's stored procedures and functions with their
definitions.

## Running a query on one server

The editor highlights SQL and completes table and column names as you type (switch
it off in Settings); ⌘/ comments lines, ⌘] and ⌘[ indent them, ⌘F finds, and ⌘O and
⌘S open and save `.sql` files. **Run** (⌘↵) streams the result into the grid; select
part of the text to run only that. **Run Current** (⌘R) runs the statement under the
cursor, as in Sequel Ace; ⌥⌘R runs them all, one after another. **Cancel** stops the app's work on the query; a statement a
server is already running finishes there on its own. **Format** tidies the statement.
**Explain** shows the server's own plan for a statement that names one MySQL or
PostgreSQL server, and typing `EXPLAIN …` does the same there; on ClickHouse a typed
`EXPLAIN` runs as a normal statement, and on a SQLite file it shows DuckDB's plan.

The bookmark button saves the statement under a name for later, and its Recent list
holds the statements you ran, kept across restarts.

A statement that names one server runs on that server in that server's own SQL, as if
you had typed it into the server's own client. `SHOW CREATE TABLE`, `SHOW PROCESSLIST`,
`SHOW GRANTS`, `HELP` and `CHECK TABLE`, which MySQL won't run through DuckDB, go to the
app's own MySQL client, and PostgreSQL's `SHOW` and `EXPLAIN` to its own PostgreSQL client. On MySQL and PostgreSQL a statement that
returns no rows (a write, DDL) is sent exactly as typed; on MySQL the result says how
many rows it changed, on PostgreSQL it says Done or shows `RETURNING`'s rows. A script
whose statements share what each sets (`SET @d = …; SELECT … WHERE d > @d`, a
temporary table, `PREPARE` and `EXECUTE`, `LOCK TABLES … UNLOCK TABLES`) runs on one
connection, as in Sequel Ace; on its own, a `SET` says it lasts for its run, and
`LOCK TABLES` and `SET autocommit` are refused, saying why. A `BEGIN` typed in the Query
tab holds the statements after it until its `COMMIT` or `ROLLBACK`. A statement that
names no server runs on the one picked at the top of the left panel, in the database
picked there. On a SQLite file, statements run in SQLite itself, in SQLite's own SQL:
its functions, `PRAGMA`, `INSERT OR REPLACE`, `RETURNING` and triggers.

As in Sequel Ace, `USE other_db` picks that database at the top of the left panel and
the statements after it run there; CREATE, ALTER, DROP and RENAME refresh the table
list, and creating or dropping a database refreshes the database list.

## Querying across servers

![Cross-server join](images/cross-engine-join.png)

Prefix each table with its connection's alias and join as usual:

```sql
SELECT o.id, o.placed_at, o.status, c.full_name, c.email
FROM shop.orders o JOIN crm.customers c ON o.customer_id = c.id
WHERE o.status = 'paid'
ORDER BY o.placed_at DESC
```

The database is filled in from the sidebar's pick for that alias, else the
connection's own; write `alias.database.table` to be explicit. The collapsible note
above the editor restates these conventions for the servers you have open.

What happens for this statement: the smaller table's distinct join keys are fetched
from its server, the other server is asked (with its own EXPLAIN) how many rows those
keys select, and the bigger side comes over reduced to them or whole, whichever is
cheaper. Both sides stream into the app and are joined as they arrive, so the first
rows appear while the rest is still crossing the wire. Simple WHERE conditions run on
the servers. The Console shows each statement, so you can see exactly what each server
was asked.

Three or more tables, outer joins, UNIONs and subqueries also work across servers;
they run on the embedded DuckDB, with each remote table copied in first. A ClickHouse
table joins one other server's table the same way, with the ClickHouse side copied.
The full rules, with what is pushed to the servers and what is not, are in
[QUERYING.md](QUERYING.md); one query is traced statement by statement in
[ARCHITECTURE.md](ARCHITECTURE.md#one-query-traced).

## Working with results

![Chart](images/chart.png)

Results stream in with no row cap; the status bar counts rows and shows the query
time. Double-click a cell to open it in a popup beside the cell: the full value, with a
JSON view for JSON text, and **Copy**, **Cancel**, **Edit** and **Save**. Edit and Save
change the value on the server when the result is one table's rows and includes that
table's primary key, which is Sequel Ace's rule: `SELECT id, status FROM shop.orders`
can be edited, while a join, a `GROUP BY` or a computed column can't, and the popup
says why. If the server refuses a value, the popup stays open with its message.
**Filter rows** narrows what is shown without rerunning the query. The right-click
menu copies a cell, a row, a row with its column names, the selected rows, or rows as
SQL `INSERT` statements. **Export** writes the result as CSV, JSON, Markdown or SQL
`INSERT` statements. The toggle at the right of the status bar turns the result into a
bar, line or pie chart: pick the label and value columns.

## Import and export

**Export database as SQL…** in the sidebar menu writes a dump of every table, schema
and data, for MySQL, PostgreSQL and SQLite; on MySQL a table's context menu exports it
alone. **Import SQL file…** in the sidebar menu runs a `.sql` file's statements in
order, with progress and **Stop**; the first that fails stops it and says which (MySQL
and PostgreSQL). **Import CSV…** on a table's context menu loads a CSV into it (MySQL
and PostgreSQL); on MySQL the sidebar menu also creates a new table from a CSV, with
columns taken from the header.

## Server and Console

**Server** shows, for MySQL and PostgreSQL, the live process list with a **Kill**
button per entry, the server's variables and its status counters, each with a filter.
For ClickHouse, which has no process list in that sense, it reads `system.query_log`:
recent queries, the slowest by duration, and a roll-up by query type.

![Console](images/console.png)

**Console** lists every statement the app runs, with its duration, row count and any
error: your queries, the server-side steps of a cross-server join, the DDL behind a
click, and the app's own reads of your tables, columns and keys, marked "by the app".
**All** shows everything; **Yours** only what you ran in the Query tab. **Export…**
writes the log as a `.sql` file; **Clear** empties it.

## Settings and shortcuts

**Appearance** sets a light, dark or system theme. **Editor** sets the font size, tab
width and whether Tab completes a word (off, it indents). **Connections** lists the saved
connections with Edit and Delete, which asks first, since the saved password goes too. **Shortcuts** lists every key the app binds:

| Keys | Action |
|---|---|
| ⌘↵ | Run every statement, or the selected text |
| ⌘R | Run the statement under the cursor; in Content and Structure, refresh |
| ⌥⌘R | Run every statement |
| Esc | Cancel the running query |
| ⌃⌥F | Format the statement |
| ⌘T | New query tab |
| ⌘W | Close the query tab you're on |
| ⌘O | Open a .sql file |
| ⌘S | Save the query tab's .sql file |
| ⇧⌘S | Save it under another name |
| ⌘/ | Comment or uncomment the lines |
| ⌘] | Indent the lines |
| ⌘[ | Outdent the lines |
| ⌘F | Find in the editor |
| ⌘G | Find the next match |
| ⌘1–⌘9 | Structure, Content, Relations, Triggers, Table Info, Query, Routines, Server, Console |
| ⇧⌘R | Refresh the databases and tables |
| ⌃⌘R | Refresh the tables |
| ⌘J | Jump to a page, or set the rows a page shows (Content) |
| ⌘D | Duplicate the selected row (Content) |
| ⌘, | Settings |
| Click a table | Open it |
| Double-click a table | Copy its name |
