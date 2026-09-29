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
  unset input_push input_inject_outcome input_readme_file_path input_validate_outcome \
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

# Do what terraform-docs/gh-actions does after it writes a README: stage the whole working
# directory ('git add <dir>/'), then count the staged changes with its own pattern. Prints
# its num_changed.
upstream_num_changed() {
  git -C "${WS}" add ./
  git -C "${WS}" status --porcelain | grep -c -E '([MA]\W).+' || true
}

# Succeed when the checkout's info/exclude lists no terraform-docs config.
nothing_excluded() {
  ! exclude_file_content | grep -q 'terraform-docs'
}

# Print the checkout's info/exclude, empty when there is none.
exclude_file_content() {
  cat "$(git -C "${WS}" rev-parse --path-format=absolute --git-path info/exclude)" 2>/dev/null || true
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
export input_push="true"
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
export input_push="true"
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
export input_push="true"
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
export input_push="true"
mkdir -p "${WS}/examples/basic"
run_step inject_config_files
assert "both missing: both configs staged" \
  test "$(staged | sort | tr '\n' ' ')" = ".terraform-docs.yml examples/.terraform-docs.yml "

# examples/ with files but no subfolders, and a hidden folder: an empty list
setup
export input_push="true"
mkdir -p "${WS}/examples/.hidden"
echo "x" >"${WS}/examples/notes.md"
run_step inject_config_files
assert "no example subfolders: step succeeds" test "${LAST_EXIT}" -eq 0
assert "no example subfolders: examples-subfolders is empty" \
  bash -c "grep -qx 'examples-subfolders=' '${GITHUB_OUTPUT}'"

# A folder name with a space survives the list
setup
export input_push="true"
mkdir -p "${WS}/examples/with space"
run_step inject_config_files
assert "example subfolder with a space is listed as is" \
  test "$(get_output examples-subfolders)" = "examples/with space/,"

# Outside a git repository the staging fails the step
setup
export input_push="true"
rm -rf "${WS}/.git"
export GIT_CEILING_DIRECTORIES="${_test_root}"
run_step inject_config_files
unset GIT_CEILING_DIRECTORIES
assert "not a git repository: step fails" test "${LAST_EXIT}" -ne 0

# push false: injected configs stay in the working tree, excluded from git
setup
export input_push="false"
mkdir -p "${WS}/examples/basic"
run_step inject_config_files
assert "push false: step succeeds" test "${LAST_EXIT}" -eq 0
assert "push false: root config injected into the working tree" \
  cmp -s "${_this_script_dir}/terraform-docs-module-root.yml" "${WS}/.terraform-docs.yml"
assert "push false: examples config injected into the working tree" \
  cmp -s "${_this_script_dir}/terraform-docs-module-examples.yml" "${WS}/examples/.terraform-docs.yml"
assert "push false: nothing staged" test -z "$(staged)"
assert "push false: both configs listed in info/exclude" \
  test "$(exclude_file_content | grep -c -x -e '/.terraform-docs.yml' -e '/examples/.terraform-docs.yml')" = "2"
assert "push false: terraform-docs' 'git add <dir>/' does not count the injected configs" \
  test "$(upstream_num_changed)" = "0"
assert "push false: the configs do not show in git status" \
  test -z "$(git -C "${WS}" status --porcelain)"
assert "push false: examples subfolders still listed" \
  test "$(get_output examples-subfolders)" = "examples/basic/,"

# push false: a README change still counts, the injected config does not
setup
export input_push="false"
echo "# Module" >"${WS}/README.md"
git -C "${WS}" add README.md
git -C "${WS}" commit -q -m "initial"
run_step inject_config_files
echo "regenerated" >>"${WS}/README.md"
assert "push false: a changed README is the one change counted" \
  test "$(upstream_num_changed)" = "1"

# push false: the repository's own configs are left alone and not excluded
setup
export input_push="false"
mkdir -p "${WS}/examples/basic"
echo "own: root" >"${WS}/.terraform-docs.yml"
echo "own: examples" >"${WS}/examples/.terraform-docs.yml"
run_step inject_config_files
assert "push false, own configs: root config unchanged" \
  test "$(cat "${WS}/.terraform-docs.yml")" = "own: root"
assert "push false, own configs: nothing excluded" nothing_excluded

# push false in a linked worktree: the exclude lands where git reads it
setup
export input_push="false"
git -C "${WS}" commit -q --allow-empty -m "initial"
git -C "${WS}" worktree add -q "${WS}.linked" 2>/dev/null
export GITHUB_WORKSPACE="${WS}.linked"
_main_ws="${WS}"
WS="${WS}.linked"
run_step inject_config_files
assert "push false, linked worktree: step succeeds" test "${LAST_EXIT}" -eq 0
assert "push false, linked worktree: injected config not counted" \
  test "$(upstream_num_changed)" = "0"
git -C "${_main_ws}" worktree remove --force "${WS}" 2>/dev/null
unset _main_ws

# push must be 'true' or 'false': anything else fails before anything is injected
for _push in "" "yes" "TRUE"; do
  setup
  export input_push="${_push}"
  run_step inject_config_files
  assert "push '${_push}': step fails" test "${LAST_EXIT}" -eq 1
  assert "push '${_push}': error names the input" grep -q "Input 'push' must be" "${_test_output}"
  assert "push '${_push}': nothing injected" test ! -e "${WS}/.terraform-docs.yml"
done
unset _push

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
#   $1 push, $2 inject outcome, $3 validate outcome,
#   $4 examples outcome, $5 examples num_changed, $6 project outcome, $7 project num_changed
report_inputs() {
  export input_push="${1}"
  export input_inject_outcome="${2}"
  export input_validate_outcome="${3}"
  export input_examples_outcome="${4}"
  export input_examples_num_changed="${5}"
  export input_project_outcome="${6}"
  export input_project_num_changed="${7}"
}

# Run the report step and assert everything it publishes.
#   $1 test name, $2 exit code, $3 status, $4 number-of-files-changed, $5 pushed,
#   $6 needs-regeneration, $7 the one step-summary line
check_report() {
  local name="${1}"
  run_step report
  assert "${name}: exit ${2}" test "${LAST_EXIT}" -eq "${2}"
  assert "${name}: status ${3}" test "$(get_output status)" = "${3}"
  assert "${name}: number-of-files-changed ${4}" test "$(get_output number-of-files-changed)" = "${4}"
  assert "${name}: pushed ${5}" test "$(get_output pushed)" = "${5}"
  assert "${name}: needs-regeneration ${6}" test "$(get_output needs-regeneration)" = "${6}"
  assert "${name}: step summary is the one line" \
    test "$(cat "${GITHUB_STEP_SUMMARY}")" = "${7}"
}

# --- push true ---

setup
report_inputs true success success success 2 success 1
check_report "push true, both steps changed files" 0 pushed 3 true false \
  "📝 Docs: regenerated and pushed (3 files)"

setup
report_inputs true success success skipped "" success 1
check_report "push true, one file" 0 pushed 1 true false \
  "📝 Docs: regenerated and pushed (1 file)"

setup
report_inputs true success success success 0 success 0
check_report "push true, nothing changed" 0 up-to-date 0 false false \
  "📝 Docs: up to date"

setup
report_inputs true success success success 2 failure 1
check_report "push true, examples pushed, module push failed" 1 failed 2 true false \
  "📝 Docs: failed (terraform-docs failed for the module)"
assert "push true, module push failed: error annotation" \
  grep -q "^::error title=terraform-docs failed::" "${_test_output}"

setup
report_inputs true success success failure 3 skipped ""
check_report "push true, a failed step's num_changed is not counted" 1 failed 0 false false \
  "📝 Docs: failed (terraform-docs failed for the examples)"

# --- push false ---

setup
report_inputs false success success success 0 success 0
check_report "push false, up to date" 0 up-to-date 0 false false \
  "📝 Docs: up to date"

setup
report_inputs false success success skipped "" success 0
check_report "push false, no examples, up to date" 0 up-to-date 0 false false \
  "📝 Docs: up to date"

setup
report_inputs false success success failure 2 skipped ""
check_report "push false, examples differ" 1 needs-regeneration 2 false true \
  "📝 Docs: README needs regenerating (2 files) — run terraform-docs, or push to a pull request where CI regenerates it"
assert "push false, examples differ: error annotation" \
  grep -q "^::error title=README needs regenerating::" "${_test_output}"

setup
report_inputs false success success success 0 failure 1
check_report "push false, module README differs" 1 needs-regeneration 1 false true \
  "📝 Docs: README needs regenerating (1 file) — run terraform-docs, or push to a pull request where CI regenerates it"

setup
report_inputs false success success success 1 success 0
check_report "push false, a diff on a successful step still needs regenerating" 1 needs-regeneration 1 false true \
  "📝 Docs: README needs regenerating (1 file) — run terraform-docs, or push to a pull request where CI regenerates it"

setup
report_inputs false success success success 0 failure ""
check_report "push false, terraform-docs failed without a count" 1 failed 0 false false \
  "📝 Docs: failed (terraform-docs failed for the module)"

setup
report_inputs false success success success 0 failure 0
check_report "push false, terraform-docs failed with zero changes" 1 failed 0 false false \
  "📝 Docs: failed (terraform-docs failed for the module)"

# --- the steps before terraform-docs ---

setup
report_inputs false success failure success 0 skipped ""
check_report "README delimiters invalid" 1 failed 0 false false \
  "📝 Docs: failed (README delimiters are invalid, see the log)"

setup
report_inputs false success failure failure 2 skipped ""
check_report "README delimiters invalid and examples differ" 1 failed 2 false true \
  "📝 Docs: failed (README delimiters are invalid, see the log)"

setup
report_inputs true success cancelled skipped "" skipped ""
check_report "README validation cancelled" 1 failed 0 false false \
  "📝 Docs: failed (README delimiters are invalid, see the log)"

setup
report_inputs true failure skipped skipped "" skipped ""
check_report "config injection failed" 1 failed 0 false false \
  "📝 Docs: failed (injecting the default terraform-docs config failed)"

setup
report_inputs true success success cancelled "" skipped ""
check_report "terraform-docs cancelled" 1 failed 0 false false \
  "📝 Docs: failed (terraform-docs was cancelled for the examples)"

setup
report_inputs true success failure failure "" skipped ""
check_report "two failures are both named" 1 failed 0 false false \
  "📝 Docs: failed (README delimiters are invalid, see the log; terraform-docs failed for the examples)"

setup
report_inputs yes failure skipped skipped "" skipped ""
check_report "push neither true nor false" 1 failed 0 false false \
  "📝 Docs: failed (input 'push' must be 'true' or 'false', got 'yes')"

setup
report_inputs "" "" "" "" "" "" ""
check_report "every input empty" 1 failed 0 false false \
  "📝 Docs: failed (input 'push' must be 'true' or 'false', got '')"

# --- num_changed arithmetic ---

setup
report_inputs true success success success "" success ""
check_report "empty num_changed on success counts as 0" 0 up-to-date 0 false false \
  "📝 Docs: up to date"

setup
report_inputs true success success success "abc" success 1
check_report "non-numeric num_changed counts as 0" 0 pushed 1 true false \
  "📝 Docs: regenerated and pushed (1 file)"
assert "non-numeric num_changed: warns" grep -q "is not a number" "${_test_output}"

setup
report_inputs true success success success 08 success 1
check_report "leading zero num_changed is read as decimal" 0 pushed 9 true false \
  "📝 Docs: regenerated and pushed (9 files)"

setup
report_inputs false success success failure " 2" skipped ""
check_report "padded num_changed on a failed step is not a diff" 1 failed 0 false false \
  "📝 Docs: failed (terraform-docs failed for the examples)"

# The summary is appended, not overwritten: earlier steps' lines survive
setup
echo "earlier line" >"${GITHUB_STEP_SUMMARY}"
report_inputs true success success success 0 success 0
run_step report
assert "step summary is appended to" \
  test "$(cat "${GITHUB_STEP_SUMMARY}")" = "earlier line
📝 Docs: up to date"

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
