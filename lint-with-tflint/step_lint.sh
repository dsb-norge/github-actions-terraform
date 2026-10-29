#!/bin/env bash
#
# Source for the lint-with-tflint lint step.
#
# Implements the lint contract of docs/Linting.md. Registers the TFLint problem
# matcher, then lints each root: the working directory, and with 'examples'
# every module example too. A root is linted first, then every local module
# directory its '.terraform/modules/modules.json' records, each as a root of its
# own; a root without a modules file is linted alone. A module directory is
# linted against a manifest derived from the root's, through TF_DATA_DIR, so it
# needs no init of its own. The root is linted once per var file it holds
# (other than the ones tflint loads itself); a module directory never gets one.
#
# Exits with the sum of the per-run exit codes so a failure anywhere surfaces as
# a failing step.
#
# Required environment variables:
#   input_working_directory - From what directory to run TFLint.
#   input_config_file       - Path of the TFLint config file, as resolved by
#                             step_get_config.sh.
#
# Optional environment variables:
#   input_examples        - 'true' also lints each 'examples/*/' directory that
#                           holds '.tf' files, as a root covering only the
#                           directories inside it. Anything else: not.
#   input_extra_envs_file - Path of a JSON file with environment variables
#                           to apply to this step only. Empty or unset is a
#                           no-op.
#   TFLINT_BIN - Path to the tflint binary (defaults to 'tflint' on PATH).
#                Used by tests to inject a stub.
#

set +o nounset

# Load helpers (provides read-terraform-module-dirs, write-derived-manifest and
# read-root-var-files via helpers_additional.sh)
source "${GITHUB_ACTION_PATH}/helpers.sh"

# One entry per tflint run, in order, for the summary and the exit code.
declare -a _run_labels=()
declare -a _run_codes=()

function record-run {
  _run_labels+=("${1}")
  _run_codes+=("${2}")
}

# Lint one root and the module directories its manifest records.
#   $1 - the root's absolute path
#   $2 - 'all' lints every local module directory; 'all-but-examples' every
#        one but those under the root's examples/, which are then linted as
#        roots of their own (a module root's manifest records the modules its
#        test files' run blocks call, the examples among them, so each would be
#        linted twice); 'inside' only the ones
#        inside the root (a module example: the module itself is linted once,
#        by its own root)
function lint-root {
  local root="${1}" scope="${2}"
  local modules_file="${root}/.terraform/modules/modules.json"
  local -a dirs=() keys=() var_files=()

  # Not ws-path: realpath fails on a file that does not exist, which is the
  # common case for a root without module calls.
  log-info "looking for terraform modules file at '${modules_file#"${GITHUB_WORKSPACE}/"}'"
  if [ -f "${modules_file}" ]; then
    log-info "found it, parsing directories to lint"
    read-terraform-module-dirs dirs keys "${modules_file}" "${root}" || return 1
  else
    log-info "no modules file found, linting will only be performed in '$(ws-path "${root}")'"
    dirs=("${root}")
    keys=("")
  fi

  if [ "${scope}" == 'inside' ] || [ "${scope}" == 'all-but-examples' ]; then
    local -a kept_dirs=() kept_keys=()
    local i canonical_root canonical_dir keep
    canonical_root="$(realpath -m "${root}")"
    for i in "${!dirs[@]}"; do
      canonical_dir="$(realpath -m "${dirs[i]}")"
      # Plain if-statements: GitHub sources this under 'bash -e', where a bare
      # test that comes out false would end the step.
      keep='false'
      if [ "${scope}" == 'inside' ]; then
        if [ "${canonical_dir}" == "${canonical_root}" ] || [[ "${canonical_dir}" == "${canonical_root}/"* ]]; then
          keep='true'
        fi
      elif [[ "${canonical_dir}" != "${canonical_root}/examples/"* ]]; then
        keep='true'
      fi
      if [ "${keep}" == 'true' ]; then
        kept_dirs+=("${dirs[i]}")
        kept_keys+=("${keys[i]}")
      fi
    done
    dirs=("${kept_dirs[@]}")
    keys=("${kept_keys[@]}")
  fi

  # Linting nothing must not report success.
  if [ ${#dirs[@]} -eq 0 ]; then
    log-error "no directories to lint were found!"
    return 1
  fi

  read-root-var-files var_files "${root}"

  # Each run's exit code is taken on the line after the run: '$?' read inside
  # an argument list that also holds a command substitution is that
  # substitution's code, not tflint's.
  local i lint_dir key label lint_exit
  for i in "${!dirs[@]}"; do
    lint_dir="${dirs[i]}"
    key="${keys[i]}"
    label="./$(ws-path "${lint_dir}")"
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
      record-run "${label}" "${init_exit}"
      end-group
      continue
    fi

    if [ -z "${key}" ]; then
      # The root: once per var file, or once without when it holds none.
      if [ ${#var_files[@]} -eq 0 ]; then
        log-info "linting ..."
        log-info "command string is '${lint_cmd[*]@Q}'"
        set +e
        "${lint_cmd[@]}"
        lint_exit=${?}
        record-run "${label}" "${lint_exit}"
      else
        local var_file
        for var_file in "${var_files[@]}"; do
          local var_cmd=("${lint_cmd[@]}" "--var-file=${var_file}")
          log-info "linting with '$(basename "${var_file}")' ..."
          log-info "command string is '${var_cmd[*]@Q}'"
          set +e
          "${var_cmd[@]}"
          lint_exit=${?}
          record-run "${label} ($(basename "${var_file}"))" "${lint_exit}"
        done
      fi
    else
      # A module directory: against the manifest derived from the root's.
      local data_dir
      data_dir="$(mktemp -d)"
      if ! write-derived-manifest "${modules_file}" "${key}" "${root}" "${data_dir}"; then
        log-error "failed to derive the modules manifest for '$(ws-path "${lint_dir}")' (key '${key}')!"
        rm -rf "${data_dir}"
        record-run "${label}" 1
        end-group
        continue
      fi
      log-info "linting against the modules '${key}' reaches in the root's manifest ..."
      log-info "command string is 'TF_DATA_DIR=${data_dir@Q} ${lint_cmd[*]@Q}'"
      set +e
      TF_DATA_DIR="${data_dir}" "${lint_cmd[@]}"
      lint_exit=${?}
      record-run "${label}" "${lint_exit}"
      rm -rf "${data_dir}"
    fi

    end-group
  done
  return 0
}

function main {
  # Applied first, before this action's own exports — see
  # docs/Per-goal-environment-variables.md §6.3.
  apply-extra-envs "${input_extra_envs_file}" || return 1

  tflint_bin="${TFLINT_BIN:-tflint}"

  # Guarded: an unguarded 'cd' that fails leaves the step running in whatever
  # directory it was invoked from and operating on the wrong tree. Errexit
  # catches it on the runner and in the suites, which source the step under
  # the runner's flags (F34), but the local runners do not set it.
  if ! cd "${input_working_directory}"; then
    log-error "the working directory '${input_working_directory}' could not be entered!"
    return 1
  fi

  # Decoration in github
  echo "::add-matcher::${GITHUB_ACTION_PATH}/tflint_matcher.json"

  if [ "${input_examples:-false}" == 'true' ]; then
    lint-root "$(pwd)" all-but-examples || return 1
  else
    lint-root "$(pwd)" all || return 1
  fi

  if [ "${input_examples:-false}" == 'true' ]; then
    local example
    for example in "$(pwd)"/examples/*/; do
      example="${example%/}"
      [ -d "${example}" ] || continue
      # A directory without '.tf' files (a README, shared fixtures) is not an example.
      compgen -G "${example}/*.tf" >/dev/null || continue
      log-info "module example '$(ws-path "${example}")'"
      lint-root "${example}" inside || return 1
    done
  fi

  # Summary
  log-info "summary:"
  local i sum_exit_codes=0
  for i in "${!_run_labels[@]}"; do
    log-info "  - $([[ ${_run_codes[i]} -ne 0 ]] && echo 'failure ->' || echo 'success ->') ${_run_labels[i]}"
    sum_exit_codes=$((sum_exit_codes + _run_codes[i]))
  done

  # Exit code — sum of all per-run codes, matching the legacy action's
  # behaviour.
  return ${sum_exit_codes}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
