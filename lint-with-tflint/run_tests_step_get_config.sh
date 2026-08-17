#!/bin/env bash
#
# Tests for step_get_config.sh
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

OUT_FILE=/tmp/test_output_get_config.txt

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}/workspace"

  WORK_DIR="${GITHUB_WORKSPACE}/envs/sandbox"
  mkdir -p "${WORK_DIR}"

  export input_working_directory="${WORK_DIR}"
  export input_config_file_path=""
}

make_config() {
  local path="${1}"
  mkdir -p "$(dirname "${path}")"
  printf 'plugin "terraform" { enabled = true }\n' >"${path}"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_get_config.sh"
  ) >"${OUT_FILE}" 2>&1
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
    cat "${OUT_FILE}" 2>/dev/null || true
    echo "--- /step output ---"
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}" 2>/dev/null || true
    echo "--- /GITHUB_OUTPUT ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}      LINT-WITH-TFLINT GET-CONFIG TESTS     ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: config in the working directory wins over the repo root
# ----------------------------------------------------------------------
setup_workdir
make_config "${WORK_DIR}/.tflint.hcl"
make_config "${GITHUB_WORKSPACE}/.tflint.hcl"
run_step
assert "Search: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Search: working-directory config takes precedence" \
  test "$(get_output file)" = "${WORK_DIR}/.tflint.hcl"

# ----------------------------------------------------------------------
# Test: falls back to the repository root
# ----------------------------------------------------------------------
setup_workdir
make_config "${GITHUB_WORKSPACE}/.tflint.hcl"
run_step
assert "Fallback: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Fallback: repo-root config is used" \
  test "$(get_output file)" = "${GITHUB_WORKSPACE}/.tflint.hcl"

# ----------------------------------------------------------------------
# Test: no config anywhere → hard error
# ----------------------------------------------------------------------
setup_workdir
run_step
assert "No config: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "No config: error explains what is missing" \
  grep -q "could not find a TFLint config file to use" "${OUT_FILE}"
assert "No config: no 'file' output published" \
  test -z "$(get_output file)"

# ----------------------------------------------------------------------
# Test: configured absolute path is used verbatim
# ----------------------------------------------------------------------
setup_workdir
make_config "${GITHUB_WORKSPACE}/.tflint.hcl"
make_config "${RUNNER_TEMP}/custom/my-tflint.hcl"
export input_config_file_path="${RUNNER_TEMP}/custom/my-tflint.hcl"
run_step
assert "Configured absolute: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Configured absolute: takes precedence over conventional locations" \
  test "$(get_output file)" = "${RUNNER_TEMP}/custom/my-tflint.hcl"

# ----------------------------------------------------------------------
# Test: configured relative path is resolved against the working directory.
# It is published as given — step_lint.sh cd's to the same working directory,
# so tflint resolves it to the same file.
# ----------------------------------------------------------------------
setup_workdir
make_config "${WORK_DIR}/config/relative.hcl"
export input_config_file_path="config/relative.hcl"
run_step
assert "Configured relative: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Configured relative: published as given" \
  test "$(get_output file)" = "config/relative.hcl"
assert "Configured relative: log resolves it under the working directory" \
  grep -q "envs/sandbox/config/relative.hcl" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: configured relative path that only exists under the working
# directory, checked from a different cwd — the fallback branch that
# prefixes '$(pwd)/' must still find it
# ----------------------------------------------------------------------
setup_workdir
make_config "${WORK_DIR}/config/only-here.hcl"
export input_config_file_path="config/only-here.hcl"
pushd "${RUNNER_TEMP}" >/dev/null || exit 1
run_step
popd >/dev/null || exit 1
assert "Configured relative from elsewhere: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Configured relative from elsewhere: resolved under the working directory" \
  test "$(get_output file)" = "config/only-here.hcl"

# ----------------------------------------------------------------------
# Test: configured path that does not exist → hard error, no silent
# fallback to a conventional location
# ----------------------------------------------------------------------
setup_workdir
make_config "${GITHUB_WORKSPACE}/.tflint.hcl"
export input_config_file_path="does/not/exist.hcl"
run_step
assert "Configured missing: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Configured missing: error names the configured path" \
  grep -q "the configured path 'does/not/exist.hcl' does not exist" "${OUT_FILE}"
assert "Configured missing: does not fall back to the repo-root config" \
  test -z "$(get_output file)"

# ----------------------------------------------------------------------
# Test: config path containing a space is handled
# ----------------------------------------------------------------------
setup_workdir
make_config "${WORK_DIR}/my configs/.tflint.hcl"
export input_config_file_path="my configs/.tflint.hcl"
run_step
assert "Space in path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Space in path: resolved path is intact" \
  test "$(get_output file)" = "my configs/.tflint.hcl"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}         step_get_config.sh SUMMARY         ${NC}"
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
