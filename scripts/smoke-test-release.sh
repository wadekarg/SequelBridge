#!/bin/bash
# smoke-test-release.sh DMG — tests a release DMG the way a user meets it: launches the
# app from the DMG on the demo connections (scripts/fixtures/demo-connections.json, with
# the demo data seeded by scripts/seed-demo.sh), connects the four demo servers and runs
# one query per path: the three-engine fallback (MySQL × PostgreSQL × SQLite), the
# streamed two-server join, and a ClickHouse-only statement. Each query is judged by the
# app's own statement history (row count, error), kept in a throwaway support folder.
# Everything addresses the test app by PID, since an installed SequelBridge has the same
# process name; clicks only while the test app is frontmost, and no keystrokes. The
# drivers are built in: connecting must install nothing in DuckDB's extension folder.
set -u
DMG="$1"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UI="$REPO/scripts/screenshots/ui"
W="$REPO/.build/release"; mkdir -p "$W"
FIX=/tmp/sb-release-fixture.json
SUP=/tmp/sb-release-support
REF_COPY=/tmp/sb-release-ref/ref.sqlite   # the demo SQLite file, outside the protected Desktop folder
EXT="$HOME/Library/Caches/SequelBridge/duckdb-extensions"   # DuckDB's extension folder, the app's own
fail() { echo "FAIL: $*"
  if [ -n "${PID:-}" ]; then   # a picture of the test window for diagnosis (frontmost, so first in z-order)
    ax "set frontmost to true" >/dev/null; sleep 0.8
    local wid; wid=$("$UI" wins 2>/dev/null | awk '$2 == "SequelBridge" && $(NF-1) == "176,131" && $NF == "1440x840" {print $1; exit}')
    [ -n "$wid" ] && [ "$(front)" = "true" ] && screencapture -x -l "$wid" "$W/smoke-fail.png" && echo "window at failure: $W/smoke-fail.png"
    kill "$PID" 2>/dev/null; sleep 2
  fi
  [ -n "${M:-}" ] && { hdiutil detach "$M" -quiet 2>/dev/null || hdiutil detach "$M" -force -quiet; }
  exit 1; }
ax() { osascript -e "with timeout of 30 seconds
tell application \"System Events\" to tell (first process whose unix id is $PID)
$1
end tell
end timeout" 2>/dev/null; }
front() { ax "get frontmost"; }
click() { local a; for a in 1 2 3 4 5; do ax "set frontmost to true" >/dev/null; sleep 0.4; [ "$(front)" = "true" ] && break; sleep 1.5; done
  [ "$(front)" = "true" ] || fail "test app not frontmost before click ($1,$2)"
  "$UI" click "$1" "$2"
  [ "$(front)" = "true" ] || fail "focus changed around click ($1,$2)"; }
hist_lines() { [ -f "$SUP/history.jsonl" ] && wc -l < "$SUP/history.jsonl" | tr -d ' ' || echo 0; }
hist_result() { # $1 lines to skip, $2 sql: the app's own record of that statement, once it finished
  python3 - "$SUP/history.jsonl" "$1" "$2" <<'PY'
import json, sys
path, skip, sql = sys.argv[1], int(sys.argv[2]), sys.argv[3]
key = " ".join(sql.split())[:30]
try:
    lines = open(path).read().splitlines()[skip:]
except FileNotFoundError:
    lines = []
for line in lines:
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if " ".join(e.get("sql", "").split()).startswith(key):
        print("ERROR " + e["error"] if e.get("error") else f"{e.get('rowsAffected')} rows in {e.get('duration', 0):.3f} s")
        break
PY
}
run_sql() { # $1 sql, $2 label, $3 max seconds — judged by the app's statement history, not the screen
  local before res=""; before=$(hist_lines)
  osascript - "$1" "$PID" <<'OSA' >/dev/null
on run argv
with timeout of 30 seconds
tell application "System Events" to tell (first process whose unix id is ((item 2 of argv) as integer))
  set value of text area 1 of scroll area 1 of group 1 of splitter group 1 of group 2 of splitter group 1 of group 1 of window 1 to (item 1 of argv)
end tell
end timeout
end run
OSA
  sleep 1; click 1565 199
  local i; for i in $(seq 1 "$3"); do sleep 1; res=$(hist_result "$before" "$1"); [ -n "$res" ] && break; done
  case "$res" in
    ERROR*) fail "$2: $res" ;;
    "")     fail "$2: no result recorded after $3 s" ;;
    "0 rows"*|"None rows"*) fail "$2: $res" ;;
    *)      echo "PASS $2: $res" ;;
  esac; }

[ -f "$DMG" ] || { echo "usage: smoke-test-release.sh path/to/SequelBridge-X.Y.Z.dmg"; exit 2; }
[ -x "$UI" ] || swiftc -O -o "$UI" "$REPO/scripts/screenshots/ui.swift"   # the click helper (no typing)
echo "machine: $(uname -m)"
# A copy of the SQLite demo file: opening it inside ~/Desktop (where the repo usually is)
# makes macOS ask the app for Desktop access, and the open waits until someone answers.
mkdir -p "$(dirname "$REF_COPY")" && cp -f "$REPO/scripts/fixtures/demo/ref.sqlite" "$REF_COPY"
sed -e "s#__REPO__/scripts/fixtures/demo/ref.sqlite#$REF_COPY#" -e "s#__REPO__#$REPO#" \
  "$REPO/scripts/fixtures/demo-connections.json" > "$FIX"
grep -qE "$HOME/(Desktop|Documents|Downloads)/" "$FIX" && fail "the fixture opens a file in a folder macOS asks permission for"
rm -rf "$SUP"; mkdir -p "$SUP"
M=$(cd "$(mktemp -d)" && pwd -P)   # the real path (/private/var/…): the process list shows that one, not /var/…
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$M" "$DMG" >/dev/null || fail "mount"
BIN="$M/SequelBridge.app/Contents/MacOS/SequelBridge"
echo "app: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$M/SequelBridge.app/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$M/SequelBridge.app/Contents/Info.plist")"
open -n "$M/SequelBridge.app" --args -SBConnectionsFile "$FIX" -SBSupportDir "$SUP" -theme Light -ApplePersistenceIgnoreState YES
for i in $(seq 1 40); do sleep 0.5; PID=$(pgrep -f "^$BIN" | head -1); [ -n "$PID" ] && break; done
[ -n "${PID:-}" ] || fail "the app did not start"
echo "pid $PID"
for i in $(seq 1 60); do sleep 0.5; [ "$(ax 'count of windows')" -ge 1 ] 2>/dev/null && break; done
[ "$(ax 'count of windows')" -ge 1 ] 2>/dev/null || fail "no window"
ax 'set frontmost to true
set position of window 1 to {176, 131}
set size of window 1 to {1440, 840}' >/dev/null; sleep 1

# Guard: Home must list exactly the demo connections. Read in ONE request against the
# PID: the element references System Events hands back name the process ("SequelBridge"),
# so walking them one by one can resolve to an installed SequelBridge that is running too.
for i in $(seq 1 15); do
  texts=$(ax 'set AppleScript'"'"'s text item delimiters to linefeed
return (value of every static text of every UI element of every row of outline 1 of scroll area 1 of group 1 of window 1) as text')
  names=$(echo "$texts" | grep -xE "Shop|CRM|Reference|Analytics" | sort | tr '\n' ' ' | sed 's/ $//')
  [ "$names" = "Analytics CRM Reference Shop" ] && break
  sleep 1
done
others=$(echo "$texts" | grep -vxE "My|Pg|Lite|CH|Shop|CRM|Reference|Analytics|ref\.sqlite|127\.0\.0\.1:[0-9]+" | grep -v '^$' || true)
[ "$names" = "Analytics CRM Reference Shop" ] && [ -z "$others" ] || fail "Home is not the demo list: names '$names', other texts '$others'"
echo "PASS launch: Home shows the demo list ($(echo "$texts" | tr '\n' ' '))"

for y in 302 351 398 446; do click 213 "$y"; sleep 0.3; done
click 496 945
# Wait for the workspace itself: its toolbar carries the nine feature tabs.
t0=$(date +%s)
for i in $(seq 1 120); do sleep 1; [ "$(ax 'count of buttons of group 1 of toolbar 1 of window 1')" = "9" ] && break; done
[ "$(ax 'count of buttons of group 1 of toolbar 1 of window 1')" = "9" ] || fail "the workspace did not open within 120 s of Connect"
echo "PASS connect: workspace open after $(( $(date +%s) - t0 )) s"
[ -z "$(ls -A "$EXT" 2>/dev/null)" ] || fail "connecting installed into $EXT: $(ls "$EXT" | tr '\n' ' ')"
echo "PASS built-in drivers: connecting installed nothing"
sleep 2; ax 'click button 8 of group 1 of toolbar 1 of window 1' >/dev/null; sleep 1.5

run_sql "$(cat "$REPO/scripts/screenshots/hero.sql")" "MySQL x PostgreSQL x SQLite" 180
run_sql "$(cat "$REPO/scripts/screenshots/cross-engine-join.sql")" "streamed two-server join" 120
run_sql "SELECT event, count() AS n FROM analytics.events GROUP BY event ORDER BY n DESC" "ClickHouse" 60

WID=$("$UI" wins 2>/dev/null | awk '$2 == "SequelBridge" && $(NF-1) == "176,131" && $NF == "1440x840" {print $1; exit}')
[ -n "$WID" ] && screencapture -x -l "$WID" "$W/smoke.png" && echo "screenshot: $W/smoke.png"
kill "$PID"; sleep 1; hdiutil detach "$M" -quiet
echo "SMOKE TEST PASSED"
