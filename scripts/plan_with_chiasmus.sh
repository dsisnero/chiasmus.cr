#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
SOURCE_PATH="${2:-${PORT_SOURCE_DIR:-}}"
SOURCE_LANGUAGE="${3:-${PORT_LANGUAGE:-typescript}}"
CRYSTAL_FACTS_DIR="${4:-${PORT_CRYSTAL_FACTS_DIR:-src}}"
OUT_DIR="${5:-${PORT_PLAN_OUT_DIR:-${ROOT_DIR}/plans/generated/parity/${SOURCE_LANGUAGE}}}"
TOP_N="${PORT_PLAN_TOP:-25}"
ENTRY_POINTS="${PORT_ENTRY_POINTS:-}"
PARSER_MODE="${PORT_PARSER:-auto}"
CRYSTAL_DIRS="${PORT_CRYSTAL_DIRS:-src:spec}"

if [[ -z "${SOURCE_PATH}" ]]; then
  echo "source path is required as arg 2 or PORT_SOURCE_DIR" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY_POINT_ARGS=()

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
INVENTORY_PATH="${ROOT_DIR}/plans/inventory/${SOURCE_LANGUAGE}_port_inventory.tsv"
PARITY_PLAN_PATH="${ROOT_DIR}/plans/parity.md"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "source directory not found: ${SOURCE_DIR}" >&2
  exit 1
fi

if [[ ! -d "${CRYSTAL_DIR}" ]]; then
  echo "crystal facts directory not found: ${CRYSTAL_DIR}" >&2
  exit 1
fi

if [[ ! -f "${INVENTORY_PATH}" ]]; then
  echo "inventory file not found: ${INVENTORY_PATH}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
build_entry_point_args

SOURCE_FACTS="${OUT_DIR}/source_facts.pl"
CRYSTAL_FACTS="${OUT_DIR}/crystal_facts.pl"
RANK_TSV="${OUT_DIR}/rank.tsv"
SAFE_TSV="${OUT_DIR}/safe.tsv"
SLICES_TSV="${OUT_DIR}/slices.tsv"
SEED_MD="${OUT_DIR}/seed.md"
TRACK_TSV="${OUT_DIR}/track.tsv"
PARITY_TSV="${OUT_DIR}/parity.tsv"
PARITY_SUMMARY="${OUT_DIR}/parity_summary.txt"
COMPLETE_STATUS="${OUT_DIR}/completion_status.tsv"
COMPLETE_INCOMPLETE="${OUT_DIR}/completion_incomplete.tsv"

source_args=(--language "${SOURCE_LANGUAGE}" --dir "${SOURCE_DIR}")
crystal_args=(--language crystal --dir "${CRYSTAL_DIR}")
if (( ${#ENTRY_POINT_ARGS[@]} > 0 )); then
  source_args+=("${ENTRY_POINT_ARGS[@]}")
  crystal_args+=("${ENTRY_POINT_ARGS[@]}")
fi

run_tool CHIASMUS_FACTS_BIN chiasmus-facts "${source_args[@]}" > "${SOURCE_FACTS}"
run_tool CHIASMUS_FACTS_BIN chiasmus-facts "${crystal_args[@]}" > "${CRYSTAL_FACTS}"

plan_args=(--facts "${SOURCE_FACTS}" --format tsv --top "${TOP_N}")
if (( ${#ENTRY_POINT_ARGS[@]} > 0 )); then
  plan_args+=("${ENTRY_POINT_ARGS[@]}")
fi

run_tool CHIASMUS_PLAN_BIN chiasmus-plan rank "${plan_args[@]}" > "${RANK_TSV}"
run_tool CHIASMUS_PLAN_BIN chiasmus-plan safe "${plan_args[@]}" > "${SAFE_TSV}"
run_tool CHIASMUS_PLAN_BIN chiasmus-plan slice "${plan_args[@]}" > "${SLICES_TSV}"
run_tool CHIASMUS_PLAN_BIN chiasmus-plan seed-parity "${plan_args[@]}" > "${SEED_MD}"

track_args=(track --facts "${SOURCE_FACTS}" --format tsv --top "${TOP_N}" --inventory "${INVENTORY_PATH}")
if [[ -f "${PARITY_PLAN_PATH}" ]]; then
  track_args+=(--parity-plan "${PARITY_PLAN_PATH}")
fi
if (( ${#ENTRY_POINT_ARGS[@]} > 0 )); then
  track_args+=("${ENTRY_POINT_ARGS[@]}")
fi
run_tool CHIASMUS_PLAN_BIN chiasmus-plan "${track_args[@]}" > "${TRACK_TSV}"

local_old_ifs="${IFS}"
IFS=':'
read -r -a crystal_dirs_array <<< "${CRYSTAL_DIRS}"
IFS="${local_old_ifs}"

parity_args=(
  --inventory "${INVENTORY_PATH}"
  --root "${ROOT_DIR}"
  --source-facts "${SOURCE_FACTS}"
  --crystal-facts "${CRYSTAL_FACTS}"
  --parser "${PARSER_MODE}"
)

for dir in "${crystal_dirs_array[@]}"; do
  [[ -n "${dir}" ]] && parity_args+=(--crystal-dir "${dir}")
done

run_tool CHIASMUS_PARITY_BIN chiasmus-parity "${parity_args[@]}" > "${PARITY_TSV}"

ruby "${SCRIPT_DIR}/summarize_parity_report.rb" --input "${PARITY_TSV}" > "${PARITY_SUMMARY}"

complete_args=(
  --inventory "${INVENTORY_PATH}"
  --root "${ROOT_DIR}"
  --source-facts "${SOURCE_FACTS}"
  --crystal-facts "${CRYSTAL_FACTS}"
  --parser "${PARSER_MODE}"
)

for dir in "${crystal_dirs_array[@]}"; do
  [[ -n "${dir}" ]] && complete_args+=(--crystal-dir "${dir}")
done

run_tool CHIASMUS_COMPLETE_BIN chiasmus-complete \
  "${complete_args[@]}" \
  --query status > "${COMPLETE_STATUS}" || true

run_tool CHIASMUS_COMPLETE_BIN chiasmus-complete \
  "${complete_args[@]}" \
  --query incomplete \
  --format tsv > "${COMPLETE_INCOMPLETE}" || true

echo "Chiasmus planning bundle written to ${OUT_DIR}"
echo "  source facts: ${SOURCE_FACTS}"
echo "  crystal facts: ${CRYSTAL_FACTS}"
echo "  rank: ${RANK_TSV}"
echo "  safe: ${SAFE_TSV}"
echo "  slices: ${SLICES_TSV}"
echo "  seed plan: ${SEED_MD}"
echo "  tracked slices: ${TRACK_TSV}"
echo "  parity report: ${PARITY_TSV}"
echo "  parity summary: ${PARITY_SUMMARY}"
echo "  completion status: ${COMPLETE_STATUS}"
echo "  completion incomplete rows: ${COMPLETE_INCOMPLETE}"
