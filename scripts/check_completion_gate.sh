#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
INVENTORY_PATH="${2:-}"
SOURCE_PATH="${3:-${PORT_SOURCE_DIR:-}}"
SOURCE_LANGUAGE="${4:-${PORT_LANGUAGE:-typescript}}"
CRYSTAL_FACTS_DIR="${5:-${PORT_CRYSTAL_FACTS_DIR:-src}}"
PARSER_MODE="${PORT_PARSER:-auto}"
CRYSTAL_DIRS="${PORT_CRYSTAL_DIRS:-src:spec}"
ENTRY_POINTS="${PORT_ENTRY_POINTS:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY_POINT_ARGS=()

if [[ -z "${INVENTORY_PATH}" ]]; then
  INVENTORY_PATH="${ROOT_DIR}/plans/inventory/${SOURCE_LANGUAGE}_port_inventory.tsv"
fi

if [[ -z "${SOURCE_PATH}" ]]; then
  echo "source path is required as arg 3 or PORT_SOURCE_DIR" >&2
  exit 1
fi

if [[ ! -f "${INVENTORY_PATH}" ]]; then
  echo "inventory file not found: ${INVENTORY_PATH}" >&2
  exit 1
fi

resolve_path() {
  local base="$1"
  local value="$2"
  if [[ "${value}" = /* ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${base}/${value}"
  fi
}

run_tool() {
  local env_var="$1"
  local tool_name="$2"
  shift 2

  local override="${!env_var:-}"
  if [[ -n "${override}" ]]; then
    "${override}" "$@"
    return
  fi

  local bin_path="${ROOT_DIR}/bin/${tool_name}"
  if [[ -x "${bin_path}" ]]; then
    "${bin_path}" "$@"
    return
  fi

  local source_file="${ROOT_DIR}/src/${tool_name//-/_}.cr"
  if [[ -f "${source_file}" ]]; then
    crystal run "${source_file}" -- "$@"
    return
  fi

  echo "unable to locate ${tool_name}; set ${env_var} or build ${bin_path}" >&2
  exit 1
}

build_entry_point_args() {
  ENTRY_POINT_ARGS=()
  if [[ -z "${ENTRY_POINTS}" ]]; then
    return
  fi

  local old_ifs="${IFS}"
  IFS=','
  read -r -a entries <<< "${ENTRY_POINTS}"
  IFS="${old_ifs}"

  local entry
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    if [[ -n "${entry}" ]]; then
      ENTRY_POINT_ARGS+=(--entry-point "${entry}")
    fi
  done
}

SOURCE_DIR="$(resolve_path "${ROOT_DIR}" "${SOURCE_PATH}")"
CRYSTAL_DIR="$(resolve_path "${ROOT_DIR}" "${CRYSTAL_FACTS_DIR}")"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "source directory not found: ${SOURCE_DIR}" >&2
  exit 1
fi

if [[ ! -d "${CRYSTAL_DIR}" ]]; then
  echo "crystal facts directory not found: ${CRYSTAL_DIR}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chiasmus-complete.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

SOURCE_FACTS="${TMP_DIR}/source.pl"
CRYSTAL_FACTS="${TMP_DIR}/crystal.pl"

build_entry_point_args

source_args=(--language "${SOURCE_LANGUAGE}" --dir "${SOURCE_DIR}")
if (( ${#ENTRY_POINT_ARGS[@]} > 0 )); then
  source_args+=("${ENTRY_POINT_ARGS[@]}")
fi
run_tool CHIASMUS_FACTS_BIN chiasmus-facts "${source_args[@]}" > "${SOURCE_FACTS}"

crystal_facts_args=(--language crystal --dir "${CRYSTAL_DIR}")
if (( ${#ENTRY_POINT_ARGS[@]} > 0 )); then
  crystal_facts_args+=("${ENTRY_POINT_ARGS[@]}")
fi
run_tool CHIASMUS_FACTS_BIN chiasmus-facts "${crystal_facts_args[@]}" > "${CRYSTAL_FACTS}"

complete_args=(
  --inventory "${INVENTORY_PATH}"
  --root "${ROOT_DIR}"
  --source-facts "${SOURCE_FACTS}"
  --crystal-facts "${CRYSTAL_FACTS}"
  --query status
  --parser "${PARSER_MODE}"
)

local_old_ifs="${IFS}"
IFS=':'
read -r -a crystal_dirs_array <<< "${CRYSTAL_DIRS}"
IFS="${local_old_ifs}"

for dir in "${crystal_dirs_array[@]}"; do
  [[ -n "${dir}" ]] && complete_args+=(--crystal-dir "${dir}")
done

run_tool CHIASMUS_COMPLETE_BIN chiasmus-complete "${complete_args[@]}"
