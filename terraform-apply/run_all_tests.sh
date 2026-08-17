#!/bin/env bash
#
# Tests for step_apply.sh
#
# Uses a stub 'terraform' binary (injected via TF_BIN) so tests don't
# require — and never call — the real terraform binary. The stub records
# its argv one element per line (preceded by the argument count) plus its
# working directory, which is what makes the array-built-invocation
# assertions possible: a string-built command that word-splits a path with
# a space shows up as a higher argument count.
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

OUT_FILE=/tmp/test_output_apply.txt

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}"

  WORK_DIR="${RUNNER_TEMP}/work"
  mkdir -p "${WORK_DIR}"

  PLAN_FILE="${GITHUB_WORKSPACE}/tf-plan-testenv.plan"
  echo 'fake plan' >"${PLAN_FILE}"

  export input_working_directory="${WORK_DIR}"
  export input_terraform_plan_file="${PLAN_FILE}"

  unset MOCK_TF_EXIT MOCK_TF_STDOUT MOCK_TF_ARGS_FILE MOCK_TF_PWD_FILE
}

install_stub_terraform() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'STUB'
#!/bin/env bash
if [ -n "${MOCK_TF_ARGS_FILE:-}" ]; then
  printf '%s\n' "${#}" "${@}" >"${MOCK_TF_ARGS_FILE}"
fi
if [ -n "${MOCK_TF_PWD_FILE:-}" ]; then
  pwd >"${MOCK_TF_PWD_FILE}"
fi
if [ -n "${MOCK_TF_STDOUT:-}" ]; then
  printf '%s\n' "${MOCK_TF_STDOUT}"
fi
exit "${MOCK_TF_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

# Enable argv + pwd recording for the next run_step.
record_invocation() {
  export MOCK_TF_ARGS_FILE="${RUNNER_TEMP}/tf-args.txt"
  export MOCK_TF_PWD_FILE="${RUNNER_TEMP}/tf-pwd.txt"
}

# Argument count as recorded by the stub.
argc() { head -n1 "${MOCK_TF_ARGS_FILE}"; }

# Nth recorded argument (1-based).
argn() { sed -n "$((${1} + 1))p" "${MOCK_TF_ARGS_FILE}"; }

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_apply.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

assert() {
  local name="${1}"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "$@"; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo "--- step output ---"
    cat "${OUT_FILE}" 2>/dev/null || true
    echo "--- /step output ---"
    echo "--- recorded argv ---"
    cat "${MOCK_TF_ARGS_FILE}" 2>/dev/null || true
    echo "--- /recorded argv ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}         TERRAFORM-APPLY STEP TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: Happy path (terraform exit 0)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_invocation
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="Apply complete! Resources: 1 added, 0 changed, 0 destroyed."
run_step
assert "Happy path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Happy path: stub stdout reaches the log" \
  grep -q "Apply complete" "${OUT_FILE}"
assert "Happy path: terraform invoked from the working directory" \
  test "$(cat "${MOCK_TF_PWD_FILE}")" = "${WORK_DIR}"

# ----------------------------------------------------------------------
# Test: argv shape — apply -input=false -auto-approve <plan-file>
# ----------------------------------------------------------------------
assert "argv: exactly 4 arguments" test "$(argc)" -eq 4
assert "argv: 1st is 'apply'" test "$(argn 1)" = "apply"
assert "argv: 2nd is '-input=false'" test "$(argn 2)" = "-input=false"
assert "argv: 3rd is '-auto-approve'" test "$(argn 3)" = "-auto-approve"
assert "argv: 4th is the plan file, verbatim" test "$(argn 4)" = "${PLAN_FILE}"

# ----------------------------------------------------------------------
# Test: Failure (terraform exit 1)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=1
export MOCK_TF_STDOUT="Error: applying plan failed"
run_step
assert "Failure: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Failure: error log line present" \
  grep -q "apply exited with code '1'" "${OUT_FILE}"
assert "Failure: terraform stderr/stdout still reaches the log" \
  grep -q "applying plan failed" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: plan file path containing a space reaches terraform as ONE argv
# element. Regression guard for the string-built invocation this action
# used to have — see docs/Per-goal-environment-variables.md §6.5.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_invocation
PLAN_FILE="${GITHUB_WORKSPACE}/tf plan with spaces.plan"
echo 'fake plan' >"${PLAN_FILE}"
export input_terraform_plan_file="${PLAN_FILE}"
export MOCK_TF_EXIT=0
run_step
assert "Space in path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Space in path: still exactly 4 arguments (no word-splitting)" \
  test "$(argc)" -eq 4
assert "Space in path: plan file arrives verbatim" \
  test "$(argn 4)" = "${PLAN_FILE}"
assert "Space in path: logged command string shows the real quoting" \
  grep -Fq "'${PLAN_FILE}'" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: plan file path containing a glob character is not expanded
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_invocation
# Files the glob would match if expansion happened.
touch "${WORK_DIR}/decoy-a" "${WORK_DIR}/decoy-b"
PLAN_FILE="${GITHUB_WORKSPACE}/tf-plan-*.plan"
touch "${GITHUB_WORKSPACE}/tf-plan-one.plan" "${GITHUB_WORKSPACE}/tf-plan-two.plan"
export input_terraform_plan_file="${PLAN_FILE}"
export MOCK_TF_EXIT=0
run_step
assert "Glob in path: still exactly 4 arguments (no glob expansion)" \
  test "$(argc)" -eq 4
assert "Glob in path: plan file arrives unexpanded" \
  test "$(argn 4)" = "${GITHUB_WORKSPACE}/tf-plan-*.plan"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}           step_apply.sh SUMMARY            ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
