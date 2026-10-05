#!/usr/bin/env bash
# One-command Android builds.
#
#   scripts/tools/export_android.sh            debug APK for side-loading
#                                               -> export/android/RopeDartArena.apk
#   scripts/tools/export_android.sh install    same, then `adb install` it on the
#                                               USB-connected phone
#   scripts/tools/export_android.sh play       release App Bundle for Google Play,
#                                               signed with the upload key
#                                               -> export/android/RopeDartArena.aab
#
# Versions come from scripts/tools/app_version.sh (VERSION file + git commit
# count). Override the Godot binary with GODOT_BIN=/path/to/Godot.
#
# One-time setup (see docs/deployment.md): Android SDK + JDK 17 paths in
# Godot's Editor Settings (Export > Android), Android export templates for
# this Godot version, and -- for `play` -- the upload keystore in
# ~/.ropedart-arena/ wired into the "Android Play" preset's credentials.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
MODE="${1:-apk}"

# --- Godot binary (standard build; a .NET build can export this project too)
if [[ -n "${GODOT_BIN:-}" ]]; then
  :
elif command -v godot4 >/dev/null 2>&1; then
  GODOT_BIN="$(command -v godot4)"
elif command -v godot >/dev/null 2>&1; then
  GODOT_BIN="$(command -v godot)"
elif [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
  GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
elif [[ -x "/Applications/Godot_mono.app/Contents/MacOS/Godot" ]]; then
  GODOT_BIN="/Applications/Godot_mono.app/Contents/MacOS/Godot"
else
  echo "export_android.sh: no Godot binary found. Set GODOT_BIN=/path/to/Godot." >&2
  exit 1
fi
echo "Using Godot binary: $GODOT_BIN"

"$REPO_ROOT/scripts/tools/generate_version.sh"
. "$REPO_ROOT/scripts/tools/app_version.sh"
stamp_export_presets
echo "Version $APP_VERSION (build $APP_BUILD)"
mkdir -p export/android

case "$MODE" in
  apk|install)
    OUT="export/android/RopeDartArena.apk"
    "$GODOT_BIN" --headless --path . --export-debug "Android" "$OUT"
    ;;
  play)
    OUT="export/android/RopeDartArena.aab"
    # The Gradle build needs Godot's Android build template in res://android
    # (~1 GB once built, gitignored); install it on first use.
    TEMPLATE_FLAG=""
    [[ -f android/.build_version ]] || TEMPLATE_FLAG="--install-android-build-template"
    "$GODOT_BIN" --headless --path . $TEMPLATE_FLAG --export-release "Android Play" "$OUT"
    ;;
  *)
    echo "usage: $0 [apk|install|play]" >&2
    exit 2
    ;;
esac

[[ -s "$OUT" ]] || { echo "export_android.sh: export produced no $OUT" >&2; exit 1; }
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"

if [[ "$MODE" == "install" ]]; then
  ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
  "$ADB" install -r "$OUT"
  "$ADB" shell monkey -p com.ropedartarena.game -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
elif [[ "$MODE" == "play" ]]; then
  echo "Upload $OUT to Google Play Console (Testing > Internal testing) -- see docs/deployment.md."
else
  echo "Install with: scripts/tools/export_android.sh install  (or adb install -r $OUT)"
fi
