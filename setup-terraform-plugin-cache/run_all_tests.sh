#!/bin/env bash
#
# Test runner for step_setup_plugin_cache.sh (setup-terraform-plugin-cache).
# Every test runs the step in a subshell with a throwaway HOME.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# The step's output, one file per run of this suite: a fixed path in /tmp is
# shared with every other suite that uses it, and suites run in parallel.
_test_output=$(mktemp)
trap 'rm -f "${_test_output}"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# Runs the step with the given HOME, RUNNER_OS and RUNNER_ARCH; sets STEP_EXIT.
run_step() {
  local home="${1}" os="${2:-Linux}" arch="${3:-X64}"
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  (
    export HOME="${home}" RUNNER_OS="${os}" RUNNER_ARCH="${arch}"
    set -o allexport
    source "${_this_script_dir}/step_setup_plugin_cache.sh"
  ) >"${_test_output}" 2>&1
  STEP_EXIT=$?
}

output() {
  sed -n "s/^${1}=//p" "${GITHUB_OUTPUT}"
}

check() {
  local name="${1}"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "$@"; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    sed 's/^/    /' "${_test_output}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -f "${GITHUB_OUTPUT}"
}

key_for() {
  echo "terraform-provider-plugin-cache-${1}-${2}-$(date +%b)-$(date +%y)"
}

test_fresh_home() {
  local home; home=$(mktemp -d)
  run_step "${home}"
  local ok=0
  [ "${STEP_EXIT}" -eq 0 ] || { echo "    exit ${STEP_EXIT}"; ok=1; }
  [ -d "${home}/.terraform.d/plugin-cache" ] || { echo "    no cache directory"; ok=1; }
  [ "$(cat "${home}/.terraformrc")" = "plugin_cache_dir = \"${home}/.terraform.d/plugin-cache\"" ] \
    || { echo "    wrong .terraformrc"; ok=1; }
  [ "$(output plugin-cache-directory)" = "${home}/.terraform.d/plugin-cache" ] || { echo "    wrong directory output"; ok=1; }
  [ "$(output monthly-rolling)" = "$(key_for linux x64)" ] || { echo "    wrong key: $(output monthly-rolling)"; ok=1; }
  rm -rf "${home}"
  return ${ok}
}

test_existing_config_is_overwritten_with_a_warning() {
  local home; home=$(mktemp -d)
  mkdir -p "${home}/.terraform.d/plugin-cache"
  echo 'plugin_cache_dir = "/somewhere/else"' >"${home}/.terraformrc"
  run_step "${home}"
  local ok=0
  [ "${STEP_EXIT}" -eq 0 ] || { echo "    exit ${STEP_EXIT}"; ok=1; }
  grep -q "nothing to do, plugin cache directory already exists." "${_test_output}" || { echo "    no 'already exists'"; ok=1; }
  grep -q "Overwriting existing Terraform CLI Configuration file!" "${_test_output}" || { echo "    no overwrite warning"; ok=1; }
  grep -q '/somewhere/else' "${_test_output}" || { echo "    the old content was not logged"; ok=1; }
  [ "$(cat "${home}/.terraformrc")" = "plugin_cache_dir = \"${home}/.terraform.d/plugin-cache\"" ] \
    || { echo "    .terraformrc not replaced"; ok=1; }
  rm -rf "${home}"
  return ${ok}
}

test_the_key_lower_cases_the_platform() {
  local home; home=$(mktemp -d)
  run_step "${home}" macOS ARM64
  local ok=0
  [ "$(output monthly-rolling)" = "$(key_for macos arm64)" ] || { echo "    wrong key: $(output monthly-rolling)"; ok=1; }
  rm -rf "${home}"
  return ${ok}
}

test_an_unwritable_home_fails() {
  local home; home=$(mktemp -d)
  # A file where the cache's parent directory would go: mkdir -p cannot create it.
  echo "not a directory" >"${home}/.terraform.d"
  run_step "${home}"
  local ok=0
  [ "${STEP_EXIT}" -eq 1 ] || { echo "    exit ${STEP_EXIT}, expected 1"; ok=1; }
  grep -q "could not create the plugin cache directory" "${_test_output}" || { echo "    no error"; ok=1; }
  [ -z "$(output plugin-cache-directory)" ] || { echo "    an output was set"; ok=1; }
  rm -rf "${home}"
  return ${ok}
}

test_an_unwritable_config_fails() {
  local home; home=$(mktemp -d)
  mkdir -p "${home}/.terraformrc"
  run_step "${home}"
  local ok=0
  [ "${STEP_EXIT}" -eq 1 ] || { echo "    exit ${STEP_EXIT}, expected 1"; ok=1; }
  grep -q "could not write the Terraform CLI Configuration file" "${_test_output}" || { echo "    no error"; ok=1; }
  [ -z "$(output monthly-rolling)" ] || { echo "    a key was set"; ok=1; }
  rm -rf "${home}"
  return ${ok}
}

test_the_shim() {
  local action="${_this_script_dir}/action.yml" ok=0
  local run; run=$(yq '.runs.steps[0].run' "${action}")
  [ "$(head -n1 <<<"${run}")" = "# Configure the terraform provider plugin cache directory and a monthly rolling cache key" ] \
    || { echo "    the run block does not open with its description comment"; ok=1; }
  grep -qx 'source "${{ github.action_path }}/step_setup_plugin_cache.sh"' <<<"${run}" || { echo "    does not source the step"; ok=1; }
  grep -qx 'set -o allexport' <<<"${run}" || { echo "    no allexport"; ok=1; }
  [ "$(yq '.runs.steps | length' "${action}")" = "1" ] || { echo "    more than one step"; ok=1; }
  [ "$(yq '.outputs.plugin-cache-directory.value' "${action}")" = '${{ steps.setup.outputs.plugin-cache-directory }}' ] \
    || { echo "    plugin-cache-directory not mapped"; ok=1; }
  [ "$(yq '.outputs.plugin-cache-key-monthly-rolling.value' "${action}")" = '${{ steps.setup.outputs.monthly-rolling }}' ] \
    || { echo "    plugin-cache-key-monthly-rolling not mapped"; ok=1; }
  return ${ok}
}

check "a fresh home: the directory, .terraformrc and both outputs" test_fresh_home
check "an existing directory and config: config replaced, with a warning and the old content" test_existing_config_is_overwritten_with_a_warning
check "the key lower-cases the runner's OS and architecture" test_the_key_lower_cases_the_platform
check "a directory that cannot be created fails the step, no outputs" test_an_unwritable_home_fails
check "a config that cannot be written fails the step, no key" test_an_unwritable_config_fails
check "the shim: one step, its description comment, the step script, the outputs" test_the_shim

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}   SETUP-TERRAFORM-PLUGIN-CACHE SUMMARY     ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""
[ "${TESTS_FAILED}" -eq 0 ]
