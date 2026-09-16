#!/bin/zsh
# Visual smoke test: builds the app (unless SKIP_BUILD=1), launches it against a temporary THUBAN_HOME with
# THUBAN_SMOKE=<output dir>, waits for it to walk the screens and exit, then prints the screenshot paths.
# Usage: scripts/smoke.sh [output-dir]      (default: .build/smoke)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${1:-$ROOT/.build/smoke}"
APP="$ROOT/.build/DerivedData/Build/Products/Debug/Thuban Study.app/Contents/MacOS/Thuban Study"
LOG=/tmp/thuban-smoke.log

if [[ "${SKIP_BUILD:-0}" != "1" || ! -x "$APP" ]]; then
  scripts/build.sh || exit 1
fi

HOME_DIR="$(mktemp -d /tmp/thuban-smoke-home.XXXXXX)"
rm -rf "$OUT"
mkdir -p "$OUT"
pkill -f "Thuban Study.app/Contents/MacOS" 2>/dev/null
echo "Smoke home: $HOME_DIR"
echo "Output:     $OUT"
THUBAN_SMOKE="$OUT" THUBAN_HOME="$HOME_DIR" "$APP" > "$LOG" 2>&1 &
PID=$!
for i in {1..60}; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "TIMEOUT: app still running after 60 s; killing"
  kill "$PID" 2>/dev/null
  STATUS=2
else
  wait "$PID"; STATUS=$?
  echo "App exited with status $STATUS"
fi
echo "--- app output (last 30 lines of $LOG):"
tail -30 "$LOG"
echo "--- screenshots:"
ls -la "$OUT"/*.png 2>/dev/null || echo "(none)"
rm -rf "$HOME_DIR"
exit $STATUS
