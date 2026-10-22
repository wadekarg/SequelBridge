#!/bin/bash
# test-release-feed.sh — checks scripts/release-feed.py on a stand-in DMG: the Sparkle
# feed (appcast.xml) the app reads to offer an update, and the Homebrew cask.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

printf 'not really a dmg' > "$T/SequelBridge-9.8.7.dmg"
SHA=$(shasum -a 256 "$T/SequelBridge-9.8.7.dmg" | awk '{print $1}')
cat > "$T/CHANGELOG.md" <<'EOF'
# Changelog

## 9.8.7 — 2026-10-21

### Fixed
- A thing that was broken
  and the line after it.
- Another one with <tags> & `code`.

### Added
- Something new.
- With **bold** words and a list:
  - **First** item
  - Second item
    across two lines.

## 9.8.6 — 2026-10-01

### Fixed
- Older.
EOF

python3 scripts/release-feed.py --version 9.8.7 --build 321 --dmg "$T/SequelBridge-9.8.7.dmg" \
  --signature 'sparkle:edSignature="c2lnbmF0dXJl" length="16"' --changelog "$T/CHANGELOG.md" --out "$T/out"

F="$T/out/appcast.xml"
xmllint --noout "$F" || fail "appcast.xml is not well-formed XML"
grep -q '<sparkle:version>321</sparkle:version>' "$F" || fail "the build number (Sparkle compares it)"
grep -q '<sparkle:shortVersionString>9.8.7</sparkle:shortVersionString>' "$F" || fail "the version"
grep -q '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>' "$F" || fail "the oldest macOS"
grep -q 'url="https://github.com/wadekarg/SequelBridge/releases/download/v9.8.7/SequelBridge-9.8.7.dmg"' "$F" || fail "the download URL"
grep -q 'sparkle:edSignature="c2lnbmF0dXJl" length="16"' "$F" || fail "the signature and length"
grep -q '<li>A thing that was broken and the line after it.</li>' "$F" || fail "a release note across two lines"
grep -q '<li>Another one with &lt;tags&gt; &amp; <code>code</code>.</li>' "$F" || fail "a note's < & and code"
grep -q '<h3>Added</h3>' "$F" || fail "a section heading"
grep -q '<li>With <b>bold</b> words and a list:<ul><li><b>First</b> item</li><li>Second item across two lines.</li></ul></li>' "$F" \
  || fail "**bold** and a nested list (the update window showed the asterisks)"
! grep -q '\*\*' "$F" || fail "asterisks left in the notes"
! grep -q 'Older' "$F" || fail "the previous version's notes came along"

C="$T/out/sequelbridge.rb"
grep -q '^cask "sequelbridge" do$' "$C" || fail "the cask's name"
grep -q '  version "9.8.7"' "$C" || fail "the cask's version"
grep -q "  sha256 \"$SHA\"" "$C" || fail "the cask's sha256"
grep -q 'url "https://github.com/wadekarg/SequelBridge/releases/download/v#{version}/SequelBridge-#{version}.dmg"' "$C" || fail "the cask's URL"
grep -q '  auto_updates true' "$C" || fail "auto_updates (the app updates itself; brew mustn't fight it)"
grep -q '  depends_on macos: :sonoma$' "$C" || fail "the oldest macOS (Homebrew: :sonoma means Sonoma or later)"
grep -q '  app "SequelBridge.app"' "$C" || fail "the app to install"
if command -v ruby >/dev/null; then ruby -c "$C" >/dev/null || fail "the cask isn't valid Ruby"; fi

# A feed for a local server (the updater's end-to-end check): the download where it says.
python3 scripts/release-feed.py --version 9.8.7 --build 321 --dmg "$T/SequelBridge-9.8.7.dmg" \
  --signature 'sparkle:edSignature="c2lnbmF0dXJl" length="16"' --changelog "$T/CHANGELOG.md" --out "$T/local" \
  --download-url http://127.0.0.1:8765/SequelBridge-9.8.7.zip > /dev/null
grep -q 'url="http://127.0.0.1:8765/SequelBridge-9.8.7.zip"' "$T/local/appcast.xml" || fail "--download-url"
echo "release feed ok"
