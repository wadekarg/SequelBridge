# vendor/DuckDB — local DuckDB 1.5.6 SwiftPM package

This replaces the remote `duckdb-swift` SwiftPM dependency so the app can run on a
**modern, stable DuckDB (1.5.6)** while keeping the app statically linked (no bundled
dylib) — which the notarized-DMG distribution relies on.

## Why it exists

`duckdb-swift` has no stable release past 1.1.3, and its newer dev tags vendor DuckDB's
*main* branch (dev versions), for which the mysql/postgres/sqlite **scanner extensions
are not published** on the CDN. A meaningful upgrade therefore needs a *stable* DuckDB
version. DuckDB 1.5.6 ships **prebuilt static libraries**, so we link those and pair them
with duckdb-swift's thin Swift wrapper.

## Layout

- `Sources/DuckDB/` — duckdb-swift's Swift wrapper (MIT, see `LICENSE`), vendored with the
  local patches listed below.
- `Sources/Cduckdb/` — the C module: `include/duckdb.h` (fetched) + a shim; links the
  prebuilt static libs.
- `Package.swift` — links `libs/*.a`, self-locating so there are no absolute paths.
- `libs/` + `Sources/Cduckdb/include/duckdb.h` — **NOT in git** (~60MB). Fetched by
  `scripts/fetch-duckdb.sh`.

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

Run from the repo root before building (and after changing the DuckDB version):

```sh
./scripts/fetch-duckdb.sh          # downloads universal (arm64+amd64) static libs for v1.5.6
```

To move to a new DuckDB version: set `DUCKDB_VERSION` in `scripts/fetch-duckdb.sh`, bump
`QueryEngine.duckDBVersion` (so the runtime scanner-extension downloads match), re-run the
script, and re-verify the suite. The scanner extensions must have CDN builds for that exact
version (stable releases only).
