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

# Per-goal environment variables, as resolve-goal-envs would produce them.
# GOMEMLIMIT is set, and a variable that exists job-wide is unset by a JSON null
# — something $GITHUB_ENV cannot express.
export DSB_LEAKY_VAR="value-from-the-job"
export DSB_UNSET_ME="also-from-the-job"
export input_extra_envs_file="${RUNNER_TEMP}/extra-envs.json"
cat >"${input_extra_envs_file}" <<'EOF'
{
  "GOMEMLIMIT": "12GiB",
  "GOGC": 25,
  "DSB_LEAKY_VAR": "value-from-the-goal",
  "DSB_UNSET_ME": null
}
EOF

# Subshell: the step script ends in 'exit', which would otherwise
# terminate this runner before it can show anything. It is also what
# makes the scoping check below meaningful — the step's exports die
# with the subshell, exactly as they do when the GitHub step ends.
( source "${_this_script_dir}/step_lint.sh" )
echo ""
echo "step exit code: ${?}"


echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"

echo ""
echo "========================================"
echo "Scoping check (values must NOT leak out)"
echo "========================================"
echo "GOMEMLIMIT after the step:    '${GOMEMLIMIT:-<unset>}'  (expected: <unset>)"
echo "DSB_LEAKY_VAR after the step: '${DSB_LEAKY_VAR:-<unset>}'  (expected: value-from-the-job)"
echo "DSB_UNSET_ME after the step:  '${DSB_UNSET_ME:-<unset>}'  (expected: also-from-the-job)"
