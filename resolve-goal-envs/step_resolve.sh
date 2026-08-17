#!/bin/env bash
#
# Source for the resolve-goal-envs main step.
#
# Resolves the effective set of environment variables for every terraform goal
# and writes one JSON file per goal into a private directory under
# $RUNNER_TEMP. What crosses from here into the goal actions is that
# directory's path — never a payload — so secret values stay out of argv, out
# of envp, and out of the goal steps' interpolated run-block script text.
#
# This is the only action besides export-env-vars that receives the secrets
# bag, and the only place per-goal values are merged or validated.
#
# Outputs:
#   envs-dir - Path of a 0700 directory containing one 0600 '<goal>.json' file
#              per goal. Every file always exists, containing at minimum '{}'.
#
# Required environment variables:
#   input_secrets_file                    - Path of a file holding
#                                           toJSON(secrets). Written by the
#                                           action.yml shim before allexport,
#                                           see §8 of the design doc.
#
# Optional environment variables:
#   input_extra_envs                      - JSON object, global plain values.
#   input_extra_envs_from_secrets         - JSON object, global secret names.
#   input_extra_envs_per_goal             - JSON object of objects, by goal.
#   input_extra_envs_from_secrets_per_goal - JSON object of objects, by goal.
#

set +o nounset

# Load helpers (provides GOAL_KEYS, normalize-json-object-file,
# find-input-errors and resolve-goal-envs-file via helpers_additional.sh)
source "${GITHUB_ACTION_PATH}/helpers.sh"

# Scratch directory holding the inputs plus a copy of the secrets bag. Removed
# on exit, including on the validation-failure paths — composite actions cannot
# declare 'post:' steps, so cleanup has to be explicit.
_WORK_DIR=""

function _cleanup {
  [ -n "${_WORK_DIR}" ] && [ -d "${_WORK_DIR}" ] && rm -rf "${_WORK_DIR}"
  [ -n "${input_secrets_file}" ] && [ -f "${input_secrets_file}" ] && rm -f "${input_secrets_file}"
  return 0
}
trap _cleanup EXIT

function main {
  if [ -z "${input_secrets_file}" ] || [ ! -f "${input_secrets_file}" ]; then
    log-error "the secrets file '${input_secrets_file}' does not exist!"
    return 1
  fi

  _WORK_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/resolve-goal-envs-work-XXXXXXXX")
  chmod 0700 "${_WORK_DIR}"

  # printf is a builtin, so the input values never reach an execve's argv.
  printf '%s' "${input_extra_envs}" >"${_WORK_DIR}/global-plain.json"
  printf '%s' "${input_extra_envs_from_secrets}" >"${_WORK_DIR}/global-secrets.json"
  printf '%s' "${input_extra_envs_per_goal}" >"${_WORK_DIR}/per-goal-plain.json"
  printf '%s' "${input_extra_envs_from_secrets_per_goal}" >"${_WORK_DIR}/per-goal-secrets.json"
  cp "${input_secrets_file}" "${_WORK_DIR}/secrets.json"
  chmod 0600 "${_WORK_DIR}"/*.json

  start-group "validating inputs"
  normalize-json-object-file "${_WORK_DIR}/global-plain.json" 'extra-envs' || { end-group; return 1; }
  normalize-json-object-file "${_WORK_DIR}/global-secrets.json" 'extra-envs-from-secrets' || { end-group; return 1; }
  normalize-json-object-file "${_WORK_DIR}/per-goal-plain.json" 'extra-envs-per-goal' || { end-group; return 1; }
  normalize-json-object-file "${_WORK_DIR}/per-goal-secrets.json" 'extra-envs-from-secrets-per-goal' || { end-group; return 1; }
  normalize-json-object-file "${_WORK_DIR}/secrets.json" 'secrets-json' || { end-group; return 1; }

  # One line per problem. Collected in a file rather than a variable so no
  # amount of input can push this into envp. The exit code is checked
  # separately from the file being non-empty: a jq failure here would
  # otherwise read as "no problems found" and let bad input through.
  if ! find-input-errors "${_WORK_DIR}" >"${_WORK_DIR}/errors.txt"; then
    log-error "failed to validate the per-goal environment variable inputs!"
    end-group
    return 1
  fi
  if [ -s "${_WORK_DIR}/errors.txt" ]; then
    while IFS= read -r error_line; do
      log-error "${error_line}"
    done <"${_WORK_DIR}/errors.txt"
    log-error "input validation failed, refusing to resolve per-goal environment variables."
    end-group
    return 1
  fi
  log-info "[OK] inputs are valid."
  end-group

  # $RUNNER_TEMP rather than $GITHUB_WORKSPACE: keeps the resolved values out
  # of actions/upload-artifact globs, out of 'terraform fmt -recursive'
  # traversal, and out of anything that could commit them.
  local envs_dir
  envs_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/resolved-goal-envs-XXXXXXXX")
  chmod 0700 "${envs_dir}"

  start-group "resolving per-goal environment variables"
  local goal out_file
  for goal in "${GOAL_KEYS[@]}"; do
    out_file="${envs_dir}/${goal}.json"

    # Create restricted before writing, so the values are never briefly
    # world-readable.
    : >"${out_file}"
    chmod 0600 "${out_file}"

    if ! resolve-goal-envs-file "${_WORK_DIR}" "${goal}" "${out_file}"; then
      log-error "failed to resolve environment variables for goal '${goal}'!"
      end-group
      return 1
    fi

    # Keys only, never values — a single map may mix plain and secret-sourced
    # entries, so the safe default is to log no values at all.
    log-info "goal '${goal}': $(jq -r 'if length == 0 then "no environment variables" else "\(length) environment variable(s): " + ([keys[]] | join(", ")) end' "${out_file}")"
  done
  end-group

  log-info "resolved environment files written to '${envs_dir}'"
  set-output 'envs-dir' "${envs_dir}"

  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
