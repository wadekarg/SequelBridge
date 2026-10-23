#!/bin/bash
# check-appstore-sandbox.sh [--ci] — the App Store build, truly sandboxed: built from the
# SequelBridgeAppStore scheme under a bundle id of its own (its own container, removed after)
# with folders openable (scripts/fixtures/sandbox-check-Info.plist), it is opened with an
# ~/.ssh stand-in and a folder holding a SQLite file, which grants them as an open panel
# would, and runs its own SSH and SQLite code there (-SBSandboxCheck): a key login and a
# passphrase key answered through the shipped askpass helper, through to the server, with
# the server's key remembered in the granted folder; a SQLite write in-process and by
# macOS's sqlite3; no socket offered; no Sparkle. Then a second launch, from the saved
# grants only. Local: the test SSH server (sb-sshd, :2224) and the repo's test keys.
# --ci: an sshd of its own on 127.0.0.1:2226 with fresh keys (GitHub's runners; beside
# sb-sshd's 2224, so it runs on a Mac with the test servers up too).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
ID=gwadekar.SequelBridge.sandboxcheck
W="$(mktemp -d)"
DD="${SB_APPSTORE_DD:-$HOME/Library/Caches/SequelBridge-appstore/check-dd}"
APP="$DD/Build/Products/Debug/SequelBridge.app"
C="$HOME/Library/Containers/$ID/Data"
finished=0
# Each cleanup step may find nothing to do: under set -e, a failing one would end the trap.
trap 'pkill -f "$APP/Contents/MacOS/SequelBridge" || true; pkill -f "$W/sshd_config" || true
      "$REPO/scripts/forget-builds.sh" "$DD/Build/Products"
      rm -rf "$W" "$HOME/Library/Containers/$ID"; [ "$finished" = 1 ] || exit 1' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$W/ssh" "$W/sqlite" "$(dirname "$DD")"
rm -rf "$HOME/Library/Containers/$ID"   # a run that was killed leaves its grants
if [ "${1:-}" = "--ci" ]; then
  SSH_PORT=2226
  ssh-keygen -q -t ed25519 -N "" -f "$W/ssh/key"
  ssh-keygen -q -t ed25519 -N "sbphrase" -f "$W/ssh/phrase_key"
  ssh-keygen -q -t ed25519 -N "" -f "$W/hostkey"
  cat "$W/ssh/key.pub" "$W/ssh/phrase_key.pub" > "$W/authorized_keys"
  printf 'Port %s\nListenAddress 127.0.0.1\nHostKey %s/hostkey\nAuthorizedKeysFile %s/authorized_keys\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPidFile %s/sshd.pid\nStrictModes no\n' "$SSH_PORT" "$W" "$W" "$W" > "$W/sshd_config"
  /usr/sbin/sshd -f "$W/sshd_config" -E "$W/sshd.log"
  SSH_USER="$(whoami)"; TARGET="127.0.0.1:$SSH_PORT"
else
  cp "$REPO/.build/ssh/sb_test_key" "$W/ssh/key"; cp "$REPO/.build/ssh/sb_phrase_key" "$W/ssh/phrase_key"
  SSH_PORT=2224; SSH_USER=tunneluser; TARGET="127.0.0.1:2222"   # sb-sshd's own sshd, seen from the server
fi
chmod 600 "$W/ssh/key" "$W/ssh/phrase_key"; : > "$W/ssh/known_hosts"
sqlite3 "$W/sqlite/check.sqlite" "CREATE TABLE t (x INTEGER);"

xcodebuild build -scheme SequelBridgeAppStore -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DD" \
  PRODUCT_BUNDLE_IDENTIFIER="$ID" INFOPLIST_FILE="$REPO/scripts/fixtures/sandbox-check-Info.plist" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= > "$DD.log" 2>&1 || { grep error: "$DD.log" | head; fail "build"; }
ARGS=(-SBCheckSSH "127.0.0.1" "$SSH_PORT" "$SSH_USER" -SBCheckTarget "$TARGET" -SBCheckPassphrase sbphrase -SBCheckSQLite check.sqlite)

run() {   # report-name [folders…]
  local name="$1"; shift
  rm -f "$C/tmp/$name.json"
  open -g -j -n -a "$APP" "$@" --args -SBSandboxCheck "$name" "${ARGS[@]}"
  for _ in $(seq 1 90); do [ -f "$C/tmp/$name.json" ] && break; sleep 1; done
  [ -f "$C/tmp/$name.json" ] || fail "no report from the $name launch"
  python3 - "$C/tmp/$name.json" "$name" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); name = sys.argv[2]
want = {"sandboxed": "yes", "sparkle": "absent", "sockets": "not offered",
        "ssh.key": "tunnel works", "ssh.passphrase": "tunnel works",
        "sqlite.duckdb": "written", "sqlite.sqlite3": "written"}
bad = {k: r.get(k) for k, v in want.items() if not str(r.get(k, "")).startswith(v)}
print(f"{name}: " + ", ".join(f"{k} {r.get(k)}" for k in want))
sys.exit(f"{name}: {bad}" if bad else 0)
PY
}
run first "$W/ssh" "$W/sqlite"
[ -s "$W/ssh/known_hosts" ] || fail "ssh didn't remember the server in the granted folder"
run second
echo "sandbox check: passed"
finished=1
