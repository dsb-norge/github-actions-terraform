#!/bin/env bash
#
# Tests for step_lint.sh
#
# Uses a stub 'tflint' binary (injected via TFLINT_BIN) so tests don't require
# — and never call — the real tflint binary. The stub appends one
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

OUT_FILE=/tmp/test_output_lint.txt

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}/workspace"

  WORK_DIR="${GITHUB_WORKSPACE}/envs/sandbox"
  mkdir -p "${WORK_DIR}"

  CONFIG_FILE="${GITHUB_WORKSPACE}/.tflint.hcl"
  printf 'plugin "terraform" { enabled = true }\n' >"${CONFIG_FILE}"

  export input_working_directory="${WORK_DIR}"
  export input_config_file="${CONFIG_FILE}"

  ARGS_FILE="${RUNNER_TEMP}/tflint-args.txt"
  : >"${ARGS_FILE}"
  export MOCK_TFLINT_ARGS_FILE="${ARGS_FILE}"

  unset MOCK_TFLINT_EXIT MOCK_TFLINT_FAIL_DIR MOCK_TFLINT_INIT_FAIL_DIR
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

install_stub_tflint() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/tflint" <<'STUB'
#!/bin/env bash
_is_init=0
_chdir=""
for arg in "${@}"; do
  [ "${arg}" = "--init" ] && _is_init=1
  case "${arg}" in --chdir=*) _chdir="${arg#--chdir=}" ;; esac
done

if [ -n "${MOCK_TFLINT_ARGS_FILE:-}" ]; then
  printf 'INVOCATION %s\n' "${#}" >>"${MOCK_TFLINT_ARGS_FILE}"
  printf '%s\n' "${@}" >>"${MOCK_TFLINT_ARGS_FILE}"
fi

if [ "${_is_init}" -eq 1 ]; then
  if [ -n "${MOCK_TFLINT_INIT_FAIL_DIR:-}" ] && [ "${_chdir}" = "${MOCK_TFLINT_INIT_FAIL_DIR}" ]; then
    echo "Failed to install plugin"
    exit 7
  fi
  exit 0
fi

if [ -n "${MOCK_TFLINT_FAIL_DIR:-}" ] && [ "${_chdir}" = "${MOCK_TFLINT_FAIL_DIR}" ]; then
  echo "main.tf:1:1: Warning - something (rule)"
  exit 2
fi
exit "${MOCK_TFLINT_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/tflint"
  export TFLINT_BIN="${stub_dir}/tflint"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_lint.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

invocations() { grep -c '^INVOCATION ' "${ARGS_FILE}"; }
init_invocations() { grep -c '^--init$' "${ARGS_FILE}"; }
lint_invocations() { grep -c '^--format=compact$' "${ARGS_FILE}"; }

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
echo -e "${YELLOW}        LINT-WITH-TFLINT LINT TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: no modules.json → lint the project directory only
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
run_step
assert "No modules file: step exits 0" test "${LAST_EXIT}" -eq 0
assert "No modules file: one init + one lint invocation" \
  test "$(invocations)" -eq 2
assert "No modules file: lints the project directory" \
  bash -c "grep -Fxq -- '--chdir=${WORK_DIR}' '${ARGS_FILE}'"
assert "No modules file: problem matcher registered" \
  grep -q '::add-matcher::.*tflint_matcher.json' "${OUT_FILE}"
assert "No modules file: config file passed to tflint" \
  bash -c "grep -Fxq -- '--config=${CONFIG_FILE}' '${ARGS_FILE}'"
assert "No modules file: summary line present" \
  grep -q "success ->" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: modules.json → init + lint per module dir, '.terraform/*' filtered
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_modules_file "." "modules/network" "modules/network" ".terraform/modules/vendored"
run_step
assert "Modules file: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Modules file: two init invocations" test "$(init_invocations)" -eq 2
assert "Modules file: two lint invocations" test "$(lint_invocations)" -eq 2
assert "Modules file: vendored '.terraform' dir excluded" \
  bash -c "! grep -q -- '--chdir=.*\.terraform/modules/vendored' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: a module directory path containing a space is linted as ONE
# directory, not two. This is the latent bug the array conversion fixes —
# see docs/Per-goal-environment-variables.md §6.5.
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_modules_file "modules/storage account"
run_step
assert "Space in dir: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Space in dir: exactly one init + one lint (not two dirs)" \
  test "$(invocations)" -eq 2
assert "Space in dir: both invocations have 3 arguments (path not word-split)" \
  test "$(grep -c '^INVOCATION 3$' "${ARGS_FILE}")" -eq 2
assert "Space in dir: path arrives verbatim as one argument" \
  bash -c "grep -Fxq -- '--chdir=${WORK_DIR}/modules/storage account' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: a module directory path containing a glob character is not expanded
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
mkdir -p "${WORK_DIR}/modules/a" "${WORK_DIR}/modules/b"
write_modules_file 'modules/*'
run_step
assert "Glob in dir: exactly one init + one lint (not one per match)" \
  test "$(invocations)" -eq 2
assert "Glob in dir: path arrives unexpanded" \
  bash -c "grep -Fxq -- '--chdir=${WORK_DIR}/modules/*' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: lint findings in one directory fail the step, other directories
# still get linted (exit codes are summed)
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_modules_file "." "modules/network" "modules/storage"
export MOCK_TFLINT_FAIL_DIR="${WORK_DIR}/modules/network"
run_step
assert "Findings: three dirs linted" test "$(lint_invocations)" -eq 3
assert "Findings: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Findings: exit code is the sum (0+2+0)" test "${LAST_EXIT}" -eq 2
assert "Findings: summary marks the failing directory" \
  grep -q "failure -> ./envs/sandbox/modules/network" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: a failing 'tflint --init' records that directory as failed and the
# remaining directories are still linted
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_modules_file "." "modules/network" "modules/storage"
export MOCK_TFLINT_INIT_FAIL_DIR="${WORK_DIR}/modules/network"
run_step
assert "Init failure: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Init failure: exit code is init's code (0+7+0)" test "${LAST_EXIT}" -eq 7
assert "Init failure: error logged" \
  grep -q "TFLint init exited with code '7'" "${OUT_FILE}"
assert "Init failure: failing dir is not linted" \
  test "$(lint_invocations)" -eq 2
assert "Init failure: remaining dirs still linted" \
  bash -c "grep -Fxq -- '--chdir=${WORK_DIR}/modules/storage' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: config file path containing a space reaches tflint as one argument
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
CONFIG_FILE="${GITHUB_WORKSPACE}/my configs/.tflint.hcl"
mkdir -p "$(dirname "${CONFIG_FILE}")"
printf 'plugin "terraform" { enabled = true }\n' >"${CONFIG_FILE}"
export input_config_file="${CONFIG_FILE}"
run_step
assert "Space in config path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Space in config path: arrives verbatim as one argument" \
  bash -c "grep -Fxq -- '--config=${CONFIG_FILE}' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}            step_lint.sh SUMMARY            ${NC}"
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
