#!/bin/bash
# test-capture-abort.sh — capture_window must refuse (non-zero, no file) when the demo
# window is not on screen. It must never fall back to a region of the screen, which
# could show anything of the owner's. Needs no running app.
set -u
source "$(dirname "$0")/lib.sh"
PROC="SequelBridgeShotsNotRunning"            # no such process, so no window
WIN_X=0; WIN_Y=0; WIN_W=1; WIN_H=1            # a region fallback, if one still existed, would grab one pixel
out="$(mktemp -d)/capture.png"
if capture_window "$out" >/dev/null 2>&1; then
  echo "FAIL: capture_window reported success without the window"; rm -f "$out"; exit 1
fi
if [ -e "$out" ]; then
  echo "FAIL: a file was written without the window"; rm -f "$out"; exit 1
fi
echo "PASS: capture refused without the window"
