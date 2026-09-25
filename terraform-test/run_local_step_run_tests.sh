#!/bin/env bash
#
# Local testing/debugging script for step_run_tests.sh
# Simulates the GitHub Actions environment and runs the step against the fake
# terraform binary of the test suite, replaying a JSON log captured from a
# real Terraform. Pass another fixture name (test-data/terraform-1.16.2/) as
# the first argument, e.g. 'fail.json' or 'runerror.json'.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

_fixture="${1:-pass.json}"
_tmp="$(mktemp -d)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT="${_tmp}/github-output"
export GITHUB_STEP_SUMMARY="${_tmp}/step-summary"
export RUNNER_TEMP="${_tmp}/runner-temp"
export GITHUB_WORKSPACE="${_tmp}/workspace"
mkdir -p "${RUNNER_TEMP}" "${GITHUB_WORKSPACE}" "${_tmp}/bin"
: >"${GITHUB_OUTPUT}"
: >"${GITHUB_STEP_SUMMARY}"

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_RUN_ID="12345678"
export RUNNER_OS="Linux"
export RUNNER_ARCH="X64"
export TF_IN_AUTOMATION=true

# Fake terraform replaying the fixture
cp "${_this_script_dir}/test-data/fake_terraform.sh" "${_tmp}/bin/terraform"
chmod +x "${_tmp}/bin/terraform"
export PATH="${_tmp}/bin:${PATH}"
export FAKE_TF_OUTPUT="${_this_script_dir}/test-data/terraform-1.16.2/${_fixture}"
export FAKE_TF_EXIT=0
if [ "$(jq -r 'select(.type == "test_summary") | .test_summary.status' "${FAKE_TF_OUTPUT}")" != "pass" ]; then
  export FAKE_TF_EXIT=1
fi

# Input variables (match what action.yml would export)
export input_test_file="unit-pass.tftest.hcl"

# Source the step in a subshell so 'exit' doesn't terminate this runner
(
  cd "${GITHUB_WORKSPACE}" || exit 99
  set -o allexport
  source "${_this_script_dir}/step_run_tests.sh"
)
echo "step exit code: $?"

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
echo ""
echo "Files are kept under ${_tmp}"
