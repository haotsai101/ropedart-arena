#!/usr/bin/env bash
# One-command iOS builds.
#
#   scripts/tools/export_ios.sh             Xcode project only
#                                            -> export/ios/RopeDartArena.xcodeproj
#   scripts/tools/export_ios.sh device      + build/sign for development and
#                                            install on the connected iPhone
#                                            -> export/ios/build/device/*.ipa
#   scripts/tools/export_ios.sh testflight  + archive, sign for the App Store and
#                                            upload to App Store Connect/TestFlight
#
# Versions come from scripts/tools/app_version.sh (VERSION file + git commit
# count). Override the Godot binary with GODOT_BIN=/path/to/Godot.
#
# Signing is automatic (team below, `-allowProvisioningUpdates`), so Xcode
# must be signed in to the Apple ID (Xcode > Settings > Accounts) -- or, for
# `testflight`, set an App Store Connect API key:
#   ASC_KEY_ID=...  ASC_ISSUER_ID=...  ASC_KEY_PATH=/path/AuthKey_XXXX.p8
# `testflight` needs a paid Apple Developer Program team and the app record
# (bundle id com.ropedartarena.game) created in App Store Connect. See
# docs/deployment.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
MODE="${1:-project}"
TEAM_ID="${IOS_TEAM_ID:-5H964M87S4}"
PROJECT="export/ios/RopeDartArena.xcodeproj"
SCHEME="RopeDartArena"

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
  echo "export_ios.sh: no Godot binary found. Set GODOT_BIN=/path/to/Godot." >&2
  exit 1
fi
echo "Using Godot binary: $GODOT_BIN"

"$REPO_ROOT/scripts/tools/generate_version.sh"
. "$REPO_ROOT/scripts/tools/app_version.sh"
stamp_export_presets
echo "Version $APP_VERSION (build $APP_BUILD)"

# --- 1) Godot: generate the Xcode project (preset is "export project only";
# signing/building is done below with full control over the settings).
mkdir -p export/ios
"$GODOT_BIN" --headless --path . --export-release "iOS" "$PROJECT"
[[ -d "$PROJECT" ]] || { echo "export_ios.sh: Godot produced no $PROJECT" >&2; exit 1; }
echo "Xcode project: $PROJECT"
[[ "$MODE" == "project" ]] && exit 0

AUTH=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH+=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi
SIGNING=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development"
         PROVISIONING_PROFILE_SPECIFIER="")
BUILD_DIR="export/ios/build/$MODE"
ARCHIVE="$BUILD_DIR/RopeDartArena.xcarchive"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- 2) Archive (signed for development; the export step below re-signs for
# the chosen distribution method).
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
  "${AUTH[@]}" "${SIGNING[@]}" archive | tail -n 20

case "$MODE" in
  device)     METHOD="debugging"; DEST="export" ;;
  testflight) METHOD="app-store-connect"; DEST="upload" ;;
  *) echo "usage: $0 [project|device|testflight]" >&2; exit 2 ;;
esac
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>$METHOD</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

# --- 3) Export: an .ipa for the device, or straight upload to App Store Connect.
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$BUILD_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" "${AUTH[@]}" | tail -n 20

if [[ "$MODE" == "device" ]]; then
  IPA="$(ls "$BUILD_DIR"/*.ipa | head -1)"
  echo "Built $IPA"
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/available|connected/ && /iPhone|iPad/ {print $3; exit}')"
  if [[ -n "$DEVICE" ]]; then
    xcrun devicectl device install app --device "$DEVICE" "$IPA"
    echo "Installed on $DEVICE"
  else
    echo "No iPhone connected -- plug one in (trusted, Developer Mode on) and run: xcrun devicectl device install app --device <id> $IPA"
  fi
else
  echo "Uploaded build $APP_VERSION ($APP_BUILD) -- it appears in App Store Connect > TestFlight after processing."
fi
