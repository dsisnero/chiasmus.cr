#!/usr/bin/env bash
set -euo pipefail

if ! git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "wktrees submodule sync: not inside a git checkout, nothing to do"
  exit 0
fi

cd "$git_root"

if [[ ! -f .gitmodules ]]; then
  echo "wktrees submodule sync: no .gitmodules found, nothing to do"
  exit 0
fi

echo "wktrees submodule sync: syncing URLs"
git submodule sync --recursive

echo "wktrees submodule sync: materializing recorded commits"
git submodule update --init --recursive --checkout

status_output="$(git submodule status --recursive || true)"
if [[ -n "$status_output" ]] && printf '%s\n' "$status_output" | grep -Eq '^[+U-]'; then
  echo "wktrees submodule sync: submodules still drift after update" >&2
  printf '%s\n' "$status_output" >&2
  exit 1
fi

echo "wktrees submodule sync: submodules ready"
