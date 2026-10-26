# Notes for App Review (App Store Connect → App Review Information)

- Sign-in required: off.
- Notes: the text between the two lines below.
- Attachment: `.build/appstore/demo.sqlite`, made with
  `cp scripts/fixtures/demo/ref.sqlite .build/appstore/demo.sqlite` (`scripts/seed-demo.sh`
  writes `ref.sqlite`: synthetic demo data only, two small tables).

---

No account or sign-in. SequelBridge is a client for the user's own databases (MySQL/MariaDB, PostgreSQL, SQLite, ClickHouse) and connects only to servers the user configures.

To try it without a server, use the attached demo.sqlite:
1. Save demo.sqlite in a folder, for example Documents.
2. In SequelBridge, click New Connection, choose SQLite, click Browse… and choose demo.sqlite. Allow its folder when asked: SQLite writes its journal beside the file.
3. Click Add to Favorites. On the home window, tick "demo" and click Connect.
4. The left panel lists the tables; the Query tab runs SQL, for example SELECT * FROM regions;

Entitlements and settings:
- com.apple.security.network.server: the app listens on 127.0.0.1 only. SSH tunnels to databases are a local port forward there (macOS's /usr/bin/ssh), and the askpass helper shipped in the app passes ssh's questions (a password, a key's passphrase, a one-time code) to the app's own dialog through it.
- Child processes: macOS's own /usr/bin/ssh (tunnels), /usr/bin/ssh-keygen (forgetting a server's changed key) and /usr/bin/sqlite3 (statements on a SQLite file); they run in the app's sandbox.
- NSAllowsArbitraryLoads: the user's ClickHouse servers are often reached over plain HTTP by host name.
- Files: only what the user picks in an open panel (their ~/.ssh folder for SSH, a SQLite file's folder), kept as security-scoped bookmarks.

---
