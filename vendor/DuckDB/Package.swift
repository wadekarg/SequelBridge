// swift-tools-version: 5.7
import PackageDescription
import Foundation

// Local DuckDB package: the duckdb-swift Swift wrapper (1.5.x) over DuckDB 1.5.6's
// PREBUILT static libraries. No compiling DuckDB from source, no bundled dylib — the
// app stays statically linked (notarized-DMG model intact), on a genuine v1.5.6 so the
// mysql/postgres/sqlite scanner extensions (built per DuckDB version) load.
//
// The ~60MB of static libs + duckdb.h are NOT in git; `scripts/fetch-duckdb.sh`
// downloads them from DuckDB's release CDN into Sources/Cduckdb/include + libs/.
// Run that script once before building.

// Self-locate the package so the linker search path is absolute yet portable.
let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let libs = pkgDir + "/libs"

let package = Package(
  name: "DuckDB",
  products: [
    .library(name: "DuckDB", targets: ["DuckDB"]),
  ],
  targets: [
    .target(name: "DuckDB", dependencies: ["Cduckdb"]),
    .target(
      name: "Cduckdb",
      linkerSettings: [
        .unsafeFlags([
          "-L", libs,
          "-lduckdb_static",
          "-lcore_functions_extension",
          "-lparquet_extension",
          "-licu_extension",
          "-ljson_extension",
          "-lautocomplete_extension",
          "-lduckdb_generated_extension_loader",
          "-lduckdb_pg_query",
          "-lduckdb_re2",
          "-lduckdb_fmt",
          "-lduckdb_fsst",
          "-lduckdb_miniz",
          "-lduckdb_utf8proc",
          "-lduckdb_hyperloglog",
          "-lduckdb_fastpforlib",
          "-lduckdb_mbedtls",
          "-lduckdb_yyjson",
          "-lduckdb_zstd",
          "-lduckdb_skiplistlib",
        ]),
        .linkedLibrary("c++"),
      ]
    ),
  ]
)
