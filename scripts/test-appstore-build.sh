#!/bin/bash
# test-appstore-build.sh [Debug|Release] — builds the App Store target (SequelBridgeAppStore)
# in derived data of its own and checks the product: sandboxed, with the App Store
# entitlements and no exception; no Sparkle (framework, code or Info.plist keys); the App
# Store Info.plist keys; the privacy manifest; macOS 14. And that the DMG build still
# carries Sparkle.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
DD="${SB_APPSTORE_DD:-$HOME/Library/Caches/SequelBridge-appstore/dd}"
mkdir -p "$(dirname "$DD")"
SIGN=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fail() { echo "FAIL: $*"; exit 1; }
build() {   # scheme derived-data log
  xcodebuild build -scheme "$1" -configuration "$CONFIG" -destination 'platform=macOS' -derivedDataPath "$2" \
    "${SIGN[@]}" > "$3" 2>&1 || { grep -E "error:" "$3" | head -5; fail "$1 doesn't build ($3)"; }
}
build SequelBridgeAppStore "$DD" "$DD.log"
APP="$DD/Build/Products/$CONFIG/SequelBridge.app"
ENT=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
keys=$(echo "$ENT" | plutil -convert json -o - - | python3 -c 'import json,sys; print(" ".join(sorted(k for k, v in json.load(sys.stdin).items() if v is True)))')
want="com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write com.apple.security.network.client com.apple.security.network.server"
[ "${keys/ com.apple.security.get-task-allow/}" = "$want" ] || fail "entitlements: $keys"
grep -q "temporary-exception" <<< "$ENT" && fail "an entitlement exception"
[ ! -e "$APP/Contents/Frameworks/Sparkle.framework" ] || fail "Sparkle.framework in the App Store build"
# Counted, not `grep -q`: under pipefail a match there stops grep early, the tool before it
# dies of SIGPIPE, and the failed pipeline skipped the `&& fail` (a binary with Sparkle passed).
[ "$(otool -L "$APP/Contents/MacOS/SequelBridge" | grep -c Sparkle)" = 0 ] || fail "the App Store build links Sparkle"
[ "$(nm "$APP/Contents/MacOS/SequelBridge" 2>/dev/null | grep -c "SPUUpdater")" = 0 ] || fail "Sparkle code in the App Store build"
P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$P" >/dev/null 2>&1 && fail "SUFeedURL in the App Store Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$P")" = "false" ] || fail "ITSAppUsesNonExemptEncryption"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$P")" = "public.app-category.developer-tools" ] || fail "category"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$P")" = "14.0" ] || fail "minimum macOS"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$P")" = "gwadekar.SequelBridge" ] || fail "bundle id"
M="$APP/Contents/Resources/PrivacyInfo.xcprivacy"
[ -f "$M" ] && [ "$(plutil -convert json -o - "$M")" = "$(plutil -convert json -o - SequelBridge/PrivacyInfo.xcprivacy)" ] \
  || fail "the privacy manifest isn't in the App Store build"
echo "App Store build: sandboxed, no Sparkle, App Store keys, privacy manifest ($CONFIG)"
build SequelBridge "$DD-direct" "$DD-direct.log"
[ -e "$DD-direct/Build/Products/$CONFIG/SequelBridge.app/Contents/Frameworks/Sparkle.framework" ] || fail "the DMG build lost Sparkle"
echo "DMG build: Sparkle as before"
"$PWD/scripts/forget-builds.sh" "$DD/Build/Products" "$DD-direct/Build/Products"
