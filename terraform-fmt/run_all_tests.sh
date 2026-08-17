#!/bin/env bash
#
# Tests for step_fmt.sh
#
# Uses a stub 'terraform' binary (injected via TF_BIN) so tests don't require
# — and never call — the real terraform binary. The stub appends one
# 'INVOCATION <argc>' line per call followed by one line per argument, which is
# what makes the "a directory path with a space is ONE argument" assertions
# possible: the old string-built form produced two bogus directories instead.
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

OUT_FILE=/tmp/test_output_fmt.txt

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}/workspace"

  WORK_DIR="${GITHUB_WORKSPACE}/envs/sandbox"
  mkdir -p "${WORK_DIR}"

  export input_working_directory="${WORK_DIR}"
  export input_format_check_in_root_dir="false"

  ARGS_FILE="${RUNNER_TEMP}/tf-args.txt"
  : >"${ARGS_FILE}"
  export MOCK_TF_ARGS_FILE="${ARGS_FILE}"

  unset MOCK_TF_EXIT MOCK_TF_FAIL_DIR
}

# Write a fake modules.json. Each argument is a module 'Dir' value. The
# directories are created too: terraform has them on disk by the time this
# runs, and ws-path (realpath) needs them to exist to render log lines.
write_modules_file() {
  local dirs_json dir
  dirs_json="$(printf '%s\n' "${@}" | jq -Rsc 'split("\n") | map(select(length > 0)) | map({Dir: .})')"
  for dir in "${@}"; do
    mkdir -p "${WORK_DIR}/${dir}"
  done
  mkdir -p "${WORK_DIR}/.terraform/modules"
  jq -n --argjson mods "${dirs_json}" '{Modules: $mods}' \
    >"${WORK_DIR}/.terraform/modules/modules.json"
}

# Stub terraform. Exits with MOCK_TF_EXIT, except when MOCK_TF_FAIL_DIR is set
# and matches the -chdir argument — then it exits 3 (terraform fmt's
# "formatting needed" code) so per-directory exit-code summing can be tested.
install_stub_terraform() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'STUB'
#!/bin/env bash
if [ -n "${MOCK_TF_ARGS_FILE:-}" ]; then
  printf 'INVOCATION %s\n' "${#}" >>"${MOCK_TF_ARGS_FILE}"
  printf '%s\n' "${@}" >>"${MOCK_TF_ARGS_FILE}"
fi
if [ -n "${MOCK_TF_FAIL_DIR:-}" ]; then
  for arg in "${@}"; do
    if [ "${arg}" = "-chdir=${MOCK_TF_FAIL_DIR}" ]; then
      echo "some.tf needs formatting"
      exit 3
    fi
  done
fi
exit "${MOCK_TF_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_fmt.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

# Number of stub invocations.
invocations() { grep -c '^INVOCATION ' "${ARGS_FILE}"; }

# All -chdir arguments, one per line, in invocation order.
chdirs() { grep '^-chdir=' "${ARGS_FILE}" | sed 's/^-chdir=//'; }

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
    echo "--- recorded invocations ---"
    cat "${ARGS_FILE}" 2>/dev/null || true
    echo "--- /recorded invocations ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}          TERRAFORM-FMT STEP TESTS          ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: no modules.json → check the project directory only
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
run_step
assert "No modules file: step exits 0" test "${LAST_EXIT}" -eq 0
assert "No modules file: exactly one invocation" test "$(invocations)" -eq 1
assert "No modules file: checks the project directory" \
  test "$(chdirs)" = "${WORK_DIR}"
assert "No modules file: argv is -chdir + fmt -check -recursive" \
  test "$(grep -c '^INVOCATION 4$' "${ARGS_FILE}")" -eq 1
assert "No modules file: log says it runs in project-dir" \
  grep -q "check will run in 'project-dir'" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: format-check-in-root-dir → check the repository root only
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
write_modules_file "." "modules/network"
export input_format_check_in_root_dir="true"
run_step
assert "Root dir: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Root dir: exactly one invocation" test "$(invocations)" -eq 1
assert "Root dir: checks GITHUB_WORKSPACE (modules file ignored)" \
  test "$(chdirs)" = "${GITHUB_WORKSPACE}"

# ----------------------------------------------------------------------
# Test: modules.json → one invocation per module dir, '.terraform/*'
#       entries filtered out, duplicates collapsed
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
write_modules_file "." "modules/network" "modules/network" ".terraform/modules/vendored"
run_step
assert "Modules file: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Modules file: one invocation per unique non-vendored dir" \
  test "$(invocations)" -eq 2
assert "Modules file: project dir ('.') included" \
  bash -c "chdirs() { grep '^-chdir=' '${ARGS_FILE}' | sed 's/^-chdir=//'; }; chdirs | grep -Fxq '${WORK_DIR}/.'"
assert "Modules file: module dir included" \
  bash -c "grep -Fxq -- '-chdir=${WORK_DIR}/modules/network' '${ARGS_FILE}'"
assert "Modules file: vendored '.terraform' dir excluded" \
  bash -c "! grep -q -- '-chdir=.*\.terraform/modules/vendored' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: a module directory path containing a space is checked as ONE
# directory, not two. This is the latent bug the array conversion fixes —
# see docs/Per-goal-environment-variables.md §6.5.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
write_modules_file "modules/storage account"
run_step
assert "Space in dir: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Space in dir: exactly one invocation (not two)" \
  test "$(invocations)" -eq 1
assert "Space in dir: argv has 4 elements (path not word-split)" \
  test "$(grep -c '^INVOCATION 4$' "${ARGS_FILE}")" -eq 1
assert "Space in dir: path arrives verbatim as one argument" \
  bash -c "grep -Fxq -- '-chdir=${WORK_DIR}/modules/storage account' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: a module directory path containing a glob character is not expanded
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
mkdir -p "${WORK_DIR}/modules/a" "${WORK_DIR}/modules/b"
write_modules_file 'modules/*'
run_step
assert "Glob in dir: exactly one invocation (not one per match)" \
  test "$(invocations)" -eq 1
assert "Glob in dir: path arrives unexpanded" \
  bash -c "grep -Fxq -- '-chdir=${WORK_DIR}/modules/*' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: non-zero exit from terraform propagates
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=3
run_step
assert "Failure: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Failure: exits with terraform's code" test "${LAST_EXIT}" -eq 3
assert "Failure: error log line present" \
  grep -q "fmt exited with code '3'!" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: exit codes are summed across directories — one failing directory
# out of three still fails the step
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
write_modules_file "." "modules/network" "modules/storage"
export MOCK_TF_FAIL_DIR="${WORK_DIR}/modules/network"
run_step
assert "Mixed results: three invocations" test "$(invocations)" -eq 3
assert "Mixed results: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Mixed results: exit code is the sum (0+3+0)" test "${LAST_EXIT}" -eq 3

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}            step_fmt.sh SUMMARY             ${NC}"
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
