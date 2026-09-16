#!/bin/zsh
# Launches the Debug build directly (so stderr is captured), waits, reports whether it is still alive, and quits it.
# Usage: scripts/launch-check.sh [seconds]   (THUBAN_DUMP_ICON=/path.png writes the rendered dock icon)
set -uo pipefail
cd "$(dirname "$0")/.."
APP=".build/DerivedData/Build/Products/Debug/Thuban Study.app/Contents/MacOS/Thuban Study"
LOG=/tmp/thuban-run.log
SECONDS_TO_WAIT="${1:-6}"
pkill -f "Thuban Study.app/Contents/MacOS" 2>/dev/null
"$APP" > "$LOG" 2>&1 &
PID=$!
sleep "$SECONDS_TO_WAIT"
if kill -0 "$PID" 2>/dev/null; then
  echo "ALIVE (pid $PID)"
  STATUS=0
else
  wait "$PID"
  echo "DEAD (exit $?)"
  STATUS=1
fi
echo "--- stderr/stdout (last 40 lines):"
tail -40 "$LOG"
kill "$PID" 2>/dev/null
pkill -f "Thuban Study.app/Contents/MacOS" 2>/dev/null
echo "--- recent crash reports:"
ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i "thuban" | head -3
exit $STATUS
