#!/bin/env bash
#
# Tests for step_plan_show.sh
#
# 'terraform show <plan-file>' is mocked via TF_BIN — no real terraform
# binary is invoked.
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
  export input_plan_tf_output_file="${RUNNER_TEMP}/fake-plan.bin"

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
    source "${_this_script_dir}/step_plan_show.sh"
  ) >/tmp/test_output_show.txt 2>&1
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
    cat /tmp/test_output_show.txt 2>/dev/null || true
    echo "--- /step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}       TERRAFORM-PLAN SHOW STEP TESTS       ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Happy path: stub prints predictable text → txt file is produced.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="Plan rendered as text content"
run_step

txt_file="$(get_output tf-plan-txt-output-file)"
assert "txt output file path is published" test -n "${txt_file}"
assert "txt output file path is under GITHUB_WORKSPACE" \
  bash -c "[[ '${txt_file}' == ${GITHUB_WORKSPACE}/* ]]"
assert "txt output file path follows tf-plan-<env>.txt convention" \
  bash -c "[[ '${txt_file}' == */tf-plan-testenv.txt ]]"
assert "txt output file exists on disk" test -f "${txt_file}"
assert "txt output file contains stub output" \
  grep -q "Plan rendered as text content" "${txt_file}"
assert "step exits 0 on happy path" test "${LAST_EXIT}" -eq 0

# ----------------------------------------------------------------------
# 'terraform show' failure: step still completes (continue-on-error in
# action.yml). The script does not propagate the failure as exit code 1 —
# matches the legacy behavior where this step was wrapped in
# continue-on-error: true.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=1
export MOCK_TF_STDOUT="Error rendering plan"
run_step
assert "Step still exits 0 when terraform show fails (continue-on-error semantics)" \
  test "${LAST_EXIT}" -eq 0
txt_file="$(get_output tf-plan-txt-output-file)"
assert "txt output file path still published on failure" \
  test -n "${txt_file}"
assert "txt output file contains the error text from stub stdout" \
  grep -q "Error rendering plan" "${txt_file}"

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}         step_plan_show.sh SUMMARY          ${NC}"
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
