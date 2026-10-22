#!/usr/bin/env bash
# Fetch DuckDB's static libraries + C header for the local `vendor/DuckDB` SwiftPM package:
# DuckDB 1.5.6 with the MySQL, PostgreSQL and SQLite drivers built in, for Apple Silicon
# and Intel, as scripts/build-duckdb.sh and scripts/package-duckdb.sh make them. They are
# NOT committed (~70 MB); run this once before building, and after the package changes.
#
# The zip is a release of github.com/wadekarg/sequelbridge-duckdb, checked against the
# SHA-256 pinned here. SB_DUCKDB_ZIP=path installs a zip built here instead (checked
# against path.sha256 when that exists): a rebuild being tried, or before it's published.
set -euo pipefail

PACKAGE="duckdb-v1.5.6-sb1"
SHA256=""   # of $PACKAGE-macos-universal.zip; pinned when the release is published
URL="https://github.com/wadekarg/sequelbridge-duckdb/releases/download/$PACKAGE/$PACKAGE-macos-universal.zip"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$HERE/vendor/DuckDB"
LIBS="$PKG/libs"
INCLUDE="$PKG/Sources/Cduckdb/include"
LICENSES="$PKG/licenses"
STAMP="$LIBS/.duckdb-version"

LOCAL="${SB_DUCKDB_ZIP:-}"
WANT="$PACKAGE"
[ -n "$LOCAL" ] && WANT="$PACKAGE (local $(shasum -a 256 "$LOCAL" | cut -c1-16))"
if [[ -f "$STAMP" && "$(cat "$STAMP" 2>/dev/null)" == "$WANT" && -f "$LIBS/libmysql_scanner_extension.a" ]]; then
  echo "DuckDB $WANT already present — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -n "$LOCAL" ]; then
  echo "Installing DuckDB from $LOCAL…"
  cp "$LOCAL" "$TMP/duckdb.zip"
  if [ -f "$LOCAL.sha256" ]; then
    echo "$(awk '{print $1}' "$LOCAL.sha256")  $TMP/duckdb.zip" | shasum -a 256 -c --quiet
  fi
else
  [ -n "$SHA256" ] || { echo "$PACKAGE isn't published yet: build it (scripts/build-duckdb.sh, scripts/package-duckdb.sh) and set SB_DUCKDB_ZIP"; exit 1; }
  echo "Fetching DuckDB $PACKAGE (drivers built in; arm64 + x86_64)…"
  curl -fsSL -o "$TMP/duckdb.zip" "$URL"
  echo "$SHA256  $TMP/duckdb.zip" | shasum -a 256 -c --quiet
fi
(cd "$TMP" && unzip -oq duckdb.zip)

mkdir -p "$LIBS" "$INCLUDE"
rm -f "$LIBS"/*.a
cp "$TMP"/libs/*.a "$LIBS/"
cp "$TMP/include/duckdb.h" "$INCLUDE/duckdb.h"
rm -rf "$LICENSES" && cp -R "$TMP/licenses" "$LICENSES"
echo "$WANT" > "$STAMP"
echo "Done: $(ls "$LIBS"/*.a | wc -l | tr -d ' ') libs ($(lipo -archs "$LIBS/libduckdb_static.a")) + duckdb.h in vendor/DuckDB."
