#!/usr/bin/env bash
# Runs tests/test_online_match.tscn end to end: starts the signaling/relay
# server locally, then a host and a guest Godot process that play a real
# match against it. Exits non-zero if either process fails.
#
# Usage: tests/run_online_match_test.sh   (GODOT_BIN=/path/to/Godot to override,
#        KEEP_LOGS=1 to keep the per-process logs, TOTAL_PLAYERS=4 to add
#        host-simulated bots -- smoke mode, bots can disturb the checks)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PORT="${ONLINE_TEST_PORT:-18081}"
URL="ws://127.0.0.1:$PORT"
TMP="$(mktemp -d)"
CODE_FILE="$TMP/room_code"

PORT="$PORT" node "$REPO_ROOT/signaling-server/server.js" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; if [[ -n "${KEEP_LOGS:-}" ]]; then echo "logs kept in $TMP"; else rm -rf "$TMP"; fi' EXIT
sleep 1

run() {
  "$GODOT_BIN" --headless --path "$REPO_ROOT" res://tests/test_online_match.tscn \
    -- --role="$1" --url="$URL" --code-file="$CODE_FILE" --total="${TOTAL_PLAYERS:-2}" > "$TMP/$1.log" 2>&1
}

run host & H=$!
run guest & G=$!

FAIL=0
wait $H || FAIL=1
wait $G || FAIL=1

grep -h "\[online match test" "$TMP"/host.log "$TMP"/guest.log
if [[ $FAIL -ne 0 ]]; then
  echo "--- errors ---"
  grep -hE "SCRIPT ERROR|ERROR" "$TMP"/*.log | sort | uniq -c | sort -rn | head -20
  echo "ONLINE MATCH TEST FAILED"
  exit 1
fi
echo "ONLINE MATCH TEST PASSED"
