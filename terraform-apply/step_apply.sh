#!/bin/env bash
#
# Source for the terraform-apply main step.
#
# Applies a previously created terraform plan file.
#
# Required environment variables:
#   input_working_directory   - Where to invoke terraform.
#   input_terraform_plan_file - Path of the plan file to apply.
#
# Optional environment variables:
#   input_extra_envs_file - Path of a JSON file with environment variables
#                           to apply to this step only. Empty or unset is a
#                           no-op.
#   TF_BIN - Path to the terraform binary (defaults to 'terraform' on PATH).
#            Used by tests to inject a stub.
#

set +o nounset

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  # Applied first, before this action's own exports — see
  # docs/Per-goal-environment-variables.md §6.3.
  apply-extra-envs "${input_extra_envs_file}" || return 1

  local tf_bin="${TF_BIN:-terraform}"

  # Guarded: an unguarded 'cd' that fails leaves the step running in whatever
  # directory it was invoked from and operating on the wrong tree. The runner's
  # errexit catches it in production, but only there — the test harness and the
  # local runners do not set it, so the failure mode is invisible where it would
  # be caught.
  if ! cd "${input_working_directory}"; then
    log-error "the working directory '${input_working_directory}' could not be entered!"
    return 1
  fi

  # Built as an array and invoked as "${apply_cmd[@]}": the plan-file path is
  # caller-supplied and, as an interpolated command string, was subject to
  # word-splitting and glob expansion before it ever reached terraform.
  local apply_cmd=(
    "${tf_bin}"
    apply
    -input=false
    -auto-approve
    "${input_terraform_plan_file}"
  )
  log-info "apply command string is '${apply_cmd[*]@Q}'"
  start-group "'terraform apply' in '$(ws-path "$(pwd)")'"

  # GitHub runner gets confused by set commands; make sure
  # 'continue-on-error' still applies to the step.
  set +e
  "${apply_cmd[@]}"
  local apply_exit=${?}

  # Avoid control characters left behind by apply, they mess up the
  # end-group command.
  echo ''
  end-group

  if [ "${apply_exit}" != "0" ]; then
    log-error "apply exited with code '${apply_exit}'"
  fi

  return ${apply_exit}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
