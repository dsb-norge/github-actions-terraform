#!/bin/env bash
#
# Source for the lint-with-tflint lint step.
#
# Registers the TFLint problem matcher, determines which directories to lint —
# every module directory terraform recorded in
# '<project-dir>/.terraform/modules/modules.json' during init, or just the
# project directory when there is no modules file — then runs 'tflint --init'
# followed by 'tflint' in each.
#
# Exits with the sum of the per-directory exit codes so a failure anywhere
# surfaces as a failing step.
#
# Required environment variables:
#   input_working_directory - From what directory to run TFLint.
#   input_config_file       - Path of the TFLint config file, as resolved by
#                             step_get_config.sh.
#
# Optional environment variables:
#   input_extra_envs_file - Path of a JSON file with environment variables
#                           to apply to this step only. Empty or unset is a
#                           no-op.
#   TFLINT_BIN - Path to the tflint binary (defaults to 'tflint' on PATH).
#                Used by tests to inject a stub.
#

set +o nounset

# Load helpers (provides read-terraform-module-dirs via helpers_additional.sh)
source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  # Applied first, before this action's own exports — see
  # docs/Per-goal-environment-variables.md §6.3.
  apply-extra-envs "${input_extra_envs_file}" || return 1

  local tflint_bin="${TFLINT_BIN:-tflint}"

  # Guarded: an unguarded 'cd' that fails leaves the step running in whatever
  # directory it was invoked from and operating on the wrong tree. The runner's
  # errexit catches it in production, but only there — the test harness and the
  # local runners do not set it, so the failure mode is invisible where it would
  # be caught.
  if ! cd "${input_working_directory}"; then
    log-error "the working directory '${input_working_directory}' could not be entered!"
    return 1
  fi

  # Decoration in github
  echo "::add-matcher::${GITHUB_ACTION_PATH}/tflint_matcher.json"

  # Dirs
  local modules_file="$(pwd)/.terraform/modules/modules.json"
  local lint_dirs=()
  log-info "looking for terraform modules file at '$(ws-path "${modules_file}")'"
  if [ -f "${modules_file}" ]; then
    log-info "found it, parsing directories to lint"
    read-terraform-module-dirs lint_dirs "${modules_file}" "$(pwd)/" || return 1
  else
    log-info "no modules file found, linting will only be performed in '$(ws-path "$(pwd)")'"
    lint_dirs=("$(pwd)")
  fi

  # Linting nothing must not report success.
  if [ ${#lint_dirs[@]} -eq 0 ]; then
    log-error "no directories to lint were found!"
    return 1
  fi

  # Lint
  declare -A lint_results
  local lint_dir
  for lint_dir in "${lint_dirs[@]}"; do
    start-group "directory '$(ws-path "${lint_dir}")'"

    # Array-built invocations so a directory path containing a space or a
    # glob character reaches tflint as exactly one argument.
    local init_cmd=("${tflint_bin}" --init "--config=${input_config_file}" "--chdir=${lint_dir}")
    local lint_cmd=("${tflint_bin}" --format=compact "--config=${input_config_file}" "--chdir=${lint_dir}")

    log-info "TFLint init ..."
    log-info "command string is '${init_cmd[*]@Q}'"
    set +e
    "${init_cmd[@]}"
    local init_exit=${?}

    # A failing '--init' used to abort the whole step on the spot. Recording
    # it as this directory's result instead keeps the remaining directories
    # linted — the step still fails, because the exit codes are summed — and
    # the log then shows which directories were reached.
    if [ ! "${init_exit}" == "0" ]; then
      log-error "TFLint init exited with code '${init_exit}', skipping linting of this directory!"
      lint_results["${lint_dir}"]=${init_exit}
      end-group
      continue
    fi

    log-info "linting ..."
    log-info "command string is '${lint_cmd[*]@Q}'"
    set +e
    "${lint_cmd[@]}"
    lint_results["${lint_dir}"]=${?}

    end-group
  done

  # Summary
  log-info "summary:"
  for lint_dir in "${lint_dirs[@]}"; do
    log-info "  - $([[ ${lint_results["${lint_dir}"]} -ne 0 ]] && echo 'failure ->' || echo 'success ->') ./$(ws-path "${lint_dir}")"
  done

  # Exit code — sum of all per-directory codes, matching the legacy
  # action's behaviour.
  local sum_exit_codes=0
  local v
  for v in "${lint_results[@]}"; do
    sum_exit_codes=$((sum_exit_codes + v))
  done
  return ${sum_exit_codes}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
