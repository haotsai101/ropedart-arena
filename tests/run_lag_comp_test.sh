#!/usr/bin/env bash
# Runs tests/test_lag_comp.tscn: a host + a guest through the server at URL
# (default: a local server it starts itself), checking that the host
# hit-tests the guest's attacks against where the guest saw its targets.
#
# Usage: tests/run_lag_comp_test.sh [wss://url]
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
TMP="$(mktemp -d)"
CODE_FILE="$TMP/room_code"
if [[ $# -ge 1 ]]; then
  URL="$1"
else
  PORT="${LAG_TEST_PORT:-18082}"
  URL="ws://127.0.0.1:$PORT"
  PORT="$PORT" node "$REPO_ROOT/signaling-server/server.js" > "$TMP/server.log" 2>&1 &
  SERVER_PID=$!
  trap 'kill $SERVER_PID 2>/dev/null' EXIT
  sleep 1
fi
run() {
  "$GODOT_BIN" --headless --max-fps 60 --path "$REPO_ROOT" res://tests/test_lag_comp.tscn -- \
    --role="$1" --url="$URL" --code-file="$CODE_FILE" > "$TMP/$1.log" 2>&1
}
run host & H=$!
run guest & G=$!
wait $H; HR=$?
kill $G 2>/dev/null; wait $G 2>/dev/null
grep -h "\[lag comp test" "$TMP"/host.log "$TMP"/guest.log
grep -hE "SCRIPT ERROR" -A2 "$TMP"/*.log | head -10
exit $HR
