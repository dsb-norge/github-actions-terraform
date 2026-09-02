#!/bin/env bash
#
# Local testing/debugging script for step_resolve.sh
# Simulates GitHub Actions environment for testing locally.
#
# Builds a repo whose environment directory declares only a LOCAL module source
# while the module tree it points at pulls remote modules — the shape the
# local-source walk exists for (docs/Terraform-module-cache.md §2.3) — plus one
# directory that reaches a branch ref and must be excluded.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_STEP_SUMMARY=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"
export RUNNER_OS="Linux"

mkdir -p "${GITHUB_WORKSPACE}/envs/sandbox" \
  "${GITHUB_WORKSPACE}/main" \
  "${GITHUB_WORKSPACE}/modules/floating"

cat >"${GITHUB_WORKSPACE}/envs/sandbox/main.tf" <<'TF'
module "shared" {
  source = "../../main"
}
TF

cat >"${GITHUB_WORKSPACE}/main/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}

module "pinned_git" {
  source = "git::https://example.com/mod.git?ref=v1.2.3"
}
TF

cat >"${GITHUB_WORKSPACE}/modules/floating/main.tf" <<'TF'
module "tracks_a_branch" {
  source = "git::https://example.com/mod.git?ref=main"
}
TF

export input_project_dir="./envs/sandbox"
export input_additional_dirs_json='["./main", "modules/floating"]'
export input_environment="sandbox-env"

echo "=== Running step_resolve.sh ==="
# Source the main script in a subshell so 'exit' doesn't terminate this runner
(source "${_this_script_dir}/step_resolve.sh")
_exit=$?

echo ""
echo "=== GITHUB_OUTPUT ==="
cat "${GITHUB_OUTPUT}"
echo ""
echo "=== excluded dirs ==="
cat "${RUNNER_TEMP}/module-cache-excluded-dirs.txt"
echo ""
echo "=== exit code: ${_exit} ==="
