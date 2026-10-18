#!/usr/bin/env bash
# Fetch DuckDB's prebuilt static libraries + C header for the local `vendor/DuckDB`
# SwiftPM package. These are NOT committed (~60MB); run this once before building,
# and after bumping DUCKDB_VERSION. Produces universal (arm64 + x86_64) archives so
# the app builds for both Apple Silicon and Intel.
#
# Mirrors how the app already downloads DuckDB scanner extensions at runtime.
set -euo pipefail

DUCKDB_VERSION="${DUCKDB_VERSION:-v1.5.6}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$HERE/vendor/DuckDB"
LIBS="$PKG/libs"
INCLUDE="$PKG/Sources/Cduckdb/include"
BASE="https://github.com/duckdb/duckdb/releases/download/$DUCKDB_VERSION"

STAMP="$LIBS/.duckdb-version"
if [[ -f "$STAMP" && "$(cat "$STAMP" 2>/dev/null)" == "$DUCKDB_VERSION" && -f "$LIBS/libduckdb_static.a" ]]; then
  echo "DuckDB $DUCKDB_VERSION static libs already present — nothing to do."
  exit 0
fi

echo "Fetching DuckDB $DUCKDB_VERSION static libs (universal: osx_arm64 + osx_amd64)…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$LIBS" "$INCLUDE"

for arch in arm64 amd64; do
  echo "  • downloading static-libs-osx-$arch.zip"
  curl -fsSL -o "$TMP/$arch.zip" "$BASE/static-libs-osx-$arch.zip"
  mkdir -p "$TMP/$arch"
  (cd "$TMP/$arch" && unzip -oq "$TMP/$arch.zip")
done

# lipo each archive into a universal (fat) static library.
echo "  • combining into universal archives"
rm -f "$LIBS"/*.a
for a in "$TMP/arm64"/*.a; do
  name="$(basename "$a")"
  lipo -create "$TMP/arm64/$name" "$TMP/amd64/$name" -output "$LIBS/$name"
done

cp "$TMP/arm64/duckdb.h" "$INCLUDE/duckdb.h"
echo "$DUCKDB_VERSION" > "$STAMP"
echo "Done: $(ls "$LIBS"/*.a | wc -l | tr -d ' ') universal libs + duckdb.h in vendor/DuckDB."
