# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through
GitHub's security advisories for this repository ("Report a vulnerability" under the
Security tab). You will get an acknowledgement within a few days and a fix or a
mitigation as soon as one is ready. The latest release is the supported version.

## How the app handles your credentials

- Passwords are stored in the macOS Keychain: a connection's database password, and
  its SSH password or key passphrase when you tick Remember in Keychain, each an item of
  its own; a one-time code is never saved. They are never written to the connection
  file, the statement history or the logs.
- SSH connections use a local port forward that ssh opens with your key file, or with
  ssh-agent and your usual keys; a password, passphrase or one-time code ssh asks for is
  typed into the app's dialog. The key never leaves your machine. Servers' keys are
  checked as ssh does in Terminal: a server met for the first time is trusted only
  when you say so, after seeing its key's fingerprint, and a changed key stops the
  connection before anything is sent.
- A connection marked read-only is enforced by the query engine, not just the
  interface: every write path refuses to run against it.
- The app sends nothing anywhere except to the database servers you configure; to
  extensions.duckdb.org, once, for the DuckDB scanner extension a first MySQL,
  PostgreSQL or SQLite connection needs; and, when you allow it, a once-a-day check for
  a new version: it reads the update feed on the project's GitHub releases
  (appcast.xml) and sends nothing about you or your databases. An update is installed
  only when its EdDSA signature matches the key the app carries (Sparkle,
  `SUPublicEDKey`), and its code signature matches the installed app's. There is no
  telemetry and no crash reporting.

## In scope

Anything that could expose credentials or data, run a statement you did not write, or
bypass read-only mode. Generated SQL (panel edits, imports, dumps) is built per dialect
in `SQLBuilder`; if you find an input that escapes it, that is a report we want.
