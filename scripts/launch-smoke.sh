#!/bin/bash
# launch-smoke.sh APP — starts a built SequelBridge.app on a throwaway support folder and a
# one-connection list (a SQLite file), and checks that after 20 seconds it is still
# running, has a window, and left no crash report. For a Mac whose Xcode can't run the
# test suites: the macOS 14 job in .github/workflows/test.yml, since Xcode 26, which the
# app needs, doesn't run on macOS 14. It shows the app starts and stays up there.
set -u
APP="${1:-}"
BIN="$APP/Contents/MacOS/SequelBridge"
[ -x "$BIN" ] || { echo "usage: launch-smoke.sh path/to/SequelBridge.app"; exit 2; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UI="$REPO/scripts/screenshots/ui"
[ -x "$UI" ] || swiftc -O -o "$UI" "$REPO/scripts/screenshots/ui.swift" || { echo "FAIL: couldn't build the window lister"; exit 1; }
echo "macOS $(sw_vers -productVersion) on $(uname -m); app $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

W=$(mktemp -d)
/usr/bin/sqlite3 "$W/smoke.sqlite" "CREATE TABLE t (id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1);"
cat > "$W/connections.json" <<EOF
[{"id": "5B0A0000-0000-4000-8000-000000000401", "name": "Smoke", "alias": "smoke", "connectionType": "TCP/IP",
  "color": "#3A9AA8", "host": "", "port": 0, "username": "", "database": "$W/smoke.sqlite", "engine": "sqlite",
  "folder": "", "readOnly": false}]
EOF
mkdir -p "$W/support"
before=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -c '^SequelBridge')

"$BIN" -SBConnectionsFile "$W/connections.json" -SBSupportDir "$W/support" \
  -ApplePersistenceIgnoreState YES -theme Light > "$W/app.log" 2>&1 &
PID=$!
sleep 20
alive=1; kill -0 "$PID" 2>/dev/null || alive=0
windows=$("$UI" wins 2>/dev/null | awk '$2 == "SequelBridge"' | wc -l | tr -d ' ')
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
after=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -c '^SequelBridge')

if [ "$alive" != 1 ]; then echo "FAIL: the app exited within 20 seconds"; tail -40 "$W/app.log"; exit 1; fi
if [ "$after" -gt "$before" ]; then echo "FAIL: a crash report appeared"; ls -t "$HOME/Library/Logs/DiagnosticReports" | grep '^SequelBridge' | head -3; exit 1; fi
if [ "$windows" -lt 1 ]; then echo "FAIL: no window after 20 seconds"; tail -40 "$W/app.log"; exit 1; fi
echo "PASS: the app started, showed $windows window(s) and stayed up for 20 seconds"
