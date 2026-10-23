#!/bin/bash
# check-driver-symbols.sh ARCH — the MySQL, PostgreSQL and SQLite drivers are linked into one
# binary, so a name two of them define must mean the same thing in both. The linker keeps
# one copy of a type's vtable and destructor (weak symbols), and the other driver's objects
# then run them: on a different layout, that frees memory that isn't theirs. DuckDB's own
# builds load each driver as a module of its own, where this can't happen.
#
# Fails when two drivers' archives both define a symbol (one DuckDB doesn't) that comes from
#   - a struct or class both drivers declare under one name, defined differently; or
#   - their shared database-connector submodule, pinned at two commits whose sources for it
#     differ.
# Run by scripts/build-duckdb.sh after the build; reads the work folder it built in.
set -euo pipefail
ARCH="${1:?usage: check-driver-symbols.sh arm64|x86_64}"
WORK="${SB_DUCKDB_WORK:-$HOME/Library/Caches/SequelBridge-duckdb-build}"
WORK="$(cd "$WORK" && pwd -P)"
LIBS="$WORK/duckdb-$ARCH/build/release/libs"
DRIVERS=(mysql postgres sqlite)
T="$(mktemp -d)"
finished=0
trap 'rm -rf "$T"; [ "$finished" = 1 ] || exit 1' EXIT

defined() { nm -arch "$ARCH" -gUj "$1" 2>/dev/null | grep -v -e ':$' -e '^$' | sort -u; }
for e in "${DRIVERS[@]}"; do defined "$LIBS/lib${e}_scanner_extension.a" > "$T/$e"; done
for a in "$LIBS"/*.a; do
  case "$(basename "$a")" in lib*_scanner_extension.a) ;; *) defined "$a" ;; esac
done | sort -u > "$T/duckdb"

# The structs and classes a driver declares in its own source (not the submodule's), and
# one's definition: from its line to the first "};" at the start of a line, spaces dropped.
declared() { grep -rhoE '^[[:space:]]*(struct|class) [A-Za-z_][A-Za-z0-9_]*[^;]*$' "$WORK/duckdb-$1/src" \
  | sed -E 's/^[[:space:]]*(struct|class) ([A-Za-z_][A-Za-z0-9_]*).*/\2/' | sort -u; }
definition() {   # driver name
  local f; f=$(grep -rlE "^[[:space:]]*(struct|class) $2([^A-Za-z0-9_;][^;]*)?$" "$WORK/duckdb-$1/src" | head -1)
  awk -v n="$2" '$0 ~ "^[[:space:]]*(struct|class) " n "([^A-Za-z0-9_;]|$)" && $0 !~ /;[[:space:]]*$/ {p=1} p {print} p && /^};/ {exit}' "$f" | tr -d '[:space:]'
}
connector_commit() { git -C "$WORK/duckdb-$1" submodule status database-connector | awk '{print $1}' | tr -d '+-'; }

problems=0; checked=0
for pair in "mysql postgres" "mysql sqlite" "postgres sqlite"; do
  set -- $pair
  comm -12 "$T/$1" "$T/$2" | comm -23 - "$T/duckdb" | c++filt > "$T/shared"
  for name in $(comm -12 <(declared "$1") <(declared "$2")); do
    grep -qE "(^|[^A-Za-z0-9_])duckdb::$name([^A-Za-z0-9_]|$)" "$T/shared" || continue
    checked=$((checked + 1))
    if [ "$(definition "$1" "$name")" != "$(definition "$2" "$name")" ]; then
      echo "duckdb::$name: defined differently by the $1 and $2 drivers, and linked once — rename it in one (a patch in vendor/DuckDB/recipe/patches)"
      problems=$((problems + 1))
    fi
  done
  if [ "$(connector_commit "$1")" != "$(connector_commit "$2")" ]; then
    for ns in $(grep -oE 'dbconnector::[a-z_]+::' "$T/shared" | sort -u | cut -d: -f3); do
      checked=$((checked + 1))
      for d in "src/include/dbconnector/$ns" "src/$ns"; do
        if ! diff -rq "$WORK/duckdb-$1/database-connector/$d" "$WORK/duckdb-$2/database-connector/$d" > /dev/null 2>&1; then
          echo "dbconnector::$ns: the $1 and $2 drivers pin database-connector at two commits whose $d differs, and both link it"
          problems=$((problems + 1))
        fi
      done
    done
  fi
done
[ "$problems" = 0 ] || { echo "$problems name(s) the drivers define differently: see above"; exit 1; }
echo "drivers: no name defined differently by two of them ($checked shared checked, $ARCH)"
finished=1
