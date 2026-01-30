#!/bin/env bash
#
# Local testing/debugging script for step_auto_merge_pr.sh
# Simulates GitHub Actions environment for testing the auto-merge logic locally.
#
# Usage:
#   ./run_local_step_auto_merge_pr.sh           # Run with mock gh (safe)
#   GH_MOCK_MODE=failure ./run_local_step_auto_merge_pr.sh  # Simulate merge failure
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

gh() {
  echo "[MOCK gh] Called with: $*" >&2
  if [[ "${GH_MOCK_MODE}" == "failure" ]]; then
    echo "[MOCK gh] Simulating failure" >&2
    return 1
  fi
  return 0
}
export -f gh

# Required input variables
export input_repo_ref="dsb-infra/azure-terraform-dsb-platform-sandbox"
export input_pr_number="60"

# GitHub event context JSON - simulates ${{ toJSON(github.event) }}
# This represents a valid, mergeable PR
export input_github_event_context_json='{
  "action": "synchronize",
  "number": 60,
  "pull_request": {
    "state": "open",
    "draft": false,
    "mergeable": true,
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
rm -f "${GITHUB_OUTPUT}"

exit ${exit_code}
