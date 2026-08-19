#!/usr/bin/env bash
# One-command iOS export: regenerates the version stamp, then runs Godot's
# export step. Still leaves the Xcode build/archive/upload step manual --
# this only replaces the two Godot-side steps (generate_version.sh + the
# `godot --export-release "iOS"` invocation) with one command.
#
# Usage (from anywhere):
#   scripts/tools/export_ios.sh
#
# Override the Godot binary if auto-detection doesn't find yours:
#   GODOT_BIN=/path/to/Godot scripts/tools/export_ios.sh
#
# After this finishes, open export/ios/RopeDartArena.xcodeproj in Xcode,
# then build/archive/install or upload to TestFlight as usual -- that part
# isn't automated here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# --- 1) Locate a Godot binary -------------------------------------------
# Respects an explicit override first, then checks common install
# locations, then falls back to whatever's on PATH. This project targets
# the STANDARD build (not .NET) -- if only a mono/.NET build is found,
# warn but still use it, since it can still export a non-C# project fine.
if [[ -n "${GODOT_BIN:-}" ]]; then
  : # explicit override, trust it
elif command -v godot4 >/dev/null 2>&1; then
  GODOT_BIN="$(command -v godot4)"
elif command -v godot >/dev/null 2>&1; then
  GODOT_BIN="$(command -v godot)"
elif [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
  GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
elif [[ -x "/Applications/Godot_mono.app/Contents/MacOS/Godot" ]]; then
  GODOT_BIN="/Applications/Godot_mono.app/Contents/MacOS/Godot"
  echo "export_ios.sh: only found the .NET/mono build (this project is standard, non-.NET) -- using it anyway, it can still export a non-C# project." >&2
else
  echo "export_ios.sh: could not find a Godot binary. Set GODOT_BIN=/path/to/Godot and re-run." >&2
  exit 1
fi

echo "Using Godot binary: $GODOT_BIN"

# --- 2) Regenerate the version stamp ------------------------------------
"$REPO_ROOT/scripts/tools/generate_version.sh"

# --- 3) Run the actual export --------------------------------------------
EXPORT_PATH="export/ios/RopeDartArena.xcodeproj"
echo "Exporting iOS project to $EXPORT_PATH ..."
"$GODOT_BIN" --headless --export-release "iOS" "$EXPORT_PATH"

echo ""
echo "Done. Next: open $EXPORT_PATH in Xcode and build/archive/upload as usual."
