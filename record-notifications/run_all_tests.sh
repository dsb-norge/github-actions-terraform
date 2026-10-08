#!/bin/env bash
#
# Tests for record-notifications: the action's own run block, end to end.
#
# The adapter (engine/dsb_tf_engine/notify_evidence.py) and the merge (notify_state.py) are unit
# tested in engine/ under the coverage and mutation gates. This suite runs the run block of
# action.yml, extracted with yq, with the step's env: set and nothing else of this suite's
# environment.
#
# To run the command by hand:
#   GITHUB_OUTPUT=<file> python3 -I -B <repo>/engine/run.py record-notifications --state-file=<file> \
#     --observations-file=<file> --results-files-pattern='notify-result-*.json' --out-file=<file>
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# The step's log, one file per run of this suite: suites run side by side.
OUT_FILE="$(mktemp)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${OUT_FILE}" "${SCRATCH}"' EXIT

pass() {
  echo -e "${GREEN}✓ PASSED${NC}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo -e "${RED}✗ FAILED${NC}: ${1}"
  echo "--- step output (tail) ---"
  tail -n 30 "${OUT_FILE}" 2>/dev/null || true
  echo "--- /step output ---"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

begin() {
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${1}${NC}"
}

make_sandbox() {
  SANDBOX="$(mktemp -d "${SCRATCH}/sandbox.XXXXXX")"
  mkdir -p "${SANDBOX}/ws" "${SANDBOX}/results" "${SANDBOX}/state"
  cat >"${SANDBOX}/observations.json" <<'EOF'
{"run_number": 42, "observations": [{"environment": "prod", "slot": "apply", "result": "failed", "kind": "apply-failed",
 "action": "open", "event": "e1", "people": ["jdoe"], "alias": "tf-alerts", "sender": "prod", "sending": true, "mentioned": ["jdoe"], "reminder_level": null, "fingerprint": null}]}
EOF
  echo '{"id": "e1", "accepted": "true", "message_id": "msg-9", "http_status": "202"}' \
    >"${SANDBOX}/results/notify-result-e1.json"
}

run_step() {
  : >"${SANDBOX}/output.txt"
  : >"${SANDBOX}/summary.md"
  yq '.runs.steps[0].run' "${_this_script_dir}/action.yml" \
    | sed "s|\${{ github.action_path }}|${_this_script_dir}|g" >"${SANDBOX}/step.sh"
  (
    cd "${SANDBOX}/ws" || exit 1
    unset $(compgen -e | grep '^GITHUB_')
    export GITHUB_OUTPUT="${SANDBOX}/output.txt" GITHUB_STEP_SUMMARY="${SANDBOX}/summary.md"
    # The step's env:, as action.yml sets it from its inputs.
    export STATE_FILE="${SANDBOX}/state/state.json" OBSERVATIONS_FILE="${SANDBOX}/observations.json"
    export RESULTS_FILES_PATTERN="${SANDBOX}/results/notify-result-*.json" OUT_FILE="${SANDBOX}/new/state.json"
    for assignment in "$@"; do export "${assignment?}"; done
    bash --noprofile --norc -eo pipefail "${SANDBOX}/step.sh"
  ) >"${OUT_FILE}" 2>&1
  STEP_EXIT=$?
}

step_output() {
  awk -v name="${1}" 'index($0, name "<<EOF_") == 1 {getline; print; exit}' "${SANDBOX}/output.txt"
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}        RECORD-NOTIFICATIONS TESTS          ${NC}"
echo -e "${YELLOW}============================================${NC}"

begin "run block: a description comment first, python3 -I, every value joined to its option"
run_block="$(yq '.runs.steps[0].run' "${_this_script_dir}/action.yml")"
if [[ "$(head -n 1 <<<"${run_block}")" == "# "* ]] \
  && grep -q '^python3 -I -B "${{ github.action_path }}/../engine/run.py" record-notifications \\$' <<<"${run_block}" \
  && [[ "$(grep -c '\${{' <<<"${run_block}")" == "1" ]] \
  && grep -qF -- '--out-file="${OUT_FILE}"' <<<"${run_block}"; then
  pass
else
  fail "the run block no longer has its hardened shape"
fi

begin "an accepted open becomes an open incident in a new state file, and changed is true"
make_sandbox
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(step_output changed)" == "true" ]] \
  && [[ "$(jq -r '.incidents["prod/apply"] | [.status, .message_id] | join(",")' "${SANDBOX}/new/state.json")" == "open,msg-9" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, changed '$(step_output changed)'"
fi

begin "the stored state is merged into: nothing new is no change"
make_sandbox
echo '{"run_number": 42, "observations": []}' >"${SANDBOX}/observations.json"
echo '{"schema_version": 1, "incidents": {}}' >"${SANDBOX}/state/state.json"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(step_output changed)" == "false" ]] \
  && [[ "$(jq -S -c . "${SANDBOX}/new/state.json")" == '{"incidents":{},"schema_version":1}' ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, changed '$(step_output changed)'"
fi

begin "observations that are missing fail the step"
make_sandbox
run_step "OBSERVATIONS_FILE=${SANDBOX}/missing.json"
if [[ ${STEP_EXIT} -eq 1 ]] && grep -q '^::error title=record-notifications::the observations cannot be read' "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}"
fi

echo ""
echo "========================================"
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "========================================"

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
fi
exit 0
