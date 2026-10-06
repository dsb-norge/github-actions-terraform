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

# Every temp file of the suite lives under one directory, removed on exit
_mock_root=$(mktemp -d)
trap 'rm -rf "${_mock_root}"' EXIT

# The commits of the tests: the head the run planned, the event's merge commit,
# the base the plans saw (the merge commit's first parent), and a base and a
# head that moved after the run planned
_head_sha="a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
_merge_sha="0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c"
_base_sha="b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3"
_moved_base_sha="c0ffee00000000000000000000000000000000b1"
_moved_head_sha="dead0000000000000000000000000000000000a2"

# ============================================================================
# Mock gh CLI
#
# Logs every call to stderr and to GH_MOCK_CALLS_FILE, and answers:
#   gh api repos/<repo>/commits/<sha>   the merge commit's first parent, GH_MOCK_PLANNED_BASE,
#                                       or fails when GH_MOCK_COMMIT_LOOKUP=fail
#   gh api repos/<repo>/branches/<ref>  the base branch's tip: the next of GH_MOCK_BASE_TIPS
#                                       (space-separated, the last repeating), or fails when
#                                       GH_MOCK_BRANCH_LOOKUP=fail
#   gh pr view --json headRefOid        the head now, GH_MOCK_HEAD_NOW, or fails when empty
#   gh pr view --json mergeable         the next of GH_MOCK_VIEW_RESPONSES, then MERGEABLE
#   gh pr merge                         by GH_MOCK_MODE: success; failure (every time, with
#                                       GH_MOCK_MERGE_ERROR on stderr); retry (fails
#                                       GH_MOCK_FAIL_COUNT times, then succeeds)
# Each call runs in a subshell of the step, so the counters live in files.
# ============================================================================
_gh_mock_next() {
  local file="${GH_MOCK_STATE_DIR}/${1}"
  local value=0
  [[ -f "${file}" ]] && value=$(cat "${file}")
  echo $((value + 1)) >"${file}"
  echo "${value}"
}

gh() {
  echo "[MOCK gh] Called with: $*" >&2
  echo "$*" >>"${GH_MOCK_CALLS_FILE}"
  local index
  if [[ "$1" == "api" ]]; then
    case "$2" in
      */commits/*)
        if [[ "${GH_MOCK_COMMIT_LOOKUP}" == "fail" ]]; then
          echo "gh: Not Found (HTTP 404)" >&2
          return 1
        fi
        echo "${GH_MOCK_PLANNED_BASE}"
        ;;
      */branches/*)
        if [[ "${GH_MOCK_BRANCH_LOOKUP}" == "fail" ]]; then
          echo "gh: Not Found (HTTP 404)" >&2
          return 1
        fi
        local tips=(${GH_MOCK_BASE_TIPS})
        index=$(_gh_mock_next branches)
        [[ ${index} -lt ${#tips[@]} ]] || index=$((${#tips[@]} - 1))
        echo "${tips[${index}]}"
        ;;
    esac
    return 0
  fi
  if [[ "$1" == "pr" && "$2" == "view" ]]; then
    if [[ " $* " == *" headRefOid "* ]]; then
      [[ -n "${GH_MOCK_HEAD_NOW}" ]] || return 1
      echo "${GH_MOCK_HEAD_NOW}"
      return 0
    fi
    index=$(_gh_mock_next view)
    if [[ ${index} -lt ${#GH_MOCK_VIEW_RESPONSES[@]} ]]; then
      echo "${GH_MOCK_VIEW_RESPONSES[${index}]}"
    else
      echo "MERGEABLE"
    fi
    return 0
  fi
  if [[ "$1" == "pr" && "$2" == "merge" ]]; then
    index=$(_gh_mock_next merge)
    case "${GH_MOCK_MODE}" in
      failure)
        echo "[MOCK gh] Simulating failure" >&2
        echo "${GH_MOCK_MERGE_ERROR}" >&2
        return 1
        ;;
      retry)
        if [[ ${index} -lt ${GH_MOCK_FAIL_COUNT} ]]; then
          echo "[MOCK gh] Simulating failure (attempt $((index + 1))/${GH_MOCK_FAIL_COUNT})" >&2
          return 1
        fi
        echo "[MOCK gh] Success on attempt $((index + 1))" >&2
        ;;
    esac
    return 0
  fi
  return 0
}
export -f gh _gh_mock_next

# Function to run a single test
# Args:
#   $1 - test_name: Description of the test
#   $2 - expected_exit_code: Expected exit code (0 for success)
#   $3... - grep patterns: each must match the output; one starting with '!' must not.
#           After 'calls:' (or '!calls:') a pattern is matched against the gh calls made.
run_test() {
  local test_name="${1}"
  local expected_exit_code="${2}"
  shift 2
  local patterns=("$@")

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Set up GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp -p "${_mock_root}")

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

  # Check the output patterns
  local failed_patterns=()
  local pattern text negate
  for pattern in "${patterns[@]}"; do
    negate=false
    if [[ "${pattern}" == '!'* ]]; then
      negate=true
      pattern="${pattern#!}"
    fi
    text="${output}"
    if [[ "${pattern}" == calls:* ]]; then
      text=$(cat "${GH_MOCK_CALLS_FILE}")
      pattern="${pattern#calls:}"
    fi
    if grep -q -- "${pattern}" <<<"${text}"; then
      [[ "${negate}" == "false" ]] || failed_patterns+=("found, but must not be: ${pattern}")
    else
      [[ "${negate}" == "true" ]] || failed_patterns+=("not found: ${pattern}")
    fi
  done

  # Report result
  if [[ "${exit_code_passed}" == "true" && ${#failed_patterns[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    if [[ "${exit_code_passed}" != "true" ]]; then
      echo "  Expected exit code: ${expected_exit_code}, got: ${actual_exit_code}"
    fi
    for pattern in "${failed_patterns[@]}"; do
      echo "  Expected output pattern ${pattern}"
    done
    echo ""
    echo "Test output:"
    echo "${output}"
    echo ""
    echo "gh calls:"
    cat "${GH_MOCK_CALLS_FILE}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
}

# Function to reset all variables to valid defaults
reset_defaults() {
  export GH_MOCK_MODE="success"
  # Fresh state for the mock's counters and call log
  export GH_MOCK_STATE_DIR=$(mktemp -d -p "${_mock_root}")
  export GH_MOCK_CALLS_FILE="${GH_MOCK_STATE_DIR}/calls"
  : >"${GH_MOCK_CALLS_FILE}"
  export GH_MOCK_FAIL_COUNT=0
  export GH_MOCK_VIEW_RESPONSES=()
  export GH_MOCK_MERGE_ERROR="GraphQL: Pull request is not mergeable (mergePullRequest)"
  # The base has not moved and the head is the planned one
  export GH_MOCK_PLANNED_BASE="${_base_sha}"
  export GH_MOCK_BASE_TIPS="${_base_sha}"
  export GH_MOCK_COMMIT_LOOKUP="ok"
  export GH_MOCK_BRANCH_LOOKUP="ok"
  export GH_MOCK_HEAD_NOW="${_head_sha}"
  # Use fast retry for testing (0 seconds instead of 5)
  export MERGE_RETRY_DELAY=0
  export MERGE_RETRY_MAX_ATTEMPTS=5
  export input_repo_ref="test-org/test-repo"
  export input_pr_number="123"
  export input_head_sha="${_head_sha}"
  export input_merge_sha="${_merge_sha}"
  export input_github_event_context_json='{
    "action": "synchronize",
    "number": 123,
    "pull_request": {
      "state": "open",
      "draft": false,
      "mergeable": true,
      "title": "Test PR",
      "number": 123,
      "head": {"sha": "'"${_head_sha}"'"},
      "base": {"ref": "main"}
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
    "mergeable": null,
    "base": {"ref": "main"}
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
    "mergeable": null,
    "base": {"ref": "main"}
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
    "mergeable": null,
    "base": {"ref": "main"}
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
    "mergeable": null,
    "base": {"ref": "main"}
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
    "mergeable": null,
    "base": {"ref": "main"}
  }
}'
run_test "Retry fails after max attempts" 1 "Failed to merge PR after 5 attempts"

# ============================================================================
# Test 21: Retry aborts if PR becomes non-mergeable
# ============================================================================
reset_defaults
export GH_MOCK_MODE="retry"
export GH_MOCK_FAIL_COUNT=5
# GitHub's value is CONFLICTING; the NOT_MERGEABLE this case used to send is no value GitHub reports
export GH_MOCK_VIEW_RESPONSES=("UNKNOWN" "CONFLICTING")
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": null,
    "base": {"ref": "main"}
  }
}'
run_test "Retry stops when PR becomes CONFLICTING" 1 \
  "::error title=Auto-merge refused::The pull request conflicts with the base branch 'main' (mergeable: CONFLICTING), so it was not merged." \
  "Merge attempt 3/5" "!Merge attempt 4/5"

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
    "mergeable": null,
    "base": {"ref": "main"}
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
    "mergeable": null,
    "base": {"ref": "main"}
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
    "mergeable": null,
    "base": {"ref": "main"}
  }
}'
run_test "Retry confirms PR is mergeable" 0 "PR is now confirmed mergeable"

# ============================================================================
# The pins (docs/Auto-merge.md §6, D2, D3, D11)
#
# The merge is tied to what the run planned: the base the plans saw (the merge
# commit's first parent) must still be the base branch's tip, and GitHub must
# find the planned head. A refusal for either is final, never retried.
# ============================================================================
_event_pending='{
  "action": "synchronize",
  "number": 123,
  "pull_request": {"state": "open", "draft": false, "mergeable": null, "base": {"ref": "main"}}
}'
_head_moved_error="GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)"

reset_defaults
run_test "Pins: the merge passes --match-head-commit with the planned head" 0 \
  "MOCK gh.*pr merge 123 --admin --rebase --delete-branch --repo test-org/test-repo --match-head-commit ${_head_sha}"

reset_defaults
run_test "Pins: the base check reads the merge commit's first parent and the base branch's tip" 0 \
  "calls:^api repos/test-org/test-repo/commits/${_merge_sha} --jq .parents\[0\].sha$" \
  "calls:^api repos/test-org/test-repo/branches/main --jq .commit.sha$" \
  "Base branch 'main' is still at ${_base_sha:0:7}"

reset_defaults
export GH_MOCK_BASE_TIPS="${_moved_base_sha}"
run_test "Pins: the base moved - refused before any merge call" 1 \
  "::error title=Auto-merge refused::The base branch 'main' moved after this run checked the pull request (checked on ${_base_sha:0:7}, now ${_moved_base_sha:0:7}), so the merged result was never checked. The next run, after the pull request is brought up to date, decides." \
  "!calls:pr merge"

reset_defaults
export GH_MOCK_BASE_TIPS="${_moved_base_sha}"
export input_github_event_context_json="${_event_pending}"
run_test "Pins: the base moved while mergeability is pending - no merge, no retry" 1 \
  "The base branch 'main' moved" "!calls:pr merge" "!Merge attempt 2/5"

reset_defaults
export GH_MOCK_MODE="retry"
export GH_MOCK_FAIL_COUNT=1
export GH_MOCK_BASE_TIPS="${_base_sha} ${_moved_base_sha}"
export input_github_event_context_json="${_event_pending}"
run_test "Pins: the base moves between attempts - the next attempt refuses and stops" 1 \
  "Merge attempt 2/5" "The base branch 'main' moved" "!Success on attempt" "!Merge attempt 3/5"

reset_defaults
export GH_MOCK_COMMIT_LOOKUP="fail"
run_test "Pins: the planned base cannot be read - not merged" 1 \
  "::error title=Auto-merge refused::Could not read the base this run checked the pull request on (the first parent of the merge commit ${_merge_sha:0:7}), so the pull request was not merged." \
  "!calls:pr merge"

reset_defaults
export GH_MOCK_BRANCH_LOOKUP="fail"
run_test "Pins: the base branch's tip cannot be read - not merged" 1 \
  "::error title=Auto-merge refused::Could not read the tip of the base branch 'main'" \
  "!calls:pr merge"

reset_defaults
export GH_MOCK_MODE="failure"
export GH_MOCK_MERGE_ERROR="${_head_moved_error}"
export GH_MOCK_HEAD_NOW="${_moved_head_sha}"
run_test "Pins: the head moved - GitHub refuses, the message names both heads" 1 \
  "::error title=Auto-merge refused::The pull request's head moved after this run checked it (checked ${_head_sha:0:7}, now ${_moved_head_sha:0:7}), so it was not merged; the run for the new head decides." \
  "calls:^pr view 123 --repo test-org/test-repo --json headRefOid --jq .headRefOid$"

reset_defaults
export GH_MOCK_MODE="failure"
export GH_MOCK_MERGE_ERROR="${_head_moved_error}"
export GH_MOCK_HEAD_NOW="${_moved_head_sha}"
export input_github_event_context_json="${_event_pending}"
run_test "Pins: the head moved while mergeability is pending - no retry" 1 \
  "The pull request's head moved" "!Merge attempt 2/5"

reset_defaults
export GH_MOCK_MODE="failure"
export GH_MOCK_MERGE_ERROR="${_head_moved_error}"
export GH_MOCK_HEAD_NOW=""
export input_github_event_context_json="${_event_pending}"
run_test "Pins: GitHub says the head moved and the head cannot be read - refused as moved" 1 \
  "The pull request's head moved after this run checked it (checked ${_head_sha:0:7}, now unknown)" "!Merge attempt 2/5"

reset_defaults
export GH_MOCK_MODE="failure"
run_test "Pins: a merge failure with the head unchanged is not taken for a moved head" 1 \
  "Failed to merge PR" "!head moved"

reset_defaults
export input_head_sha=""
run_test "Pins: head-sha missing - not merged, nothing looked up" 1 \
  "Missing required input: head-sha" "!calls:."

reset_defaults
export input_merge_sha=""
run_test "Pins: merge-sha missing - not merged, nothing looked up" 1 \
  "Missing required input: merge-sha" "!calls:."

reset_defaults
export input_head_sha="abc123"
run_test "Pins: head-sha that is not a full commit SHA - not merged" 1 \
  "Input head-sha 'abc123' is not a full commit SHA" "!calls:."

reset_defaults
export input_github_event_context_json='{"action": "synchronize", "number": 123, "pull_request": {"state": "open", "draft": false, "mergeable": true}}'
run_test "Pins: an event without the base branch - not merged" 1 \
  "Missing required 'pull_request.base.ref' field" "!calls:."

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}              TEST SUMMARY                 ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "${GREEN}Tests passed: ${TESTS_PASSED}${NC}"
if [[ ${TESTS_FAILED} -gt 0 ]]; then
  echo -e "${RED}Tests failed: ${TESTS_FAILED}${NC}"
  exit 1
else
  echo -e "Tests failed: 0"
  echo ""
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
