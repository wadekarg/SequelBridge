# The App Store listing (App Store Connect → SequelBridge → App Store)

Each field below pastes as it is: the description's paragraphs are one line each, since
App Store Connect keeps every line break.

- Name (30): SequelBridge
- Subtitle (30): One SQL query, many databases
- Promotional text (170): Query MySQL, PostgreSQL, SQLite and ClickHouse side by side, and join tables across servers in one SQL statement. Free and open source.
- Keywords (100): mysql,postgresql,postgres,sqlite,clickhouse,mariadb,sql,database,query,duckdb,ssh,client
- Support URL: https://github.com/wadekarg/SequelBridge/issues
- Marketing URL: https://sequelbridge.pages.dev
- Privacy Policy URL: https://sequelbridge.pages.dev/privacy.html (live once `website/` is deployed with `privacy.html`: the site is deployed by hand)
- Category: Developer Tools; secondary: Productivity
- Price: Free, all territories
- Age rating: 4+ (none of the content questions apply)
- Copyright: 2026 Gajanan Wadekar
- Screenshots: `.build/appstore/screenshots/`, in their numbered order (`scripts/appstore-screenshots.sh` makes them)
- What's New: not asked for the first version

## Description (4000)

SequelBridge is a native Mac app for your databases: MySQL and MariaDB, PostgreSQL, SQLite and ClickHouse, each in its own SQL, and all of them together.

Connect to several servers at once and join their tables in one query. SequelBridge runs it on DuckDB, built into the app, and simple WHERE conditions run on the servers themselves.

• Browse tables, edit rows in place, and change structure: columns, indexes, foreign keys and triggers
• A query editor with completion, formatting, history and saved queries
• Results you can filter, chart, and export as CSV, JSON, Markdown or SQL
• SSH tunnels with your keys, passwords, passphrases and one-time codes
• Encrypted connections (TLS) for servers that require them, such as Amazon RDS and Azure
• Read-only connections, so a production server can't be changed by accident
• CSV import and SQL dumps

Your data stays on your Mac: connections and history are files on it, passwords are in the Keychain, and the app connects only to the servers you configure. It collects nothing.

The App Store version runs in macOS's sandbox, so it asks once for your ~/.ssh folder (and for an SSH key kept elsewhere) and once for each folder holding a SQLite file you open. It can't connect through a local socket (use TCP/IP to 127.0.0.1) or use ssh-agent (use your key files).

Free and open source (MIT): github.com/wadekarg/SequelBridge
