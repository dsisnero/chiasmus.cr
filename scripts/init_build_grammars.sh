#!/usr/bin/env bash
# Initialize only pinned grammar submodules needed by CLI/release builds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

grammar_paths=()
while IFS=$'\t' read -r metadata path; do
  [[ "${metadata}" == 160000\ * ]] || continue
  [[ "${path}" == grammars/tree-sitter-* ]] || continue
  grammar_paths+=("${path}")
done < <(git ls-files --stage -- grammars)

if (( ${#grammar_paths[@]} == 0 )); then
  echo "No pinned grammar submodules found" >&2
  exit 1
fi

case "${1:-}" in
  --list) printf '%s\n' "${grammar_paths[@]}" ;;
  '') git submodule update --init -- "${grammar_paths[@]}" ;;
  *) echo "Usage: $0 [--list]" >&2; exit 2 ;;
esac
