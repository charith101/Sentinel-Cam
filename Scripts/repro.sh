#!/bin/zsh
# Repro harness: rebuild, run dist app under lldb with a fatal-exception trap,
# print PASS (no loop-crash within runtime) or FAIL (crashed).
# Usage: repro.sh [timeout-seconds] [run-args...]
set -uo pipefail
cd "$(dirname "$0")/.."
TIMEOUT="${1:-45}"
shift || true
SW=`swift build -c release 2>&1 | tail -1`
if [[ "$SW" != *complete* ]]; then echo BUILD-FAIL; echo "$SW" | tail -5; exit 9; fi
APP="dist/Sentinel.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sentinel "$APP/Contents/MacOS/Sentinel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1

LOG=/private/var/folders/yb/5w_ys32x6wl11_sghr5b24y80000gn/T/opencode/repro-last.log
osascript -e 'quit app id "com.charith.sentinel"' 2>/dev/null
sleep 1
lldb -b -s /private/var/folders/yb/5w_ys32x6wl11_sghr5b24y80000gn/T/opencode/sentinel-trap.lldb \
  $APP/Contents/MacOS/Sentinel -- "$@" > "$LOG" 2>&1 &
LLDB_PID=$!
# Pin the cursor over the window content: AppKit runs cursor-tracking hit tests
# on every display cycle while the pointer sits over the window (matches the
# crash stacks). CGWarpMouseCursorPosition works without Accessibility.
( sleep 3; swift Scripts/warp-cursor.swift >/dev/null 2>&1 ) &
START=$(date +%s)
CRASHED=0
while :; do
  sleep 2
  if ! kill -0 $LLDB_PID 2>/dev/null; then CRASHED=1; break; fi
  NOW=$(date +%s); if (( NOW-START >= TIMEOUT )); then break; fi
done
if (( ! CRASHED )); then
  kill -9 $LLDB_PID 2>/dev/null
  sleep 1
  pkill -9 -f "dist/Sentinel.app/Contents/MacOS/Sentinel" 2>/dev/null
fi
sleep 1
if grep -q "Update Constraints in Window pass" "$LOG" 2>/dev/null; then
  echo "FAIL: loop-detector fired"
  exit 1
else
  echo "PASS: ran ${TIMEOUT}s clean"
  exit 0
fi
