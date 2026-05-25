#!/bin/env bash
#
# Local testing/debugging script for step_validate.sh.
# Simulates GitHub Actions environment using a stub 'terraform' binary.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

WORK_DIR="${RUNNER_TEMP}/envs/sandbox"
mkdir -p "${WORK_DIR}"

STUB_DIR="${RUNNER_TEMP}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/terraform" <<'EOF'
#!/bin/env bash
echo "stub terraform $*"
echo "Success! The configuration is valid."
exit 0
EOF
chmod +x "${STUB_DIR}/terraform"
export TF_BIN="${STUB_DIR}/terraform"

export input_working_directory="${WORK_DIR}"
export input_environment_name="sandbox"

source "${_this_script_dir}/step_validate.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
echo ""
echo "========================================"
echo "Console-output file contents:"
echo "========================================"
console_file=$(grep '^tf-validate-console-output-file=' "${GITHUB_OUTPUT}" | cut -d= -f2-)
cat "${console_file}" 2>/dev/null || echo "(missing)"
