#!/bin/env bash
#
# Source for the terraform-apply main step.
#
# Applies a previously created terraform plan file, captures the console
# output, and measures the wall-clock time the apply command took.
#
# Outputs:
#   tf-apply-console-output-file - Path of file with captured stdout/stderr.
#                                  Emitted BEFORE terraform runs, so it is
#                                  set even when apply fails — and a failed
#                                  apply's console is the only record of
#                                  what was and was not applied.
#   tf-apply-exitcode            - The raw exit code from 'terraform apply'.
#   apply-time                   - Wall-clock duration of the apply command,
#                                  formatted as 'mm:ss'. Always emitted,
#                                  including on failure, so the PR comment
#                                  can say "failed after N minutes".
#
# Required environment variables:
#   input_working_directory   - Where to invoke terraform.
#   input_terraform_plan_file - Path of the plan file to apply.
#
# Optional environment variables:
#   input_environment_name - Used when naming the console output file.
#                            Empty yields 'tf-apply-console-output.txt'.
#   input_extra_envs_file  - Path of a JSON file with environment variables
#                            to apply to this step only. Empty or unset is a
#                            no-op.
#   TF_BIN - Path to the terraform binary (defaults to 'terraform' on PATH).
#            Used by tests to inject a stub.
#
# ARG_MAX: this script is sourced under the shim's allexport. The console
# output goes to disk via tee and only its PATH is ever held in a variable —
# never the content. See the ARG_MAX section of the repository's CLAUDE.md.
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

  # Console file named like terraform-plan's, so the two sit side by side in
  # the workspace. Published before terraform runs: if apply fails the file
  # holds the errors, and downstream consumers must still be able to find it.
  local console_suffix=""
  [ -n "${input_environment_name:-}" ] && console_suffix="-${input_environment_name}"
  local apply_console_out_file="${GITHUB_WORKSPACE}/tf-apply-console-output${console_suffix}.txt"
  set-output 'tf-apply-console-output-file' "${apply_console_out_file}"

  # Built as an array and invoked as "${apply_cmd[@]}": the plan-file path is
  # caller-supplied and, as an interpolated command string, was subject to
  # word-splitting and glob expansion before it ever reached terraform.
  #
  # -no-color: the console file is rendered inside a PR comment's code fence;
  # ANSI escapes would show up there as literal 'ESC[0m'. Same flag
  # terraform-plan passes. The job log loses colour for this step.
  local apply_cmd=(
    "${tf_bin}"
    apply
    -input=false
    -auto-approve
    -no-color
    "${input_terraform_plan_file}"
  )
  log-info "apply command string is '${apply_cmd[*]@Q}'"
  start-group "'terraform apply' in '$(ws-path "$(pwd)")'"

  # Needed to catch terraform's exit code through the pipe to tee.
  set -o pipefail

  # GitHub runner gets confused by set commands; make sure
  # 'continue-on-error' still applies to the step.
  set +e

  # SECONDS is a bash builtin that increments once per real second; the
  # delta is the wall-clock time spent inside terraform apply.
  local apply_start=${SECONDS}
  "${apply_cmd[@]}" 2>&1 | tee "${apply_console_out_file}"
  local apply_exit=${?}
  local apply_duration=$((SECONDS - apply_start))

  # Emitted before any return path so the PR comment can still show how
  # long terraform ran when it failed.
  set-output 'apply-time' "$(format-duration-mmss "${apply_duration}")"
  set-output 'tf-apply-exitcode' "${apply_exit}"

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
