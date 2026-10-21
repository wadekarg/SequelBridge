#!/bin/bash
# test-update-e2e.sh APP — the in-app updater end to end, headless: an older copy of APP
# updates itself to a newer one from a feed served on 127.0.0.1, and refuses an update
# whose file doesn't match its signature. The real chain: the feed scripts/release-feed.py
# writes, an Ed25519 signature from Sparkle's sign_update checked against the app's
# SUPublicEDKey, the code signature checked against the old copy's, the install.
#
# Nothing of the owner's is used: a throwaway signing key (not the release key in the
# Keychain), copies under a test bundle id (Sparkle keeps its state in the bundle's
# defaults; the real app's are untouched) in a temp folder. Sparkle's command-line
# updater (sparkle-cli) is built once from Sparkle's 2.10.0 source, outside the repo:
# codesign refuses what is built in an iCloud-synced folder such as ~/Desktop.
# Needs a "Developer ID Application" identity: Sparkle installs an update only when it is
# signed like the copy it replaces.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$(pwd)
APP="${1:?usage: test-update-e2e.sh path/to/SequelBridge.app}"
ID="gwadekar.SequelBridge.UpdateTest"
PORT=8765
IDENT=$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
[ -n "$IDENT" ] || { echo "No Developer ID Application identity in the keychain"; exit 1; }
fail() { echo "FAIL: $*"; exit 1; }

# Sparkle's command-line updater, built once.
CACHE="$HOME/Library/Caches/SequelBridge-test"
CLI="$CACHE/sparkle-cli/Build/Products/Release/sparkle.app/Contents/MacOS/sparkle"
if [ ! -x "$CLI" ]; then
  mkdir -p "$CACHE"
  [ -d "$CACHE/sparkle-src" ] || git -c advice.detachedHead=false clone -q --depth 1 --branch 2.10.0 \
    https://github.com/sparkle-project/Sparkle "$CACHE/sparkle-src"
  xcodebuild build -project "$CACHE/sparkle-src/Sparkle.xcodeproj" -scheme sparkle-cli -configuration Release \
    -derivedDataPath "$CACHE/sparkle-cli" CODE_SIGN_IDENTITY=- > "$CACHE/sparkle-cli.log" 2>&1 \
    || { tail -20 "$CACHE/sparkle-cli.log"; fail "sparkle-cli didn't build"; }
fi

T=$(mktemp -d /private/tmp/sb-update-e2e.XXXXXX)
SERVER=""
cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  defaults delete "$ID" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

# A throwaway Ed25519 key: the private seed for sign_update, the public key for the copies.
read -r PRIV PUB < <(python3 - <<'EOF'
import base64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = Ed25519PrivateKey.generate()
seed = k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())
pub = k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
print(base64.b64encode(seed).decode(), base64.b64encode(pub).decode())
EOF
)

# A copy of APP as version $2 (build $3), under the test bundle id, signed like a release.
copy_as() { # $1 destination .app, $2 version, $3 build
  ditto "$APP" "$1"
  xattr -cr "$1"
  local plist="$1/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleShortVersionString $2" \
    -c "Set :CFBundleVersion $3" -c "Set :SUPublicEDKey $PUB" "$plist"
  codesign --force --options runtime --timestamp=none --sign "$IDENT" "$1/Contents/Frameworks/Sparkle.framework" 2>/dev/null
  codesign --force --options runtime --timestamp=none --sign "$IDENT" --preserve-metadata=entitlements "$1" 2>/dev/null
  codesign --verify --strict "$1" || fail "the copy $2 isn't validly signed"
}
version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"; }

mkdir -p "$T/feed"
copy_as "$T/new/SequelBridge.app" 9.0.1 9001
ditto -c -k --sequesterRsrc --keepParent "$T/new/SequelBridge.app" "$T/feed/SequelBridge-9.0.1.zip"
printf '%s' "$PRIV" > "$T/test-key"
SIG=$("$ROOT/vendor/Sparkle/bin/sign_update" --ed-key-file "$T/test-key" "$T/feed/SequelBridge-9.0.1.zip")
python3 scripts/release-feed.py --version 9.0.1 --build 9001 --dmg "$T/feed/SequelBridge-9.0.1.zip" \
  --signature "$SIG" --out "$T/feed" --download-url "http://127.0.0.1:$PORT/SequelBridge-9.0.1.zip" > /dev/null
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/feed" > "$T/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/appcast.xml" && break; sleep 0.2; done

run_cli() { # $1 .app, $2 probe (only look) or install
  local mode=(--check-immediately)
  [ "$2" = probe ] && mode=(--probe)
  "$CLI" "$1" "${mode[@]}" --grant-automatic-checks --user-agent-name SBUpdateTest \
    --feed-url "http://127.0.0.1:$PORT/appcast.xml" > "$T/cli.log" 2>&1
}

# 1. The old copy sees the update, installs it, and is the new version after.
copy_as "$T/old/SequelBridge.app" 9.0.0 9000
run_cli "$T/old/SequelBridge.app" probe || { cat "$T/cli.log"; fail "no update offered to 9.0.0"; }
run_cli "$T/old/SequelBridge.app" install || { cat "$T/cli.log"; fail "the update didn't install"; }
[ "$(version_of "$T/old/SequelBridge.app")" = "9.0.1" ] || { cat "$T/cli.log"; fail "still $(version_of "$T/old/SequelBridge.app") after the update"; }
codesign --verify --strict "$T/old/SequelBridge.app" || fail "the updated app isn't validly signed"
echo "ok: 9.0.0 updated itself to 9.0.1"

# 2. A file that doesn't match its signature is refused, and the copy stays as it was.
printf 'x' >> "$T/feed/SequelBridge-9.0.1.zip"
copy_as "$T/old2/SequelBridge.app" 9.0.0 9000
defaults delete "$ID" >/dev/null 2>&1 || true
if run_cli "$T/old2/SequelBridge.app" install; then cat "$T/cli.log"; fail "a tampered update was accepted"; fi
[ "$(version_of "$T/old2/SequelBridge.app")" = "9.0.0" ] || fail "a tampered update changed the app"
grep -q "improperly signed" "$T/cli.log" || { cat "$T/cli.log"; fail "refused, but not for its signature"; }
echo "ok: a tampered update was refused"
echo "update end to end ok"
