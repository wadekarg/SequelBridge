// swift-tools-version: 5.7
import PackageDescription
import Foundation

// Local DuckDB package: the duckdb-swift Swift wrapper (1.5.x) over DuckDB 1.5.6's static
// libraries, built with the MySQL, PostgreSQL and SQLite drivers in them
// (scripts/build-duckdb.sh): the app downloads no driver. No bundled dylib — the app stays
// statically linked (notarized-DMG model intact).
//
// The ~70MB of static libs + duckdb.h are NOT in git; `scripts/fetch-duckdb.sh` installs
// them into Sources/Cduckdb/include + libs/. Run that script once before building.

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
          // The database drivers, built in (scripts/build-duckdb.sh), and the libraries
          // they use: MariaDB Connector/C, libpq, curl, OpenSSL, lz4, zlib. A library
          // comes before the ones it uses.
          "-lmysql_scanner_extension",
          "-lpostgres_scanner_extension",
          "-lsqlite_scanner_extension",
          "-lmariadbclient",
          "-lpq",
          "-lpgcommon",
          "-lpgport",
          "-lcurl",
          "-lssl",
          "-lcrypto",
          "-llz4",
          "-lz",
        ]),
        .linkedLibrary("c++"),
        .linkedLibrary("iconv"),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"),
      ]
    ),
  ]
)
