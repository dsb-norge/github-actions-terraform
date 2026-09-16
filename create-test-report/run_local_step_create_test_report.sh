#!/bin/env bash
#
# Local testing/debugging script for step_create_test_report.sh
# Simulates GitHub Actions environment for testing locally.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"
export GITHUB_WORKFLOW="DSB Terraform Module CI"
export GITHUB_ACTOR="test-user"
export GITHUB_EVENT_NAME="pull_request"

# Required input variables (match what action.yml would export)
export input_test_file="main.tftest.hcl"
export input_status_init="success"
export input_status_test="failure"
export input_test_summary='"Failure! 1 passed, 1 failed."'
export input_test_report="${_this_script_dir}/test-data/report_failure.txt"

# Source the main script in a subshell so 'exit' doesn't terminate this runner.
# No allexport — mirrors the action.yml shim (see the comment there).
(
  source "${_this_script_dir}/step_create_test_report.sh"
)
echo ""
echo "step exit code: ${?}"

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"

echo ""
echo "========================================"
echo "Rendered body-file:"
echo "========================================"
cat "$(grep '^body-file=' "${GITHUB_OUTPUT}" | cut -d= -f2-)"
echo
