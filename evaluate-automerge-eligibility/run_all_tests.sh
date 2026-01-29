#!/bin/env bash
#
# Comprehensive test runner for step_evaluate.sh
# Tests all scenarios from LOGIC_PLANNING.md plus additional edge cases
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# Function to run a single test
run_test() {
  local test_name="${1}"
  local expected_eligible="${2}"
  # All other variables should be set before calling this function

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Set up GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)

  # Required system variables
  export GITHUB_ACTION_PATH="${_this_script_dir}"

  # Run the step_evaluate.sh script in a subshell with all exports
  (
    set -o allexport
    bash "${_this_script_dir}/step_evaluate.sh"
  ) > /tmp/test_output.txt 2>&1

  # Check the result
  local actual_eligible
  actual_eligible=$(grep "^is-eligible=" "${GITHUB_OUTPUT}" | cut -d= -f2)

  if [[ "${actual_eligible}" == "${expected_eligible}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: Expected is-eligible=${expected_eligible}, got ${actual_eligible}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: Expected is-eligible=${expected_eligible}, got ${actual_eligible}"
    echo ""
    echo "Test output:"
    cat /tmp/test_output.txt
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
}

# Function to reset all variables to defaults
reset_defaults() {
  export GITHUB_ACTOR="dependabot[bot]"

  export input_environment_name="test-env"
  export input_plan_shouldve_been_created="true"
  export input_plan_was_created="true"
  export input_performing_apply_on_pr="false"
  export input_apply_on_pr_succeeded="false"
  export input_plan_count_add="0"
  export input_plan_count_change="0"
  export input_plan_count_destroy="0"
  export input_plan_count_import="0"
  export input_plan_count_move="0"
  export input_plan_count_remove="0"

  export input_destroy_plan_shouldve_been_created="false"
  export input_destroy_plan_was_created="false"
  export input_performing_destroy_on_pr="false"
  export input_destroy_on_pr_succeeded="false"
  export input_destroy_plan_count_add="0"
  export input_destroy_plan_count_change="0"
  export input_destroy_plan_count_destroy="0"
  export input_destroy_plan_count_import="0"
  export input_destroy_plan_count_move="0"
  export input_destroy_plan_count_remove="0"

  # Default limits - all unlimited
  export input_pr_auto_merge_limits_json='{
    "plan-max-count-add": -1,
    "plan-max-count-change": -1,
    "plan-max-count-destroy": -1,
    "plan-max-count-import": -1,
    "plan-max-count-move": -1,
    "plan-max-count-remove": -1
  }'

  # Default - all actors allowed
  export input_pr_auto_merge_from_actors_json='[]'
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}  AUTOMERGE ELIGIBILITY EVALUATION TESTS   ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ============================================================================
# Test 1: All limits ignored (apply-on-pr + destroy-on-pr)
# ============================================================================
reset_defaults
input_performing_apply_on_pr="true"
input_apply_on_pr_succeeded="true"
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="true"
input_destroy_on_pr_succeeded="true"
# Set some counts that would normally fail limits
input_plan_count_add="100"
input_destroy_plan_count_destroy="100"
# Set restrictive limits
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 0,
  "plan-max-count-change": 0,
  "plan-max-count-destroy": 0,
  "plan-max-count-import": 0,
  "plan-max-count-move": 0,
  "plan-max-count-remove": 0
}'
run_test "All limits ignored (apply-on-pr + destroy-on-pr)" "true"

# ============================================================================
# Test 2: Only plan limits evaluated
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="true"
input_plan_was_created="true"
input_performing_apply_on_pr="false"
input_destroy_plan_shouldve_been_created="false"
input_plan_count_change="5"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": 10,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Only plan limits evaluated - within limit" "true"

# ============================================================================
# Test 3: Only destroy plan limits evaluated
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="false"
input_plan_was_created="false"
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="false"
input_destroy_plan_count_destroy="5"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": 10,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Only destroy plan limits evaluated - within limit" "true"

# ============================================================================
# Test 4: Both plan limits evaluated (aggregated counts)
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="true"
input_plan_was_created="true"
input_performing_apply_on_pr="false"
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="false"
# Each plan has 5, total = 10, limit = 10 (should pass at exactly limit)
input_plan_count_change="5"
input_destroy_plan_count_change="5"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": 10,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Both plan limits evaluated (aggregated counts at exactly limit)" "true"

# ============================================================================
# Test 5: Actor not in allowed list
# ============================================================================
reset_defaults
GITHUB_ACTOR="unknown-actor"
input_pr_auto_merge_from_actors_json='["dependabot[bot]", "renovate[bot]"]'
run_test "Actor not in allowed list" "false"

# ============================================================================
# Test 6: Plan creation failed
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="true"
input_plan_was_created="false"
run_test "Plan creation failed" "false"

# ============================================================================
# Test 7: Count exceeds single limit
# ============================================================================
reset_defaults
input_plan_count_add="5"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 3,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Count exceeds single limit" "false"

# ============================================================================
# Test 8: Counts exceed multiple limits
# ============================================================================
reset_defaults
input_plan_count_add="5"
input_plan_count_change="10"
input_plan_count_destroy="3"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 3,
  "plan-max-count-change": 5,
  "plan-max-count-destroy": 2,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Counts exceed multiple limits" "false"

# ============================================================================
# Test 9: All counts at exactly the limit
# ============================================================================
reset_defaults
input_plan_count_add="5"
input_plan_count_change="10"
input_plan_count_destroy="3"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 5,
  "plan-max-count-change": 10,
  "plan-max-count-destroy": 3,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "All counts at exactly the limit" "true"

# ============================================================================
# Test 10: All counts below limits
# ============================================================================
reset_defaults
input_plan_count_add="2"
input_plan_count_change="5"
input_plan_count_destroy="1"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 5,
  "plan-max-count-change": 10,
  "plan-max-count-destroy": 3,
  "plan-max-count-import": 10,
  "plan-max-count-move": 10,
  "plan-max-count-remove": 10
}'
run_test "All counts below limits" "true"

# ============================================================================
# Test 11: Mixed limits (some -1, some specific values)
# ============================================================================
reset_defaults
input_plan_count_add="1000"  # unlimited
input_plan_count_change="5"   # within limit
input_plan_count_destroy="0"  # within limit
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": 10,
  "plan-max-count-destroy": 5,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Mixed limits (some -1, some specific values) - pass" "true"

# ============================================================================
# Test 12: Zero changes
# ============================================================================
reset_defaults
input_plan_count_add="0"
input_plan_count_change="0"
input_plan_count_destroy="0"
input_plan_count_import="0"
input_plan_count_move="0"
input_plan_count_remove="0"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 0,
  "plan-max-count-change": 0,
  "plan-max-count-destroy": 0,
  "plan-max-count-import": 0,
  "plan-max-count-move": 0,
  "plan-max-count-remove": 0
}'
run_test "Zero changes" "true"

# ============================================================================
# Test 13: Missing counts when needed
# ============================================================================
reset_defaults
input_plan_count_add=""  # Empty - should fail validation
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 5,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Missing counts when needed" "false"

# ============================================================================
# Test 14: Missing counts when not needed
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="false"
input_plan_was_created="false"
input_destroy_plan_shouldve_been_created="false"
input_destroy_plan_was_created="false"
# Counts are empty but limits are ignored
input_plan_count_add=""
input_plan_count_change=""
run_test "Missing counts when not needed" "true"

# ============================================================================
# Test 15: Invalid configuration (empty limits)
# ============================================================================
reset_defaults
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": "",
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
# Note: This test expects the script to ERROR (exit 1), not just return is-eligible=false
# We need to handle this differently
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST $((TESTS_RUN + 1)): Invalid configuration (empty limits)${NC}"
echo -e "${BLUE}========================================${NC}"
TESTS_RUN=$((TESTS_RUN + 1))

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
(
  set -o allexport
  bash "${_this_script_dir}/step_evaluate.sh"
) > /tmp/test_output.txt 2>&1
exit_code=$?

if [[ ${exit_code} -ne 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: Script exited with error code ${exit_code} for invalid config"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: Script should have exited with error for invalid config"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -f "${GITHUB_OUTPUT}"

# ============================================================================
# Additional Test 16: Destroy plan creation failed
# ============================================================================
reset_defaults
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="false"
run_test "Destroy plan creation failed" "false"

# ============================================================================
# Additional Test 17: Apply on PR failed
# ============================================================================
reset_defaults
input_performing_apply_on_pr="true"
input_apply_on_pr_succeeded="false"
run_test "Apply on PR failed" "false"

# ============================================================================
# Additional Test 18: Destroy on PR failed
# ============================================================================
reset_defaults
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="true"
input_destroy_on_pr_succeeded="false"
run_test "Destroy on PR failed" "false"

# ============================================================================
# Additional Test 19: Actor in allowed list (case-sensitive match)
# ============================================================================
reset_defaults
GITHUB_ACTOR="renovate[bot]"
input_pr_auto_merge_from_actors_json='["dependabot[bot]", "renovate[bot]"]'
run_test "Actor in allowed list (case-sensitive match)" "true"

# ============================================================================
# Additional Test 20: Empty actor list (all actors allowed)
# ============================================================================
reset_defaults
GITHUB_ACTOR="any-random-actor"
input_pr_auto_merge_from_actors_json='[]'
run_test "Empty actor list (all actors allowed)" "true"

# ============================================================================
# Additional Test 21: Plan limits ignored when performing apply-on-pr
# ============================================================================
reset_defaults
input_performing_apply_on_pr="true"
input_apply_on_pr_succeeded="true"
input_plan_count_add="1000"  # Would exceed limit if checked
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 0,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Plan limits ignored when performing apply-on-pr" "true"

# ============================================================================
# Additional Test 22: Destroy plan limits ignored when performing destroy-on-pr
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="false"
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="true"
input_destroy_on_pr_succeeded="true"
input_destroy_plan_count_destroy="1000"  # Would exceed limit if checked
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": 0,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Destroy plan limits ignored when performing destroy-on-pr" "true"

# ============================================================================
# Additional Test 23: Aggregated counts exceed limit (both plans)
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="true"
input_plan_was_created="true"
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
# Each has 5, total = 10, limit = 9 (should fail)
input_plan_count_change="5"
input_destroy_plan_count_change="5"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": 9,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Aggregated counts exceed limit (both plans)" "false"

# ============================================================================
# Additional Test 24: Invalid configuration (null limit)
# ============================================================================
reset_defaults
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": null,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST $((TESTS_RUN + 1)): Invalid configuration (null limit)${NC}"
echo -e "${BLUE}========================================${NC}"
TESTS_RUN=$((TESTS_RUN + 1))

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
(
  set -o allexport
  source "${_this_script_dir}/step_evaluate.sh"
  exit_code=$?
  set +o allexport
  exit ${exit_code}
) > /tmp/test_output.txt 2>&1
exit_code=$?

if [[ ${exit_code} -ne 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: Script exited with error code ${exit_code} for null config"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: Script should have exited with error for null config"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -f "${GITHUB_OUTPUT}"

# ============================================================================
# Additional Test 25: Invalid configuration (non-numeric limit)
# ============================================================================
reset_defaults
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": "abc",
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST $((TESTS_RUN + 1)): Invalid configuration (non-numeric limit)${NC}"
echo -e "${BLUE}========================================${NC}"
TESTS_RUN=$((TESTS_RUN + 1))

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
(
  set -o allexport
  source "${_this_script_dir}/step_evaluate.sh"
  exit_code=$?
  set +o allexport
  exit ${exit_code}
) > /tmp/test_output.txt 2>&1
exit_code=$?

if [[ ${exit_code} -ne 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: Script exited with error code ${exit_code} for non-numeric config"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: Script should have exited with error for non-numeric config"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -f "${GITHUB_OUTPUT}"

# ============================================================================
# Additional Test 26: Limit of zero - count is zero (edge case)
# ============================================================================
reset_defaults
input_plan_count_add="0"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 0,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Limit of zero - count is zero (edge case)" "true"

# ============================================================================
# Additional Test 27: Limit of zero - count is one (should fail)
# ============================================================================
reset_defaults
input_plan_count_add="1"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 0,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Limit of zero - count is one (should fail)" "false"

# ============================================================================
# Additional Test 28: No plans required - eligible by default
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="false"
input_plan_was_created="false"
input_destroy_plan_shouldve_been_created="false"
input_destroy_plan_was_created="false"
run_test "No plans required - eligible by default" "true"

# ============================================================================
# Additional Test 29: Actor with special characters (dependabot[bot])
# ============================================================================
reset_defaults
GITHUB_ACTOR="dependabot[bot]"
input_pr_auto_merge_from_actors_json='["dependabot[bot]", "renovate[bot]"]'
run_test "Actor with special characters (dependabot[bot])" "true"

# ============================================================================
# Additional Test 30: Multiple failure reasons collected
# ============================================================================
reset_defaults
GITHUB_ACTOR="unknown-actor"
input_pr_auto_merge_from_actors_json='["dependabot[bot]"]'
input_plan_count_add="10"
input_plan_count_destroy="5"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 5,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": 2,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Multiple failure reasons collected" "false"

# ============================================================================
# Additional Test 31: Actor case sensitivity - wrong case should fail
# ============================================================================
reset_defaults
GITHUB_ACTOR="Renovate[bot]"  # proper case vs "renovate[bot]" in list
input_pr_auto_merge_from_actors_json='["dependabot[bot]", "renovate[bot]"]'
run_test "Actor case sensitivity - wrong case should fail" "false"

# ============================================================================
# Additional Test 32: Missing limit field in configuration
# ============================================================================
reset_defaults
input_pr_auto_merge_limits_json='{
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
# Note: plan-max-count-add is missing entirely - should ERROR
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST $((TESTS_RUN + 1)): Missing limit field in configuration${NC}"
echo -e "${BLUE}========================================${NC}"
TESTS_RUN=$((TESTS_RUN + 1))

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
(
  set -o allexport
  source "${_this_script_dir}/step_evaluate.sh"
  exit_code=$?
  set +o allexport
  exit ${exit_code}
) > /tmp/test_output.txt 2>&1
exit_code=$?

if [[ ${exit_code} -ne 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: Script exited with error code ${exit_code} for missing limit field"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: Script should have exited with error for missing limit field"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -f "${GITHUB_OUTPUT}"

# ============================================================================
# Additional Test 33: Destroy plan counts missing when destroy limits evaluated
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="false"
input_plan_was_created="false"
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="false"
input_destroy_plan_count_destroy=""  # Empty - should fail validation
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": 10,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Destroy plan counts missing when destroy limits evaluated" "false"

# ============================================================================
# Additional Test 34: Both operations performed - apply succeeds, destroy fails
# ============================================================================
reset_defaults
input_performing_apply_on_pr="true"
input_apply_on_pr_succeeded="true"
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="true"
input_destroy_on_pr_succeeded="false"  # Destroy failed
run_test "Both operations performed - apply succeeds, destroy fails" "false"

# ============================================================================
# Additional Test 35: Both operations performed - apply fails, destroy succeeds
# ============================================================================
reset_defaults
input_performing_apply_on_pr="true"
input_apply_on_pr_succeeded="false"  # Apply failed
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="true"
input_destroy_on_pr_succeeded="true"
run_test "Both operations performed - apply fails, destroy succeeds" "false"

# ============================================================================
# Additional Test 36: Plan counts empty but limits ignored (apply-on-pr)
# ============================================================================
reset_defaults
input_performing_apply_on_pr="true"
input_apply_on_pr_succeeded="true"
input_plan_count_add=""  # Empty but should not matter
input_plan_count_change=""
input_plan_count_destroy=""
input_plan_count_import=""
input_plan_count_move=""
input_plan_count_remove=""
run_test "Plan counts empty but limits ignored (apply-on-pr)" "true"

# ============================================================================
# Additional Test 37: Only destroy plan required - exceeds limit
# ============================================================================
reset_defaults
input_plan_shouldve_been_created="false"
input_plan_was_created="false"
input_destroy_plan_shouldve_been_created="true"
input_destroy_plan_was_created="true"
input_performing_destroy_on_pr="false"
input_destroy_plan_count_destroy="15"  # Exceeds limit
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": 10,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Only destroy plan required - exceeds limit" "false"

# ============================================================================
# Additional Test 38: Large count values (boundary test)
# ============================================================================
reset_defaults
input_plan_count_add="999999999"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 1000000000,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Large count values (boundary test) - within limit" "true"

# ============================================================================
# Additional Test 39: Large count exceeds large limit
# ============================================================================
reset_defaults
input_plan_count_add="1000000001"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 1000000000,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Large count exceeds large limit" "false"

# ============================================================================
# Additional Test 40: All six count types evaluated
# ============================================================================
reset_defaults
input_plan_count_add="1"
input_plan_count_change="2"
input_plan_count_destroy="3"
input_plan_count_import="4"
input_plan_count_move="5"
input_plan_count_remove="6"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": 1,
  "plan-max-count-change": 2,
  "plan-max-count-destroy": 3,
  "plan-max-count-import": 4,
  "plan-max-count-move": 5,
  "plan-max-count-remove": 6
}'
run_test "All six count types evaluated at exact limits" "true"

# ============================================================================
# Additional Test 41: Import count exceeds limit
# ============================================================================
reset_defaults
input_plan_count_import="10"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": 5,
  "plan-max-count-move": -1,
  "plan-max-count-remove": -1
}'
run_test "Import count exceeds limit" "false"

# ============================================================================
# Additional Test 42: Move count exceeds limit
# ============================================================================
reset_defaults
input_plan_count_move="10"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": 5,
  "plan-max-count-remove": -1
}'
run_test "Move count exceeds limit" "false"

# ============================================================================
# Additional Test 43: Remove count exceeds limit
# ============================================================================
reset_defaults
input_plan_count_remove="10"
input_pr_auto_merge_limits_json='{
  "plan-max-count-add": -1,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": -1,
  "plan-max-count-import": -1,
  "plan-max-count-move": -1,
  "plan-max-count-remove": 5
}'
run_test "Remove count exceeds limit" "false"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}                 SUMMARY                    ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -eq 0 ]]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
fi
