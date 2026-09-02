#!/bin/env bash
#
# Local testing/debugging script for step_prune.sh
# Simulates GitHub Actions environment for testing locally.
#
# Lays down a module tree shaped like the one terraform leaves behind — a
# manifest, module sources, a '.git' directory from the clone and a '.git'
# gitlink file from the submodule update — and prunes it.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE=$(mktemp -d)

_modules="${GITHUB_WORKSPACE}/envs/sandbox/.terraform/modules"
mkdir -p "${_modules}/naming/.git/objects" "${_modules}/naming/vendored"
cat >"${_modules}/modules.json" <<'JSON'
{"Modules":[
  {"Key":"","Source":"","Dir":"."},
  {"Key":"naming","Source":"registry.terraform.io/Azure/naming/azurerm","Version":"0.4.2","Dir":".terraform/modules/naming"}
]}
JSON
echo 'output "name" { value = "x" }' >"${_modules}/naming/main.tf"
head -c 200000 /dev/urandom >"${_modules}/naming/.git/objects/pack"
# What 'git submodule update' leaves for a nested checkout: a file, not a dir.
echo 'gitdir: ../../.git/modules/vendored' >"${_modules}/naming/vendored/.git"

# The repository's own metadata, which must survive untouched.
mkdir -p "${GITHUB_WORKSPACE}/.git"
echo 'the repository itself' >"${GITHUB_WORKSPACE}/.git/HEAD"

export input_cache_paths="envs/sandbox/.terraform/modules"

echo "=== before ==="
find "${GITHUB_WORKSPACE}" -name .git | sed "s|${GITHUB_WORKSPACE}|.|"
du -sk "${_modules}"

echo ""
echo "=== Running step_prune.sh ==="
# In a subshell: the step script ends in 'exit', which sourced directly would
# end this script too and take everything printed below with it.
(source "${_this_script_dir}/step_prune.sh")
_exit=$?

echo ""
echo "=== GITHUB_OUTPUT ==="
cat "${GITHUB_OUTPUT}"
echo ""
echo "=== after ==="
find "${GITHUB_WORKSPACE}" -name .git | sed "s|${GITHUB_WORKSPACE}|.|"
du -sk "${_modules}"
echo ""
echo "=== the module and its manifest are still there ==="
ls "${_modules}" "${_modules}/naming"
echo ""
echo "=== exit code: ${_exit} ==="
