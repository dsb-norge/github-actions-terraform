#!/bin/env bash
#
# Local testing/debugging script for step_parse_plan_output.sh
# Simulates GitHub Actions environment for testing locally.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${_this_script_dir}"

# Required input variables (match what action.yml would export)
# Use a test data file that exercises common parsing paths
export input_plan_console_file="${_this_script_dir}/test-data/plan_1_add_1_change_5_destroy_2_move.log"

# Source the main script in a subshell so 'exit' doesn't terminate this runner
(
  set -o allexport
  source "${_this_script_dir}/step_parse_plan_output.sh"
)

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
