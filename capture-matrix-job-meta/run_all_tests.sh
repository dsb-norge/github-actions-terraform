#!/bin/env bash
#
# Comprehensive test runner for step_capture.sh
# Tests various scenarios including edge cases and missing data handling
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
  local expected_field_check="${2}"  # jq expression to validate
  local expected_result="${3}"

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Set up GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)

  # Required system variables
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_RUN_ID="12345678"
  export GITHUB_RUN_NUMBER="42"
  export GITHUB_RUN_ATTEMPT="1"
  export GITHUB_WORKFLOW="Terraform CI/CD"
  export GITHUB_JOB="terraform-ci-cd"
  export GITHUB_ACTOR="test-user"
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_REF="refs/pull/123/merge"
  export GITHUB_SHA="abc123def456"

  # Run the step_capture.sh script in a subshell
  (
    set -o allexport
    source "${_this_script_dir}/step_capture.sh"
  ) > /tmp/test_output.txt 2>&1
  local exit_code=$?

  # Get the result file path
  local result_file
  result_file=$(grep "^result-json-file=" "${GITHUB_OUTPUT}" | cut -d= -f2)

  # Validate
  local actual_result=""
  if [[ -f "${result_file}" ]]; then
    actual_result=$(cat "${result_file}" | jq -r "${expected_field_check}" 2>/dev/null)
  fi

  if [[ "${exit_code}" -eq 0 && "${actual_result}" == "${expected_result}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: Exit code=${exit_code}, field check passed"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: Expected '${expected_result}', got '${actual_result}', exit code=${exit_code}"
    echo ""
    echo "Test output:"
    cat /tmp/test_output.txt
    if [[ -f "${result_file}" ]]; then
      echo ""
      echo "Result file:"
      cat "${result_file}" | jq '.'
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${RUNNER_TEMP}"
}

# Function to reset all variables to defaults
reset_defaults() {
  export input_environment_name="test-env"
  export input_matrix_context_json='{
    "environment": "test-env",
    "vars": {
      "github-environment": "test-env",
      "goals": ["all"]
    }
  }'
  export input_github_context_json='{"repository": "test/repo"}'
  export input_steps_context_json='{
    "init": {"outputs": {}, "outcome": "success", "conclusion": "success"},
    "fmt": {"outputs": {}, "outcome": "success", "conclusion": "success"},
    "validate": {"outputs": {}, "outcome": "success", "conclusion": "success"},
    "plan": {"outputs": {}, "outcome": "success", "conclusion": "success"}
  }'
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}     MATRIX JOB METADATA CAPTURE TESTS     ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ============================================================================
# Test 1: Basic capture with minimal inputs
# ============================================================================
reset_defaults
run_test "Basic capture with minimal inputs" '.metadata.environment' "test-env"

# ============================================================================
# Test 2: Capture with step outcomes
# ============================================================================
reset_defaults
export input_steps_context_json='{
  "init": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "plan": {"outputs": {}, "outcome": "failure", "conclusion": "failure"}
}'
run_test "Capture with step outcomes" '.steps["plan"].outcome' "failure"

# ============================================================================
# Test 3: Handle missing/empty JSON gracefully
# ============================================================================
reset_defaults
export input_matrix_context_json=""
run_test "Handle missing matrix context JSON" '.matrix_context' "{}"

# ============================================================================
# Test 4: Capture step outputs correctly
# ============================================================================
reset_defaults
export input_steps_context_json='{
  "parse-plan": {"outputs": {"count-add": "5", "count-change": "2"}, "outcome": "success", "conclusion": "success"}
}'
run_test "Capture step outputs" '.steps["parse-plan"].outputs["count-add"]' "5"

# ============================================================================
# Test 5: Filter sensitive data from matrix context
# ============================================================================
reset_defaults
export input_matrix_context_json='{
  "environment": "test",
  "vars": {
    "github-environment": "test",
    "secret-value": "should-be-removed",
    "password": "hidden"
  }
}'
run_test "Filter sensitive data from matrix context" '.matrix_context.vars | has("secret-value")' "false"

# ============================================================================
# Test 6: Schema version is set (updated to 2.0.0)
# ============================================================================
reset_defaults
run_test "Schema version is set" '.metadata.schema_version' "2.0.0"

# ============================================================================
# Test 7: Steps are captured dynamically
# ============================================================================
reset_defaults
export input_steps_context_json='{
  "step1": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step2": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step3": {"outputs": {}, "outcome": "success", "conclusion": "success"}
}'
run_test "Steps captured dynamically (count)" '.steps | keys | length' "3"

# ============================================================================
# Test 8: Handle empty steps context gracefully
# ============================================================================
reset_defaults
export input_steps_context_json='{}'
run_test "Handle empty steps context" '.steps | keys | length' "0"

# ============================================================================
# Test 9: Workflow metadata is captured
# ============================================================================
reset_defaults
run_test "Workflow run_id captured" '.workflow.run_id' "12345678"

# ============================================================================
# Test 10: Filter password fields from context
# ============================================================================
reset_defaults
export input_github_context_json='{"repository": "test/repo", "token": "secret-token-value"}'
run_test "Filter token from github context" '.github_context | has("token")' "false"

# ============================================================================
# Test 11: Preserve non-sensitive fields
# ============================================================================
reset_defaults
export input_github_context_json='{"repository": "test/repo", "event_name": "pull_request", "ref": "refs/heads/main"}'
run_test "Preserve event_name field" '.github_context.event_name' "pull_request"

# ============================================================================
# Test 12: Handle null JSON input
# ============================================================================
reset_defaults
export input_matrix_context_json="null"
run_test "Handle null JSON input" '.matrix_context' "{}"

# ============================================================================
# Test 13: Capture step conclusion (different from outcome)
# ============================================================================
reset_defaults
export input_steps_context_json='{
  "init": {"outputs": {}, "outcome": "failure", "conclusion": "success"}
}'
run_test "Capture step conclusion" '.steps["init"].conclusion' "success"

# ============================================================================
# Test 14: Environment name in metadata
# ============================================================================
reset_defaults
export input_environment_name="production"
run_test "Environment name used" '.metadata.environment' "production"

# ============================================================================
# Test 15: Timestamp is present
# ============================================================================
reset_defaults
run_test "Timestamp is present" '.metadata.captured_at | length > 0' "true"

# ============================================================================
# Test 16: Step names are preserved correctly
# ============================================================================
reset_defaults
export input_steps_context_json='{
  "setup-terraform-cache": {"outputs": {"plugin-cache-directory": "/cache"}, "outcome": "success", "conclusion": "success"}
}'
run_test "Step names preserved" '.steps["setup-terraform-cache"].outputs["plugin-cache-directory"]' "/cache"

# ============================================================================
# Test 17: Handle null steps context
# ============================================================================
reset_defaults
export input_steps_context_json="null"
run_test "Handle null steps context" '.steps | keys | length' "0"

# ============================================================================
# Test 18: Many steps are captured
# ============================================================================
reset_defaults
export input_steps_context_json='{
  "step1": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step2": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step3": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step4": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step5": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step6": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step7": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step8": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step9": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step10": {"outputs": {}, "outcome": "success", "conclusion": "success"}
}'
run_test "Many steps captured" '.steps | keys | length' "10"

# ============================================================================
# Summary
# ============================================================================

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
