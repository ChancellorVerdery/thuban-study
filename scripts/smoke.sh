#!/bin/zsh
# Visual smoke test: builds the app (unless SKIP_BUILD=1), launches it against a temporary THUBAN_HOME with
# THUBAN_SMOKE=<output dir>, waits for it to walk the screens and exit, then prints the screenshot paths.
# Usage: scripts/smoke.sh [output-dir]      (default: .build/smoke; OFFLINE=1 denies the network)
set -uo pipefail
cd "$(dirname "$0")/.."
scripts/link-graph.sh || exit 1
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
# Only a previous smoke run of this checkout's Debug build; the installed app (if open) is left alone.
pkill -f "$APP" 2>/dev/null
echo "Smoke home: $HOME_DIR"
echo "Output:     $OUT"
TRAP_PID=""
if [[ "${OFFLINE:-0}" == "1" ]]; then
  # Offline proof: every graph and calculator scene must render with the network denied. sandbox-exec covers the
  # app process only; WebKit loads run in WebKit's own networking process, so the app routes them (smoke only) to
  # a local trap that records every attempt and forwards nothing. The app's probe load must show up there, and
  # nothing else may.
  TRAP_LOG="$OUT/offline-trap.log"
  TRAP_PORT_FILE="$(mktemp /tmp/thuban-smoke-trap.XXXXXX)"
  : > "$TRAP_LOG"
  /usr/bin/python3 -c '
import socket, sys
log, port_file = sys.argv[1], sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(64)
open(port_file, "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept(); c.settimeout(2)
    try: first = c.recv(4096).split(b"\r\n")[0].decode("latin-1")
    except Exception: first = "(no request line)"
    open(log, "a").write(first + "\n"); c.close()
' "$TRAP_LOG" "$TRAP_PORT_FILE" &
  TRAP_PID=$!
  for i in {1..50}; do [[ -s "$TRAP_PORT_FILE" ]] && break; sleep 0.1; done
  TRAP="127.0.0.1:$(cat "$TRAP_PORT_FILE")"
  rm -f "$TRAP_PORT_FILE"
  echo "Offline:    network denied (sandbox-exec); WebKit trapped at $TRAP"
  THUBAN_SMOKE="$OUT" THUBAN_HOME="$HOME_DIR" THUBAN_SMOKE_PROXY_TRAP="$TRAP" \
    sandbox-exec -p '(version 1)(allow default)(deny network*)' "$APP" > "$LOG" 2>&1 &
else
  THUBAN_SMOKE="$OUT" THUBAN_HOME="$HOME_DIR" "$APP" > "$LOG" 2>&1 &
fi
PID=$!
for i in {1..180}; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "TIMEOUT: app still running after 180 s; killing"
  kill "$PID" 2>/dev/null
  STATUS=2
else
  wait "$PID"; STATUS=$?
  echo "App exited with status $STATUS"
fi
echo "--- app output (last 30 lines of $LOG):"
tail -30 "$LOG"
if grep -q "smoke: FAIL" "$LOG"; then
  echo "--- FAIL lines:"; grep "smoke: FAIL" "$LOG"
  [[ $STATUS == 0 ]] && STATUS=4
fi
if [[ -n "$TRAP_PID" ]]; then
  kill "$TRAP_PID" 2>/dev/null
  echo "--- offline trap ($TRAP_LOG):"
  cat "$TRAP_LOG"
  if ! grep -q "example.com" "$TRAP_LOG"; then
    echo "OFFLINE FAIL: the probe load never reached the trap, so WebKit traffic was not covered"; STATUS=3
  elif grep -v "example.com" "$TRAP_LOG" | grep -q .; then
    echo "OFFLINE FAIL: WebKit tried to reach the network"; STATUS=3
  else
    echo "OFFLINE OK: no WebKit network attempts besides the probe"
  fi
fi
echo "--- screenshots:"
ls -la "$OUT"/*.png 2>/dev/null || echo "(none)"
rm -rf "$HOME_DIR"
exit $STATUS
