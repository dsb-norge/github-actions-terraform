#!/bin/env bash
#
# Source for the terraform-plan main step.
#
# Runs 'terraform plan' in the working directory, captures the console
# output, and measures the wall-clock time the plan command took.
#
# Outputs:
#   tf-plan-console-output-file - Path of file with captured stdout/stderr.
#   tf-plan-tf-output-file      - Path of the binary plan file.
#   tf-plan-exitcode            - The raw exit code from 'terraform plan'.
#                                 NOTE: terraform plan returns 2 on success
#                                 when there are changes (with
#                                 -detailed-exitcode); the raw code is
#                                 published so downstream consumers can
#                                 distinguish 'success-with-changes' from
#                                 'success-no-changes'. The script itself
#                                 still exits 0 in both cases.
#                                 https://www.terraform.io/docs/commands/plan.html#detailed-exitcode
#   plan-time                   - Wall-clock duration of the plan command,
#                                 formatted as 'mm:ss'. Always emitted —
#                                 even on failure, so PR-comment tables can
#                                 surface "this plan failed AND it took N
#                                 minutes" in one glance.
#
# Required environment variables:
#   input_working_directory   - Where to invoke terraform.
#   input_environment_name    - Used when naming the plan output files.
#   input_extra_global_args   - Args before the 'plan' subcommand.
#   input_extra_plan_args     - Args after the 'plan' subcommand.
#
# Optional environment variables:
#   input_extra_envs_file - Path of a JSON file with environment variables
#                           to apply to this step only. Empty or unset is a
#                           no-op.
#   TF_BIN - Path to the terraform binary (defaults to 'terraform' on PATH).
#            Used by tests to inject a stub.
#

set +o nounset

# Load helpers (provides format-duration-mmss via helpers_additional.sh)
source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  # Applied first, before this action's own exports — see
  # docs/Per-goal-environment-variables.md §6.3.
  apply-extra-envs "${input_extra_envs_file}" || return 1

  local tf_bin="${TF_BIN:-terraform}"

  cd "${input_working_directory}"

  local plan_console_out_file="${GITHUB_WORKSPACE}/tf-plan-console-output-${input_environment_name}.txt"
  local plan_tf_out_file="${GITHUB_WORKSPACE}/tf-plan-${input_environment_name}.plan"
  set-output 'tf-plan-console-output-file' "${plan_console_out_file}"
  set-output 'tf-plan-tf-output-file' "${plan_tf_out_file}"

  # Build the command as an array and invoke it as "${plan_cmd[@]}". The
  # extra-* args are still whitespace-split (that is their documented
  # contract, see split-args-to-array), but the paths this script builds —
  # notably -out= — are no longer word-split or glob-expanded on the way to
  # terraform.
  local extra_global_args=() extra_plan_args=()
  split-args-to-array extra_global_args "${input_extra_global_args}"
  split-args-to-array extra_plan_args "${input_extra_plan_args}"

  local plan_cmd=("${tf_bin}")
  plan_cmd+=("${extra_global_args[@]}")
  plan_cmd+=(plan -detailed-exitcode -input=false -no-color "-out=${plan_tf_out_file}")
  plan_cmd+=("${extra_plan_args[@]}")

  log-info "command string is '${plan_cmd[*]@Q}'"
  start-group "'terraform plan' in '$(ws-path "$(pwd)")'"

  # Needed to properly catch terraform's exit code through the pipe to tee.
  set -o pipefail

  # GitHub runner gets confused by set commands; make sure
  # 'continue-on-error: true' still applies after 'set -o pipefail'.
  set +e

  # Capture elapsed seconds around the actual plan invocation. SECONDS is a
  # bash builtin that increments once per real second; the delta is the
  # wall-clock time spent inside terraform plan (plus the trivial overhead
  # of the surrounding shell, which is below mm:ss granularity).
  local plan_start=${SECONDS}
  "${plan_cmd[@]}" 2>&1 | tee "${plan_console_out_file}"
  local plan_exit_code=${?}
  local plan_duration=$((SECONDS - plan_start))

  # Emit plan-time before any return path so that even on parse/eval failure
  # downstream, the PR comment still shows how long terraform actually ran.
  set-output 'plan-time' "$(format-duration-mmss "${plan_duration}")"

  set-output 'tf-plan-exitcode' "${plan_exit_code}"

  # Normalize the local exit code so the action returns 0 on
  # success-with-changes (terraform's exit 2 from -detailed-exitcode).
  # The raw code is still published via tf-plan-exitcode above.
  if [ "${plan_exit_code}" == "0" ]; then
    log-info 'successfully planned Terraform configuration, no changes indicated.'
  elif [ "${plan_exit_code}" == "2" ]; then
    plan_exit_code=0
    log-info 'successfully planned Terraform configuration, changes indicated!'
  else
    log-error "failed to plan Terraform configuration, exit code: ${plan_exit_code}"
    plan_exit_code=-1
  fi
  end-group

  return ${plan_exit_code}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
