#!/usr/bin/env bash
# Runs tests/test_relay_multiplayer.tscn end to end: starts the signaling/
# relay server locally, then one host + two guest Godot processes against it.
# Exits non-zero if any process fails.
#
# Usage: tests/run_relay_test.sh   (GODOT_BIN=/path/to/Godot to override)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PORT="${RELAY_TEST_PORT:-18080}"
URL="ws://127.0.0.1:$PORT"
TMP="$(mktemp -d)"
CODE_FILE="$TMP/room_code"

PORT="$PORT" node "$REPO_ROOT/signaling-server/server.js" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; if [[ -n "${KEEP_LOGS:-}" ]]; then echo "logs kept in $TMP"; else rm -rf "$TMP"; fi' EXIT
sleep 1

run() {
  "$GODOT_BIN" --headless --path "$REPO_ROOT" res://tests/test_relay_multiplayer.tscn \
    -- --role="$1" --url="$URL" --code-file="$CODE_FILE" > "$TMP/$2.log" 2>&1
}

run host host & H=$!
run guest guest_a & A=$!
run guest guest_b & B=$!

FAIL=0
wait $H || FAIL=1
wait $A || FAIL=1
wait $B || FAIL=1

grep -h "\[relay test" "$TMP"/host.log "$TMP"/guest_a.log "$TMP"/guest_b.log
if [[ $FAIL -ne 0 ]]; then
  echo "--- errors ---"
  grep -hE "ERROR|SCRIPT" "$TMP"/*.log | head -20
  echo "RELAY TEST FAILED"
  exit 1
fi
echo "RELAY TEST PASSED"
