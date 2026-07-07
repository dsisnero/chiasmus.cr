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
. "${SCRIPT_DIR}/port_path_lib.sh"
ENTRY_POINT_ARGS=()
ENTRY_POINTS_KEY=""

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

spawn_tool_to_file() {
  local output_path="$1"
  shift

  (
    run_tool "$@" > "${output_path}"
  ) &

  SPAWNED_PID="$!"
}

wait_for_pids() {
  local failed=0
  local pid
  for pid in "$@"; do
    if ! wait "${pid}"; then
      failed=1
    fi
  done

  return "${failed}"
}

build_entry_point_args() {
  ENTRY_POINT_ARGS=()
  ENTRY_POINTS_KEY=""
  if [[ -z "${ENTRY_POINTS}" ]]; then
    return
  fi

  local old_ifs="${IFS}"
  IFS=','
  read -r -a entries <<< "${ENTRY_POINTS}"
  IFS="${old_ifs}"

  local entry
  local normalized_entries=()
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    if [[ -n "${entry}" ]]; then
      normalized_entries+=("${entry}")
      ENTRY_POINT_ARGS+=(--entry-point "${entry}")
    fi
  done

  if (( ${#normalized_entries[@]} > 0 )); then
    local join_ifs="${IFS}"
    IFS=','
    ENTRY_POINTS_KEY="${normalized_entries[*]}"
    IFS="${join_ifs}"
  fi
}

facts_meta_path() {
  printf '%s.meta\n' "$1"
}

write_facts_metadata() {
  local facts_path="$1"
  local language="$2"
  local dir="$3"
  local meta_path
  meta_path="$(facts_meta_path "${facts_path}")"

  cat > "${meta_path}" <<EOF
language=${language}
dir=${dir}
entry_points=${ENTRY_POINTS_KEY}
EOF
}

facts_snapshot_fresh() {
  local facts_path="$1"
  local language="$2"
  local dir="$3"
  local meta_path
  meta_path="$(facts_meta_path "${facts_path}")"

  [[ -f "${facts_path}" ]] || return 1
  [[ -f "${meta_path}" ]] || return 1
  grep -Fxq "language=${language}" "${meta_path}" || return 1
  grep -Fxq "dir=${dir}" "${meta_path}" || return 1
  grep -Fxq "entry_points=${ENTRY_POINTS_KEY}" "${meta_path}" || return 1

  local newer_path
  newer_path="$(find "${dir}" -type f -newer "${facts_path}" -print -quit 2>/dev/null || true)"
  [[ -z "${newer_path}" ]] || return 1

  return 0
}

refresh_facts_snapshot() {
  local facts_path="$1"
  local language="$2"
  local dir="$3"
  shift 3

  run_tool CHIASMUS_FACTS_BIN chiasmus-facts "$@" > "${facts_path}"
  write_facts_metadata "${facts_path}" "${language}" "${dir}"
}

SOURCE_DIR="$(resolve_port_source_path "${ROOT_DIR}" "${SOURCE_PATH}")"
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

if ! facts_snapshot_fresh "${SOURCE_FACTS}" "${SOURCE_LANGUAGE}" "${SOURCE_DIR}"; then
  refresh_facts_snapshot "${SOURCE_FACTS}" "${SOURCE_LANGUAGE}" "${SOURCE_DIR}" "${source_args[@]}"
fi

if ! facts_snapshot_fresh "${CRYSTAL_FACTS}" crystal "${CRYSTAL_DIR}"; then
  refresh_facts_snapshot "${CRYSTAL_FACTS}" crystal "${CRYSTAL_DIR}" "${crystal_args[@]}"
fi

plan_args=(--facts "${SOURCE_FACTS}" --format tsv --top "${TOP_N}")
if (( ${#ENTRY_POINT_ARGS[@]} > 0 )); then
  plan_args+=("${ENTRY_POINT_ARGS[@]}")
fi

track_args=(track --facts "${SOURCE_FACTS}" --format tsv --top "${TOP_N}" --inventory "${INVENTORY_PATH}")
if [[ -f "${PARITY_PLAN_PATH}" ]]; then
  track_args+=(--parity-plan "${PARITY_PLAN_PATH}")
fi
if (( ${#ENTRY_POINT_ARGS[@]} > 0 )); then
  track_args+=("${ENTRY_POINT_ARGS[@]}")
fi

plan_pids=()
spawn_tool_to_file "${RANK_TSV}" CHIASMUS_PLAN_BIN chiasmus-plan rank "${plan_args[@]}"
plan_pids+=("${SPAWNED_PID}")
spawn_tool_to_file "${SAFE_TSV}" CHIASMUS_PLAN_BIN chiasmus-plan safe "${plan_args[@]}"
plan_pids+=("${SPAWNED_PID}")
spawn_tool_to_file "${SLICES_TSV}" CHIASMUS_PLAN_BIN chiasmus-plan slice "${plan_args[@]}"
plan_pids+=("${SPAWNED_PID}")
spawn_tool_to_file "${SEED_MD}" CHIASMUS_PLAN_BIN chiasmus-plan seed-parity "${plan_args[@]}"
plan_pids+=("${SPAWNED_PID}")
spawn_tool_to_file "${TRACK_TSV}" CHIASMUS_PLAN_BIN chiasmus-plan "${track_args[@]}"
plan_pids+=("${SPAWNED_PID}")

wait_for_pids "${plan_pids[@]}"

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
  --source-facts "${SOURCE_FACTS}"
  --parity-report "${PARITY_TSV}"
)

complete_pids=()
spawn_tool_to_file "${COMPLETE_STATUS}" CHIASMUS_COMPLETE_BIN chiasmus-complete "${complete_args[@]}" --query status
complete_pids+=("${SPAWNED_PID}")
spawn_tool_to_file "${COMPLETE_INCOMPLETE}" CHIASMUS_COMPLETE_BIN chiasmus-complete "${complete_args[@]}" --query incomplete --format tsv
complete_pids+=("${SPAWNED_PID}")

wait_for_pids "${complete_pids[@]}" || true

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
