#!/usr/bin/env bash
# Tracked source-of-truth for the post-commit git hook. Git hooks themselves
# live in .git/hooks/, which git does NOT version -- this file is what
# actually gets copied there by install-git-hooks.sh. Edit THIS file, not
# .git/hooks/post-commit directly, then re-run the installer.
#
# Runs the iOS and Android exports automatically after every commit, using
# the existing export_ios.sh / export_android.sh wrappers (version stamp +
# godot --export-release "<platform>").
#
# This can NOT block or roll back the commit -- post-commit hooks run after
# the commit has already been made, git has no concept of a "failing"
# post-commit hook. Failures here are reported clearly but never treated as
# fatal; this script always exits 0 so git itself never shows an alarming
# "hook failed" message for what is, at worst, a stale Xcode/Android export.
#
# Opt out for one commit if you don't want an export to run (e.g. a big
# non-gameplay commit, or you're mid-troubleshooting an export itself):
#   SKIP_IOS_EXPORT=1 git commit -m "..."
#   SKIP_ANDROID_EXPORT=1 git commit -m "..."

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -n "${SKIP_IOS_EXPORT:-}" ]]; then
  echo "[post-commit] SKIP_IOS_EXPORT set -- skipping iOS export for this commit."
else
  echo "[post-commit] Running iOS export (scripts/tools/export_ios.sh)..."
  if "$REPO_ROOT/scripts/tools/export_ios.sh"; then
    echo "[post-commit] iOS export succeeded."
  else
    echo "[post-commit] iOS export FAILED -- the commit itself is fine and already made," \
         "but export/ios/ may now be stale or partially written. Run" \
         "scripts/tools/export_ios.sh manually to see the full error." >&2
  fi
fi

if [[ -n "${SKIP_ANDROID_EXPORT:-}" ]]; then
  echo "[post-commit] SKIP_ANDROID_EXPORT set -- skipping Android export for this commit."
else
  echo "[post-commit] Running Android export (scripts/tools/export_android.sh)..."
  if "$REPO_ROOT/scripts/tools/export_android.sh"; then
    echo "[post-commit] Android export succeeded."
  else
    echo "[post-commit] Android export FAILED -- the commit itself is fine and already made," \
         "but export/android/ may now be stale or partially written. Run" \
         "scripts/tools/export_android.sh manually to see the full error." >&2
  fi
fi

exit 0
