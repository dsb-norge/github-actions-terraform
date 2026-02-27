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
# Usage: run_test <test_name> <expected_imports> <expected_adds> <expected_changes> <expected_destroys> <expected_moves> <expected_removes>
run_test() {
  local test_name="${1}"
  local expected_imports="${2}"
  local expected_adds="${3}"
  local expected_changes="${4}"
  local expected_destroys="${5}"
  local expected_moves="${6}"
  local expected_removes="${7}"

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
  local actual_imports actual_adds actual_changes actual_destroys actual_moves actual_removes
  actual_imports=$(get_output "import-count")
  actual_adds=$(get_output "add-count")
  actual_changes=$(get_output "change-count")
  actual_destroys=$(get_output "destroy-count")
  actual_moves=$(get_output "move-count")
  actual_removes=$(get_output "remove-count")

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

# Test 5: Empty input (no file specified)
export input_plan_console_file=""
#                   imports adds changes destroys moves removes
run_test "Empty input file path yields fallback values" \
  "?" "?" "?" "?" "?" "?"

# Test 6: Non-existent file (empty file = file exists but is empty)
_empty_file=$(mktemp)
export input_plan_console_file="${_empty_file}"
#                   imports adds changes destroys moves removes
run_test "Empty file yields fallback values" \
  "?" "?" "?" "?" "?" "?"
rm -f "${_empty_file}"

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
