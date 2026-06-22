#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="${CHIASMUS_BENCH_OUT_DIR:-/private/tmp/chiasmus-concurrency-bench}"
cache_root="${CHIASMUS_BENCH_CACHE_ROOT:-/private/tmp/chiasmus-concurrency-bench-cache}"

mkdir -p "$out_dir" "$cache_root"

release_bin="$out_dir/measure_concurrency.release"
ctx_bin="$out_dir/measure_concurrency.ctx"

echo "Building release benchmark binary..."
CRYSTAL_CACHE_DIR="$cache_root/release" \
  crystal build --release \
  -o "$release_bin" \
  "$root_dir/scripts/measure_concurrency.cr"

echo "Building execution-context benchmark binary..."
CRYSTAL_CACHE_DIR="$cache_root/ctx" \
  crystal build --release -Dpreview_mt -Dexecution_context \
  -o "$ctx_bin" \
  "$root_dir/scripts/measure_concurrency.cr"

cat <<EOF
Built:
  $release_bin
  $ctx_bin

Suggested runs:
  CHIASMUS_BENCH_SECTIONS=discover,extract CHIASMUS_BENCH_FILE_COUNT=8 CHIASMUS_BENCH_METHOD_COUNT=12 "$release_bin"
  CHIASMUS_BENCH_SECTIONS=extract CHIASMUS_BENCH_FILE_COUNT=40 CHIASMUS_BENCH_METHOD_COUNT=20 "$ctx_bin"
EOF
