#!/bin/env bash
#
# Comprehensive test runner for step_auto_merge_pr.sh
# Tests various scenarios including edge cases and error handling
#
# Testing strategy for destructive actions:
#   - Mocks the 'gh' CLI command with a function that logs calls and returns configurable exit codes
#   - Tests verify correct logic flow and error handling without any actual GitHub API calls
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

# ============================================================================
# Mock gh CLI - succeeds and logs what was called
# ============================================================================
gh_mock_success() {
  echo "[MOCK gh] Called with: $*" >&2
  return 0
}

# ============================================================================
# Mock gh CLI - fails with exit code 1 and logs what was called
# ============================================================================
gh_mock_failure() {
  echo "[MOCK gh] Called with: $*" >&2
  echo "[MOCK gh] Simulating failure" >&2
  return 1
}

# Current mock mode (success or failure)
GH_MOCK_MODE="success"

# The actual mock function that gets exported - delegates based on mode
gh() {
  if [[ "${GH_MOCK_MODE}" == "failure" ]]; then
    gh_mock_failure "$@"
  else
    gh_mock_success "$@"
  fi
}
export -f gh gh_mock_success gh_mock_failure

# Function to run a single test
# Args:
#   $1 - test_name: Description of the test
#   $2 - expected_exit_code: Expected exit code (0 for success)
#   $3 - expected_output_pattern: Optional grep pattern to match in output
run_test() {
  local test_name="${1}"
  local expected_exit_code="${2}"
  local expected_output_pattern="${3:-}"

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Set up GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)

  # Required system variables
  export GITHUB_ACTION_PATH="${_this_script_dir}"

  # Run the step script and capture output
  local actual_exit_code=0
  local output=""
  output=$( (
    set -o allexport
    source "${_this_script_dir}/step_auto_merge_pr.sh"
  ) 2>&1) || actual_exit_code=$?

  # Check exit code
  local exit_code_passed=false
  if [[ "${actual_exit_code}" -eq "${expected_exit_code}" ]]; then
    exit_code_passed=true
  fi

  # Check output pattern if specified
  local pattern_passed=true
  if [[ -n "${expected_output_pattern}" ]]; then
    if echo "${output}" | grep -q "${expected_output_pattern}"; then
      pattern_passed=true
    else
      pattern_passed=false
    fi
  fi

  # Report result
  if [[ "${exit_code_passed}" == "true" && "${pattern_passed}" == "true" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    if [[ "${exit_code_passed}" != "true" ]]; then
      echo "  Expected exit code: ${expected_exit_code}, got: ${actual_exit_code}"
    fi
    if [[ "${pattern_passed}" != "true" ]]; then
      echo "  Expected output pattern '${expected_output_pattern}' not found"
    fi
    echo ""
    echo "Test output:"
    echo "${output}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
}

# Function to reset all variables to valid defaults
reset_defaults() {
  export GH_MOCK_MODE="success"
  export input_repo_ref="test-org/test-repo"
  export input_pr_number="123"
  export input_github_event_context_json='{
    "action": "synchronize",
    "number": 123,
    "pull_request": {
      "state": "open",
      "draft": false,
      "mergeable": true,
      "title": "Test PR",
      "number": 123
    },
    "repository": {
      "full_name": "test-org/test-repo"
    }
  }'
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}     AUTO-MERGE-PR STEP TESTS              ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "${YELLOW}Note: Tests use a mock gh CLI function${NC}"
echo -e "${YELLOW}      No actual GitHub API calls will be made${NC}"

# ============================================================================
# Test 1: Successful merge with valid PR state
# ============================================================================
reset_defaults
run_test "Successful merge with valid PR state" 0 "Successfully merged PR"

# ============================================================================
# Test 2: PR is not open (closed)
# ============================================================================
reset_defaults
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "closed",
    "draft": false,
    "mergeable": true
  }
}'
run_test "Reject closed PR" 1 "PR is not in an open state"

# ============================================================================
# Test 3: PR is a draft
# ============================================================================
reset_defaults
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": true,
    "mergeable": true
  }
}'
run_test "Reject draft PR" 1 "PR is a draft"

# ============================================================================
# Test 4: PR is not mergeable
# ============================================================================
reset_defaults
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": false
  }
}'
run_test "Reject non-mergeable PR" 1 "PR is in a non-mergeable state"

# ============================================================================
# Test 5: PR mergeable status is null (pending)
# ============================================================================
reset_defaults
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null
  }
}'
run_test "Handle null mergeable status (pending)" 0 "mergeable status is pending"

# ============================================================================
# Test 6: Missing pull_request in event context
# ============================================================================
reset_defaults
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123
}'
run_test "Reject missing pull_request object" 1 "Missing required 'pull_request' field"

# ============================================================================
# Test 7: Missing state field in pull_request
# ============================================================================
reset_defaults
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "draft": false,
    "mergeable": true
  }
}'
run_test "Reject missing state field" 1 "Missing required 'pull_request.state' field"

# ============================================================================
# Test 8: Missing draft field in pull_request
# ============================================================================
reset_defaults
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "mergeable": true
  }
}'
run_test "Reject missing draft field" 1 "Missing required 'pull_request.draft' field"

# ============================================================================
# Test 9: Missing repo reference input
# ============================================================================
reset_defaults
export input_repo_ref=""
run_test "Reject missing repo reference" 1 "Missing required input: repository reference"

# ============================================================================
# Test 10: Missing PR number input
# ============================================================================
reset_defaults
export input_pr_number=""
run_test "Reject missing PR number" 1 "Missing required input: PR number"

# ============================================================================
# Test 11: Missing event context JSON input
# ============================================================================
reset_defaults
export input_github_event_context_json=""
run_test "Reject missing event context JSON" 1 "Missing required input: github event context JSON"

# ============================================================================
# Test 12: Mock gh CLI is called with correct arguments
# ============================================================================
reset_defaults
run_test "gh CLI called with correct merge arguments" 0 "MOCK gh.*pr merge 123 --admin --rebase --delete-branch --repo test-org/test-repo"

# ============================================================================
# Test 13: PR merged state (already merged)
# ============================================================================
reset_defaults
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "merged",
    "draft": false,
    "mergeable": true
  }
}'
run_test "Reject already merged PR" 1 "PR is not in an open state"

# ============================================================================
# Test 14: Merge failure triggers debug info output
# ============================================================================
reset_defaults
export GH_MOCK_MODE="failure"
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": true,
    "title": "Test PR for debugging",
    "head": {"sha": "abc123"},
    "base": {"ref": "main"}
  }
}'
run_test "Merge failure shows debug info" 1 "PR details for debugging"

# ============================================================================
# Test 15: Debug info extraction includes correct fields
# ============================================================================
reset_defaults
export GH_MOCK_MODE="failure"
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": true,
    "title": "Debug Test PR",
    "mergeable_state": "clean",
    "head": {"sha": "deadbeef123"},
    "base": {"ref": "develop"}
  }
}'
run_test "Debug info contains PR title" 1 "Debug Test PR"

# ============================================================================
# Test 16: Successful merge logs success message
# ============================================================================
reset_defaults
run_test "Successful merge logs success" 0 "Successfully merged PR"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}              TEST SUMMARY                 ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Total tests: ${TESTS_RUN}"
echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
if [[ ${TESTS_FAILED} -gt 0 ]]; then
  echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"
  exit 1
else
  echo -e "Failed: 0"
  echo ""
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
