#!/bin/env bash
#
# Source for the terraform-validate main step.
#
# Runs 'terraform validate' in the working directory (and, with 'examples',
# in each module example) and tees the combined stdout/stderr to a
# console-output file so downstream steps (parse-terraform-warnings) can scan
# it for diagnostics.
#
# Outputs:
#   tf-validate-console-output-file - Path of file with captured stdout/stderr.
#
# Required environment variables:
#   input_working_directory     - Where to invoke 'terraform validate'.
#
# Optional environment variables:
#   input_examples        - 'true' also validates each 'examples/*/' holding
#                           '.tf' files, initialised by terraform-init's
#                           'examples'. Default 'false'.
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

  local examples="${input_examples:-false}"
  if [ ! "${examples}" == 'true' ] && [ ! "${examples}" == 'false' ]; then
    log-error "input 'examples' must be 'true' or 'false', got '${examples}'!"
    return 1
  fi

  local tf_bin="${TF_BIN:-terraform}"

  local console_file="${GITHUB_WORKSPACE}/tf-validate-console-output-${input_environment_name}.txt"
  set-output 'tf-validate-console-output-file' "${console_file}"

  # Guarded: an unguarded 'cd' that fails leaves the step running in whatever
  # directory it was invoked from and operating on the wrong tree. Errexit
  # catches it on the runner and in the suites, which source the step under
  # the runner's flags (F34), but the local runners do not set it.
  if ! cd "${input_working_directory}"; then
    log-error "the working directory '${input_working_directory}' could not be entered!"
    return 1
  fi

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

  # Module examples (module CI): validated after the project, appending to the
  # same console file, so a module repository's examples are checked as the
  # dsb CLI checks them (docs/Linting.md).
  if [ "${examples}" == 'true' ]; then
    local example example_exit
    for example in "$(pwd)"/examples/*/; do
      example="${example%/}"
      [ -d "${example}" ] || continue
      # A directory without '.tf' files (a README, shared fixtures) is not an example.
      compgen -G "${example}/*.tf" >/dev/null || continue
      start-group "running 'terraform validate' in example '$(ws-path "${example}")'"
      set -o pipefail
      set +e
      "${tf_bin}" -chdir="${example}" validate 2>&1 | tee -a "${console_file}"
      example_exit=${?}
      set +o pipefail
      end-group
      if [ "${example_exit}" != "0" ]; then
        log-error "validate exited with code '${example_exit}' in '$(ws-path "${example}")'"
        validate_exit=$((validate_exit + example_exit))
      fi
    done
  fi

  return ${validate_exit}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
