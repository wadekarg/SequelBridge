#!/bin/bash
# project-version.sh [project.pbxproj] — the app's version (MARKETING_VERSION), which every
# target carries, the DMG build's and the App Store build's alike: printed when they all
# agree, refused naming them when they don't (a version bumped in one target only).
set -euo pipefail
cd "$(dirname "$0")/.."
PBX="${1:-SequelBridge.xcodeproj/project.pbxproj}"
versions=$(grep -o 'MARKETING_VERSION = [0-9.]*;' "$PBX" | awk '{print $3}' | tr -d ';' | sort -u || true)
[ -n "$versions" ] || { echo "no MARKETING_VERSION in $PBX" >&2; exit 1; }
if [ "$(printf '%s\n' "$versions" | wc -l | tr -d ' ')" != 1 ]; then
  echo "the targets' versions differ ($(echo $versions)): set MARKETING_VERSION to one version in every target" >&2
  exit 1
fi
echo "$versions"
