#!/bin/bash
# build-release.sh — builds the distributable DMG from a clean working tree: a universal
# (Apple Silicon + Intel) Release archive, exported with a Developer ID, the app and the
# DMG each notarized by Apple and stapled, then checked by Gatekeeper. Nothing is
# published; the DMG lands in .build/release/. The version and build number are the
# project's (run scripts/sync-build-number.sh and set the version first).
#
# Needs: a "Developer ID Application" certificate in the login keychain, and notarytool
# credentials stored once under a profile name:
#   xcrun notarytool store-credentials sequelbridge-notary --apple-id … --team-id …
# Overrides: SB_SIGN_IDENTITY (default: the first Developer ID Application identity),
#            SB_NOTARY_PROFILE (default: sequelbridge-notary).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/.build/release"           # the finished DMG and the logs
# The build itself runs outside the repo: a checkout inside an iCloud-synced folder
# (Desktop, Documents) gets file-provider attributes on every new file, and codesign
# rejects those ("resource fork, Finder information, or similar detritus not allowed").
WORK="${SB_RELEASE_WORK:-$HOME/Library/Caches/SequelBridge-release}"
PROFILE="${SB_NOTARY_PROFILE:-sequelbridge-notary}"
IDENT="${SB_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"')}"
[ -n "$IDENT" ] || { echo "No Developer ID Application identity in the keychain"; exit 1; }
TEAM=$(echo "$IDENT" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
VERSION=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' SequelBridge.xcodeproj/project.pbxproj | awk '{print $3}')
DMG="$WORK/SequelBridge-$VERSION.dmg"
step() { printf '\n==> %s\n' "$*"; }

[ -z "$(git status --porcelain)" ] || { echo "The working tree has changes; commit them first"; exit 1; }
rm -rf "$OUT" "$WORK"; mkdir -p "$OUT" "$WORK"
echo "SequelBridge $VERSION, signed by $IDENT, notary profile $PROFILE"

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key><string>export</string>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM</string>
</dict>
</plist>
PLIST

step "archive (Release, arm64 + x86_64)"
xcodebuild -project SequelBridge.xcodeproj -scheme SequelBridge -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/dd" \
  -archivePath "$WORK/SequelBridge.xcarchive" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO archive \
  > "$OUT/archive.log" 2>&1 || {
    grep -E "error:|detritus|failed with" "$OUT/archive.log" | head || true
    echo "archive failed: $OUT/archive.log"; exit 1; }

step "export (Developer ID)"
xcodebuild -exportArchive -archivePath "$WORK/SequelBridge.xcarchive" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export" > "$OUT/export.log" 2>&1 \
  || { tail -20 "$OUT/export.log"; echo "export failed"; exit 1; }
APP="$WORK/export/SequelBridge.app"
P="$APP/Contents/Info.plist"
echo "version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$P") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$P"), $(lipo -archs "$APP/Contents/MacOS/SequelBridge")"
[ "$(ls "$APP/Contents/MacOS")" = "SequelBridge" ] || { echo "unexpected files in Contents/MacOS"; exit 1; }
codesign --verify --deep --strict "$APP"
# (captured first: `codesign | grep -q` reports a match as a failure under pipefail,
# because grep closes the pipe early and codesign dies of SIGPIPE)
sig=$(codesign -dv "$APP" 2>&1)
grep -q "flags=.*runtime" <<<"$sig" || { echo "hardened runtime is off"; exit 1; }

notarize() { # $1 file: submit, wait, require Accepted
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait > "$OUT/notary.log" 2>&1 || true
  grep -q "status: Accepted" "$OUT/notary.log" || { cat "$OUT/notary.log"; echo "notarization not accepted: $1"; exit 1; }
  echo "notarized: $(basename "$1")"
}

step "notarize and staple the app"
ditto -c -k --keepParent "$APP" "$WORK/SequelBridge-app.zip"
notarize "$WORK/SequelBridge-app.zip"
xcrun stapler staple -q "$APP"

step "DMG: sign, notarize, staple"
mkdir -p "$WORK/dmg" && cp -R "$APP" "$WORK/dmg/" && ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname "SequelBridge" -srcfolder "$WORK/dmg" -ov -format UDZO "$DMG"
codesign -s "$IDENT" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"
cp "$DMG" "$OUT/"
DMG="$OUT/$(basename "$DMG")"

step "Gatekeeper"
spctl -a -t open --context context:primary-signature "$DMG"
M=$(mktemp -d); hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$M" "$DMG" >/dev/null
spctl -a -t exec "$M/SequelBridge.app"
sleep 2; hdiutil detach "$M" -quiet 2>/dev/null || hdiutil detach "$M" -force -quiet   # Spotlight can hold it briefly
echo "accepted: the DMG and the app inside it (Notarized Developer ID)"
echo "$DMG"
shasum -a 256 "$DMG"
