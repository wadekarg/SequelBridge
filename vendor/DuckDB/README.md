# vendor/DuckDB — local DuckDB 1.5.6 SwiftPM package

DuckDB 1.5.6, linked statically, with its MySQL, PostgreSQL and SQLite scanner
extensions built in, behind duckdb-swift's thin Swift wrapper. Nothing is downloaded at
run time and there is no bundled dylib, which the notarized-DMG distribution relies on.

## Why it exists

`duckdb-swift` has no stable release past 1.1.3, and its newer dev tags vendor DuckDB's
*main* branch. DuckDB's own prebuilt static libraries leave the scanner extensions out:
the app downloaded them at the first connection (~30 MB each) and loaded them unsigned.
So `scripts/build-duckdb.sh` builds DuckDB 1.5.6 from source, for each CPU, with the
three scanners and their libraries (MariaDB Connector/C, libpq, OpenSSL, curl, zlib,
LZ4) linked in, and `scripts/package-duckdb.sh` combines both CPUs into the zip that
`scripts/fetch-duckdb.sh` installs here.

## Layout

- `Sources/DuckDB/` — duckdb-swift's Swift wrapper (MIT, see `LICENSE`), vendored with the
  local patches listed below.
- `Sources/Cduckdb/` — the C module: `include/duckdb.h` (fetched) + a shim; links the
  static libs.
- `Package.swift` — links `libs/*.a`: DuckDB, the three scanners and their libraries,
  and the system frameworks they need; self-locating so there are no absolute paths.
- `libs/`, `Sources/Cduckdb/include/duckdb.h` and `licenses/` — **NOT in git**. Fetched
  by `scripts/fetch-duckdb.sh`; `licenses/` holds the license file of each library in
  the package, which `scripts/acknowledgements.py` puts in the app's Acknowledgements.
- `recipe/` — what `scripts/build-duckdb.sh` builds with: patches to the MySQL and
  PostgreSQL scanners (each marked `SequelBridge`) so they link statically, vcpkg
  triplets for macOS 14, and the list of extensions built in.

## Local patches (re-apply when refreshing the wrapper)

The wrapper is upstream `duckdb-swift` except for these SequelBridge changes, each
marked `SequelBridge patch` in the source:

- `Sources/DuckDB/ResultSet.swift` — `ChunkStorage` records each chunk's starting row
  (`chunkStarts`) and offers `locate(row:)` / `chunkSize(at:)`; `element(forColumn:at:)`
  uses a binary search instead of walking every chunk from the first on each call (that
  made reading a result O(rows² / 2048) per column). `ChunkStorage` and `chunkStorage`
  are internal rather than (file)private so the bulk reader can use them.
- `Sources/DuckDB/ResultSet+Bulk.swift` (new) — public `bulk(_:column:rows:)` readers
  that walk the data chunks once with a single `Vector` per chunk. The per-element
  `Column` subscript allocates a `Vector`, a `LogicalType` and an `Element` for every
  cell; the app's result extraction uses `bulk` instead. The readers are shared with
  `ResultChunk` below through the internal `ChunkWalker` protocol.
- `Sources/DuckDB/StreamingResult.swift` (new) — `StreamingResult` executes a prepared
  statement as a streaming result (`duckdb_execute_prepared_streaming`, part of the
  deprecated-but-compiled surface like the chunk functions `ResultSet` already uses;
  move to the pending API if DuckDB removes it) and hands out one `ResultChunk` at a
  time via `duckdb_fetch_chunk`, so a large result is never materialized inside DuckDB
  and the first rows arrive while the query still runs. `DataChunk` gained an owning
  initializer for the fetched chunks.

- `Sources/DuckDB/Connection.swift` — `execute(_:)` keeps the `duckdb_result` so a failed
  statement throws DuckDB's message; upstream passed no result, so a failed `ATTACH`
  (wrong password, SSL required by the connection) said only "Connection query failed".

## Setup / upgrading

Run from the repo root before building (and after the package changes):

```sh
./scripts/fetch-duckdb.sh          # the universal (arm64 + x86_64) package, checked against its SHA-256
```

To move to a new DuckDB version: in `scripts/build-duckdb.sh` set `DUCKDB_TAG`, the
scanners' commits (DuckDB names them in `.github/config/extensions/<name>.cmake`) and
vcpkg's tag (DuckDB's `Makefile`); check that `recipe/patches` still apply; build both
CPUs and package them (CONTRIBUTING.md), with the new name in `package-duckdb.sh`;
publish the zip as a new release of `wadekarg/sequelbridge-duckdb`
(`duckdb-v<version>-sb<n>`) and set `PACKAGE` and `SHA256` in `scripts/fetch-duckdb.sh`;
update the versions in `scripts/acknowledgements.py` and run it; re-verify the suite.
