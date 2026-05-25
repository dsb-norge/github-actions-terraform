#!/bin/env bash
#
# Tests for step_init.sh
#
# Uses a stub 'terraform' binary (injected via TF_BIN) so tests don't
# require — and never call — the real terraform binary. The stub records
# its argv when MOCK_TF_ARGV_FILE is set and obeys MOCK_TF_EXIT,
# MOCK_TF_STDOUT env vars.
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

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}"

  WORK_DIR="${RUNNER_TEMP}/work"
  mkdir -p "${WORK_DIR}"

  export input_working_directory="${WORK_DIR}"
  export input_environment_name="testenv"
  export input_additional_dirs_json="[]"
  export input_plugin_cache_directory=""

  unset MOCK_TF_EXIT MOCK_TF_STDOUT MOCK_TF_ARGV_FILE
}

# Installs a stub terraform that records argv and obeys MOCK_TF_EXIT.
# When MOCK_TF_EXIT_DIR_<base64-of-cwd> is set, the stub uses that value
# instead — lets a single test exercise different exit codes per dir.
install_stub_terraform() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'STUB'
#!/bin/env bash
if [ -n "${MOCK_TF_ARGV_FILE:-}" ]; then
  # Record argv plus PWD so tests can verify which dir each call ran from.
  printf 'pwd=%s argv=%s\n' "$(pwd)" "$*" >>"${MOCK_TF_ARGV_FILE}"
fi
if [ -n "${MOCK_TF_STDOUT:-}" ]; then
  printf '%s\n' "${MOCK_TF_STDOUT}"
fi
# Per-call exit override based on argv. Lets one test exercise mixed
# success/failure across project-dir + additional-dirs init.
for tok in "$@"; do
  case "${tok}" in
    -chdir=*)
      _chdir="${tok#-chdir=}"
      _env_var="MOCK_TF_EXIT_$(echo -n "${_chdir}" | md5sum | cut -c1-8)"
      if [ -n "${!_env_var:-}" ]; then exit "${!_env_var}"; fi
      ;;
  esac
done
exit "${MOCK_TF_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_init.sh"
  ) >/tmp/test_output_init.txt 2>&1
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
    cat /tmp/test_output_init.txt 2>/dev/null || true
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
echo -e "${YELLOW}         TERRAFORM-INIT STEP TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: Happy path, no additional dirs
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="Terraform has been successfully initialized!"
run_step
assert "Happy path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Happy path: console-output-file output is published" \
  test -n "$(get_output tf-init-console-output-file)"
assert "Happy path: console-output-file exists" \
  test -s "$(get_output tf-init-console-output-file)"
assert "Happy path: console-output-file contains stub stdout" \
  grep -q "successfully initialized" "$(get_output tf-init-console-output-file)"

# ----------------------------------------------------------------------
# Test: Additional dirs — both init invocations land in the same console file
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
EXTRA_DIR="modules/foo"
mkdir -p "${GITHUB_WORKSPACE}/${EXTRA_DIR}"
export input_additional_dirs_json="[\"${EXTRA_DIR}\"]"
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="initialized OK"
export MOCK_TF_ARGV_FILE="${RUNNER_TEMP}/argv.log"
run_step
assert "Additional dirs: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Additional dirs: terraform invoked twice" \
  bash -c "[[ \$(wc -l <\"${MOCK_TF_ARGV_FILE}\") -eq 2 ]]"
assert "Additional dirs: second invocation uses -chdir=" \
  grep -q -- "-chdir=${GITHUB_WORKSPACE}/${EXTRA_DIR}" "${MOCK_TF_ARGV_FILE}"
_cf="$(get_output tf-init-console-output-file)"
assert "Additional dirs: console file contains both invocations' output" \
  bash -c "[[ \$(grep -c 'initialized OK' '${_cf}') -eq 2 ]]"

# ----------------------------------------------------------------------
# Test: Failure path — terraform exit 1 → step exits non-zero
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=1
export MOCK_TF_STDOUT="Error: failed to init"
run_step
assert "Failure: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Failure: error log line present" \
  grep -q "init exited with code '1'" /tmp/test_output_init.txt
assert "Failure: console-output-file still captured" \
  test -s "$(get_output tf-init-console-output-file)"

# ----------------------------------------------------------------------
# Test: Mixed success/failure across project dir + additional dir
# Project init exits 0; additional dir's init exits 1; total non-zero.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
EXTRA_DIR="modules/bar"
mkdir -p "${GITHUB_WORKSPACE}/${EXTRA_DIR}"
export input_additional_dirs_json="[\"${EXTRA_DIR}\"]"
export MOCK_TF_EXIT=0
# Set exit-override for the extra dir's abs path
_chdir_hash="$(echo -n "${GITHUB_WORKSPACE}/${EXTRA_DIR}" | md5sum | cut -c1-8)"
declare -x "MOCK_TF_EXIT_${_chdir_hash}=1"
run_step
assert "Mixed: step exits non-zero overall" test "${LAST_EXIT}" -ne 0
assert "Mixed: failure log mentions exit code 1" \
  grep -q "init exited with code '1'" /tmp/test_output_init.txt
unset "MOCK_TF_EXIT_${_chdir_hash}"

# ----------------------------------------------------------------------
# Test: Missing additional dir → step exits non-zero with descriptive log
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_additional_dirs_json="[\"modules/does-not-exist\"]"
export MOCK_TF_EXIT=0
run_step
assert "Missing dir: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Missing dir: log mentions does-not-exist" \
  grep -q "does not exist" /tmp/test_output_init.txt

# ----------------------------------------------------------------------
# Test: Empty additional-dirs JSON falls back to project-only init
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_additional_dirs_json=""
export MOCK_TF_EXIT=0
export MOCK_TF_ARGV_FILE="${RUNNER_TEMP}/argv.log"
run_step
assert "Empty JSON: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Empty JSON: terraform invoked exactly once" \
  bash -c "[[ \$(wc -l <\"${MOCK_TF_ARGV_FILE}\") -eq 1 ]]"
assert "Empty JSON: no-additional-dirs log line present" \
  grep -q "no additional directories" /tmp/test_output_init.txt

# ----------------------------------------------------------------------
# Test: Environment name appears in console-output-file path
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_environment_name="my-special-env"
export MOCK_TF_EXIT=0
run_step
cf="$(get_output tf-init-console-output-file)"
assert "Env name: file name embeds environment name" \
  bash -c "[[ '${cf}' == *'tf-init-console-output-my-special-env.txt' ]]"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}            step_init.sh SUMMARY            ${NC}"
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
