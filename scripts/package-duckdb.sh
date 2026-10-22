#!/bin/bash
# package-duckdb.sh [--single ARCH] — the zip scripts/fetch-duckdb.sh installs: each static
# library of out/arm64 and out/x86_64 (scripts/build-duckdb.sh) combined into one universal
# archive with lipo, duckdb.h, the license files and MariaDB Connector/C's source; and its
# SHA-256, which fetch-duckdb.sh pins. --single packages one CPU's build, for a local try.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
WORK="${SB_DUCKDB_WORK:-$HOME/Library/Caches/SequelBridge-duckdb-build}"
WORK="$(cd "$WORK" && pwd -P)"
NAME="${SB_DUCKDB_PACKAGE:-duckdb-v1.5.6-sb1}"
STAGE="$WORK/out/package"
rm -rf "$STAGE" && mkdir -p "$STAGE/libs" "$STAGE/include"
if [ "${1:-}" = "--single" ]; then
  ARCH="${2:?usage: package-duckdb.sh [--single arm64|x86_64]}"
  cp "$WORK/out/$ARCH"/libs/*.a "$STAGE/libs/"
  ZIP="$WORK/$NAME-macos-$ARCH.zip"
  SRC="$WORK/out/$ARCH"
else
  for a in "$WORK/out/arm64"/libs/*.a; do
    name=$(basename "$a")
    [ -f "$WORK/out/x86_64/libs/$name" ] || { echo "$name has no x86_64 build"; exit 1; }
    lipo -create "$a" "$WORK/out/x86_64/libs/$name" -output "$STAGE/libs/$name"
  done
  ZIP="$WORK/$NAME-macos-universal.zip"
  SRC="$WORK/out/arm64"
fi
cp "$SRC/include/duckdb.h" "$STAGE/include/"
cp -R "$SRC/licenses" "$STAGE/licenses"
cp -R "$SRC/sources" "$STAGE/sources"
rm -f "$ZIP" && (cd "$STAGE" && zip -qr "$ZIP" libs include licenses sources)
(cd "$WORK" && shasum -a 256 "$(basename "$ZIP")" | tee "$ZIP.sha256")
