#!/bin/env bash
#
# Source for the lint-with-tflint get-config step.
#
# Resolves which TFLint config file to use: either the caller-configured path
# (absolute, or relative to the working directory) or the first of the
# conventional locations that exists.
#
# Outputs:
#   file - Absolute path of the TFLint config file to use.
#
# Required environment variables:
#   input_working_directory - From what directory to run TFLint.
#
# Optional environment variables:
#   input_config_file_path  - Caller-configured config file path. When empty
#                             the conventional locations are searched.
#

set +o nounset

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  cd "${input_working_directory}"

  local configured_path="${input_config_file_path}"
  local possible_paths=(
    "$(pwd)/.tflint.hcl"
    "${GITHUB_WORKSPACE}/.tflint.hcl"
  )

  local path_to_use=""
  if [ -n "${configured_path}" ]; then
    log-info "using configured TFLint config file path"
    if [ -f "${configured_path}" ]; then
      path_to_use="${configured_path}"
    elif [ -f "$(pwd)/${configured_path}" ]; then
      path_to_use="$(pwd)/${configured_path}"
    else
      log-error "the configured path '${configured_path}' does not exist, unable to perform linting!"
      return 1
    fi
  else
    log-info "TFLint config file path was not configured, attempting to locate one ..."
    local candidate
    for candidate in "${possible_paths[@]}"; do
      if [ -f "${candidate}" ]; then
        path_to_use="${candidate}"
        break
      fi
    done
    if [ ! -f "${path_to_use}" ]; then
      log-error "could not find a TFLint config file to use, unable to perform linting!"
      return 1
    fi
  fi

  log-info "using TFLint config file located at '$(ws-path "${path_to_use}")'"
  set-output 'file' "${path_to_use}"

  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
