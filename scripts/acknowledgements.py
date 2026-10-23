#!/usr/bin/env python3
"""acknowledgements.py — writes SequelBridge/Acknowledgements.txt, which Help →
Acknowledgements shows: each project whose code the app ships, its version, its license
and the license's text. The texts come from vendor/DuckDB/licenses (the DuckDB package
scripts/fetch-duckdb.sh installs) and the vendored packages' own files. Run it after
fetch-duckdb.sh whenever the package or Sparkle changes, and commit the result.

--check writes nothing: it fails when the committed file isn't what the installed package
gives (scripts/run-all-tests.sh, scripts/build-release.sh and CI run it)."""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LICENSES = os.path.join(ROOT, "vendor/DuckDB/licenses")
OUT = os.path.join(ROOT, "SequelBridge/Acknowledgements.txt")
REPO = "https://github.com/wadekarg/SequelBridge"

INTRO = f"""SequelBridge includes code from the projects below, built into the app. Their
licenses follow, each with its project.

MariaDB Connector/C is linked into the app statically, under the GNU Lesser General
Public License 2.1. Its source, as compiled for the app (with the patches vcpkg
applies), is in the sources folder of each release of the app's DuckDB package:
https://github.com/wadekarg/sequelbridge-duckdb/releases
To use a modified version of it: SequelBridge's source, and the recipe that builds its
DuckDB with the database drivers (scripts/build-duckdb.sh, with the versions and
patches it uses), are at
{REPO}
Build DuckDB with your version of the library, then the app (CONTRIBUTING.md says how).
"""

# (section title, version, license, home, license file)
COMPONENTS = [
    ("DuckDB", "1.5.6", "MIT License", "https://github.com/duckdb/duckdb", "licenses/duckdb.txt"),
    ("DuckDB MySQL extension", "duckdb-mysql 99c2e09", "MIT License", "https://github.com/duckdb/duckdb-mysql",
     "licenses/duckdb-mysql.txt"),
    ("DuckDB PostgreSQL extension", "duckdb-postgres 318dabb", "MIT License",
     "https://github.com/duckdb/duckdb-postgres", "licenses/duckdb-postgres.txt"),
    ("DuckDB SQLite extension", "duckdb-sqlite 5274128, with SQLite (public domain)", "MIT License",
     "https://github.com/duckdb/duckdb-sqlite", "licenses/duckdb-sqlite.txt"),
    ("duckdb-swift", "the Swift wrapper, in vendor/DuckDB", "MIT License", "https://github.com/duckdb/duckdb-swift",
     "vendor/DuckDB/LICENSE"),
    ("MariaDB Connector/C", "3.4.7", "GNU Lesser General Public License 2.1",
     "https://github.com/mariadb-corporation/mariadb-connector-c", "licenses/libmariadb.txt"),
    ("PostgreSQL (libpq)", "18.3", "PostgreSQL License", "https://www.postgresql.org", "licenses/libpq.txt"),
    ("OpenSSL", "3.6.0", "Apache License 2.0", "https://www.openssl.org", "licenses/openssl.txt"),
    ("curl", "8.17.0", "curl License", "https://curl.se", "licenses/curl.txt"),
    ("zlib", "1.3.1", "zlib License", "https://zlib.net", "licenses/zlib.txt"),
    ("LZ4", "1.10.0", "BSD 2-Clause License", "https://github.com/lz4/lz4", "licenses/lz4.txt"),
    ("Sparkle", "2.10.0", "MIT License", "https://sparkle-project.org", "vendor/Sparkle/LICENSE"),
]


def read(rel):
    path = os.path.join(ROOT, "vendor/DuckDB", rel) if rel.startswith("licenses/") else os.path.join(ROOT, rel)
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().strip("\n")


def main():
    parts = [INTRO]
    for title, version, license_name, home, rel in COMPONENTS:
        parts.append(f"\n== {title} ({version}) — {license_name}\n{home}\n\n{read(rel)}\n")
    third = sorted(f for f in os.listdir(LICENSES) if f.startswith("duckdb-third-party-"))
    if third:
        names = ", ".join(f[len("duckdb-third-party-"):-len(".txt")] for f in third)
        parts.append(f"\n== Libraries in DuckDB's source\nDuckDB carries these in its source (its third_party "
                     f"folder, and its extensions': ICU), each under its license, with its NOTICE where one "
                     f"comes with it: {names}.\nhttps://github.com/duckdb/duckdb/tree/v1.5.6/third_party\n")
        for f in third:
            name = f[len("duckdb-third-party-"):-len(".txt")]
            parts.append(f"\n-- {name}\n\n{read('licenses/' + f)}\n")
    text = "".join(parts)
    if "--check" in sys.argv[1:]:
        with open(OUT, encoding="utf-8") as f:
            if f.read() != text:
                sys.exit(f"{os.path.relpath(OUT, ROOT)} is out of date: run scripts/acknowledgements.py and commit it")
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(OUT, text.count("\n"), "lines")


if __name__ == "__main__":
    main()
