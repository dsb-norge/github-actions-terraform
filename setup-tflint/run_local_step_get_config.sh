#!/bin/env bash
#
# Local runner for step_get_config.sh.
# Creates a temp working dir with a sample .tflint.hcl and runs the step.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"

TEST_DIR=$(mktemp -d)
echo "plugin \"terraform\" { enabled = true }" > "${TEST_DIR}/.tflint.hcl"
export GITHUB_WORKSPACE="${TEST_DIR}"
export input_config_file_path=""
export input_working_directory="${TEST_DIR}"

set -o allexport
source "${_this_script_dir}/step_get_config.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
rm -rf "${TEST_DIR}" "${GITHUB_OUTPUT}"
