#!/bin/env bash
#
# Local testing/debugging script for step_verify.sh
# Simulates GitHub Actions environment for testing locally.
#
# Sets up an exact-hit scenario where init both changed the module set (so the
# completeness check fires) and resolved a transitive branch ref that the
# pre-init audit could not have seen (so the save gate refuses).
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

MODULES_DIR="${GITHUB_WORKSPACE}/envs/sandbox/.terraform/modules"
SNAPSHOT_DIR="${RUNNER_TEMP}/module-cache-manifests"
mkdir -p "${MODULES_DIR}" "${SNAPSHOT_DIR}"

# Before-image: what the restore put on disk.
cat >"${SNAPSHOT_DIR}/envs_sandbox_terraform_modules.json" <<'JSON'
{"Modules":[
  {"Key":"parent","Source":"git::https://example.com/p.git?ref=v1.0.0","Dir":".terraform/modules/parent"}
]}
JSON

# After init: an extra module appeared, and it tracks a branch.
cat >"${MODULES_DIR}/modules.json" <<'JSON'
{"Modules":[
  {"Key":"parent","Source":"git::https://example.com/p.git?ref=v1.0.0","Dir":".terraform/modules/parent"},
  {"Key":"parent.child","Source":"git::https://example.com/c.git?ref=main","Dir":".terraform/modules/parent.child"}
]}
JSON

export input_cache_paths="envs/sandbox/.terraform/modules"
export input_cache_hit="true"
export input_snapshot_dir="${SNAPSHOT_DIR}"

echo "=== Running step_verify.sh ==="
# Source the main script in a subshell so 'exit' doesn't terminate this runner
(source "${_this_script_dir}/step_verify.sh")
_exit=$?

echo ""
echo "=== GITHUB_OUTPUT ==="
cat "${GITHUB_OUTPUT}"
echo ""
echo "=== exit code: ${_exit} ==="
