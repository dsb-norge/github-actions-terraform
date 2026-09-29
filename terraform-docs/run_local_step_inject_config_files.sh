#!/bin/env bash
#
# Local testing/debugging script for step_inject_config_files.sh
# Simulates GitHub Actions environment for testing locally.
#
# Builds a throwaway module repository with an examples/ folder and no
# terraform-docs configs, then runs the step in it. Set input_push to 'true'
# to see the configs staged instead of excluded.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}/module"

# A module repository with two examples and no configs
mkdir -p "${GITHUB_WORKSPACE}/examples/basic" "${GITHUB_WORKSPACE}/examples/complete"
git -C "${GITHUB_WORKSPACE}" init -q
echo 'variable "name" {}' >"${GITHUB_WORKSPACE}/main.tf"

# Required input variables (match what action.yaml would export)
export input_push="false"

# Source the main script in a subshell so 'exit' doesn't terminate this runner
(
  cd "${GITHUB_WORKSPACE}" || exit 1
  set -o allexport
  source "${_this_script_dir}/step_inject_config_files.sh"
)
echo "Step exit code: $?"

echo ""
echo "========================================"
echo "git status of the module repository:"
echo "========================================"
git -C "${GITHUB_WORKSPACE}" status --short

echo ""
echo "========================================"
echo "info/exclude of the module repository:"
echo "========================================"
cat "${GITHUB_WORKSPACE}/.git/info/exclude"

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
