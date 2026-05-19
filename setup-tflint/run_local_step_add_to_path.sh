#!/bin/env bash
#
# Local runner for step_add_to_path.sh.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

TEST_DIR=$(mktemp -d)
export GITHUB_OUTPUT=$(mktemp)
export GITHUB_PATH=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export input_install_dir="${TEST_DIR}"

set -o allexport
source "${_this_script_dir}/step_add_to_path.sh"
set +o allexport

echo ""
echo "GITHUB_PATH appended with:"
cat "${GITHUB_PATH}"

rm -rf "${TEST_DIR}" "${GITHUB_OUTPUT}" "${GITHUB_PATH}"
