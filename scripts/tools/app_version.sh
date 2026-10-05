#!/usr/bin/env bash
# Store versions for the iOS / Android builds, one source for both:
#   APP_VERSION  marketing version, from the VERSION file (bump by hand per
#                release: 0.1.0 -> 0.2.0 ...). iOS CFBundleShortVersionString,
#                Android versionName.
#   APP_BUILD    build number = git commit count. Always increases, which
#                both stores require for every upload. iOS CFBundleVersion,
#                Android versionCode.
# Source it:  . scripts/tools/app_version.sh
_APPV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_VERSION="$(tr -d '[:space:]' < "$_APPV_ROOT/VERSION" 2>/dev/null || true)"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="$(git -C "$_APPV_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
export APP_VERSION APP_BUILD

# Write APP_VERSION/APP_BUILD into export_presets.cfg for one export, and put
# the file back afterwards (it's committed; versions are build-time only).
stamp_export_presets() {
  cp "$_APPV_ROOT/export_presets.cfg" "$_APPV_ROOT/.godot/export_presets.cfg.orig"
  trap 'mv -f "$_APPV_ROOT/.godot/export_presets.cfg.orig" "$_APPV_ROOT/export_presets.cfg"' EXIT
  sed -i '' -E \
    -e "s/^(version\/code=).*/\1$APP_BUILD/" \
    -e "s/^(version\/name=).*/\1\"$APP_VERSION\"/" \
    -e "s/^(application\/short_version=).*/\1\"$APP_VERSION\"/" \
    -e "s/^(application\/version=).*/\1\"$APP_BUILD\"/" \
    "$_APPV_ROOT/export_presets.cfg"
}
