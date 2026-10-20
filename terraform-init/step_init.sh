#!/bin/env bash
#
# Source for the terraform-init main step.
#
# Runs 'terraform init' in the working directory (and, with 'examples', in
# each module example), tees the combined stdout/stderr to a single
# console-output file so downstream steps (parse-terraform-warnings,
# validation summary) can scan it for diagnostics.
#
# Outputs:
#   tf-init-console-output-file - Path of file with captured stdout/stderr
#                                 across the project init + any example
#                                 inits. Examples append (tee -a) so warnings
#                                 from every init call are scannable from one
#                                 place.
#
# Required environment variables:
#   input_working_directory     - Where to invoke 'terraform init'.
#
# Deprecated environment variables:
#   input_additional_dirs_json  - Ignored, with a log line when it lists
#                                 anything: the lint prepares module
#                                 directories itself (docs/Linting.md).
#
# Optional environment variables:
#   input_extra_envs_file - Path of a JSON file with environment variables
#                           to apply to this step only. Empty or unset is a
#                           no-op.
#   input_environment_name      - Used in the console-file name. Defaults
#                                 to empty (file becomes
#                                 'tf-init-console-output-.txt' — ugly but
#                                 functional).
#   input_examples               - 'true' also initialises each
#                                  'examples/*/' holding '.tf' files, with
#                                  '-backend=false'. Default 'false'.
#   input_plugin_cache_directory - The plugin cache directory, exported as
#                                  TF_PLUGIN_CACHE_DIR for the project init when
#                                  'plugin-cache-may-break-lock-file' asks.
#   input_backend                - 'false' adds '-backend=false' to the
#                                  project init. Default 'true'.
#   input_lockfile_mode          - 'default' (the default), 'readonly' or
#                                  'readonly-if-present'; decides whether the
#                                  project init gets '-lockfile=readonly'.
#   input_plugin_cache_may_break_lock_file
#                                - 'true' exports TF_PLUGIN_CACHE_DIR and
#                                  TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE
#                                  for the project init too, when a plugin
#                                  cache directory is set and the lock stays
#                                  writable. Default 'false'.
#   input_github_token    - When set, terraform's github.com module clones are
#                           authenticated with it. Empty or unset leaves them
#                           anonymous, which is what they were before this
#                           existed. See configure-github-clone-auth in
#                           helpers_additional.sh for why this is needed.
#   TF_BIN                       - Path to the terraform binary (defaults
#                                  to 'terraform' on PATH). Used by tests
#                                  to inject a stub.
#

set +o nounset

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  # Validated before anything runs: a typo in a mode must not silently fall
  # back to a writable lock, which is exactly what read-only mode exists to
  # prevent.
  local backend="${input_backend:-true}"
  if [ ! "${backend}" == 'true' ] && [ ! "${backend}" == 'false' ]; then
    log-error "input 'backend' must be 'true' or 'false', got '${backend}'!"
    return 1
  fi
  local lockfile_mode="${input_lockfile_mode:-default}"
  if ! is-valid-lockfile-mode "${lockfile_mode}"; then
    log-error "input 'lockfile-mode' must be one of 'default', 'readonly' or 'readonly-if-present', got '${lockfile_mode}'!"
    return 1
  fi
  local may_break="${input_plugin_cache_may_break_lock_file:-false}"
  if [ ! "${may_break}" == 'true' ] && [ ! "${may_break}" == 'false' ]; then
    log-error "input 'plugin-cache-may-break-lock-file' must be 'true' or 'false', got '${may_break}'!"
    return 1
  fi
  local examples="${input_examples:-false}"
  if [ ! "${examples}" == 'true' ] && [ ! "${examples}" == 'false' ]; then
    log-error "input 'examples' must be 'true' or 'false', got '${examples}'!"
    return 1
  fi

  # Applied first, before this action's own exports — see
  # docs/Per-goal-environment-variables.md §6.3.
  apply-extra-envs "${input_extra_envs_file}" || return 1

  # Before the first invocation: terraform shells out to 'git clone' for every
  # remote module, and those clones are what this authenticates.
  configure-github-clone-auth "${input_github_token}"

  local tf_bin="${TF_BIN:-terraform}"

  local console_file="${GITHUB_WORKSPACE}/tf-init-console-output-${input_environment_name}.txt"
  set-output 'tf-init-console-output-file' "${console_file}"

  # Track exit codes per directory. Sum at end so a failure anywhere
  # surfaces as a non-zero overall exit (matches the legacy action's
  # behaviour: "exit ${TF_INIT_SUM_EXIT_CODES}").
  declare -A TF_INIT_RESULTS

  # Guarded: an unguarded 'cd' that fails leaves the step running in whatever
  # directory it was invoked from and operating on the wrong tree. The runner's
  # errexit catches it in production, but only there — the test harness and the
  # local runners do not set it, so the failure mode is invisible where it would
  # be caught.
  if ! cd "${input_working_directory}"; then
    log-error "the working directory '${input_working_directory}' could not be entered!"
    return 1
  fi

  # The project init's arguments. With every input at its default this is
  # exactly the command the action ran before the inputs existed.
  local -a init_args=(init -input=false -reconfigure)
  if [ "${backend}" == 'false' ]; then
    init_args+=(-backend=false)
  fi
  local lock_readonly='false'
  if [ "${lockfile_mode}" == 'readonly' ]; then
    lock_readonly='true'
  elif [ "${lockfile_mode}" == 'readonly-if-present' ] && [ -f '.terraform.lock.hcl' ]; then
    lock_readonly='true'
  fi
  if [ "${lock_readonly}" == 'true' ]; then
    init_args+=(-lockfile=readonly)
  fi

  # Opt-in rather than implied by a writable lock: the environment job inits
  # against a committed lock with the plugin cache set, and there the variable
  # would record new providers with one platform's checksum only and turn a
  # cached package the lock has no checksum for into an init failure. Never
  # with a read-only lock, where init cannot write the checksums it needs and
  # passes with a package later commands refuse.
  if [ "${may_break}" == 'true' ]; then
    if [ "${lock_readonly}" == 'true' ]; then
      log-info "the lock is read-only, so the project init leaves the plugin cache's lock rules alone."
    elif [ -z "${input_plugin_cache_directory:-}" ]; then
      log-info "no plugin cache directory configured, so the project init leaves the plugin cache's lock rules alone."
    else
      log-info "the project init may let the plugin cache break the dependency lock file."
      export TF_PLUGIN_CACHE_DIR="${input_plugin_cache_directory}"
      # ref. https://developer.hashicorp.com/terraform/cli/config/config-file#allowing-the-provider-plugin-cache-to-break-the-dependency-lock-file
      export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE="true"
    fi
  fi

  # Project init — tee with overwrite ('>' under tee) so re-runs of the
  # step in the same workspace start fresh.
  start-group "running 'terraform init' in 'project-dir' '$(ws-path "$(pwd)")' ..."
  set -o pipefail
  set +e
  "${tf_bin}" "${init_args[@]}" 2>&1 | tee "${console_file}"
  local init_exit=${?}
  set +o pipefail
  TF_INIT_RESULTS["$(pwd)"]="${init_exit}"
  if [ ! "${init_exit}" == "0" ]; then
    log-error "init exited with code '${init_exit}'!"
  fi
  end-group

  # Deprecated: the lint prepares module directories itself, from the
  # project's own modules manifest (docs/Linting.md), so nothing else is
  # initialised. A workflow release from before that still passes the input.
  local more_dirs_json="${input_additional_dirs_json:-}"
  if [ -n "${more_dirs_json}" ] && [ ! "${more_dirs_json}" == '[]' ] && [ ! "${more_dirs_json}" == 'null' ]; then
    log-info "input 'additional-dirs-json' is deprecated and ignored: the lint prepares module directories itself (docs/Linting.md)."
  fi

  # Module examples (module CI): each 'examples/*/' holding '.tf' files is
  # initialised after the project, appending to the same console file, so it
  # can be validated and linted. Never with a backend, and never letting the
  # plugin cache break the lock: an example has no lock to start from, and that
  # would record one platform's checksum and warn of an incomplete lock on
  # every run.
  if [ "${examples}" == 'true' ]; then
    local example
    for example in "$(pwd)"/examples/*/; do
      example="${example%/}"
      [ -d "${example}" ] || continue
      # A directory without '.tf' files (a README, shared fixtures) is not an example.
      compgen -G "${example}/*.tf" >/dev/null || continue
      start-group "running 'terraform init' in example '$(ws-path "${example}")' ..."
      set -o pipefail
      set +e
      env -u TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE \
        "${tf_bin}" -chdir="${example}" init -input=false -backend=false 2>&1 | tee -a "${console_file}"
      local example_exit=${?}
      set +o pipefail
      TF_INIT_RESULTS["${example}"]="${example_exit}"
      if [ ! "${example_exit}" == "0" ]; then
        log-error "init exited with code '${example_exit}'!"
      fi
      end-group
    done
  fi

  # Sum exit codes — any non-zero entry yields a non-zero total. Matches
  # the legacy action behaviour. Empty array (no inits ran) shouldn't be
  # possible — project init always runs — but guard anyway.
  local sum_exit_codes=0
  local v
  for v in "${TF_INIT_RESULTS[@]}"; do
    sum_exit_codes=$((sum_exit_codes + v))
  done

  # After the sum, so the annotation can say whether it actually broke the init.
  if [ "${sum_exit_codes}" == '0' ]; then
    annotate-refused-clones "${console_file}" 'false'
  else
    annotate-refused-clones "${console_file}" 'true'
  fi

  return ${sum_exit_codes}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
