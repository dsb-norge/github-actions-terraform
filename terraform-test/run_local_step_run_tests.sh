#!/bin/env bash
#
# Local testing/debugging script for step_run_tests.sh
# Simulates the GitHub Actions environment and runs the step against the fake
# terraform binary of the test suite, replaying a JSON log captured from a
# real Terraform. Pass another fixture name (test-data/terraform-1.16.2/) as
# the first argument, e.g. 'fail.json' or 'runerror.json'.
#   bash run_local_step_run_tests.sh [fixture]
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

# Input variables (match what action.yml would export). The fixtures were
# captured from a module root with its tests/ directory.
mkdir -p "${GITHUB_WORKSPACE}/modules/net"
export input_test_file="tests/unit-pass.tftest.hcl"
case "${_fixture}" in
  fail.json) input_test_file="tests/unit-fail.tftest.hcl" ;;
  runerror.json) input_test_file="tests/unit-runerror.tftest.hcl" ;;
  fileerror.json) input_test_file="tests/unit-fileerror.tftest.hcl" ;;
  unknownprov.json) input_test_file="tests/unit-unknownprov.tftest.hcl" ;;
  filtermiss.json) input_test_file="tests/nosuch.tftest.hcl" ;;
  emptyroot-mock.json | modnotinstalled.json) input_test_file="tests/unit-mod.tftest.hcl" ;;
esac
export input_working_directory="modules/net"
export input_junit="true"
export input_slug="modules-net--local"
export input_status_credentials=""
export input_status_lock=""
export input_status_init="success"
export input_environments_lock_file="envs/prod/.terraform.lock.hcl"

# The lock init would have written, and the environment lock it was copied from
cp "${_this_script_dir}/test-data/terraform-1.16.2/written.lock.hcl" "${GITHUB_WORKSPACE}/modules/net/.terraform.lock.hcl"
mkdir -p "${GITHUB_WORKSPACE}/envs/prod"
cp "${_this_script_dir}/test-data/terraform-1.16.2/copied.lock.hcl" "${GITHUB_WORKSPACE}/envs/prod/.terraform.lock.hcl"

# Source the step in a subshell so 'exit' doesn't terminate this runner
(
  cd "${GITHUB_WORKSPACE}" || exit 99
  set -eo pipefail
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
echo "========================================"
echo "Step summary:"
echo "========================================"
cat "${GITHUB_STEP_SUMMARY}"
echo "Files are kept under ${_tmp}"
