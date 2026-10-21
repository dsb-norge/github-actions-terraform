#!/bin/env bash
#
# Tests for download-newest-attempt: the action's steps, as far as they run off GitHub.
#
# The rule (engine/dsb_tf_engine/attempts.py) and the adapter (attempt_files.py) are unit tested in
# engine/ under the coverage and mutation gates. This suite runs the stage and newest steps' run
# blocks of action.yml, extracted with yq, with each step's env: set and nothing else of this suite's
# environment, on files laid out as actions/download-artifact's merge-multiple lays them out; the
# download step itself only runs on GitHub, so its inputs are checked as written.
#
# To run the command by hand:
#   python3 -I -B <repo>/engine/run.py newest-attempt --from-dir=<download> --to-dir=<dir> [--min-attempt=<n>]
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

# A download of a partial re-run: prod failed in the first attempt and was re-run, test was not.
make_sandbox() {
  SANDBOX="$(mktemp -d "${SCRATCH}/sandbox.XXXXXX")"
  mkdir -p "${SANDBOX}/ws" "${SANDBOX}/download" "${SANDBOX}/temp"
  echo '{"metadata": {"environment": "prod"}, "workflow": {"run_attempt": "1"}}' \
    >"${SANDBOX}/download/matrix-job-meta-prod-attempt-1.json"
  echo '{"metadata": {"environment": "prod"}, "workflow": {"run_attempt": "2"}}' \
    >"${SANDBOX}/download/matrix-job-meta-prod-attempt-2.json"
  echo '{"metadata": {"environment": "test"}, "workflow": {"run_attempt": "1"}}' \
    >"${SANDBOX}/download/matrix-job-meta-test-attempt-1.json"
}

# run_step <step id> [VAR=value ...]: the step's run block, its env: as action.yml sets it, in the workspace.
run_step() {
  local id="${1}"
  shift
  : >"${SANDBOX}/output.txt"
  yq ".runs.steps[] | select(.id == \"${id}\") | .run" "${_this_script_dir}/action.yml" \
    | sed "s|\${{ github.action_path }}|${_this_script_dir}|g" >"${SANDBOX}/step.sh"
  (
    cd "${SANDBOX}/ws" || exit 1
    unset $(compgen -e | grep '^GITHUB_')
    export GITHUB_OUTPUT="${SANDBOX}/output.txt" RUNNER_TEMP="${SANDBOX}/temp"
    # The newest step's env:, as action.yml sets it from its inputs and the stage step.
    export FROM_DIR="${SANDBOX}/download" TO_DIR="${SANDBOX}/ws" MIN_ATTEMPT=""
    for assignment in "$@"; do export "${assignment?}"; done
    bash --noprofile --norc -eo pipefail "${SANDBOX}/step.sh"
  ) >"${OUT_FILE}" 2>&1
  STEP_EXIT=$?
}

# written <dir>: each file in the directory and the attempt its content says, sorted.
written() {
  local file
  for file in "${1}"/*.json; do
    [[ -e "${file}" ]] || continue
    printf '%s=%s\n' "$(basename "${file}")" "$(jq -r '.workflow.run_attempt' "${file}")"
  done
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}       DOWNLOAD-NEWEST-ATTEMPT TESTS        ${NC}"
echo -e "${YELLOW}============================================${NC}"

begin "the download step takes every attempt of the pattern, merged into the stage step's directory"
if [[ "$(yq -o=json -I=0 '[.runs.steps[] | select(.uses != null)]' "${_this_script_dir}/action.yml")" \
  == '[{"name":"📥 Download every attempt'"'"'s artifacts","uses":"actions/download-artifact@v8","with":{"pattern":"${{ inputs.pattern }}","path":"${{ steps.stage.outputs.dir }}","merge-multiple":true}}]' ]]; then
  pass
else
  fail "the download step is $(yq -o=json -I=0 '[.runs.steps[] | select(.uses != null)]' "${_this_script_dir}/action.yml")"
fi

begin "the newest step reads the stage directory and writes to path, or the workspace when path is empty"
if [[ "$(yq -o=json -I=0 '.runs.steps[] | select(.id == "newest") | .env' "${_this_script_dir}/action.yml")" \
  == '{"FROM_DIR":"${{ steps.stage.outputs.dir }}","TO_DIR":"${{ inputs.path || github.workspace }}","MIN_ATTEMPT":"${{ inputs.min-attempt }}"}' ]]; then
  pass
else
  fail "the newest step's env is $(yq -o=json -I=0 '.runs.steps[] | select(.id == "newest") | .env' "${_this_script_dir}/action.yml")"
fi

begin "run blocks: a description comment first; python3 -I; no expression but the action's path"
newest_block="$(yq '.runs.steps[] | select(.id == "newest") | .run' "${_this_script_dir}/action.yml")"
stage_block="$(yq '.runs.steps[] | select(.id == "stage") | .run' "${_this_script_dir}/action.yml")"
if [[ "$(head -n 1 <<<"${newest_block}")" == "# "* && "$(head -n 1 <<<"${stage_block}")" == "# "* ]] \
  && grep -q '^python3 -I -B "${{ github.action_path }}/../engine/run.py" newest-attempt \\$' <<<"${newest_block}" \
  && [[ "$(grep -c '\${{' <<<"${newest_block}")" == "1" && "$(grep -c '\${{' <<<"${stage_block}")" == "0" ]] \
  && grep -qF -- '--min-attempt="${MIN_ATTEMPT}"' <<<"${newest_block}"; then
  pass
else
  fail "a run block no longer has its hardened shape"
fi

begin "the stage step makes a new, empty directory under RUNNER_TEMP for every call"
make_sandbox
run_step stage
first="$(sed -n 's/^dir=//p' "${SANDBOX}/output.txt")"
run_step stage
second="$(sed -n 's/^dir=//p' "${SANDBOX}/output.txt")"
if [[ ${STEP_EXIT} -eq 0 && -d "${first}" && -d "${second}" && "${first}" != "${second}" \
  && "${first}" == "${SANDBOX}/temp/"* && -z "$(ls -A "${first}")" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, directories '${first}' and '${second}'"
fi

begin "a partial re-run: each environment is written from its newest attempt, under its name"
make_sandbox
run_step newest
if [[ ${STEP_EXIT} -eq 0 ]] \
  && [[ "$(written "${SANDBOX}/ws")" == $'matrix-job-meta-prod.json=2\nmatrix-job-meta-test.json=1' ]] \
  && grep -qx 'matrix-job-meta-prod.json: attempt 2 (found 1, 2)' "${OUT_FILE}" \
  && grep -qx 'matrix-job-meta-test.json: attempt 1 (found 1)' "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, written: $(written "${SANDBOX}/ws" | tr '\n' ' ')"
fi

begin "min-attempt leaves out the attempts before it"
make_sandbox
run_step newest "MIN_ATTEMPT=2"
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(written "${SANDBOX}/ws")" == 'matrix-job-meta-prod.json=2' ]] \
  && grep -qx 'matrix-job-meta-test-attempt-1.json: left out, attempt 1 is before attempt 2' "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, written: $(written "${SANDBOX}/ws" | tr '\n' ' ')"
fi

begin "a file from before attempts were named is read only when no attempt replaced it"
make_sandbox
echo '{"workflow": {"run_attempt": "1"}}' >"${SANDBOX}/download/matrix-job-meta-prod.json"
echo '{"workflow": {"run_attempt": "1"}}' >"${SANDBOX}/download/matrix-job-meta-old.json"
run_step newest
if [[ ${STEP_EXIT} -eq 0 ]] \
  && [[ "$(written "${SANDBOX}/ws")" == $'matrix-job-meta-old.json=1\nmatrix-job-meta-prod.json=2\nmatrix-job-meta-test.json=1' ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, written: $(written "${SANDBOX}/ws" | tr '\n' ' ')"
fi

begin "nothing downloaded: nothing written, and the step succeeds"
make_sandbox
rm -f "${SANDBOX}/download/"*
run_step newest
if [[ ${STEP_EXIT} -eq 0 && -z "$(ls -A "${SANDBOX}/ws")" ]] && grep -qx 'No artifact file was downloaded.' "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}"
fi

begin "a relative path is the workspace's"
make_sandbox
run_step newest "TO_DIR=meta"
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(written "${SANDBOX}/ws/meta")" == $'matrix-job-meta-prod.json=2\nmatrix-job-meta-test.json=1' ]]; then
  pass
else
  fail "exit ${STEP_EXIT}"
fi

begin "a min-attempt that is not a number fails the step"
make_sandbox
run_step newest "MIN_ATTEMPT=two"
if [[ ${STEP_EXIT} -eq 1 ]] \
  && grep -qx "::error title=download-newest-attempt::min-attempt is 'two', not an attempt number" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}"
fi

begin "a caller's json.py in the workspace is never imported"
make_sandbox
echo 'raise SystemExit("the caller'"'"'s json.py was imported")' >"${SANDBOX}/ws/json.py"
run_step newest
if [[ ${STEP_EXIT} -eq 0 ]] && ! grep -q "json.py was imported" "${OUT_FILE}" \
  && [[ -f "${SANDBOX}/ws/matrix-job-meta-prod.json" ]]; then
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
