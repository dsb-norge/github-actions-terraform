#!/bin/env bash
#
# Local testing/debugging script for step_auto_merge_pr.sh
# Simulates GitHub Actions environment for testing the auto-merge logic locally.
#
# Usage:
#   ./run_local_step_auto_merge_pr.sh                     # Run with mock gh (safe)
#   GH_MOCK_MODE=failure ./run_local_step_auto_merge_pr.sh  # Simulate merge failure
#   TEST_NULL_MERGEABLE=true GH_MOCK_MODE=retry GH_MOCK_FAIL_COUNT=2 MERGE_RETRY_DELAY=0 ./run_local_step_auto_merge_pr.sh  # Simulate retry
#   GH_MOCK_BASE_MOVED=true ./run_local_step_auto_merge_pr.sh  # Simulate a base that moved after the plan
#
# Environment variables:
#   GH_MOCK_MODE        - Mock mode: success, failure, or retry (default: success)
#   GH_MOCK_FAIL_COUNT  - For retry mode, number of failures before success (default: 2)
#   GH_MOCK_BASE_MOVED  - Set to "true" for a base branch tip other than the planned base
#   MERGE_RETRY_DELAY   - Seconds between retry attempts (default: 5, use 0 for fast tests)
#   TEST_NULL_MERGEABLE - Set to "true" to test with null mergeable status (triggers retry logic)
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"

# ============================================================================
# Mock gh CLI for local testing - prevents actual GitHub API calls
# ============================================================================
GH_MOCK_MODE="${GH_MOCK_MODE:-success}"
GH_MOCK_FAIL_COUNT="${GH_MOCK_FAIL_COUNT:-2}"
GH_MOCK_BASE_MOVED="${GH_MOCK_BASE_MOVED:-false}"
GH_MOCK_ATTEMPT_FILE=$(mktemp)
echo "0" > "${GH_MOCK_ATTEMPT_FILE}"

# The head the run planned, the event's merge commit, and the base the plans saw
PLANNED_HEAD_SHA="e12b36765775e6f04c2be35fad528ecad246af07"
MERGE_COMMIT_SHA="03b530372841a10494f3d0cf838598a4eacee798"
PLANNED_BASE_SHA="5f2c9e0d1a3b4c5d6e7f8091a2b3c4d5e6f70819"

gh() {
  echo "[MOCK gh] Called with: $*" >&2

  # The base check and the head read answer the same in every mode
  if [[ "$1" == "api" && "$2" == */commits/* ]]; then
    echo "${PLANNED_BASE_SHA}"
    return 0
  fi
  if [[ "$1" == "api" && "$2" == */branches/* ]]; then
    if [[ "${GH_MOCK_BASE_MOVED}" == "true" ]]; then
      echo "9a8b7c6d5e4f30211203f4e5d6c7b8a990a1b2c3"
    else
      echo "${PLANNED_BASE_SHA}"
    fi
    return 0
  fi
  if [[ "$1" == "pr" && "$2" == "view" && " $* " == *" headRefOid "* ]]; then
    echo "${PLANNED_HEAD_SHA}"
    return 0
  fi

  case "${GH_MOCK_MODE}" in
    failure)
      echo "[MOCK gh] Simulating failure" >&2
      return 1
      ;;
    retry)
      # Handle 'gh pr view' for mergeable status check
      if [[ "$1" == "pr" && "$2" == "view" ]]; then
        local view_file="${GH_MOCK_ATTEMPT_FILE}.view"
        local view_attempt=0
        if [[ -f "${view_file}" ]]; then
          view_attempt=$(cat "${view_file}")
        fi
        echo $((view_attempt + 1)) > "${view_file}"

        # Return UNKNOWN for first few attempts, then MERGEABLE
        if [[ ${view_attempt} -lt ${GH_MOCK_FAIL_COUNT} ]]; then
          echo "UNKNOWN"
        else
          echo "MERGEABLE"
        fi
        return 0
      fi

      # Handle 'gh pr merge'
      if [[ "$1" == "pr" && "$2" == "merge" ]]; then
        local current_attempt=$(cat "${GH_MOCK_ATTEMPT_FILE}")
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
      ;;
    *)
      # Handle 'gh pr view' for mergeable status check
      if [[ "$1" == "pr" && "$2" == "view" ]]; then
        echo "MERGEABLE"
      fi
      return 0
      ;;
  esac
}
export -f gh

# Required input variables
export input_repo_ref="dsb-infra/azure-terraform-dsb-platform-sandbox"
export input_pr_number="60"
export input_head_sha="${PLANNED_HEAD_SHA}"
export input_merge_sha="${MERGE_COMMIT_SHA}"

# GitHub event context JSON - simulates ${{ toJSON(github.event) }}
# Use TEST_NULL_MERGEABLE=true to test with null mergeable status (triggers retry logic)
TEST_NULL_MERGEABLE="${TEST_NULL_MERGEABLE:-false}"

if [[ "${TEST_NULL_MERGEABLE}" == "true" ]]; then
  mergeable_value="null"
else
  mergeable_value="true"
fi

export input_github_event_context_json='{
  "action": "synchronize",
  "number": 60,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": '"${mergeable_value}"',
    "title": "feat: Enable auto-merge for PRs",
    "number": 60,
    "head": {
      "ref": "gradual-meadowlark",
      "sha": "e12b36765775e6f04c2be35fad528ecad246af07"
    },
    "base": {
      "ref": "main"
    },
    "user": {
      "login": "a-random-user"
    }
  },
  "repository": {
    "full_name": "dsb-infra/azure-terraform-dsb-platform-sandbox",
    "name": "azure-terraform-dsb-platform-sandbox",
    "owner": {
      "login": "dsb-infra"
    }
  },
  "sender": {
    "login": "a-random-user"
  }
}'

echo ""
echo "========================================"
echo "  AUTO-MERGE-PR LOCAL TEST"
echo "========================================"
echo ""
echo "Mock mode: ${GH_MOCK_MODE}"
if [[ "${GH_MOCK_MODE}" == "retry" ]]; then
  echo "Fail count: ${GH_MOCK_FAIL_COUNT}"
fi
echo "Repository: ${input_repo_ref}"
echo "PR Number: ${input_pr_number}"
echo ""
echo "----------------------------------------"
echo ""

# Run the step script
(
  set -o allexport
  source "${_this_script_dir}/step_auto_merge_pr.sh"
)
exit_code=$?

echo ""
echo "----------------------------------------"
echo ""
echo "Exit code: ${exit_code}"

# Cleanup
rm -f "${GITHUB_OUTPUT}" "${GH_MOCK_ATTEMPT_FILE}" "${GH_MOCK_ATTEMPT_FILE}.view"

exit ${exit_code}
