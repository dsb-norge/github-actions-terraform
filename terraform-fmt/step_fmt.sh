#!/bin/env bash
#
# Source for the terraform-fmt main step.
#
# Runs 'terraform fmt -check -recursive' in one or more directories:
#   1. the repository root, if 'format-check-in-root-dir' is 'true'
#   2. otherwise every module directory terraform recorded in
#      '<project-dir>/.terraform/modules/modules.json' during init
#   3. otherwise just the project directory
#
# Exits with the sum of the per-directory exit codes so a failure anywhere
# surfaces as a failing step.
#
# Required environment variables:
#   input_working_directory        - Where to invoke terraform.
#   input_format_check_in_root_dir - 'true' to check from the repository root.
#
# Optional environment variables:
#   TF_BIN - Path to the terraform binary (defaults to 'terraform' on PATH).
#            Used by tests to inject a stub.
#

set +o nounset

# Load helpers (provides read-terraform-module-dirs via helpers_additional.sh)
source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  local tf_bin="${TF_BIN:-terraform}"

  cd "${input_working_directory}"

  # Where to check?
  local modules_file="$(pwd)/.terraform/modules/modules.json"
  local fmt_dirs=()
  if [ "${input_format_check_in_root_dir}" == 'true' ]; then
    log-info "check will run from root directory."
    fmt_dirs=("${GITHUB_WORKSPACE}")
  elif [ -f "${modules_file}" ]; then
    log-info "check will run in directories from terraform modules file '$(ws-path "${modules_file}")'"
    read-terraform-module-dirs fmt_dirs "${modules_file}" "$(pwd)/"
  else
    log-info "check will run in 'project-dir' '$(pwd)'"
    fmt_dirs=("$(pwd)")
  fi

  # Run check
  declare -A fmt_results
  local fmt_dir
  for fmt_dir in "${fmt_dirs[@]}"; do
    log-info "running in: '$(ws-path "${fmt_dir}")'"

    # Array-built invocation so a directory path containing a space or a
    # glob character reaches terraform as exactly one argument.
    local fmt_cmd=("${tf_bin}" "-chdir=${fmt_dir}" fmt -check -recursive)
    log-info "command string is '${fmt_cmd[*]@Q}'"

    set +e
    "${fmt_cmd[@]}"
    local fmt_exit=${?}
    fmt_results["${fmt_dir}"]="${fmt_exit}"
    if [ ! "${fmt_exit}" == "0" ]; then
      log-error "fmt exited with code '${fmt_exit}'!"
    fi
  done

  # Exit code — sum of all per-directory codes, matching the legacy
  # action's behaviour.
  local sum_exit_codes=0
  local v
  for v in "${fmt_results[@]}"; do
    sum_exit_codes=$((sum_exit_codes + v))
  done
  return ${sum_exit_codes}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
