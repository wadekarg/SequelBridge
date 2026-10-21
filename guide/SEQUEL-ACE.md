# Coming from Sequel Ace

Every feature of Sequel Ace (taken from its menus and screens), whether SequelBridge
has it, and the test that proves it. A feature without a test doesn't count as done.

✓ works, and the test named proves it · ✓ *no test* works, test still to write ·
◐ partly, or differently (the note says how) · ✗ not in SequelBridge yet ·
● an everyday flow, also covered by the UI tests

## Connecting

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● TCP/IP connection | ✓ | `MySQLIntegrationTests`, `ConnectionTypeTests` |
| Socket connection | ✓ | `ConnectionTypeTests` |
| ● SSH tunnel with a key file | ✓ also old `ssh-rsa`-only servers | `SSHTunnelTests` |
| SSH tunnel with a password | ✓ asked in a dialog, can be saved in Keychain | `SSHTunnelTests.passwordLogin` |
| SSH key with a passphrase | ✓ asked in a dialog, can be saved in Keychain | `SSHTunnelTests.passphraseLogin` |
| SSH one-time code (RSA token, authenticator) | ✓ asked in a dialog, never saved | `SSHTunnelTests.oneTimeCodeLogin` |
| SSH key held by ssh-agent, no key file | ✓ | `SSHTunnelTests.agentLogin` |
| SSH server met for the first time | ✓ shows its key's fingerprint and asks to trust it | `SSHTunnelTests.newServerTrusted`, `SSHHostKeyUITests` |
| SSH server whose key changed | ✓ says so; forgets the old key once you confirm the new one | `SSHTunnelTests.changedKey`, `SSHHostKeyUITests` |
| Require SSL | ✓ | `SSLConnectionTests` |
| SSL with client key, certificate and CA files | ✗ | |
| Favorites with colours | ✓ | `ConnectionStoreTests` |
| Favorite groups | ◐ one level of folders | `ConnectionStoreTests` |
| Import and export favorites | ✗ | |
| Connect from a `mysql://` URL | ✗ | |
| Test connection | ✓ the server's reason when it fails, never the password | `ServerToolsTests` |
| Several connections at once | ✓ one workspace holds several servers, and a query can join them | `MultiServerTests` |
| New connection window or tab | ✗ the app has one set of open connections: File > New Window opens Home again, and a Connect there closes the ones the other window's workspace uses | |
| Save a connection or session file (`.spf`) | ✗ | |

## Databases

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● Choose a database | ✓ one switch at a time, the last pick wins; one that can't be opened says why; another database closes the table open from the one before (fixed: Content kept its rows while edits went to the new database) | `DatabaseSwitchTests`, `MySQLWorkflowUITests` |
| ● `USE db` in a query selects it | ✓ | `DatabaseSwitchTests.useFollows`, `QueryEffectsTests`, `MySQLWorkflowUITests` |
| Add database (with encoding and collation) | ✓ Add Database… in the database menu: a name, and the server's encodings and collations, each starting at its default; the new database is picked (MySQL) | `DatabaseSheetTests`, `DatabaseSwitchTests`, `MySQLWorkflowUITests` |
| Delete database | ✓ Delete Database… in the database menu, after a confirmation; the connection's own database is picked again (MySQL) | `DatabaseSheetTests`, `DatabaseSwitchTests`, `MySQLWorkflowUITests` |
| Duplicate, rename or alter a database | ✗ | |
| Refresh databases, refresh tables | ✓ ↻ beside the database picker: ⇧⌘R both, ⌃⌘R the tables, as in Sequel Ace (fixed: the keys refreshed the first connection shown) | `DatabaseSwitchTests.refresh`, `MySQLRefreshUITests` |
| Open a database in a new tab | ✗ | |
| Export a database as SQL | ✓ | `DatabaseDumpTests` |
| Flush privileges | ◐ typed only | |
| User accounts and privileges | ✗ | |
| View using another encoding | ✗ | |
| Server variables | ✓ Server tab, with a filter | `DestructiveDDLVerifyTests` |
| Server processes, with Kill | ✓ Kill ends a running statement | `DestructiveDDLVerifyTests`, `ServerToolsTests` |
| Shut down the server | ✗ | |

## Tables (left panel)

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● Filter tables | ✓ part of the name, any case, spaces around it ignored | `TableListFilterTests`, `MySQLWorkflowUITests` |
| ● Add a table | ✓ | `PanelWritePathTests`, `SQLBuilderDDLTests` |
| Duplicate a table, with or without its rows | ✓ MySQL and PostgreSQL, from its context menu | `RenameDuplicateTableTests`, `PanelWritePathTests`, `MySQLWorkflowUITests` |
| Rename a table | ✓ MySQL and PostgreSQL, from its context menu | `RenameDuplicateTableTests`, `PanelWritePathTests`, `MySQLWorkflowUITests` |
| Truncate a table | ✓ | `DestructiveDDLVerifyTests` |
| Drop a table | ✓ | `DestructiveDDLVerifyTests` |
| Copy or show `CREATE TABLE` | ✓ in Table Info, with Copy: the server's own on MySQL and ClickHouse, the file's own on SQLite; PostgreSQL keeps none, so it is rebuilt and says so | `MySQLIntegrationTests.serverCreateTable`, `MySQLWorkflowUITests` |
| Check, repair, analyze, optimize, flush, checksum | ✓ Table Maintenance on the table's right-click menu, with the server's answer; only Check and Checksum on a read-only connection (MySQL) | `TableMaintenanceTests`, `ServerToolsTests`, `MySQLWorkflowUITests` |
| Open a table in a new tab or window | ◐ `SELECT * FROM …` on the table's context menu opens it in a new query tab | |
| Pin a table to the top | ✗ | |
| Copy the table name | ✓ *no test* | |
| Export a table | ◐ as SQL on MySQL; any query's result as CSV, JSON, Markdown or SQL | `DatabaseDumpTests`, `ResultExporterTests` |
| Reset `AUTO_INCREMENT` | ✗ | |
| Views listed apart from tables | ✓ | `TableListFilterTests`, `ServerToolsTests` |

## Structure

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● Columns with type, length, nullability, key, default, extra | ✓ | `MySQLIntegrationTests` |
| Unsigned, zerofill, binary, encoding, collation, comment per column | ◐ unsigned and collation, no comment column | `AlterStatementTests` |
| ● Add, edit and delete a column | ✓ | `PanelWritePathTests`, `AlterStatementTests` |
| Duplicate a column | ✗ | |
| Reorder columns | ✗ | |
| Indexes: add and delete PRIMARY, UNIQUE, INDEX | ✓ | `PanelWritePathTests` |
| FULLTEXT and SPATIAL indexes | ◐ listed, not created from the panel | |
| Edit table details: engine, encoding, collation, comment, `AUTO_INCREMENT` | ✗ shown in Table Info, not editable | |
| Refresh the structure | ✓ ⌘R, on the table on screen (fixed: it reloaded the first table opened) | `MySQLWorkflowUITests` |

## Content

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● Browse rows a page at a time | ✓ | `ContentBrowseTests` |
| Page size, jump to a page | ✓ ⌘J: a page number, and 100 to 5,000 rows a page, kept across launches | `ContentPagingTests`, `MySQLWorkflowUITests` |
| ● Filter rows | ✓ a column, an operator (=, ≠, <, >, contains, begins with, is in, between, is NULL …) and a value, as in Sequel Ace; Type WHERE shows the rule as SQL to adjust; a condition the server can't read says why | `ContentFilterTests`, `ContentBrowseTests`, `MySQLWorkflowUITests` |
| Saved filters | ✗ | |
| ● Sort by a column | ✓ on the server | `DestructiveDDLVerifyTests`, `ContentDMLTests` |
| ● Edit a cell in place | ✓ Return or a click away saves, Esc cancels | `InlineCellEditTests`, `ContentEditTests`, `MySQLWorkflowUITests` |
| Edit a long value in a sheet | ◐ in the Query tab's popup; the Content tab edits in place | `QueryResultEditTests` |
| ● Set a cell to NULL | ✓ right-click; stores NULL, not an empty string | `ContentBrowseTests`, `MySQLWorkflowUITests` |
| ● Add a row | ✓ | `PanelWritePathTests` |
| Duplicate a row | ✓ ⌘D: the copy opens in the row sheet, its auto-increment key left to the server | `ContentPagingTests`, `MySQLWorkflowUITests` |
| ● Delete rows | ✓ | `PanelWritePathTests` |
| ● Copy rows, or rows with column names | ✓ tab-separated, a NULL as an empty value | `RowCopyTests` |
| Copy rows as SQL `INSERT` | ✓ a text value that reads NULL stays text (fixed) | `InsertStatementTests` |
| Follow a foreign key to the row it points at | ✓ a key cell's right-click menu: Go to customers where id = 2, which opens with that filter; keys of several columns too | `ForeignKeyFollowTests`, `MySQLWorkflowUITests` |
| Show binary data as hex | ◐ BLOBs are decoded for display | |
| Refresh the content | ✓ ⌘R, on the table on screen | `MySQLWorkflowUITests` |

## Relations, Triggers, Table Info

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● List foreign keys | ✓ | `MySQLRelationsTests`, `MySQLIntegrationTests` |
| Add and delete a foreign key | ✓ | `PanelWritePathTests` |
| List triggers | ✓ | `MySQLIntegrationTests` |
| Create and delete a trigger | ✓ | `PanelWritePathTests` |
| Edit a trigger | ✗ drop and create it again | |
| Table Info: engine, rows, sizes, dates, comment | ✓ | `MySQLIntegrationTests`, `RealSchemaTests` |

## Query

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● Run all, or the selection | ✓ ⌘↵ | `WorkspaceControlsUITests`, `MySQLWorkflowUITests` |
| Run the statement under the cursor | ✓ Run Current: ⌘R as in Sequel Ace, ⌥⌘R runs them all | `SQLScriptTests.underCursor`, `MySQLWorkflowUITests` |
| ● Highlighting and completion of tables and columns | ✓ `--` inside a string, `#` and `/* */` comments, backticked names (fixed) | `SQLHighlighterTests`, `SQLCompletionTests` |
| ● MySQL's own statements | ✓ run on the server as typed, with the rows changed (fixed: DuckDB read them first, refused `AUTO_INCREMENT`, backticks, `ON DUPLICATE KEY UPDATE` and more, and made a `VARCHAR(40)` column `TEXT`); `LOCK TABLES` and `SET autocommit` are refused, saying why | `QueryTabAsTypedTests`, `AsTypedRoutingTests`, `MySQLWorkflowUITests` |
| ● Several statements in one run | ✓ one at a time, as in Sequel Ace, `DELIMITER` and `/*! */` included (fixed: two `SELECT`s failed on MySQL) | `SQLScriptTests`, `MySQLWorkflowUITests` |
| ● Edit a result's values | ✓ one table's rows with its primary key, as in Sequel Ace | `ResultEditingSourceTests`, `ResultEditTargetTests`, `QueryResultEditTests` |
| Query history: menu, previous and next | ◐ the bookmark menu lists the last 10 statements, kept across restarts; no previous and next keys | `HistoryStoreTests` |
| ● Query favorites: save, load, delete | ✓ | `SavedQueryStoreTests` |
| ● Explain | ✓ | `TypedExplainTests`, `MySQL8Tests` |
| Comment a line (⌘/), shift indent (⌘[ ⌘]) | ✓ | `EditorEditsTests`, `EditorCommandTests`, `MySQLWorkflowUITests` |
| Find and replace in the editor | ✓ macOS's find bar: ⌘F, ⌘G | `EditorCommandTests` |
| Auto-pair brackets and quotes, uppercase keywords | ✗ | |
| ● Export a result | ✓ CSV, JSON, Markdown, SQL `INSERT` | `ResultExporterTests` |
| ● Several query tabs | ✓ ⌘T opens one, ⌘W closes the one you're on (fixed: it closed another) | `WorkspaceControlsUITests` |
| Open and save `.sql` files in the editor | ✓ ⌘O, ⌘S, ⇧⌘S; UTF-8, or Latin-1 for an old file | `SQLFileTests`, `OpenSQLTabTests` |
| Cancel a running query | ✓ | `QueryCancelTests` |
| MySQL help for a word | ✗ | |

## Import and export

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| Import CSV with field mapping | ◐ columns matched by header name, no mapping step | `DestructiveDDLVerifyTests`, `CSVParserTests`, `CSVInferenceTests` |
| Import a SQL file | ✓ MySQL and PostgreSQL: its statements in order, on one connection as mysql and psql run a file, with progress and Stop; the first that fails stops it and says which | `MySQLIntegrationTests.importDump`, `SQLFileTests` |
| Import from the clipboard | ✗ | |
| Export SQL with structure and content options | ◐ structure and content, no options | `DatabaseDumpTests` |
| Export CSV, XML | ◐ CSV of a result; no XML | `ResultExporterTests` |

## Window, shortcuts, settings

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ⌘1–⌘6 switch the main tabs | ✓ Sequel Ace's six, then ⌘7–⌘9 for Routines, Server, Console | `FeatureTabShortcutTests`, `MySQLWorkflowUITests` |
| Back and forward through visited tables | ✗ | |
| ● Console: show and clear | ✓ | `MySQLWorkflowUITests` |
| Save the history to a file | ✓ the Console's Export | `ConsoleExporterTests` |
| Navigator | ✗ | |
| Light and dark theme | ✓ | `AppSettingsTests` |
| Editor font size, tab width | ✓ | `AppSettingsTests` |
| NULL display text, default page size | ◐ the page size, set in the Content tab (⌘J); no NULL text | `ContentPagingTests` |
| Bundles (scripts) | ✗ | |
| Print | ✗ | |

## Only in SequelBridge

Read-only mode for production servers; PostgreSQL, SQLite files and ClickHouse beside
MySQL; one query across several servers; result charts; ClickHouse query insights.
