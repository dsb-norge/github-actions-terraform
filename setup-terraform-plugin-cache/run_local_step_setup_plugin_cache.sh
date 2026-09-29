#!/bin/env bash
#
# Local testing/debugging script for step_setup_plugin_cache.sh.
# Simulates the GitHub Actions environment with a throwaway HOME, so the
# real ~/.terraformrc is never touched.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export HOME=$(mktemp -d)
export RUNNER_OS="Linux"
export RUNNER_ARCH="X64"

(
  set -o allexport
  source "${_this_script_dir}/step_setup_plugin_cache.sh"
)
echo "exit code: $?"
echo "--- GITHUB_OUTPUT ---"
cat "${GITHUB_OUTPUT}"
echo "--- ${HOME}/.terraformrc ---"
cat "${HOME}/.terraformrc"
rm -rf "${HOME}" "${GITHUB_OUTPUT}"
