#!/bin/env bash
#
# Source for the plan-json step (post-plan).
#
# Renders the binary plan file as JSON via 'terraform show -json' and
# exposes the path of the resulting file. The file stays on the runner: it
# holds sensitive values in plain text, which the console plan does not.
#
# Outputs:
#   tf-plan-json-output-file - Path of the rendered .json file. Published
#                              whenever the step runs; the file exists only
#                              when 'terraform show -json' succeeded.
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
  local plan_json_out_file="${GITHUB_WORKSPACE}/tf-plan-${input_environment_name}.json"

  # Published, and any file already at the path removed, before anything can
  # fail: whatever goes wrong below, a consumer is handed this plan's path, and
  # at it either this plan's JSON or nothing. An empty output would read as "no
  # JSON plan was made" rather than "the JSON plan failed", and a stale file
  # would pass for this plan's.
  set-output 'tf-plan-json-output-file' "${plan_json_out_file}"
  rm -f "${plan_json_out_file}"

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
  # Only stdout goes to the file. stderr used to be redirected into it too, and
  # a single warning line there made the whole document unreadable as JSON;
  # it now reaches the log, where a person can read it.
  local show_exit_code=0
  "${tf_bin}" show -json "${plan_tf_out_file}" >"${plan_json_out_file}" || show_exit_code=${?}
  if [ "${show_exit_code}" -ne 0 ]; then
    # A failed show may have written part of a document. Removed, so nothing
    # reads a partial plan as the plan.
    rm -f "${plan_json_out_file}"
    log-error "'terraform show -json' failed with exit code ${show_exit_code}; no JSON plan was written."
    end-group
    return 1
  fi
  log-info "wrote the plan as JSON to '$(ws-path "${plan_json_out_file}")'."
  end-group
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
