#!/bin/env bash
#
# Local testing/debugging script for step_init.sh.
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

# An additional dir relative to GITHUB_WORKSPACE so the multi-dir branch
# also gets exercised when the local harness runs.
EXTRA_DIR_REL="modules/foo"
mkdir -p "${GITHUB_WORKSPACE}/${EXTRA_DIR_REL}"

STUB_DIR="${RUNNER_TEMP}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/terraform" <<'EOF'
#!/bin/env bash
echo "stub terraform $*"
echo "Initializing..."
exit 0
EOF
chmod +x "${STUB_DIR}/terraform"
export TF_BIN="${STUB_DIR}/terraform"

export input_working_directory="${WORK_DIR}"
export input_environment_name="sandbox"
export input_additional_dirs_json="[\"${EXTRA_DIR_REL}\"]"
export input_plugin_cache_directory=""

source "${_this_script_dir}/step_init.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
echo ""
echo "========================================"
echo "Console-output file contents:"
echo "========================================"
console_file=$(grep '^tf-init-console-output-file=' "${GITHUB_OUTPUT}" | cut -d= -f2-)
cat "${console_file}" 2>/dev/null || echo "(missing)"
