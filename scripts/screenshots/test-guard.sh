#!/bin/bash
# test-guard.sh — the capture guard must refuse a fixture with a fifth, non-demo
# connection, before taking a single picture. Needs the shots app built (shots_build).
set -u
cd "$(dirname "$0")/../.."
source scripts/screenshots/lib.sh
python3 - "$REPO" <<'PY'
import json, sys
repo = sys.argv[1]
d = json.load(open('scripts/fixtures/demo-connections.json'))
for c in d:
    c['database'] = c['database'].replace('__REPO__', repo)
d.append({"id": "7E3C9A10-0009-4000-8000-000000000009", "name": "Intruder", "alias": "intr", "connectionType": "TCP/IP",
          "color": "#FF0000", "host": "10.0.0.9", "port": 3306, "username": "x", "database": "d", "engine": "mysql"})
json.dump(d, open('/tmp/sb-shots-connections.json', 'w'))
PY
pkill -f "$PROC.app/Contents/MacOS" 2>/dev/null; sleep 1
open -n "$APP" --args -SBConnectionsFile "$FIXTURE" -theme Light -ApplePersistenceIgnoreState YES
for i in $(seq 1 60); do sleep 0.5
  [ "$(osascript -e "tell application \"System Events\" to tell application process \"$PROC\" to count of windows" 2>/dev/null)" -ge 1 ] 2>/dev/null && break; done
sleep 1
if (shots_guard); then echo "FAIL: guard accepted a foreign connection"; shots_quit; exit 1
else echo "PASS: guard refused the foreign connection"; shots_quit; exit 0; fi
