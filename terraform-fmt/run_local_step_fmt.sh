#!/bin/env bash
#
# Local testing/debugging script for step_fmt.sh.
# Simulates GitHub Actions environment using a stub 'terraform' binary and a
# fake '.terraform/modules/modules.json'.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

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

STUB_DIR="${RUNNER_TEMP}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/terraform" <<'EOF'
#!/bin/env bash
echo "stub terraform received ${#} argument(s):"
for arg in "${@}"; do
  echo "  - '${arg}'"
done
exit 0
EOF
chmod +x "${STUB_DIR}/terraform"
export TF_BIN="${STUB_DIR}/terraform"

export input_working_directory="${WORK_DIR}"
export input_format_check_in_root_dir="false"

source "${_this_script_dir}/step_fmt.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
