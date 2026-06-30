#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .gitmodules ]]; then
  echo "wktrees vendor sync: no .gitmodules found, nothing to do"
  exit 0
fi

echo "wktrees vendor sync: syncing and initializing submodules"
git submodule sync --recursive
git submodule update --init --recursive
