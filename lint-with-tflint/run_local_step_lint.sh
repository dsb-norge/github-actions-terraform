#!/bin/env bash
#
# Local testing/debugging script for step_lint.sh.
# Simulates GitHub Actions environment using a stub 'tflint' binary and a
# fake '.terraform/modules/modules.json'.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}/workspace"

WORK_DIR="${GITHUB_WORKSPACE}/envs/sandbox"
mkdir -p "${WORK_DIR}/.terraform/modules"
mkdir -p "${WORK_DIR}/modules/network" "${WORK_DIR}/modules/storage account"

cat >"${WORK_DIR}/.terraform/modules/modules.json" <<'EOF'
{
  "Modules": [
    { "Key": "", "Source": "", "Dir": "." },
    { "Key": "network", "Source": "./modules/network", "Dir": "modules/network" },
    { "Key": "storage", "Source": "./modules/storage account", "Dir": "modules/storage account" },
    { "Key": "vendored", "Source": "registry.example.com/foo", "Dir": ".terraform/modules/vendored" }
  ]
}
EOF

cat >"${GITHUB_WORKSPACE}/.tflint.hcl" <<'EOF'
plugin "terraform" {
  enabled = true
}
EOF

STUB_DIR="${RUNNER_TEMP}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/tflint" <<'EOF'
#!/bin/env bash
echo "stub tflint received ${#} argument(s):"
for arg in "${@}"; do
  echo "  - '${arg}'"
done
exit 0
EOF
chmod +x "${STUB_DIR}/tflint"
export TFLINT_BIN="${STUB_DIR}/tflint"

export input_working_directory="${WORK_DIR}"
export input_config_file="${GITHUB_WORKSPACE}/.tflint.hcl"

source "${_this_script_dir}/step_lint.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
