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
| SSH one-time code (RSA token, authenticator) | ✓ *no live test*: same path as a password, no OTP server in the test setup | `SSHLoginTests` |
| SSH key held by ssh-agent, no key file | ✓ *no test* | |
| Require SSL | ✓ | `SSLConnectionTests` |
| SSL with client key, certificate and CA files | ✗ | |
| Favorites with colours | ✓ | `ConnectionStoreTests` |
| Favorite groups | ◐ one level of folders | `ConnectionStoreTests` |
| Import and export favorites | ✗ | |
| Connect from a `mysql://` URL | ✗ | |
| Test connection | ✓ the server's reason when it fails, never the password | `ServerToolsTests` |
| Several connections at once | ✓ one workspace holds several servers, and a query can join them | `MultiServerTests` |
| New connection window or tab | ◐ File > New Window opens another workspace | |
| Save a connection or session file (`.spf`) | ✗ | |

## Databases

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● Choose a database | ✓ one switch at a time, the last pick wins; one that can't be opened says why | `DatabaseSwitchTests` |
| ● `USE db` in a query selects it | ✓ | `DatabaseSwitchTests.useFollows`, `QueryEffectsTests` |
| Add database (with encoding and collation) | ◐ typed `CREATE DATABASE` only; the list refreshes | `DatabaseSwitchTests.databaseDDL` |
| Delete database | ◐ typed `DROP DATABASE` only; a dropped selection goes back to the connection's own | `DatabaseSwitchTests.databaseDDL` |
| Duplicate, rename or alter a database | ✗ | |
| Refresh databases, refresh tables | ✗ no button: the lists refresh after the app's own changes and typed DDL only | |
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
| ● Filter tables | ✓ part of the name, any case, spaces around it ignored | `TableListFilterTests` |
| ● Add a table | ✓ | `PanelWritePathTests`, `SQLBuilderDDLTests` |
| Duplicate a table, with or without its rows | ✗ | |
| Rename a table | ✗ typed only | |
| Truncate a table | ✓ | `DestructiveDDLVerifyTests` |
| Drop a table | ✓ | `DestructiveDDLVerifyTests` |
| Copy or show `CREATE TABLE` | ◐ Table Info rebuilds it from the columns and indexes, with Copy; the server's own statement (foreign keys, partitions, table options) isn't shown | `ShowCreateTableTests` |
| Check, repair, analyze, optimize, flush, checksum | ✗ typed only | |
| Open a table in a new tab or window | ◐ double-click opens `SELECT *` in a new query tab | |
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
| Refresh the structure | ✗ | |

## Content

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ● Browse rows a page at a time | ✓ | `ContentBrowseTests` |
| Page size, jump to a page | ◐ fixed page size, next and previous | |
| ● Filter rows | ◐ a typed `WHERE` condition, not field-operator-value pickers; a condition the server can't read says why | `ContentBrowseTests` |
| Saved filters | ✗ | |
| ● Sort by a column | ✓ on the server | `DestructiveDDLVerifyTests`, `ContentDMLTests` |
| ● Edit a cell in place | ✓ Return or a click away saves, Esc cancels | `InlineCellEditTests`, `ContentEditTests` |
| Edit a long value in a sheet | ◐ in the Query tab's popup; the Content tab edits in place | `QueryResultEditTests` |
| ● Set a cell to NULL | ✓ right-click; stores NULL, not an empty string | `ContentBrowseTests` |
| ● Add a row | ✓ | `PanelWritePathTests` |
| Duplicate a row | ✗ | |
| ● Delete rows | ✓ | `PanelWritePathTests` |
| ● Copy rows, or rows with column names | ✓ tab-separated, a NULL as an empty value | `RowCopyTests` |
| Copy rows as SQL `INSERT` | ✓ a text value that reads NULL stays text (fixed) | `InsertStatementTests` |
| Follow a foreign key to the row it points at | ✗ | |
| Show binary data as hex | ◐ BLOBs are decoded for display | |
| Refresh the content | ✓ *no test* | |

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
| ● Run all, or the selection | ✓ ⌘↵; *no test* yet (a UI test is written, not yet run) | |
| Run the statement under the cursor | ✗ | |
| ● Highlighting and completion of tables and columns | ✓ `--` inside a string, `#` and `/* */` comments, backticked names (fixed) | `SQLHighlighterTests`, `SQLCompletionTests` |
| ● Several statements in one run | ✓ one at a time, as in Sequel Ace, `DELIMITER` included (fixed: two `SELECT`s failed on MySQL); the run loop itself: *no test* yet | `SQLScriptTests` |
| ● Edit a result's values | ✓ one table's rows with its primary key, as in Sequel Ace | `ResultEditingSourceTests`, `ResultEditTargetTests`, `QueryResultEditTests` |
| Query history: menu, previous and next | ◐ kept across restarts and shown in the Console; no history menu in the editor | `HistoryStoreTests` |
| ● Query favorites: save, load, delete | ✓ | `SavedQueryStoreTests` |
| ● Explain | ✓ | `TypedExplainTests`, `MySQL8Tests` |
| Comment a line (⌘/), shift indent (⌘[ ⌘]) | ✗ | |
| Find and replace in the editor | ✗ | |
| Auto-pair brackets and quotes, uppercase keywords | ✗ | |
| ● Export a result | ✓ CSV, JSON, Markdown, SQL `INSERT` | `ResultExporterTests` |
| ● Several query tabs | ✓ | `WorkspaceControlsUITests` |
| Open and save `.sql` files in the editor | ✗ the Console exports its log as `.sql` | `ConsoleExporterTests` |
| Cancel a running query | ✓ | `QueryCancelTests` |
| MySQL help for a word | ✗ | |

## Import and export

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| Import CSV with field mapping | ◐ columns matched by header name, no mapping step | `DestructiveDDLVerifyTests`, `CSVParserTests`, `CSVInferenceTests` |
| Import a SQL file | ✗ | |
| Import from the clipboard | ✗ | |
| Export SQL with structure and content options | ◐ structure and content, no options | `DatabaseDumpTests` |
| Export CSV, XML | ◐ CSV of a result; no XML | `ResultExporterTests` |

## Window, shortcuts, settings

| Sequel Ace | SequelBridge | Tested by |
|---|---|---|
| ⌘1–⌘6 switch the main tabs | ✓ Sequel Ace's six, then ⌘7–⌘9 for Routines, Server, Console | `FeatureTabShortcutTests` |
| Back and forward through visited tables | ✗ | |
| ● Console: show and clear | ✓ *no test* | |
| Save the history to a file | ✓ the Console's Export | `ConsoleExporterTests` |
| Navigator | ✗ | |
| Light and dark theme | ✓ | `AppSettingsTests` |
| Editor font size, tab width | ✓ | `AppSettingsTests` |
| NULL display text, default page size | ✗ | |
| Bundles (scripts) | ✗ | |
| Print | ✗ | |

## Only in SequelBridge

Read-only mode for production servers; PostgreSQL, SQLite files and ClickHouse beside
MySQL; one query across several servers; result charts; ClickHouse query insights.
