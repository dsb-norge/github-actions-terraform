#!/bin/env bash
#
# Source for the get-config step of setup-tflint.
#
# Locates a TFLint config file (.tflint.hcl). Either uses the caller-provided
# `config-file-path` or searches the working directory and $GITHUB_WORKSPACE.
# Emits the resolved path as the 'config-file' output (may be empty when no
# config could be located — the hashFiles() in the plugin cache key gracefully
# handles that).
#
# Required environment variables:
#   input_config_file_path  - explicit path (may be empty)
#   input_working_directory - cwd to use when searching for .tflint.hcl
#   GITHUB_WORKSPACE        - workspace root (fallback search location)
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  # Honor the action.yml `working-directory:` semantics by cd'ing.
  cd "${input_working_directory}" || {
    log-error "cannot cd to working directory '${input_working_directory}'"
    return 1
  }

  local configured_path="${input_config_file_path}"
  local -a possible_paths=(
    "$(pwd)/.tflint.hcl"
    "${GITHUB_WORKSPACE}/.tflint.hcl"
  )

  # Allow output to be empty — hashFiles('') in the plugin cache key just
  # produces an empty hash, which is benign.
  local path_to_use=""
  if [ -n "${configured_path}" ]; then
    log-info "using configured TFLint config file path"
    if [ -f "${configured_path}" ]; then
      path_to_use="${configured_path}"
    elif [ -f "$(pwd)/${configured_path}" ]; then
      path_to_use="$(pwd)/${configured_path}"
    else
      log-warn "the configured path '${configured_path}' does not exist, unable to conform to configuration!"
    fi
  else
    log-info "TFLint config file path was not configured, attempting to locate one ..."
    for path_to_use in "${possible_paths[@]}"; do
      [ -f "${path_to_use}" ] && break || :
    done
    if [ ! -f "${path_to_use}" ]; then
      # NOTE: preserves the pre-conversion behavior of leaving path_to_use
      # set to the last for-loop value when nothing matched. The plugin
      # cache-key in the calling workflow uses hashFiles() which tolerates
      # non-existent paths (empty hash). If we ever want to clean this up,
      # do it in a separate, intentional commit.
      log-warn "could not find a TFLint config file to use, unable to conform to configuration!"
    fi
  fi
  log-info "using TFLint config file path '${path_to_use}'"
  set-output 'config-file' "${path_to_use}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
