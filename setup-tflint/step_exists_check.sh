#!/bin/env bash
#
# Source for the exists-check step of setup-tflint.
#
# Checks whether the tflint binary is already present in the resolved
# install-dir (from a previous run restored by actions/cache). Outputs:
#   already-installed = 'true' iff both the dir AND the binary exist.
# Creates the install-dir if it didn't exist so the install step has
# somewhere to extract the zip.
#
# Required environment variables:
#   input_install_dir       - $RUNNER_TOOL_CACHE/tflint_<tag>
#   input_install_bin_path  - <install_dir>/tflint
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  local already_installed='true'
  if [ -d "${input_install_dir}" ]; then
    log-info "found tflint install dir at '${input_install_dir}'"
  else
    log-info "could not locate tflint install dir at '${input_install_dir}'"
    already_installed='false'
    mkdir -p "${input_install_dir}"
  fi

  if [ -f "${input_install_bin_path}" ]; then
    log-info "found tflint binary at '${input_install_bin_path}'"
  else
    log-info "could not locate tflint binary '${input_install_bin_path}'"
    already_installed='false'
  fi

  set-output 'already-installed' "${already_installed}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
