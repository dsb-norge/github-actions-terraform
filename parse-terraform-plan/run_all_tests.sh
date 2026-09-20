#!/bin/env bash
#
# Test runner for step_parse_plan_output.sh
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

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

# Helper to get an output value from GITHUB_OUTPUT
get_output() {
  local key="${1}"
  grep "^${key}=" "${GITHUB_OUTPUT}" | cut -d= -f2-
}

# Generic test runner function
# Usage: run_test <test_name> <imports> <adds> <changes> <destroys> <moves> <removes> [<expected_has_output_only_changes>]
# 8th argument defaults to "false" — most plans aren't output-only.
run_test() {
  local test_name="${1}"
  local expected_imports="${2}"
  local expected_adds="${3}"
  local expected_changes="${4}"
  local expected_destroys="${5}"
  local expected_moves="${6}"
  local expected_removes="${7}"
  local expected_has_output_only_changes="${8:-false}"

  TESTS_RUN=$((TESTS_RUN + 1))

  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"

  # Set up fresh GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${_this_script_dir}"

  # Run step in a subshell
  local exit_code
  (
    set -o allexport
    source "${_this_script_dir}/step_parse_plan_output.sh"
  ) > /tmp/test_output.txt 2>&1
  exit_code=$?

  # Assertions
  local actual_imports actual_adds actual_changes actual_destroys actual_moves actual_removes actual_total
  actual_imports=$(get_output "import-count")
  actual_adds=$(get_output "add-count")
  actual_changes=$(get_output "change-count")
  actual_destroys=$(get_output "destroy-count")
  actual_moves=$(get_output "move-count")
  actual_removes=$(get_output "remove-count")
  actual_total=$(get_output "total-count")
  local actual_has_output_only_changes
  actual_has_output_only_changes=$(get_output "has-output-only-changes")
  # Expected total derived from the per-category expectations so existing
  # run_test callers don't need to pass it explicitly. When any expectation
  # is the parse-failed sentinel '?', expected_total is also '?'.
  local expected_total='?'
  if [[ "${expected_imports}${expected_adds}${expected_changes}${expected_destroys}${expected_moves}${expected_removes}" =~ ^[0-9]+$ ]]; then
    expected_total=$((expected_imports + expected_adds + expected_changes + expected_destroys + expected_moves + expected_removes))
  fi

  local failed=0
  local failures=""

  if [[ "${exit_code}" -ne 0 ]]; then
    failed=1
    failures+="  exit code: expected 0, got ${exit_code}\n"
  fi
  if [[ "${actual_imports}" != "${expected_imports}" ]]; then
    failed=1
    failures+="  import-count: expected '${expected_imports}', got '${actual_imports}'\n"
  fi
  if [[ "${actual_adds}" != "${expected_adds}" ]]; then
    failed=1
    failures+="  add-count: expected '${expected_adds}', got '${actual_adds}'\n"
  fi
  if [[ "${actual_changes}" != "${expected_changes}" ]]; then
    failed=1
    failures+="  change-count: expected '${expected_changes}', got '${actual_changes}'\n"
  fi
  if [[ "${actual_destroys}" != "${expected_destroys}" ]]; then
    failed=1
    failures+="  destroy-count: expected '${expected_destroys}', got '${actual_destroys}'\n"
  fi
  if [[ "${actual_moves}" != "${expected_moves}" ]]; then
    failed=1
    failures+="  move-count: expected '${expected_moves}', got '${actual_moves}'\n"
  fi
  if [[ "${actual_removes}" != "${expected_removes}" ]]; then
    failed=1
    failures+="  remove-count: expected '${expected_removes}', got '${actual_removes}'\n"
  fi
  if [[ "${actual_total}" != "${expected_total}" ]]; then
    failed=1
    failures+="  total-count: expected '${expected_total}' (sum of categories), got '${actual_total}'\n"
  fi
  if [[ "${actual_has_output_only_changes}" != "${expected_has_output_only_changes}" ]]; then
    failed=1
    failures+="  has-output-only-changes: expected '${expected_has_output_only_changes}', got '${actual_has_output_only_changes}'\n"
  fi

  if [[ ${failed} -eq 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}:"
    echo -e "${failures}"
    echo "--- Step output ---"
    cat /tmp/test_output.txt
    echo "--- End step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
}

# --------------------------------------------------
# Test cases using test-data files
# --------------------------------------------------

# Test 1: No changes plan
export input_plan_console_file="${_this_script_dir}/test-data/plan_0_changes.log"
#                   imports adds changes destroys moves removes
run_test "No changes plan" \
  "0" "0" "0" "0" "0" "0"

# Test 2: Plan with adds, changes, and removed resources (not destroyed)
export input_plan_console_file="${_this_script_dir}/test-data/plan_14_add_21_change_0_destroy_14_removed_and_not_destroyed.log"
#                   imports adds changes destroys moves removes
run_test "14 add, 21 change, 0 destroy, 14 removed" \
  "0" "14" "21" "0" "0" "14"

# Test 3: Plan with adds, changes, destroys, and moves
export input_plan_console_file="${_this_script_dir}/test-data/plan_1_add_1_change_5_destroy_2_move.log"
#                   imports adds changes destroys moves removes
run_test "1 add, 1 change, 5 destroy, 2 move" \
  "0" "1" "1" "5" "2" "0"

# Test 4: Plan with only changes
export input_plan_console_file="${_this_script_dir}/test-data/plan_1_change.log"
#                   imports adds changes destroys moves removes
run_test "0 add, 1 change, 0 destroy" \
  "0" "0" "1" "0" "0" "0"

# Test 5: Output-only changes (no resource changes)
# Resource counts are all 0 BUT has-output-only-changes flips to 'true' so
# consumers can render the plan extract instead of short-circuiting to
# "no changes" (the changes-to-outputs section lives inside the extract).
export input_plan_console_file="${_this_script_dir}/test-data/plan_output_only_changes.log"
#                   imports adds changes destroys moves removes  has-output-only-changes
run_test "Output-only changes (no resource changes)" \
  "0" "0" "0" "0" "0" "0" "true"

# Test 6: Output-only changes in a plan that also defers a data source read.
# Regression guard. Terraform prints "…without changing any real infrastructure."
# only for a plan with no resource actions at all. A deferred data read
# ("# data.x.y will be read during apply") counts as an action, so Terraform
# instead emits the normal action list plus "Plan: 0 to add, 0 to change,
# 0 to destroy." and no such sentence — while outputs are still the only thing
# that changes. Detection therefore keys off the "Changes to Outputs:" header,
# not the sentence; keying off the sentence rendered these plans as
# "Plan: no changes ✅" with the output diff hidden.
export input_plan_console_file="${_this_script_dir}/test-data/plan_output_only_changes_with_data_read.log"
#                   imports adds changes destroys moves removes  has-output-only-changes
run_test "Output-only changes alongside a deferred data source read" \
  "0" "0" "0" "0" "0" "0" "true"

# Test 7: Deferred data source read, no output changes.
# Same "Plan: 0 to add, 0 to change, 0 to destroy." shape as test 6 but with no
# "Changes to Outputs:" section, so the flag must stay false and consumers keep
# rendering "no changes" — a data read changes nothing.
#
# The fixture also carries the literal words "Changes to Outputs:" indented
# inside a heredoc attribute value. That guards the anchor in the detection
# grep: Terraform always prints the real header unindented, so an unanchored
# match would report output-only changes for a plan that has none.
export input_plan_console_file="${_this_script_dir}/test-data/plan_0_changes_with_data_read.log"
#                   imports adds changes destroys moves removes  has-output-only-changes
run_test "Deferred data source read without output changes" \
  "0" "0" "0" "0" "0" "0" "false"

# Test 8: Resource changes *and* output changes.
# The flag is gated on every resource count being zero, so a plan that touches
# both must not claim to be output-only — it already renders its extract on the
# strength of a non-zero total, under the "N changes" summary rather than the
# "output-only changes" one.
export input_plan_console_file="${_this_script_dir}/test-data/plan_1_change_with_output_changes.log"
#                   imports adds changes destroys moves removes  has-output-only-changes
run_test "Resource changes alongside output changes are not output-only" \
  "0" "0" "1" "0" "0" "0" "false"

# Test 9: Empty input (no file specified)
export input_plan_console_file=""
#                   imports adds changes destroys moves removes
run_test "Empty input file path yields fallback values" \
  "?" "?" "?" "?" "?" "?"

# Test 10: Non-existent file (empty file = file exists but is empty)
_empty_file=$(mktemp)
export input_plan_console_file="${_empty_file}"
#                   imports adds changes destroys moves removes
run_test "Empty file yields fallback values" \
  "?" "?" "?" "?" "?" "?"
rm -f "${_empty_file}"

# --------------------------------------------------
# R1–R15: real console output, captured by contract-tests/run.sh from the
# scenarios under contract-tests/scenarios/ (provenance and terraform version
# in test-data/README.md). One fixture per plan shape; the contract tests
# prove these are still what terraform prints. Wording found on capture:
#   - imports are a segment of the "Plan:" line, FIRST: "Plan: 1 to import, 1 to add, …"
#   - moves and removals have NO segment on the "Plan:" line; they are counted
#     from "has moved to" / "will no longer be managed by Terraform"
#   - an output-only plan has no "Plan:" line at all
#   - a -refresh-only plan with nothing drifted says "No changes. Your
#     infrastructure still matches the configuration."
# --------------------------------------------------
#                                                       imports adds changes destroys moves removes [output-only]
export input_plan_console_file="${_this_script_dir}/test-data/plan_adds_only.log"
run_test "R1: adds only"                                  "0" "2" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_change_in_place.log"
run_test "R2: change in place, plus an output change → not output-only" \
                                                          "0" "0" "1" "0" "0" "0" "false"
export input_plan_console_file="${_this_script_dir}/test-data/plan_replace.log"
run_test "R3: replace = 1 to add + 1 to destroy"          "0" "1" "0" "1" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_destroys_only.log"
run_test "R4: destroys only"                              "0" "0" "0" "1" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_import_block.log"
run_test "R5: import block — 'N to import' leads the Plan line" \
                                                          "1" "1" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_moved_block.log"
run_test "R6: moved block — counted from 'has moved to'"  "0" "0" "0" "0" "1" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_removed_block_forget.log"
run_test "R7: removed block (forget) — counted from 'will no longer be managed'" \
                                                          "0" "0" "0" "0" "0" "1"
export input_plan_console_file="${_this_script_dir}/test-data/plan_no_changes.log"
run_test "R8: no changes"                                 "0" "0" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_outputs_only.log"
run_test "R9: outputs only — no Plan line, output-only flag" \
                                                          "0" "0" "0" "0" "0" "0" "true"
export input_plan_console_file="${_this_script_dir}/test-data/plan_refresh_only.log"
run_test "R10: -refresh-only with nothing drifted"        "0" "0" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_destroy_plan_applied.log"
run_test "R11: a -destroy plan"                           "0" "0" "0" "2" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_failed_provisioner.log"
run_test "R12: the plan of an apply that later fails is an ordinary plan" \
                                                          "0" "2" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_interrupted.log"
run_test "R13: the plan of an apply later interrupted"    "0" "1" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_check_warnings.log"
run_test "R14: a check-block warning after the Plan line" "0" "0" "1" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_progress_ticks.log"
run_test "R15: a slow create's plan"                      "0" "1" "0" "0" "0" "0"

# --------------------------------------------------
# H1: Terraform 1.14+ appends 'Actions: N to invoke.' to the 'Plan:' line
# (#37689). The per-segment regexes read 'N to add' / 'to change' / 'to
# destroy' one at a time, so the extra sentence is invisible to them — pinned
# so that stays true. The apply parser needed a fix for the same suffix on its
# summary line (P37). Hand-written: no built-in action type exists to capture
# from.
# --------------------------------------------------
export input_plan_console_file="${_this_script_dir}/test-data/plan_with_actions.log"
run_test "H1: 'Actions: 2 to invoke.' after the Plan line's counts" \
                                                          "0" "1" "0" "0" "0" "0"

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "========================================"
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "========================================"

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
