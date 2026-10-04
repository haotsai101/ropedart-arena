#!/usr/bin/env bash
# Runs tests/test_net_probe.tscn: 1 host + (TOTAL_PLAYERS-1) guest Godot
# processes play a real online match through the server at URL while each
# records connection metrics, plus a raw WebSocket ping sampler. Then runs
# tests/analyze_net_probe.py over the results.
#
# Usage: tests/run_net_probe.sh [wss://url]   (default: the Render server)
#        TOTAL_PLAYERS=4 OUT=/dir IDLE=10 LATENCY=25 CHAOS=40
#        FPS=60 (render-loop cap; real phones run 60, uncapped headless runs ~150)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
URL="${1:-wss://ropedart-arena.onrender.com}"
TOTAL="${TOTAL_PLAYERS:-4}"
OUT="${OUT:-$(mktemp -d)}"
IDLE="${IDLE:-10}"; LATENCY="${LATENCY:-25}"; CHAOS="${CHAOS:-40}"
mkdir -p "$OUT"; rm -f "$OUT"/*.json "$OUT"/room_code

# Wake a sleeping free-tier server first so cold start isn't in the numbers.
curl -s -m 90 -o /dev/null -w "server warm-up: HTTP %{http_code} in %{time_total}s\n" \
  "$(echo "$URL" | sed 's#^wss://#https://#; s#^ws://#http://#')/rooms"
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n" \
    "$(echo "$URL" | sed 's#^wss://#https://#; s#^ws://#http://#')/rooms"
done > "$OUT/http_timing.txt"

DURATION=$(( IDLE + LATENCY + CHAOS + 30 ))
node "$REPO_ROOT/tests/net_probe_ws_ping.js" "$URL" "$DURATION" "$OUT/ws_ping.json" &
P=$!

run() {
  "$GODOT_BIN" --headless --max-fps "${FPS:-60}" --path "$REPO_ROOT" res://tests/test_net_probe.tscn -- \
    --role="$1" --url="$URL" --code-file="$OUT/room_code" --out="$OUT" --total="$TOTAL" \
    --idle="$IDLE" --latency="$LATENCY" --chaos="$CHAOS" > "$OUT/$2.log" 2>&1
}
run host host & PIDS=($!)
for i in $(seq 1 $(( TOTAL - 1 ))); do
  sleep 0.3
  run guest "guest$i" & PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p"; done
wait $P
echo "results in $OUT"
python3 "$REPO_ROOT/tests/analyze_net_probe.py" "$OUT"
