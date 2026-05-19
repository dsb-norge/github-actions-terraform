#!/bin/env bash
#
# Local runner for step_exists_check.sh. Two-mode demo: first runs against a
# non-existent dir (already-installed=false + dir created), then re-runs
# against the same dir (this time with a pretend binary) to demonstrate
# already-installed=true.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

TEST_DIR=$(mktemp -d)
INSTALL_DIR="${TEST_DIR}/tflint_v0.61.0"
export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export input_install_dir="${INSTALL_DIR}"
export input_install_bin_path="${INSTALL_DIR}/tflint"

echo "--- Run 1: nothing installed yet ---"
set -o allexport
source "${_this_script_dir}/step_exists_check.sh"
set +o allexport
echo "  outputs:"
cat "${GITHUB_OUTPUT}"

# Reset output file, simulate a cached binary, run again
: > "${GITHUB_OUTPUT}"
touch "${INSTALL_DIR}/tflint"
chmod +x "${INSTALL_DIR}/tflint"

echo ""
echo "--- Run 2: binary present at ${INSTALL_DIR}/tflint ---"
set -o allexport
source "${_this_script_dir}/step_exists_check.sh"
set +o allexport
echo "  outputs:"
cat "${GITHUB_OUTPUT}"

rm -rf "${TEST_DIR}" "${GITHUB_OUTPUT}"
