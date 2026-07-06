#!/usr/bin/env bash

git_common_vendor_root() {
  local root_dir="$1"
  local common_dir
  common_dir="$(git -C "${root_dir}" rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -n "${common_dir}" ]] || return 1

  if [[ "${common_dir}" != /* ]]; then
    common_dir="${root_dir%/}/${common_dir}"
  fi

  local common_parent
  common_parent="$(cd "$(dirname "${common_dir}")" && pwd)"
  printf '%s/vendor\n' "${common_parent}"
}

vendor_root_dir() {
  local vendor_root="${PORT_VENDOR_DIR:-${VENDOR_DIR:-}}"
  if [[ -n "${vendor_root}" ]]; then
    printf '%s\n' "${vendor_root%/}"
    return 0
  fi

  git_common_vendor_root "${1:-$(pwd)}"
}

resolve_port_source_path() {
  local root_dir="$1"
  local value="${2:-}"

  if [[ -z "${value}" ]]; then
    printf '%s\n' ""
    return 0
  fi

  if [[ "${value}" = /* ]]; then
    printf '%s\n' "${value}"
    return 0
  fi

  local project_candidate="${root_dir%/}/${value}"
  if [[ -e "${project_candidate}" ]]; then
    printf '%s\n' "${project_candidate}"
    return 0
  fi

  local vendor_root
  vendor_root="$(vendor_root_dir "${root_dir}" || true)"
  if [[ -n "${vendor_root}" && "${value}" == vendor/* ]]; then
    local shared_candidate="${vendor_root}/${value#vendor/}"
    if [[ -e "${shared_candidate}" ]]; then
      printf '%s\n' "${shared_candidate}"
      return 0
    fi
  fi

  printf '%s\n' "${project_candidate}"
}
