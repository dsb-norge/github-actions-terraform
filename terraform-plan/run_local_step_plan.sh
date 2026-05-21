#!/bin/env bash
#
# Local testing/debugging script for step_plan.sh.
# Simulates GitHub Actions environment using a stub 'terraform' binary,
# so no real terraform install or backend is needed.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

WORK_DIR="${RUNNER_TEMP}/envs/sandbox"
mkdir -p "${WORK_DIR}"

# Stub terraform that exits 2 (success-with-changes) after a short sleep
# so the plan-time output is non-zero.
STUB_DIR="${RUNNER_TEMP}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/terraform" <<'EOF'
#!/bin/env bash
echo "stub terraform $*"
echo "Plan: 1 to add, 0 to change, 0 to destroy."
sleep 1
exit 2
EOF
chmod +x "${STUB_DIR}/terraform"
export TF_BIN="${STUB_DIR}/terraform"

export input_working_directory="${WORK_DIR}"
export input_environment_name="sandbox"
export input_extra_global_args=""
export input_extra_plan_args=""

source "${_this_script_dir}/step_plan.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
