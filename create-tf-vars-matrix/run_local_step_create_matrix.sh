#!/bin/env bash
#
# Local testing/debugging script for step_create_matrix.sh
# Simulates GitHub Actions environment for testing locally.
#
# Runs the step against one of the engine's port cases (default: 'defaults') in a scratch
# workspace holding the case's directories, and prints the matrix-json it publishes.
#
# Usage: run_local_step_create_matrix.sh [case-name]
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
_case_dir="${_this_script_dir}/../engine/tests/port/cases/${1:-defaults}"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

# Inputs, as the action.yml shim passes them
export input_repository="example-org/example-repo"
export input_event_name="push"
export input_ref_name="$(jq -r '.ref_name' "${_case_dir}/case.json")"
export input_default_branch="$(jq -r '.default_branch' "${_case_dir}/case.json")"
input_inputs_json="$(jq '.inputs_json' "${_case_dir}/case.json")"

while IFS= read -r directory; do
  mkdir -p "${GITHUB_WORKSPACE}/${directory}"
done < <(jq -r '.directories[]?' "${_case_dir}/case.json")

(
  cd "${GITHUB_WORKSPACE}" || exit 1
  set -o allexport
  source "${_this_script_dir}/step_create_matrix.sh"
)
echo "step exit code: $?"
echo "--- GITHUB_OUTPUT ---"
cat "${GITHUB_OUTPUT}"
