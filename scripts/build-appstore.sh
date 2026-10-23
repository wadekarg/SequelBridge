#!/bin/bash
# build-appstore.sh [--upload] — the App Store build from a clean working tree: archived for
# both CPUs from the SequelBridgeAppStore scheme, exported for App Store Connect with Xcode's
# account (Apple Distribution, a Mac App Store profile, automatic signing), and checked:
# sandboxed, no Sparkle, both CPUs, macOS 14, the privacy manifest, the published DuckDB
# package. --upload sends it to App Store Connect (TestFlight, then review): asked first.
# The version and build number are the project's, as in the DMG. The package and the logs
# land in .build/appstore/build/, beside the screenshots and the review's demo file; the
# build itself runs outside the repo, as build-release.sh's does (codesign refuses the
# attributes iCloud gives new files in Desktop and Documents).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${SB_APPSTORE_WORK:-$HOME/Library/Caches/SequelBridge-appstore/release}"
OUT="$PWD/.build/appstore/build"
TEAM=4NJA57K54Y
DEST=export; [ "${1:-}" = "--upload" ] && DEST=upload
finished=0
trap '[ "$finished" = 1 ] || exit 1' EXIT
fail() { echo "FAIL: $*"; exit 1; }
[ -z "$(git status --porcelain)" ] || fail "the working tree has changes; commit them first"
scripts/fetch-duckdb.sh --check-published
python3 scripts/acknowledgements.py --check
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DEST</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild -project SequelBridge.xcodeproj -scheme SequelBridgeAppStore -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/dd" -archivePath "$WORK/SequelBridge.xcarchive" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
  || { grep -E "error:|detritus|failed with" "$OUT/archive.log" | head || true; fail "archive ($OUT/archive.log)"; }
xcodebuild -exportArchive -archivePath "$WORK/SequelBridge.xcarchive" -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -exportPath "$WORK/export" -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
  || { tail -20 "$OUT/export.log"; fail "export ($OUT/export.log)"; }
APP="$WORK/SequelBridge.xcarchive/Products/Applications/SequelBridge.app"
P="$APP/Contents/Info.plist"
ARCHS=$(lipo -archs "$APP/Contents/MacOS/SequelBridge")
echo "SequelBridge $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$P")" \
  "build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$P"), $ARCHS"
# Each tool's output is captured before grep reads it: under pipefail, `tool | grep -q`
# fails on a match when grep stops reading early and the tool dies of SIGPIPE.
ENT=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
grep -q "com.apple.security.app-sandbox" <<< "$ENT" || fail "not sandboxed"
[ ! -e "$APP/Contents/Frameworks/Sparkle.framework" ] || fail "Sparkle in the archive"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || fail "not universal: $ARCHS"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$P")" = "14.0" ] || fail "minimum macOS"
[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] || fail "no privacy manifest"
if [ "$DEST" = export ]; then
  PKG=$(ls "$WORK/export"/*.pkg 2>/dev/null | head -1 || true)
  [ -n "$PKG" ] || fail "no package in $WORK/export"
  SIG=$(pkgutil --check-signature "$PKG")
  grep -q -E "Installer|Distribution" <<< "$SIG" || fail "the package isn't signed for the App Store"
  cp "$PKG" "$OUT/"
  echo "App Store package: $OUT/$(basename "$PKG")"
else
  echo "Uploaded to App Store Connect: see TestFlight"
fi
finished=1
