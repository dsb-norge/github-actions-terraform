#!/bin/env bash
#
# Local testing/debugging script for step_apply.sh.
# Simulates GitHub Actions environment using a stub 'terraform' binary.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

WORK_DIR="${RUNNER_TEMP}/envs/sandbox"
mkdir -p "${WORK_DIR}"

PLAN_FILE="${GITHUB_WORKSPACE}/tf-plan-sandbox.plan"
echo 'fake binary plan' >"${PLAN_FILE}"

STUB_DIR="${RUNNER_TEMP}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/terraform" <<'EOF'
#!/bin/env bash
echo "stub terraform received ${#} argument(s):"
for arg in "${@}"; do
  echo "  - '${arg}'"
done
echo "Apply complete! Resources: 1 added, 0 changed, 0 destroyed."
exit 0
EOF
chmod +x "${STUB_DIR}/terraform"
export TF_BIN="${STUB_DIR}/terraform"

export input_working_directory="${WORK_DIR}"
export input_terraform_plan_file="${PLAN_FILE}"

source "${_this_script_dir}/step_apply.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
