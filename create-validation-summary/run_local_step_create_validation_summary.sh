#!/bin/env bash
#
# Local testing/debugging script for step_create_validation_summary.sh
# Simulates GitHub Actions environment for testing locally.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${_this_script_dir}"
export GITHUB_SERVER_URL="https://github.com"
export GITHUB_REPOSITORY="dsb-norge/github-actions-terraform"
export GITHUB_RUN_ID="12345678"
export GITHUB_WORKFLOW="Terraform CI"

# Required input variables (match what action.yml would export)
export input_environment_name="dev"
export input_plan_console_file=""
export input_plan_txt_output_file=""
export input_status_init="success"
export input_status_fmt="success"
export input_status_validate="success"
export input_status_lint="success"
export input_status_plan="success"
export input_include_plan_details="true"
export input_plan_count_add="3"
export input_plan_count_change="1"
export input_plan_count_destroy="0"
export input_plan_count_import="0"
export input_plan_count_move="2"
export input_plan_count_remove="0"
export input_job_check_run_id="87654321"
export input_github_actor="test-user"
export input_github_event_name="pull_request"

# Source the main script in a subshell so 'exit' doesn't terminate this runner
(
  set -o allexport
  source "${_this_script_dir}/step_create_validation_summary.sh"
)

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
