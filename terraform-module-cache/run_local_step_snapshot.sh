#!/bin/env bash
#
# Local testing/debugging script for step_snapshot.sh
# Simulates GitHub Actions environment for testing locally.
#
# Lays down a restored-looking modules.json and takes its before-image.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

mkdir -p "${GITHUB_WORKSPACE}/envs/sandbox/.terraform/modules"
cat >"${GITHUB_WORKSPACE}/envs/sandbox/.terraform/modules/modules.json" <<'JSON'
{"Modules":[
  {"Key":"","Source":"","Dir":"."},
  {"Key":"naming","Source":"registry.terraform.io/Azure/naming/azurerm","Version":"0.4.2","Dir":".terraform/modules/naming"}
]}
JSON

export input_cache_paths="envs/sandbox/.terraform/modules"
export input_cache_hit="true"

echo "=== Running step_snapshot.sh ==="
# Source the main script in a subshell so 'exit' doesn't terminate this runner
(source "${_this_script_dir}/step_snapshot.sh")
_exit=$?

echo ""
echo "=== GITHUB_OUTPUT ==="
cat "${GITHUB_OUTPUT}"
echo ""
echo "=== snapshots taken ==="
ls -la "${RUNNER_TEMP}/module-cache-manifests"
echo ""
echo "=== exit code: ${_exit} ==="
