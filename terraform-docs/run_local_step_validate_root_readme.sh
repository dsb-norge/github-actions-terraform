#!/bin/env bash
#
# Local testing/debugging script for step_validate_root_readme.sh
# Simulates GitHub Actions environment for testing locally.
#
# Builds a README.md without the terraform-docs delimiters and runs the step,
# which appends them. Swap the README below for one with the delimiters in the
# wrong order to see the failure.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}/module"

mkdir -p "${GITHUB_WORKSPACE}"
cat >"${GITHUB_WORKSPACE}/README.md" <<'README'
# My module

Creates the thing.
README

# Required input variables (match what action.yaml would export)
export input_readme_file_path="."

# Source the main script in a subshell so 'exit' doesn't terminate this runner
(
  cd "${GITHUB_WORKSPACE}" || exit 1
  set -o allexport
  source "${_this_script_dir}/step_validate_root_readme.sh"
)
echo "Step exit code: $?"

echo ""
echo "========================================"
echo "README.md after the step:"
echo "========================================"
cat "${GITHUB_WORKSPACE}/README.md"
