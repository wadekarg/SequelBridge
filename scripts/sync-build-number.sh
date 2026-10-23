#!/usr/bin/env bash
# Sync the app's build number (CURRENT_PROJECT_VERSION → CFBundleVersion) to the git
# commit count, giving every release a unique, monotonically-increasing build number.
# Run this before cutting a release/DMG. The marketing version (MARKETING_VERSION) is
# a human decision: bump it in every target (the DMG build's and the App Store build's
# carry the same one; scripts/project-version.sh refuses them unequal).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# The public history starts at the 1.2.0 release commit. The 94 commits made before it
# are added back, so build numbers keep increasing past 1.1.0's build 52.
HISTORY_BEFORE_1_2_0=94
n=$(( $(git rev-list --count HEAD) + HISTORY_BEFORE_1_2_0 ))
pbxproj="SequelBridge.xcodeproj/project.pbxproj"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${n};/g" "$pbxproj"
echo "Build number (CURRENT_PROJECT_VERSION) set to ${n}"
