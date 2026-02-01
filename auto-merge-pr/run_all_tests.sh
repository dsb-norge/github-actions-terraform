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
  # Handle 'gh pr view' for mergeable status check
  if [[ "$1" == "pr" && "$2" == "view" ]]; then
    echo "MERGEABLE"
  fi
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

# ============================================================================
# Mock gh CLI - fails initially then succeeds (for retry testing)
# Uses a temp file to track attempts across subshells
# ============================================================================
GH_MOCK_ATTEMPT_FILE=""
GH_MOCK_FAIL_COUNT=0
GH_MOCK_VIEW_RESPONSES=()

gh_mock_retry() {
  echo "[MOCK gh] Called with: $*" >&2

  # Read current attempt from file
  local current_attempt=0
  if [[ -f "${GH_MOCK_ATTEMPT_FILE}" ]]; then
    current_attempt=$(cat "${GH_MOCK_ATTEMPT_FILE}")
  fi

  # Handle 'gh pr view' for mergeable status check
  if [[ "$1" == "pr" && "$2" == "view" ]]; then
    # Use view_attempt to track which response to return
    local view_file="${GH_MOCK_ATTEMPT_FILE}.view"
    local view_attempt=0
    if [[ -f "${view_file}" ]]; then
      view_attempt=$(cat "${view_file}")
    fi
    echo $((view_attempt + 1)) > "${view_file}"

    if [[ ${#GH_MOCK_VIEW_RESPONSES[@]} -gt 0 && ${view_attempt} -lt ${#GH_MOCK_VIEW_RESPONSES[@]} ]]; then
      echo "${GH_MOCK_VIEW_RESPONSES[${view_attempt}]}"
    else
      echo "MERGEABLE"
    fi
    return 0
  fi

  # Handle 'gh pr merge'
  if [[ "$1" == "pr" && "$2" == "merge" ]]; then
    current_attempt=$((current_attempt + 1))
    echo "${current_attempt}" > "${GH_MOCK_ATTEMPT_FILE}"

    if [[ ${current_attempt} -le ${GH_MOCK_FAIL_COUNT} ]]; then
      echo "[MOCK gh] Simulating failure (attempt ${current_attempt}/${GH_MOCK_FAIL_COUNT})" >&2
      return 1
    fi
    echo "[MOCK gh] Success on attempt ${current_attempt}" >&2
    return 0
  fi

  return 0
}

# Current mock mode (success, failure, or retry)
GH_MOCK_MODE="success"

# The actual mock function that gets exported - delegates based on mode
gh() {
  case "${GH_MOCK_MODE}" in
    failure)
      gh_mock_failure "$@"
      ;;
    retry)
      gh_mock_retry "$@"
      ;;
    *)
      gh_mock_success "$@"
      ;;
  esac
}
export -f gh gh_mock_success gh_mock_failure gh_mock_retry

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
  # Create fresh temp file for retry attempt tracking
  export GH_MOCK_ATTEMPT_FILE=$(mktemp)
  echo "0" > "${GH_MOCK_ATTEMPT_FILE}"
  export GH_MOCK_FAIL_COUNT=0
  export GH_MOCK_VIEW_RESPONSES=()
  # Use fast retry for testing (0 seconds instead of 5)
  export MERGE_RETRY_DELAY=0
  export MERGE_RETRY_MAX_ATTEMPTS=5
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
# Test 17: Null mergeable triggers retry logic
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
run_test "Null mergeable uses retry logic" 0 "Using retry logic due to pending mergeable status"

# ============================================================================
# Test 18: Retry succeeds on second attempt
# ============================================================================
reset_defaults
export GH_MOCK_MODE="retry"
export GH_MOCK_FAIL_COUNT=1
export GH_MOCK_VIEW_RESPONSES=("UNKNOWN" "MERGEABLE")
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null
  }
}'
run_test "Retry succeeds on second attempt" 0 "Merge attempt 2"

# ============================================================================
# Test 19: Retry succeeds on third attempt
# ============================================================================
reset_defaults
export GH_MOCK_MODE="retry"
export GH_MOCK_FAIL_COUNT=2
export GH_MOCK_VIEW_RESPONSES=("UNKNOWN" "UNKNOWN" "MERGEABLE")
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null
  }
}'
run_test "Retry succeeds on third attempt" 0 "Merge attempt 3"

# ============================================================================
# Test 20: Retry fails after max attempts
# ============================================================================
reset_defaults
export GH_MOCK_MODE="failure"
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null
  }
}'
run_test "Retry fails after max attempts" 1 "Failed to merge PR after 5 attempts"

# ============================================================================
# Test 21: Retry aborts if PR becomes non-mergeable
# ============================================================================
reset_defaults
export GH_MOCK_MODE="retry"
export GH_MOCK_FAIL_COUNT=5
export GH_MOCK_VIEW_RESPONSES=("UNKNOWN" "NOT_MERGEABLE")
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null
  }
}'
run_test "Retry aborts when PR becomes non-mergeable" 1 "PR is not mergeable"

# ============================================================================
# Test 22: Retry logs waiting message between attempts
# ============================================================================
reset_defaults
export GH_MOCK_MODE="retry"
export GH_MOCK_FAIL_COUNT=1
export GH_MOCK_VIEW_RESPONSES=("UNKNOWN" "MERGEABLE")
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null
  }
}'
run_test "Retry logs wait message" 0 "Waiting .* seconds before retry"

# ============================================================================
# Test 23: Retry logs current mergeable status
# ============================================================================
reset_defaults
export GH_MOCK_MODE="retry"
export GH_MOCK_FAIL_COUNT=1
export GH_MOCK_VIEW_RESPONSES=("UNKNOWN" "MERGEABLE")
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null
  }
}'
run_test "Retry logs mergeable status check" 0 "Current mergeable status:"

# ============================================================================
# Test 24: Retry confirms when PR becomes mergeable
# ============================================================================
reset_defaults
export GH_MOCK_MODE="retry"
export GH_MOCK_FAIL_COUNT=2
# First view returns UNKNOWN, second returns MERGEABLE (triggers the confirmation message)
export GH_MOCK_VIEW_RESPONSES=("UNKNOWN" "MERGEABLE" "MERGEABLE")
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null
  }
}'
run_test "Retry confirms PR is mergeable" 0 "PR is now confirmed mergeable"

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
