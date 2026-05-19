#!/bin/env bash
#
# Local runner for step_get_meta.sh.
# Hits the real GitHub Releases API by default; pass tflint-version on the
# command line, e.g. `bash run_local_step_get_meta.sh v0.61.0`.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"

export input_tflint_version="${1:-latest}"
export input_github_token="${GH_TOKEN:-}"
export input_runner_tool_cache="${RUNNER_TOOL_CACHE:-/tmp/runner-tool-cache}"
export input_runner_os="Linux"
export input_runner_arch="X64"

set -o allexport
source "${_this_script_dir}/step_get_meta.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
rm -f "${GITHUB_OUTPUT}"
