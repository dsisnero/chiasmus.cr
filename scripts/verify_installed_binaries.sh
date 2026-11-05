#!/bin/sh
set -eu

bin_dir=${1:?usage: verify_installed_binaries.sh BIN_DIR}

for name in chiasmus chiasmus-grammar chiasmus-discover chiasmus-facts chiasmus-agent; do
  if ! "$bin_dir/$name" --help >/dev/null 2>&1; then
    printf 'error: installed %s failed its --help probe\n' "$bin_dir/$name" >&2
    exit 1
  fi
done

if ! "$bin_dir/chiasmus" --version >/dev/null 2>&1; then
  printf 'error: installed %s failed its --version probe\n' "$bin_dir/chiasmus" >&2
  exit 1
fi
