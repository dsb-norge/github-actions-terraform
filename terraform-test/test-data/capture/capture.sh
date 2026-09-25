#!/bin/env bash
#
# Captures the Terraform JSON logs the terraform-test suite replays, from a
# real Terraform and the public registry. Only credential-free providers
# (null, random, time) and mock_provider are used.
#
#   bash capture.sh [fixture ...]
#
# Writes into ../terraform-<version>/ (the version 'terraform version' reports);
# with no arguments every fixture is written, else only the named ones (file
# names without directory, e.g. pass.json written.lock.hcl). Re-capturing
# changes timestamps, so re-capture only what a change needs.
#
# Sources: module/ (a module with a tests/ directory), envprod/ (an
# environment whose lock pins older providers), emptyroot/ (a repository-root
# tests/ directory whose run block names ./mod). Every other case is derived
# from those in a scratch copy below.
#

set -o errexit -o nounset -o pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
version="$(terraform version -json | jq -r '.terraform_version')"
out="${_here}/../terraform-${version}"
mkdir -p "${out}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export TF_IN_AUTOMATION=true
unset TF_PLUGIN_CACHE_DIR TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE TF_CLI_ARGS_test

wanted=("$@")
want() {
  [ ${#wanted[@]} -eq 0 ] && return 0
  local name
  for name in "${wanted[@]}"; do
    [ "${name}" == "${1}" ] && return 0
  done
  return 1
}

# tf_test <dir> <filter> <fixture base name> [junit]
tf_test() {
  local dir="${1}" filter="${2}" name="${3}" junit="${4:-}"
  want "${name}.json" || return 0
  local junit_arg=()
  [ -n "${junit}" ] && junit_arg=("-junit-xml=${work}/${name}.junit.xml")
  (cd "${dir}" && terraform test -json -no-color "-filter=${filter}" "${junit_arg[@]}" >"${out}/${name}.json" 2>&1) || true
  if [ -n "${junit}" ] && [ -f "${work}/${name}.junit.xml" ]; then
    cp "${work}/${name}.junit.xml" "${out}/${name}.junit.xml"
  fi
  echo "captured ${name}.json"
}

init() { (cd "${1}" && terraform init -no-color "${@:2}" >/dev/null); }

want version.json && terraform version -json >"${out}/version.json"

# A module root, initialised: pass, assertion failure, run error with a
# skipped follower, file-level errors, a filter that matches nothing.
cp -r "${_here}/module" "${work}/module"
init "${work}/module"
tf_test "${work}/module" tests/unit-pass.tftest.hcl pass junit
tf_test "${work}/module" tests/unit-fail.tftest.hcl fail junit
tf_test "${work}/module" tests/unit-runerror.tftest.hcl runerror
tf_test "${work}/module" tests/unit-fileerror.tftest.hcl fileerror
tf_test "${work}/module" tests/nosuch.tftest.hcl filtermiss

# File-level error: a mock_provider for a provider nothing requires is not
# installed, and the file errors with "unknown provider" before any run.
cp -r "${work}/module" "${work}/unknownprov"
cat >"${work}/unknownprov/tests/unit-unknownprov.tftest.hcl" <<'HCL'
mock_provider "time" {}
run "uses_time" {
  command   = plan
  providers = { time = time }
}
HCL
tf_test "${work}/unknownprov" tests/unit-unknownprov.tftest.hcl unknownprov

# A parse error in a sibling test file, added after init: no test_abstract.
cp -r "${work}/module" "${work}/invalid"
cat >"${work}/invalid/tests/unit-broken.tftest.hcl" <<'HCL'
run "broken" {
  command = plan
  assert {
    condition =
  }
}
HCL
tf_test "${work}/invalid" tests/unit-pass.tftest.hcl invalid

# Not initialised, four ways.
# 1. Never initialised: the run errors with "Missing required provider".
mkdir -p "${work}/noinit/tests"
cp "${_here}/module/main.tf" "${work}/noinit/"
cp "${_here}/module/tests/unit-pass.tftest.hcl" "${work}/noinit/tests/"
tf_test "${work}/noinit" tests/unit-pass.tftest.hcl noinit
# 2. An empty root whose run block names a module, never initialised.
mkdir -p "${work}/emptyroot-noinit/tests" "${work}/emptyroot-noinit/mod"
cp "${_here}/module/main.tf" "${work}/emptyroot-noinit/mod/"
cp "${_here}/emptyroot/tests/unit-mod.tftest.hcl" "${work}/emptyroot-noinit/tests/"
tf_test "${work}/emptyroot-noinit" tests/unit-mod.tftest.hcl modnotinstalled
# 3. One provider package removed after init: "there is no package for".
cp -r "${work}/module" "${work}/nopackage"
rm -rf "${work}/nopackage/.terraform/providers/registry.terraform.io/hashicorp/random"
tf_test "${work}/nopackage" tests/unit-pass.tftest.hcl nopackage
# 4. Every provider missing: "missing or corrupted provider plugins" (what a
#    read-only init against a lock without the runner's platform leaves).
cp -r "${work}/module" "${work}/corrupted"
rm -rf "${work}/corrupted/.terraform/providers"
tf_test "${work}/corrupted" tests/unit-pass.tftest.hcl corruptedplugins
# 5. A lock whose checksums do not match the installed package.
cp -r "${work}/module" "${work}/badhash"
sed -i '/provider "registry.terraform.io\/hashicorp\/random"/,/^}/{s/"h1:[^"]*"/"h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="/;/"zh:/d}' "${work}/badhash/.terraform.lock.hcl"
tf_test "${work}/badhash" tests/unit-pass.tftest.hcl checksummismatch

# An empty root with mock providers, initialised: passes.
mkdir -p "${work}/emptyroot/tests" "${work}/emptyroot/mod"
cp "${_here}/module/main.tf" "${work}/emptyroot/mod/"
cp "${_here}/emptyroot/tests/unit-mod.tftest.hcl" "${work}/emptyroot/tests/"
init "${work}/emptyroot"
tf_test "${work}/emptyroot" tests/unit-mod.tftest.hcl emptyroot-mock

# Provider versions from an environment: envprod's lock (null 3.2.3,
# time 0.12.1) copied into the module root before init. Init keeps null at
# 3.2.3, drops time and adds random at its newest (floating).
cp -r "${_here}/envprod" "${work}/envprod"
init "${work}/envprod"
mkdir -p "${work}/lockroot/tests"
cp "${_here}/module/main.tf" "${work}/lockroot/"
cp "${_here}/module/tests/unit-pass.tftest.hcl" "${work}/lockroot/tests/"
cp "${work}/envprod/.terraform.lock.hcl" "${work}/lockroot/.terraform.lock.hcl"
init "${work}/lockroot"
tf_test "${work}/lockroot" tests/unit-pass.tftest.hcl lockroot
want copied.lock.hcl && cp "${work}/envprod/.terraform.lock.hcl" "${out}/copied.lock.hcl"
want written.lock.hcl && cp "${work}/lockroot/.terraform.lock.hcl" "${out}/written.lock.hcl"

echo "fixtures in ${out}"
