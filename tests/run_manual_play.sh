#!/usr/bin/env bash
# Hands-on online test: starts a headless host and opens a game window that
# joins it as a guest -- you play the guest through the real server.
# Close the window to end the session (the host exits with it).
#
# Usage: tests/run_manual_play.sh [wss://url]   (default: the Render server)
#        TOTAL_PLAYERS=4 (2+ adds bots; your guest + a standing host player)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
URL="${1:-wss://ropedart-arena.onrender.com}"
TMP="$(mktemp -d)"
CODE_FILE="$TMP/room_code"

curl -s -m 90 -o /dev/null -w "server warm-up: HTTP %{http_code} in %{time_total}s\n" \
  "$(echo "$URL" | sed 's#^wss://#https://#; s#^ws://#http://#')/rooms"

"$GODOT_BIN" --headless --path "$REPO_ROOT" res://tests/manual_online_play.tscn -- \
  --role=host --url="$URL" --code-file="$CODE_FILE" --total="${TOTAL_PLAYERS:-4}" > "$TMP/host.log" 2>&1 &
H=$!
trap 'kill $H 2>/dev/null' EXIT

"$GODOT_BIN" --path "$REPO_ROOT" res://tests/manual_online_play.tscn -- \
  --role=guest --url="$URL" --code-file="$CODE_FILE" --total="${TOTAL_PLAYERS:-4}" > "$TMP/guest.log" 2>&1
echo "session ended; logs in $TMP"
