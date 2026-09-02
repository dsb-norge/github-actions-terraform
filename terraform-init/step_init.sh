#!/bin/env bash
#
# Source for the terraform-init main step.
#
# Runs 'terraform init' in the working directory (and any additional
# directories), tees the combined stdout/stderr to a single console-output
# file so downstream steps (parse-terraform-warnings, validation summary)
# can scan it for diagnostics.
#
# Outputs:
#   tf-init-console-output-file - Path of file with captured stdout/stderr
#                                 across the project init + any additional
#                                 init invocations. Additional dirs append
#                                 (tee -a) so warnings from every init call
#                                 are scannable from one place.
#
# Required environment variables:
#   input_working_directory     - Where to invoke 'terraform init'.
#   input_additional_dirs_json  - JSON array of extra directories (relative
#                                 to GITHUB_WORKSPACE) to also init. Empty
#                                 array or empty string skips the loop.
#
# Optional environment variables:
#   input_extra_envs_file - Path of a JSON file with environment variables
#                           to apply to this step only. Empty or unset is a
#                           no-op.
#   input_environment_name      - Used in the console-file name. Defaults
#                                 to empty (file becomes
#                                 'tf-init-console-output-.txt' — ugly but
#                                 functional).
#   input_plugin_cache_directory - When set, exported as TF_PLUGIN_CACHE_DIR
#                                  during the additional-dirs loop so
#                                  providers are reused across envs.
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

  # Project init — tee with overwrite ('>' under tee) so re-runs of the
  # step in the same workspace start fresh.
  start-group "running 'terraform init' in 'project-dir' '$(ws-path "$(pwd)")' ..."
  set -o pipefail
  set +e
  "${tf_bin}" init -input=false -reconfigure 2>&1 | tee "${console_file}"
  local init_exit=${?}
  set +o pipefail
  TF_INIT_RESULTS["$(pwd)"]="${init_exit}"
  if [ ! "${init_exit}" == "0" ]; then
    log-error "init exited with code '${init_exit}'!"
  fi
  end-group

  # Additional dirs init — parse JSON array, iterate, tee -a so each
  # invocation's output is appended to the same console file.
  local more_dirs_json="${input_additional_dirs_json:-[]}"
  local more_dirs
  more_dirs=$(printf '%s' "${more_dirs_json}" | jq -cr '.[]?' 2>/dev/null || echo "")

  if [ -z "${more_dirs}" ]; then
    log-info "no additional directories to init specified"
  else
    log-info "additional directories to init specified"

    if [ -n "${input_plugin_cache_directory:-}" ]; then
      export TF_PLUGIN_CACHE_DIR="${input_plugin_cache_directory}"
      # ref. https://developer.hashicorp.com/terraform/cli/config/config-file#allowing-the-provider-plugin-cache-to-break-the-dependency-lock-file
      export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE="true"
    fi

    local extra_dir
    for extra_dir in ${more_dirs}; do
      start-group "additional init directory '${extra_dir}'"
      local abs_dir="${GITHUB_WORKSPACE}/${extra_dir}"
      log-info "looking for directory ..."
      if [ -d "${abs_dir}" ]; then
        log-info "found it. Running terraform init now ..."
        set -o pipefail
        set +e
        "${tf_bin}" -chdir="${abs_dir}" init -input=false -reconfigure 2>&1 | tee -a "${console_file}"
        local extra_exit=${?}
        set +o pipefail
        TF_INIT_RESULTS["${abs_dir}"]="${extra_exit}"
        if [ ! "${extra_exit}" == "0" ]; then
          log-error "init exited with code '${extra_exit}'!"
        fi
      else
        log-error "additional init directory '${extra_dir}' does not exist!"
        end-group
        return 1
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
