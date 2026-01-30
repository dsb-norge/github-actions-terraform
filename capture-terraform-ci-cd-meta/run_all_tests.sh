#!/usr/bin/env bash
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
  export GITHUB_WORKSPACE=$(mktemp -d)

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
    bash "${_this_script_dir}/step_capture.sh"
  ) > /tmp/test_output.txt 2>&1
  local exit_code=$?

  # Get the result file path
  local result_file
  result_file=$(grep "^result-json-file=" "${GITHUB_OUTPUT}" | cut -d= -f2)

  # Validate
  local actual_result=""
  if [[ -f "${result_file}" ]]; then
    actual_result=$(cat "${result_file}" | jq -r "${expected_field_check}")
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
  rm -rf "${GITHUB_WORKSPACE}"
}

# Function to reset all variables to defaults
reset_defaults() {
  export input_environment_name="test-env"
  export input_matrix_vars_json='{"github-environment": "test-env", "goals": ["all"]}'
  export input_github_context_json='{"repository": "test/repo"}'

  # Default outcomes - all empty
  export input_step_init_outcome=""
  export input_step_init_result=""
  export input_step_fmt_outcome=""
  export input_step_fmt_result=""
  export input_step_validate_outcome=""
  export input_step_validate_result=""
  export input_step_lint_outcome=""
  export input_step_lint_result=""
  export input_step_plan_outcome=""
  export input_step_plan_result=""
  export input_step_parse_plan_outcome=""
  export input_step_parse_plan_result=""
  export input_step_apply_outcome=""
  export input_step_apply_result=""
  export input_step_destroy_plan_outcome=""
  export input_step_destroy_plan_result=""
  export input_step_parse_destroy_plan_outcome=""
  export input_step_parse_destroy_plan_result=""
  export input_step_destroy_outcome=""
  export input_step_destroy_result=""
  export input_step_evaluate_automerge_outcome=""
  export input_step_evaluate_automerge_result=""
  export input_step_create_validation_summary_outcome=""
  export input_step_create_validation_summary_result=""

  # Default outputs - all empty
  export input_step_init_outputs_json='{}'
  export input_step_fmt_outputs_json='{}'
  export input_step_validate_outputs_json='{}'
  export input_step_lint_outputs_json='{}'
  export input_step_plan_outputs_json='{}'
  export input_step_parse_plan_outputs_json='{}'
  export input_step_apply_outputs_json='{}'
  export input_step_destroy_plan_outputs_json='{}'
  export input_step_parse_destroy_plan_outputs_json='{}'
  export input_step_destroy_outputs_json='{}'
  export input_step_evaluate_automerge_outputs_json='{}'
  export input_step_create_validation_summary_outputs_json='{}'
  export input_step_setup_terraform_cache_outputs_json='{}'
  export input_step_setup_tflint_outputs_json='{}'
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}  TERRAFORM CI/CD METADATA CAPTURE TESTS   ${NC}"
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
input_step_init_outcome="success"
input_step_plan_outcome="success"
run_test "Capture with step outcomes" '.steps[] | select(.name == "init") | .outcome' "success"

# ============================================================================
# Test 3: Handle missing/empty JSON gracefully
# ============================================================================
reset_defaults
unset input_matrix_vars_json
run_test "Handle missing matrix vars JSON" '.matrix_vars' "{}"

# ============================================================================
# Test 4: Capture plan outputs correctly
# ============================================================================
reset_defaults
input_step_parse_plan_outputs_json='{"count-add": "5", "count-change": "2"}'
run_test "Capture plan outputs" '.steps[] | select(.name == "parse-plan") | .outputs["count-add"]' "5"

# ============================================================================
# Test 5: Filter sensitive data from matrix vars
# ============================================================================
reset_defaults
input_matrix_vars_json='{"github-environment": "test", "secret-value": "should-be-removed", "password": "hidden"}'
run_test "Filter sensitive data from matrix vars" '.matrix_vars | has("secret-value")' "false"

# ============================================================================
# Test 6: Schema version is set
# ============================================================================
reset_defaults
run_test "Schema version is set" '.metadata.schema_version' "1.0.0"

# ============================================================================
# Test 7: All core steps are captured
# ============================================================================
reset_defaults
run_test "All core steps captured" '.steps | length' "14"

# ============================================================================
# Test 8: Handle invalid JSON in outputs gracefully
# ============================================================================
reset_defaults
input_step_plan_outputs_json="not-valid-json"
run_test "Handle invalid JSON gracefully" '.steps[] | select(.name == "plan") | .outputs' "{}"

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
