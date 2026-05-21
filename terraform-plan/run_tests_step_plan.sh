#!/bin/env bash
#
# Tests for step_plan.sh
#
# Uses a stub 'terraform' binary (injected via TF_BIN) so tests don't
# require — and never call — the real terraform binary. The stub records
# its argv when MOCK_TF_ARGV_FILE is set and obeys MOCK_TF_EXIT,
# MOCK_TF_STDOUT, MOCK_TF_SLEEP env vars.
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

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

# Fresh GITHUB_OUTPUT, workspace, working dir; clear MOCK_TF_* overrides
# left by previous tests.
setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}"

  WORK_DIR="${RUNNER_TEMP}/work"
  mkdir -p "${WORK_DIR}"

  export input_working_directory="${WORK_DIR}"
  export input_environment_name="testenv"
  export input_extra_global_args=""
  export input_extra_plan_args=""

  unset MOCK_TF_EXIT MOCK_TF_STDOUT MOCK_TF_SLEEP MOCK_TF_ARGV_FILE
}

# Install a stub 'terraform' binary configurable per-test via env vars.
# Captures argv to MOCK_TF_ARGV_FILE if that variable is set when the
# stub is invoked. Path is exported as TF_BIN so step_plan.sh picks it
# up without needing to alter PATH (the legacy action shells out to bare
# 'terraform'; the script reads TF_BIN to allow this seam).
install_stub_terraform() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'STUB'
#!/bin/env bash
# Recorded argv (one line per invocation)
if [ -n "${MOCK_TF_ARGV_FILE:-}" ]; then
  printf '%s\n' "$*" >>"${MOCK_TF_ARGV_FILE}"
fi
if [ -n "${MOCK_TF_STDOUT:-}" ]; then
  printf '%s\n' "${MOCK_TF_STDOUT}"
fi
if [ "${MOCK_TF_SLEEP:-0}" -gt 0 ]; then
  sleep "${MOCK_TF_SLEEP}"
fi
exit "${MOCK_TF_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_plan.sh"
  ) >/tmp/test_output_plan.txt 2>&1
  LAST_EXIT=$?
}

get_output() {
  local key="${1}"
  grep "^${key}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-
}

# assert <name> <command...>
# Runs the command and reports pass/fail. The command's stderr is captured
# alongside the step's output for diagnostics on failure.
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
    cat /tmp/test_output_plan.txt 2>/dev/null || true
    echo "--- /step output ---"
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}" 2>/dev/null || true
    echo "--- /GITHUB_OUTPUT ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}         TERRAFORM-PLAN STEP TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: Happy path, no changes (terraform exit 0)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="No changes. Your infrastructure matches the configuration."
run_step
assert "Exit 0: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Exit 0: tf-plan-exitcode output is '0'" \
  test "$(get_output tf-plan-exitcode)" = "0"
assert "Exit 0: no-changes log line present" \
  grep -q "no changes indicated" /tmp/test_output_plan.txt
assert "Exit 0: console output file path is published" \
  test -n "$(get_output tf-plan-console-output-file)"
assert "Exit 0: console output file exists and contains stub stdout" \
  grep -q "No changes" "$(get_output tf-plan-console-output-file)"

# ----------------------------------------------------------------------
# Test: Happy path, with changes (terraform exit 2 → script exit 0,
#                                 raw 2 still published)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=2
export MOCK_TF_STDOUT="Plan: 1 to add, 0 to change, 0 to destroy."
run_step
assert "Exit 2: step exits 0 (success-with-changes normalized)" \
  test "${LAST_EXIT}" -eq 0
assert "Exit 2: tf-plan-exitcode publishes raw '2'" \
  test "$(get_output tf-plan-exitcode)" = "2"
assert "Exit 2: success-with-changes log line present" \
  grep -q "changes indicated" /tmp/test_output_plan.txt

# ----------------------------------------------------------------------
# Test: Failure (terraform exit 1 → script exits non-zero)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=1
export MOCK_TF_STDOUT="Error: something went wrong"
run_step
assert "Exit 1: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Exit 1: tf-plan-exitcode publishes raw '1'" \
  test "$(get_output tf-plan-exitcode)" = "1"
assert "Exit 1: failure log line present" \
  grep -q "failed to plan" /tmp/test_output_plan.txt

# ----------------------------------------------------------------------
# Test: extra-global-args and extra-plan-args reach terraform invocation
# in the expected order:
#   <tf_bin> <global> plan -detailed-exitcode -input=false -no-color -out=<file> <plan>
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=0
export MOCK_TF_ARGV_FILE="${RUNNER_TEMP}/argv.log"
export input_extra_global_args="-chdir=/tmp/fake"
export input_extra_plan_args="-var foo=bar -var baz=qux"
run_step
argv_line="$(head -n1 "${MOCK_TF_ARGV_FILE}" 2>/dev/null || true)"
assert "argv: global arg precedes 'plan'" \
  bash -c "[[ '${argv_line}' == *'-chdir=/tmp/fake plan'* ]]"
assert "argv: plan flags from script present" \
  bash -c "[[ '${argv_line}' == *'-detailed-exitcode'* && '${argv_line}' == *'-input=false'* && '${argv_line}' == *'-no-color'* ]]"
assert "argv: plan args appear after the -out flag" \
  bash -c "[[ '${argv_line}' == *'-var foo=bar -var baz=qux' ]]"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}            step_plan.sh SUMMARY            ${NC}"
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
