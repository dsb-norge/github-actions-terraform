#!/bin/env bash
#
# Test runner for terraform-module-cache.
#
# The action has four steps, so tests are organised per step and sourced from
# here — shared counters, one canonical summary. See
# docs/Action-implementation-guide.md and docs/Testing-in-ci.md.
#
# No terraform binary is needed: the resolve phase reads .tf files, the
# snapshot/verify phases read modules.json and the prune phase only moves files
# around, so every fixture is static text.
#
# Fixture ids map to the scenarios in docs/Terraform-module-cache.md §9.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

# Fresh simulated GitHub Actions environment plus an empty workspace.
# Sets globals: WORK_DIR (== GITHUB_WORKSPACE), STEP_LOG
setup_workspace() {
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_STEP_SUMMARY=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export RUNNER_OS="Linux"
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE=$(mktemp -d)
  WORK_DIR="${GITHUB_WORKSPACE}"
  STEP_LOG=$(mktemp)

  # Clear inputs so a value never leaks from the previous test.
  unset input_project_dir input_additional_dirs_json input_environment
  unset input_cache_paths input_cache_hit input_snapshot_dir
  export input_additional_dirs_json='[]'
  export input_environment='test-env'
  export input_cache_hit='false'
}

# Write a .tf file, creating the directory. write_tf <relpath> <<'TF' … TF
write_tf() {
  local rel="${1}"
  mkdir -p "${WORK_DIR}/$(dirname "${rel}")"
  cat >"${WORK_DIR}/${rel}"
}

# Write a modules.json for a directory. write_manifest <dir> <<'JSON' … JSON
write_manifest() {
  local dir="${1}"
  mkdir -p "${WORK_DIR}/${dir}/.terraform/modules"
  cat >"${WORK_DIR}/${dir}/.terraform/modules/modules.json"
}

# Run one step in a subshell so its 'exit' does not end the suite.
# Stdout+stderr land in STEP_LOG; LAST_EXIT holds the code.
run_step() {
  local script="${1}"
  # Each step gets a fresh outputs file, as it would on a runner. Without this
  # a second run in the same fixture appends, and out_value returns both.
  : >"${GITHUB_OUTPUT}"
  # '-e -o pipefail' matches the shell GitHub sources a composite step's script
  # in. A command whose non-zero status is normal — a find that hits an
  # unreadable path, a grep that matches nothing — ends the step there, so a
  # harness without errexit passes code that fails on every real run.
  (bash -e -o pipefail "${_this_script_dir}/${script}") >"${STEP_LOG}" 2>&1
  LAST_EXIT=$?
}

run_resolve() { run_step step_resolve.sh; }
run_snapshot() {
  run_step step_snapshot.sh
  export input_snapshot_dir="${RUNNER_TEMP}/module-cache-manifests"
}
run_verify() { run_step step_verify.sh; }
run_prune() { run_step step_prune.sh; }

# Read a value from GITHUB_OUTPUT, handling both 'k=v' and the heredoc form
# that set-multiline-output writes.
out_value() {
  awk -v key="${1}" '
    !inblock && index($0, key "=") == 1 { print substr($0, length(key) + 2); found=1; next }
    !inblock && index($0, key "<<") == 1 { inblock=1; delim=substr($0, length(key) + 3); next }
    inblock && $0 == delim { inblock=0; next }
    inblock { print }
  ' "${GITHUB_OUTPUT}"
}

assert() {
  local name="${1}"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "${@}"; then
    echo -e "  ${GREEN}PASS${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "  ${RED}FAIL${NC}"
    echo "  --- step output ---"
    sed 's/^/  /' "${STEP_LOG}" 2>/dev/null | head -30
    echo "  --- step outputs ---"
    sed 's/^/  /' "${GITHUB_OUTPUT}" 2>/dev/null | head -20
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_eq() {
  local name="${1}" expected="${2}" actual="${3}"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if [[ "${expected}" == "${actual}" ]]; then
    echo -e "  ${GREEN}PASS${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "  ${RED}FAIL${NC} expected '${expected}', got '${actual}'"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# Assert the step log contains (or does not contain) a fixed string.
assert_log_has() { assert "${1}" grep -qF -- "${2}" "${STEP_LOG}"; }
assert_log_lacks() { assert "${1}" bash -c '! grep -qF -- "$1" "$2"' _ "${2}" "${STEP_LOG}"; }

# --------------------------------------------------------------------------
# Per-step suites
# --------------------------------------------------------------------------

echo -e "${YELLOW}=== step_resolve.sh ===${NC}"
source "${_this_script_dir}/run_tests_step_resolve.sh"

echo ""
echo -e "${YELLOW}=== step_snapshot.sh / step_verify.sh ===${NC}"
source "${_this_script_dir}/run_tests_step_verify.sh"

echo ""
echo -e "${YELLOW}=== step_prune.sh ===${NC}"
source "${_this_script_dir}/run_tests_step_prune.sh"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}               TEST SUMMARY                ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  echo -e "${RED}SOME TESTS FAILED!${NC}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED!${NC}"
  exit 0
fi
