#!/usr/bin/env bash
set -euo pipefail

# Copy dotfiles and root-level config files from the parent repo into a
# newly-created worktree.  Skipped when the source repo cannot be found.

if ! git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "wktrees dotfile sync: not inside a git checkout, nothing to do"
  exit 0
fi

# Resolve the bare repo (the "parent" of all worktrees).
bare="$(git rev-parse --git-common-dir 2>/dev/null)"
if [[ ! -d "$bare" ]]; then
  echo "wktrees dotfile sync: cannot find bare repo, nothing to do"
  exit 0
fi

# The parent repo lives at "$bare/.." (the --git-common-dir for a worktree
# points into .git, so the repo root is one level up).
parent="$(cd "$bare/.." && pwd)"
if [[ ! -d "$parent" ]]; then
  echo "wktrees dotfile sync: parent repo not found at '$parent'"
  exit 0
fi

cd "$git_root"

DOTFILES=(
  .ameba.yml
  .editorconfig
  .env.enc.json
  .gitignore
  .gitmodules
  .mise.toml
  .rumdl.toml
)

ROOT_FILES=(
  AGENTS.md
  CHANGELOG.md
  LICENSE
  Makefile
  README.md
)

CI_FILES=(
  .github/workflows/ci.yml
  .github/workflows/release.yml
)

copied=0

copy_if_missing() {
  local src="$1"
  local dst="$2"
  if [[ ! -e "$dst" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    copied=1
  fi
}

for f in "${DOTFILES[@]}"; do
  copy_if_missing "$parent/$f" "$git_root/$f"
done

for f in "${ROOT_FILES[@]}"; do
  copy_if_missing "$parent/$f" "$git_root/$f"
done

for f in "${CI_FILES[@]}"; do
  copy_if_missing "$parent/$f" "$git_root/$f"
done

if (( copied )); then
  echo "wktrees dotfile sync: copied missing dotfiles from parent repo"
else
  echo "wktrees dotfile sync: all dotfiles already present"
fi
