#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
SOURCE_PATH="${2:-${PORT_SOURCE_DIR:-}}"
LANGUAGE="${3:-${PORT_LANGUAGE:-go}}"
CRYSTAL_SPEC_CMD="${4:-}"
UPSTREAM_TEST_CMD="${5:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/port_path_lib.sh"
SOURCE_PATH="$(resolve_port_source_path "${ROOT_DIR}" "${SOURCE_PATH}")"
ENSURE_SCRIPT="${ENSURE_PARITY_PLAN_SCRIPT:-${SCRIPT_DIR}/ensure_parity_plan.sh}"
COMPLETION_GATE_SCRIPT="${CHECK_COMPLETION_GATE_SCRIPT:-${SCRIPT_DIR}/check_completion_gate.sh}"
PORT_INVENTORY="${ROOT_DIR}/plans/inventory/${LANGUAGE}_port_inventory.tsv"

"${ENSURE_SCRIPT}" "${ROOT_DIR}" "${SOURCE_PATH}" "${LANGUAGE}" "${PORT_PARSER:-auto}" 0

for manifest in \
  "${PORT_INVENTORY}" \
  "${ROOT_DIR}/plans/inventory/${LANGUAGE}_source_parity.tsv" \
  "${ROOT_DIR}/plans/inventory/${LANGUAGE}_test_parity.tsv"; do
  if rg -n "\\t\\t|\\t$" "${manifest}" >/dev/null 2>&1; then
    echo "Manifest contains empty TSV fields (\\t\\t or trailing tab): ${manifest}" >&2
    exit 1
  fi
done

# Strict manifest quality checks.
ruby -e '
  file = ARGV[0]
  rows = File.readlines(file, chomp: true).reject { |l| l.start_with?("#") || l.strip.empty? }
  bad = rows.select do |r|
    c = r.split("\t", -1)
    next true if c.size < 5
    status = c[2]
    refs = c[3]
    (%w[ported partial].include?(status) && refs.to_s.strip.empty?)
  end
  unless bad.empty?
    warn "Invalid port inventory rows in #{file}:"
    bad.each { |r| warn "  - #{r}" }
    exit 1
  end
' "${PORT_INVENTORY}"

# Detect explicitly disabled specs in Crystal side when applicable. Runtime
# `pending` is validated from the actual spec command output below because a
# static grep produces false positives for conditional pendings and non-spec
# identifiers such as `pending : PendingCall`.
if [[ -d "${ROOT_DIR}/spec" ]]; then
  if rg --pcre2 -n "^\s*xit\(|^\s*xdescribe\(|^\s*xcontext\(" "${ROOT_DIR}/spec" "${ROOT_DIR}/src" >/dev/null 2>&1; then
    echo "Found disabled specs in src/spec. Resolve before parity signoff." >&2
    exit 1
  fi
fi

"${COMPLETION_GATE_SCRIPT}" "${ROOT_DIR}" "${PORT_INVENTORY}" "${SOURCE_PATH}" "${LANGUAGE}"

if [[ -n "${CRYSTAL_SPEC_CMD}" ]]; then
  SPEC_LOG="$(mktemp)"
  set +e
  (cd "${ROOT_DIR}" && eval "${CRYSTAL_SPEC_CMD}") | tee "${SPEC_LOG}"
  SPEC_STATUS=${PIPESTATUS[0]}
  set -e
  if [[ ${SPEC_STATUS} -ne 0 ]]; then
    exit "${SPEC_STATUS}"
  fi
  if rg -n "^Pending:" "${SPEC_LOG}" >/dev/null 2>&1; then
    echo "Crystal spec command reported pending examples. Resolve before parity signoff." >&2
    exit 1
  fi
fi

if [[ -n "${UPSTREAM_TEST_CMD}" ]]; then
  if [[ -n "${SOURCE_PATH}" ]]; then
    if [[ "${SOURCE_PATH}" = /* ]]; then
      (cd "${SOURCE_PATH}" && eval "${UPSTREAM_TEST_CMD}")
    else
      (cd "${ROOT_DIR}/${SOURCE_PATH}" && eval "${UPSTREAM_TEST_CMD}")
    fi
  else
    (cd "${ROOT_DIR}" && eval "${UPSTREAM_TEST_CMD}")
  fi
fi

echo "Adversarial parity verification passed for language=${LANGUAGE}."
