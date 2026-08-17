#!/bin/env bash
#
# Source for the plan-json step (post-plan).
#
# Renders the binary plan file as JSON via 'terraform show -json' and
# exposes the path of the resulting file.
#
# Outputs:
#   tf-plan-json-output-file - Path of the rendered .json file.
#
# Required environment variables:
#   input_working_directory   - terraform working directory.
#   input_environment_name    - used when naming the output file.
#   input_plan_tf_output_file - the binary plan file produced by step_plan.sh.
#
# Optional environment variables:
#   input_extra_envs_file - Path of a JSON file with environment variables
#                           to apply to this step only. Empty or unset is a
#                           no-op.
#   TF_BIN - Path to terraform binary (defaults to 'terraform' on PATH).
#

set +o nounset

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

  start-group "output the plan as json"
  local plan_tf_out_file="${input_plan_tf_output_file}"
  local plan_json_out_file="${GITHUB_WORKSPACE}/tf-plan-${input_environment_name}.json"
  set-output 'tf-plan-json-output-file' "${plan_json_out_file}"
  "${tf_bin}" show -json "${plan_tf_out_file}" >"${plan_json_out_file}" 2>&1
  end-group
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
