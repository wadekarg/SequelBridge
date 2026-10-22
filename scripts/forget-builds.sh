#!/bin/bash
# forget-builds.sh DIR... — Launch Services forgets every app under each DIR; nothing is
# deleted. Xcode registers each app it builds, and macOS opens the highest version of an
# app it knows: a build of the next version in DerivedData or the release cache was
# opened from Spotlight and Finder in place of the copy in Applications. A Debug build
# runs no updater, so there Check for Updates… stayed off.
set -u
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] || exit 0
for dir in "$@"; do
  [ -d "$dir" ] || continue
  find "$dir" -name '*.app' -type d -print0 2>/dev/null | while IFS= read -r -d '' app; do
    "$LSREGISTER" -u "$app" 2>/dev/null
  done
done
exit 0
