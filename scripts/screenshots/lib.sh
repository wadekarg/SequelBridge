#!/bin/bash
# lib.sh — drives a renamed copy of the app (SequelBridgeShots) through macOS
# accessibility for the guide screenshots. No synthetic keystrokes: clicks go
# through a frontmost guard, text goes in as an accessibility value. Sourced by
# scripts/capture-screenshots.sh and scripts/screenshots/test-guard.sh.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DD=/tmp/sb-shots-dd
APP="$DD/Build/Products/Release/SequelBridgeShots.app"
PROC=SequelBridgeShots
FIXTURE=/tmp/sb-shots-connections.json
REF_COPY=/tmp/sb-shots-ref/ref.sqlite         # the demo SQLite file, outside the protected Desktop folder
SUPPORT=/tmp/sb-shots-support                  # the instance's own history/saved queries, never the owner's
DEMO_NAMES="Analytics CRM Reference Shop"     # sorted; the only names the guard accepts
UI="$REPO/scripts/screenshots/ui"
WIN_X=176; WIN_Y=131; WIN_W=1440; WIN_H=840

shots_build() {   # Release build, renamed so System Events can address it by name beside the owner's app
  xcodebuild -project "$REPO/SequelBridge.xcodeproj" -scheme SequelBridge -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
  local src="$DD/Build/Products/Release/SequelBridge.app"
  rm -rf "$APP" && cp -R "$src" "$APP"
  mv "$APP/Contents/MacOS/SequelBridge" "$APP/Contents/MacOS/$PROC"
  # Its own bundle identifier too, so its defaults (@AppStorage) never touch the owner's.
  local bid; bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $PROC" -c "Set :CFBundleName $PROC" \
    -c "Set :CFBundleIdentifier ${bid}Shots" "$APP/Contents/Info.plist"
  local ident; ident=$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
  codesign -f -s "$ident" --deep --preserve-metadata=entitlements,flags "$APP" 2>&1 | tail -1
  [ -x "$UI" ] || swiftc -O -o "$UI" "$REPO/scripts/screenshots/ui.swift"
}

shots_launch() {  # $1 = theme (Light); uses the fixture with the repo path filled in
  # The SQLite demo file is opened from a copy: the repo usually sits in ~/Desktop, and an
  # app opening a file there makes macOS ask for Desktop access, which blocks the open until
  # someone answers. A fresh copy each launch also starts every run from the committed data.
  mkdir -p "$(dirname "$REF_COPY")" && cp -f "$REPO/scripts/fixtures/demo/ref.sqlite" "$REF_COPY"
  sed -e "s#__REPO__/scripts/fixtures/demo/ref.sqlite#$REF_COPY#" -e "s#__REPO__#$REPO#" \
    "$REPO/scripts/fixtures/demo-connections.json" > "$FIXTURE"
  if grep -qE "$HOME/(Desktop|Documents|Downloads)/" "$FIXTURE"; then
    echo "ABORT: the fixture opens a file in a folder macOS asks permission for"; exit 7; fi
  pkill -f "$PROC.app/Contents/MacOS" 2>/dev/null || true; sleep 1   # (no match is fine under set -e)
  # A fresh support folder each launch: the console shows only this run's statements,
  # and nothing is written into the owner's history or saved queries.
  rm -rf "$SUPPORT"; mkdir -p "$SUPPORT"
  open -n "$APP" --args -SBConnectionsFile "$FIXTURE" -SBSupportDir "$SUPPORT" -theme "${1:-Light}" -ApplePersistenceIgnoreState YES
  local i; for i in $(seq 1 60); do sleep 0.5
    [ "$(osascript -e "tell application \"System Events\" to tell application process \"$PROC\" to count of windows" 2>/dev/null)" -ge 1 ] 2>/dev/null && break; done
  osascript -e "tell application \"System Events\" to tell application process \"$PROC\"
set frontmost to true
set position of window 1 to {$WIN_X, $WIN_Y}
set size of window 1 to {$WIN_W, $WIN_H}
end tell" >/dev/null
  sleep 1
  # Read the frame back: every click position and capture assumes exactly this window.
  local geom; geom=$("$UI" wins 2>/dev/null | awk -v p="$PROC" '$2 == p {print $(NF-1), $NF; exit}')
  [ "$geom" = "$WIN_X,$WIN_Y ${WIN_W}x${WIN_H}" ] || { echo "ABORT: window is at '$geom', expected '$WIN_X,$WIN_Y ${WIN_W}x${WIN_H}'"; shots_quit; exit 6; }
}

shots_quit() { pkill -f "$PROC.app/Contents/MacOS" 2>/dev/null || true; sleep 1; }

front() { osascript -e "tell application \"System Events\" to get frontmost of application process \"$PROC\"" 2>/dev/null; }

gclick() {        # click only while the shots app is frontmost before and after (never the owner's windows)
  local a; for a in 1 2 3 4 5 6; do
    osascript -e "tell application \"System Events\" to set frontmost of application process \"$PROC\" to true" >/dev/null 2>&1; sleep 0.4
    [ "$(front)" = "true" ] && break; sleep 2; done
  [ "$(front)" = "true" ] || { echo "ABORT: shots app not frontmost before click ($1,$2)"; exit 2; }
  "$UI" click "$1" "$2"
  [ "$(front)" = "true" ] || { echo "ABORT: focus changed around click ($1,$2)"; exit 3; }
}

ax_home_names() { # the connection names shown on Home, one per line (badges, hosts and the folder header filtered out)
  osascript <<OSA 2>/dev/null | grep -vxE "My|Pg|Lite|CH|Demo" | grep -vE ":|\\." || true
with timeout of 20 seconds
tell application "System Events" to tell application process "$PROC"
  set names to {}
  set elems to entire contents of scroll area 1 of group 1 of window 1
  repeat with e in elems
    try
      if (class of e) as text is "static text" then set end of names to (value of e as text)
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return names as text
end tell
end timeout
OSA
}

shots_guard() {   # abort unless Home shows exactly the four demo connections and the fixture is local-only
  local names; names=$(ax_home_names | sort | tr '\n' ' ' | sed 's/ $//')
  [ "$names" = "$DEMO_NAMES" ] || { echo "ABORT: Home shows '$names', expected '$DEMO_NAMES' — not capturing"; shots_quit; exit 4; }
  if grep -vE "127\\.0\\.0\\.1" "$FIXTURE" | grep -qE "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}"; then
    echo "ABORT: a non-local host in the fixture"; shots_quit; exit 4; fi
  echo "guard ok: $names"
}

ax_status() {     # results status bar text ("N rows | 0.3s | ...")
  osascript <<OSA 2>/dev/null
with timeout of 10 seconds
tell application "System Events" to tell application process "$PROC"
  set out to ""
  try
    set res to group 2 of splitter group 1 of group 2 of splitter group 1 of group 1 of window 1
    repeat with e in (UI elements of res)
      try
        if (class of e) as text is "static text" then set out to out & (value of e as text) & " | "
      end try
    end repeat
  end try
  return out
end tell
end timeout
OSA
}

ax_set_editor() { # $1 = SQL; the editor accepts an accessibility value (SQLTextView routes it through the binding)
  osascript - "$1" <<'OSA' >/dev/null
on run argv
with timeout of 30 seconds
tell application "System Events" to tell application process "SequelBridgeShots"
  set ta to text area 1 of scroll area 1 of group 1 of splitter group 1 of group 2 of splitter group 1 of group 1 of window 1
  set value of ta to (item 1 of argv)
end tell
end timeout
end run
OSA
  sleep 1
}

ax_click_tab() {  # $1 = feature tab title; the tabs are the nine buttons of the toolbar's group, in this order
  # (clicked by position: inside one toolbar item group every button reports the group's
  # accessibility label, "Structure", so the titles can't be searched for)
  local tabs=("Structure" "Content" "Relations" "Triggers" "Table Info" "Routines" "Server" "Query" "Console")
  local i n=0; for i in "${!tabs[@]}"; do [ "${tabs[$i]}" = "$1" ] && n=$((i + 1)); done
  [ "$n" -gt 0 ] || { echo "NOT A TAB: $1"; return 1; }
  local a; for a in 1 2; do   # a first click right after a state change can time out without landing
    osascript -e "with timeout of 8 seconds
tell application \"System Events\" to tell application process \"$PROC\" to click button $n of group 1 of toolbar 1 of window 1
end timeout" >/dev/null 2>&1 && { echo "clicked $1 (toolbar button $n)"; sleep 1.2; return 0; }
    sleep 1; done
  echo "TAB CLICK FAILED: $1"; return 1
}


wait_rows() {     # until the status bar shows a final row count (no "Loading"), max $1 s
  local i; for i in $(seq 1 "${1:-120}"); do
    local st; st=$(ax_status)
    echo "$st" | grep -q "Query Error" && { echo "QUERY ERROR: $st"; return 1; }
    echo "$st" | grep -qE "[0-9][0-9,]* rows" && ! echo "$st" | grep -q "Loading" && return 0
    sleep 1; done; echo "TIMEOUT waiting for rows: $(ax_status)"; return 1
}

capture_window() { # $1 = output png; the main window with its shadow and any open menu. Refuses when the
  # window isn't on screen: a region of the screen could show anything of the owner's, so there is no fallback.
  # The app must be frontmost, or the picture shows an inactive window (grey controls, a smaller shadow).
  local a; for a in 1 2 3 4 5; do
    osascript -e "tell application \"System Events\" to tell application process \"$PROC\" to set frontmost to true" >/dev/null 2>&1; sleep 0.8
    [ "$(front)" = "true" ] && break; sleep 2; done
  [ "$(front)" = "true" ] || { echo "ABORT: $PROC is not frontmost — not capturing $1"; return 5; }
  # the process's window of the main window's size — not its frontmost, which can be a tooltip (BSD awk: no IGNORECASE)
  local wid; wid=$("$UI" wins 2>/dev/null | awk -v p="$PROC" -v s="${WIN_W}x${WIN_H}" '$2 == p && $NF == s {print $1; exit}')
  [ -n "$wid" ] || { echo "ABORT: no ${WIN_W}x${WIN_H} window of $PROC on screen — not capturing $1"; return 5; }
  screencapture -x -l "$wid" "$1" && echo "captured window $wid → $1"
}
