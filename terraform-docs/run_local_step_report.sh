#!/bin/env bash
#
# Local testing/debugging script for step_report.sh
# Simulates GitHub Actions environment for testing locally.
#
# Feeds the step the outcomes and num_changed outputs the two terraform-docs
# steps would have produced: here, push 'false' and an examples README that
# differs from what terraform-docs generates (status 'needs-regeneration').
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT and step summary like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export GITHUB_STEP_SUMMARY=$(mktemp)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"

# Required input variables (match what action.yaml would export)
export input_push="false"
export input_inject_outcome="success"
export input_validate_outcome="success"
export input_examples_outcome="failure"
export input_examples_num_changed="1"
export input_project_outcome="skipped"
export input_project_num_changed=""

# Source the main script in a subshell so 'exit' doesn't terminate this runner
(
  set -o allexport
  source "${_this_script_dir}/step_report.sh"
)
echo "Step exit code: $?"

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"

echo ""
echo "========================================"
echo "Step summary (GITHUB_STEP_SUMMARY):"
echo "========================================"
cat "${GITHUB_STEP_SUMMARY}"
