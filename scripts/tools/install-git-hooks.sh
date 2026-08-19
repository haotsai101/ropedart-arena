#!/usr/bin/env bash
# Installs this repo's tracked git hooks into .git/hooks/, where git actually
# looks for them (a directory git itself never versions -- that's why this
# install step exists at all, and why it must be re-run by anyone who clones
# the repo fresh, on their own machine).
#
# Usage (from anywhere, run once per clone):
#   scripts/tools/install-git-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
  echo "install-git-hooks.sh: $HOOKS_DIR not found -- is this a git repo?" >&2
  exit 1
fi

install_hook() {
  local name="$1" src="$2"
  local dest="$HOOKS_DIR/$name"
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    echo "install-git-hooks.sh: $dest already exists and isn't a symlink we manage -- back it up and remove it, then re-run this script." >&2
    exit 1
  fi
  ln -sf "$src" "$dest"
  chmod +x "$src"
  echo "Installed $name -> $src"
}

install_hook "post-commit" "$REPO_ROOT/scripts/tools/post-commit-hook.sh"

echo ""
echo "Done. Every commit will now run scripts/tools/export_ios.sh automatically."
echo "Opt out for one commit with: SKIP_IOS_EXPORT=1 git commit -m \"...\""
