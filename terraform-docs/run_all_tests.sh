#!/bin/env bash
#
# Test runner for the terraform-docs action's step scripts:
#   step_inject_config_files.sh, step_validate_root_readme.sh, step_report.sh
#
# The two terraform-docs/gh-actions steps are a Docker action and cannot run here. The report
# step is tested by feeding it, through env, the outcomes and num_changed outputs those steps
# produce.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# The step's output, one file per run of this suite: a fixed path in /tmp is
# shared with every other suite that uses it, and suites run in parallel.
_test_output=$(mktemp)
_test_root=$(mktemp -d)
trap 'rm -rf "${_test_output}" "${_test_root}"' EXIT

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

# A fresh git repository as the checkout, fresh output files, and no step inputs.
# Sets globals: WS
setup() {
  export GITHUB_OUTPUT=$(mktemp -p "${_test_root}")
  export GITHUB_STEP_SUMMARY=$(mktemp -p "${_test_root}")
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  WS=$(mktemp -d -p "${_test_root}")
  export GITHUB_WORKSPACE="${WS}"
  git -C "${WS}" init -q
  git -C "${WS}" config user.name "test"
  git -C "${WS}" config user.email "test@example.com"
  unset input_readme_file_path input_validate_outcome \
    input_examples_outcome input_examples_num_changed \
    input_project_outcome input_project_num_changed
}

# Run a step script in a subshell from the checkout. Sets LAST_EXIT.
#   $1 - the step's name, as in step_<name>.sh
run_step() {
  (
    cd "${WS}" || exit 99
    set -o allexport
    source "${_this_script_dir}/step_${1}.sh"
  ) >"${_test_output}" 2>&1
  LAST_EXIT=$?
}

# Print a single-line output value from $GITHUB_OUTPUT.
get_output() {
  grep "^${1}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-
}

# Print the staged paths of the checkout, one per line.
staged() {
  git -C "${WS}" diff --cached --name-only
}

# Common assertion + reporting wrapper.
# Args: test_name, condition_command...
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
    cat "${_test_output}" 2>/dev/null || true
    echo "--- /step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# --------------------------------------------------------------------------
# inject-config-files
# --------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}          INJECT CONFIG FILES TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# No config and no examples/: the root config is injected and staged
setup
run_step inject_config_files
assert "no config: step succeeds" test "${LAST_EXIT}" -eq 0
assert "no config: root config is the action's default" \
  cmp -s "${_this_script_dir}/terraform-docs-module-root.yml" "${WS}/.terraform-docs.yml"
assert "no config: root config is staged" \
  test "$(staged)" = ".terraform-docs.yml"
assert "no examples/: examples-folder-exists=false" \
  test "$(get_output examples-folder-exists)" = "false"
assert "no examples/: no examples-subfolders output" \
  bash -c "! grep -q '^examples-subfolders=' '${GITHUB_OUTPUT}'"
assert "no examples/: examples/ is not created" test ! -e "${WS}/examples"

# The repository's own configs are left alone and not staged
setup
mkdir -p "${WS}/examples/basic"
echo "own: root" >"${WS}/.terraform-docs.yml"
echo "own: examples" >"${WS}/examples/.terraform-docs.yml"
run_step inject_config_files
assert "own configs: step succeeds" test "${LAST_EXIT}" -eq 0
assert "own configs: root config unchanged" \
  test "$(cat "${WS}/.terraform-docs.yml")" = "own: root"
assert "own configs: examples config unchanged" \
  test "$(cat "${WS}/examples/.terraform-docs.yml")" = "own: examples"
assert "own configs: nothing staged" test -z "$(staged)"

# examples/ without a config: the examples default is injected and staged
setup
mkdir -p "${WS}/examples/basic" "${WS}/examples/complete"
echo "own: root" >"${WS}/.terraform-docs.yml"
run_step inject_config_files
assert "examples without config: step succeeds" test "${LAST_EXIT}" -eq 0
assert "examples without config: examples config is the action's default" \
  cmp -s "${_this_script_dir}/terraform-docs-module-examples.yml" "${WS}/examples/.terraform-docs.yml"
assert "examples without config: only the examples config is staged" \
  test "$(staged)" = "examples/.terraform-docs.yml"
assert "examples without config: examples-folder-exists=true" \
  test "$(get_output examples-folder-exists)" = "true"
assert "examples subfolders: sorted, relative, with trailing slash and comma" \
  test "$(get_output examples-subfolders)" = "examples/basic/,examples/complete/,"

# Both missing, examples/ present: both injected and staged
setup
mkdir -p "${WS}/examples/basic"
run_step inject_config_files
assert "both missing: both configs staged" \
  test "$(staged | sort | tr '\n' ' ')" = ".terraform-docs.yml examples/.terraform-docs.yml "

# examples/ with files but no subfolders, and a hidden folder: an empty list
setup
mkdir -p "${WS}/examples/.hidden"
echo "x" >"${WS}/examples/notes.md"
run_step inject_config_files
assert "no example subfolders: step succeeds" test "${LAST_EXIT}" -eq 0
assert "no example subfolders: examples-subfolders is empty" \
  bash -c "grep -qx 'examples-subfolders=' '${GITHUB_OUTPUT}'"

# A folder name with a space survives the list
setup
mkdir -p "${WS}/examples/with space"
run_step inject_config_files
assert "example subfolder with a space is listed as is" \
  test "$(get_output examples-subfolders)" = "examples/with space/,"

# Outside a git repository the staging fails the step
setup
rm -rf "${WS}/.git"
export GIT_CEILING_DIRECTORIES="${_test_root}"
run_step inject_config_files
unset GIT_CEILING_DIRECTORIES
assert "not a git repository: step fails" test "${LAST_EXIT}" -ne 0

# --------------------------------------------------------------------------
# validate-root-readme
# --------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}         VALIDATE ROOT README TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# No README: nothing to do, terraform-docs creates it
setup
export input_readme_file_path="."
run_step validate_root_readme
assert "missing README: step succeeds" test "${LAST_EXIT}" -eq 0
assert "missing README: README is not created" test ! -e "${WS}/README.md"

# README without delimiters: they are appended after a note
setup
export input_readme_file_path="."
printf '# My module\n' >"${WS}/README.md"
run_step validate_root_readme
assert "no delimiters: step succeeds" test "${LAST_EXIT}" -eq 0
assert "no delimiters: delimiters appended after the note" \
  cmp -s "${WS}/README.md" <(printf '# My module\n\nBelow is a placeholder for Terraform-docs generated documentation. Do not edit between the delimiters.\n<!-- BEGIN_TF_DOCS -->\n \n<!-- END_TF_DOCS -->\n')

# README with only one delimiter: both are appended, as before
setup
export input_readme_file_path="."
printf '# My module\n<!-- BEGIN_TF_DOCS -->\n' >"${WS}/README.md"
run_step validate_root_readme
assert "one delimiter: step succeeds" test "${LAST_EXIT}" -eq 0
assert "one delimiter: an END delimiter is appended" \
  grep -qF '<!-- END_TF_DOCS -->' "${WS}/README.md"

# README with delimiters in the right order: left as is
setup
export input_readme_file_path="."
printf '# My module\n<!-- BEGIN_TF_DOCS -->\ndocs\n<!-- END_TF_DOCS -->\n' >"${WS}/README.md"
cp "${WS}/README.md" "${_test_root}/readme.orig"
run_step validate_root_readme
assert "correct delimiters: step succeeds" test "${LAST_EXIT}" -eq 0
assert "correct delimiters: README unchanged" cmp -s "${_test_root}/readme.orig" "${WS}/README.md"

# README with delimiters in the wrong order: the step fails, README untouched
setup
export input_readme_file_path="."
printf '<!-- END_TF_DOCS -->\ndocs\n<!-- BEGIN_TF_DOCS -->\n' >"${WS}/README.md"
cp "${WS}/README.md" "${_test_root}/readme.orig"
run_step validate_root_readme
assert "wrong order: step fails" test "${LAST_EXIT}" -eq 1
assert "wrong order: error names the order" grep -q "not in the correct order" "${_test_output}"
assert "wrong order: README unchanged" cmp -s "${_test_root}/readme.orig" "${WS}/README.md"

# A delimiter twice: the step fails
setup
export input_readme_file_path="."
printf '<!-- BEGIN_TF_DOCS -->\n<!-- END_TF_DOCS -->\n<!-- BEGIN_TF_DOCS -->\n<!-- END_TF_DOCS -->\n' >"${WS}/README.md"
run_step validate_root_readme
assert "duplicate delimiters: step fails" test "${LAST_EXIT}" -eq 1
assert "duplicate delimiters: error names the duplicate" grep -q "more than once" "${_test_output}"

# README in a subdirectory
setup
mkdir -p "${WS}/modules/sub"
export input_readme_file_path="modules/sub"
printf '# Sub\n' >"${WS}/modules/sub/README.md"
run_step validate_root_readme
assert "subdirectory README: delimiters appended there" \
  grep -qF '<!-- BEGIN_TF_DOCS -->' "${WS}/modules/sub/README.md"

# --------------------------------------------------------------------------
# report
# --------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}                REPORT TESTS                ${NC}"
echo -e "${YELLOW}============================================${NC}"

# Set the report step's inputs.
#   $1 validate outcome, $2 examples outcome, $3 examples num_changed,
#   $4 project outcome, $5 project num_changed
report_inputs() {
  export input_validate_outcome="${1}"
  export input_examples_outcome="${2}"
  export input_examples_num_changed="${3}"
  export input_project_outcome="${4}"
  export input_project_num_changed="${5}"
}

setup
report_inputs success success 2 success 1
run_step report
assert "both steps changed files: exit 0" test "${LAST_EXIT}" -eq 0
assert "both steps changed files: total is the sum" test "$(get_output number-of-files-changed)" = "3"

setup
report_inputs success skipped "" success 0
run_step report
assert "no examples, nothing changed: total 0" test "$(get_output number-of-files-changed)" = "0"

setup
report_inputs success success "" success ""
run_step report
assert "empty num_changed on success: exit 0" test "${LAST_EXIT}" -eq 0
assert "empty num_changed on success: counts as 0" test "$(get_output number-of-files-changed)" = "0"

setup
report_inputs success success "abc" success 1
run_step report
assert "non-numeric num_changed: counts as 0" test "$(get_output number-of-files-changed)" = "1"
assert "non-numeric num_changed: warns" grep -q "is not a number" "${_test_output}"

setup
report_inputs success success 08 success 1
run_step report
assert "leading zero num_changed: read as decimal" test "$(get_output number-of-files-changed)" = "9"

setup
report_inputs success failure 3 success 1
run_step report
assert "a failed step's num_changed is not counted" test "$(get_output number-of-files-changed)" = "1"

setup
report_inputs failure success 2 skipped ""
run_step report
assert "README validation failed: exit 1" test "${LAST_EXIT}" -eq 1
assert "README validation failed: total still reported" test "$(get_output number-of-files-changed)" = "2"

setup
report_inputs cancelled skipped "" skipped ""
run_step report
assert "README validation cancelled: exit 1" test "${LAST_EXIT}" -eq 1

setup
report_inputs "" "" "" "" ""
run_step report
assert "all inputs empty: exit 0" test "${LAST_EXIT}" -eq 0
assert "all inputs empty: total 0" test "$(get_output number-of-files-changed)" = "0"

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
