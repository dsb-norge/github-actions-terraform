#!/bin/env bash
#
# Local testing/debugging script for step_get_config.sh.
# Simulates GitHub Actions environment.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}/workspace"

WORK_DIR="${GITHUB_WORKSPACE}/envs/sandbox"
mkdir -p "${WORK_DIR}"

# Only a repo-root config exists, so the fallback search should find it there.
cat >"${GITHUB_WORKSPACE}/.tflint.hcl" <<'EOF'
plugin "terraform" {
  enabled = true
}
EOF

export input_working_directory="${WORK_DIR}"
export input_config_file_path=""

source "${_this_script_dir}/step_get_config.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
