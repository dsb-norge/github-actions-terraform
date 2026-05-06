#!/bin/env bash
#
# Local testing/debugging script for step_verify_lock.sh
# Simulates GitHub Actions environment for testing locally.
#
# Sets up a fake project directory with a .terraform.lock.hcl and a stub
# 'terraform' binary, then runs the step.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT and step summary like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export GITHUB_STEP_SUMMARY=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

# Build a fake working directory with a sample lock file and an empty
# .terraform/ directory (simulates a prior 'terraform init').
WORK_DIR="${RUNNER_TEMP}/envs/sandbox"
mkdir -p "${WORK_DIR}/.terraform"
cat >"${WORK_DIR}/.terraform.lock.hcl" <<'EOF'
# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.

provider "registry.terraform.io/hashicorp/null" {
  version = "3.2.2"
  hashes = [
    "h1:linux_amd64hash==",
  ]
}
EOF

# Stub terraform binary that does not modify the lock file (success case).
# Swap to the "modify" variant below to simulate a missing-platform failure.
STUB_DIR="${RUNNER_TEMP}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/terraform" <<'EOF'
#!/bin/env bash
# Stub: pretend providers lock ran and changed nothing.
echo "stub terraform $*"
exit 0
EOF
chmod +x "${STUB_DIR}/terraform"
export TF_BIN="${STUB_DIR}/terraform"

# Required input variables
export input_working_directory="${WORK_DIR}"
export input_platforms="linux_amd64
linux_arm64
darwin_arm64"

# Source the main script
source "${_this_script_dir}/step_verify_lock.sh"

# Display GitHub Actions outputs and step summary
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"

echo ""
echo "========================================"
echo "Step Summary (GITHUB_STEP_SUMMARY):"
echo "========================================"
cat "${GITHUB_STEP_SUMMARY}"
