#!/bin/env bash
#
# Source for the terraform-validate main step.
#
# Runs 'terraform validate' in the working directory and tees the
# combined stdout/stderr to a console-output file so downstream steps
# (parse-terraform-warnings) can scan it for diagnostics.
#
# Outputs:
#   tf-validate-console-output-file - Path of file with captured stdout/stderr.
#
# Required environment variables:
#   input_working_directory     - Where to invoke 'terraform validate'.
#
# Optional environment variables:
#   input_extra_envs_file - Path of a JSON file with environment variables
#                           to apply to this step only. Empty or unset is a
#                           no-op.
#   input_environment_name      - Used in the console-file name. Defaults
#                                 to empty.
#   TF_BIN                       - Path to the terraform binary (defaults
#                                  to 'terraform' on PATH). Used by tests
#                                  to inject a stub.
#

set +o nounset

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  # Applied first, before this action's own exports — see
  # docs/Per-goal-environment-variables.md §6.3.
  apply-extra-envs "${input_extra_envs_file}" || return 1

  local tf_bin="${TF_BIN:-terraform}"

  local console_file="${GITHUB_WORKSPACE}/tf-validate-console-output-${input_environment_name}.txt"
  set-output 'tf-validate-console-output-file' "${console_file}"

  cd "${input_working_directory}"

  start-group "running 'terraform validate' in '$(ws-path "$(pwd)")'"
  set -o pipefail
  set +e
  "${tf_bin}" validate 2>&1 | tee "${console_file}"
  local validate_exit=${?}
  set +o pipefail
  end-group

  if [ "${validate_exit}" != "0" ]; then
    log-error "validate exited with code '${validate_exit}'"
  fi

  return ${validate_exit}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
