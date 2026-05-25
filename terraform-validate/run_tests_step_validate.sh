#!/bin/env bash
#
# Tests for step_validate.sh
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

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}"

  WORK_DIR="${RUNNER_TEMP}/work"
  mkdir -p "${WORK_DIR}"

  export input_working_directory="${WORK_DIR}"
  export input_environment_name="testenv"

  unset MOCK_TF_EXIT MOCK_TF_STDOUT
}

install_stub_terraform() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'STUB'
#!/bin/env bash
if [ -n "${MOCK_TF_STDOUT:-}" ]; then
  printf '%s\n' "${MOCK_TF_STDOUT}"
fi
exit "${MOCK_TF_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_validate.sh"
  ) >/tmp/test_output_validate.txt 2>&1
  LAST_EXIT=$?
}

get_output() {
  local key="${1}"
  grep "^${key}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-
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
    cat /tmp/test_output_validate.txt 2>/dev/null || true
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}" 2>/dev/null || true
    echo "--- /GITHUB_OUTPUT ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}       TERRAFORM-VALIDATE STEP TESTS       ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: Happy path (terraform exit 0)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="Success! The configuration is valid."
run_step
assert "Happy path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Happy path: console-output-file output is published" \
  test -n "$(get_output tf-validate-console-output-file)"
assert "Happy path: console-output-file exists" \
  test -s "$(get_output tf-validate-console-output-file)"
assert "Happy path: console-output-file contains stub stdout" \
  grep -q "configuration is valid" "$(get_output tf-validate-console-output-file)"

# ----------------------------------------------------------------------
# Test: Failure (terraform exit 1)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=1
export MOCK_TF_STDOUT="Error: invalid configuration"
run_step
assert "Failure: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Failure: error log line present" \
  grep -q "validate exited with code '1'" /tmp/test_output_validate.txt
assert "Failure: console-output-file still captured" \
  test -s "$(get_output tf-validate-console-output-file)"
assert "Failure: console-output-file contains error text" \
  grep -q "invalid configuration" "$(get_output tf-validate-console-output-file)"

# ----------------------------------------------------------------------
# Test: Environment name appears in console-output-file path
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_environment_name="weird-env-name"
export MOCK_TF_EXIT=0
run_step
cf="$(get_output tf-validate-console-output-file)"
assert "Env name: file name embeds environment name" \
  bash -c "[[ '${cf}' == *'tf-validate-console-output-weird-env-name.txt' ]]"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}          step_validate.sh SUMMARY          ${NC}"
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
