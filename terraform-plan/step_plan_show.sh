#!/bin/env bash
#
# Source for the plan-show step (post-plan).
#
# Renders the binary plan file as a human-readable text artifact via
# 'terraform show' and exposes the path of the resulting file.
#
# Outputs:
#   tf-plan-txt-output-file - Path of the rendered .txt file.
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

  cd "${input_working_directory}"

  start-group "output the plan as txt"
  local plan_tf_out_file="${input_plan_tf_output_file}"
  local plan_txt_out_file="${GITHUB_WORKSPACE}/tf-plan-${input_environment_name}.txt"
  set-output 'tf-plan-txt-output-file' "${plan_txt_out_file}"
  "${tf_bin}" show -no-color "${plan_tf_out_file}" 2>&1 | tee "${plan_txt_out_file}"
  end-group
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
