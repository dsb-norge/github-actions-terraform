#!/bin/env bash
#
# Source for the export-envs step
#
# Makes environment variables available to the subsequent steps of the job by
# appending them to $GITHUB_ENV, in this order:
#   1. the plain values of 'extra-envs';
#   2. the secret-sourced values of 'extra-envs-from-secrets'.
# $GITHUB_ENV is last-wins, so a key in both maps ends up with the
# secret-sourced value.
#
# Plain values are logged; secret values never are. A mapped secret name that
# is missing from the secrets bag fails the step; whatever was appended before
# it stays appended, the step is not transactional.
#
# Required variables (shell-locals set by the action.yml shim, NOT exported):
#   input_extra_envs               - JSON object, env name -> value
#   input_extra_envs_from_secrets  - JSON object, env name -> secret name
#   input_secrets_json             - JSON object, toJSON(secrets)
#
# Every failure below returns explicitly instead of relying on 'set -e', so the
# step fails the same way under the runner's 'bash -eo pipefail' and in the
# local runner; the exit status is the failing command's own (jq's, typically).
#

set +o nounset

# Load helpers (provides export-environment-variable and
# export-secret-environment-variable via helpers_additional.sh)
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Main Logic
# ============================================================================

function export-plain-envs {
  [ ! -z "${input_extra_envs}" ] || return 0

  local env_keys env_key env_value
  start-group "Making environment variables available to subsequent actions"
  # The keys are joined on spaces and word-split again below, so a key that
  # contains whitespace becomes several variables. Names like that are not
  # valid environment variable names anyway.
  env_keys=$(echo ${input_extra_envs} | jq -r '[keys[]] | join(" ")') || return $?
  for env_key in ${env_keys}; do
    env_value=$(echo "${input_extra_envs}" | jq --arg key "${env_key}" -r '.[$key]') || return $?
    export-environment-variable "${env_key}" "${env_value}" || return $?
  done
  end-group
}

function export-secret-envs {
  [ ! -z "${input_extra_envs_from_secrets}" ] || return 0

  local env_keys env_key secret_name secret_value
  start-group "Making environment variables with secrets available to subsequent actions"
  env_keys=$(echo ${input_extra_envs_from_secrets} | jq -r '[keys[]] | join(" ")') || return $?
  for env_key in ${env_keys}; do
    log-info "Get secret name for '${env_key}' ..."
    secret_name=$(echo "${input_extra_envs_from_secrets}" | jq --arg key "${env_key}" -r '.[$key]') || return $?

    # A secret name that is not available to the workflow used to resolve to
    # the literal four characters 'null' and get exported as if it were a
    # value, with no warning. That surfaced far from its cause — typically as
    # an opaque Azure login failure. The key's existence is checked, not the
    # value: an existing secret whose value is 'null' or empty is legitimate.
    if [ ! "$(echo "${input_secrets_json}" | jq --arg key "${secret_name}" 'has($key)')" == 'true' ]; then
      log-error "the secret '${secret_name}', configured for environment variable '${env_key}', is not available to this workflow!"
      log-error "check the spelling, and that the calling workflow passes secrets down with 'secrets: inherit'."
      return 1
    fi

    log-info "Secret is named '${secret_name}', reading value ..."
    secret_value=$(echo "${input_secrets_json}" | jq --arg key "${secret_name}" -r '.[$key]') || return $?
    export-secret-environment-variable "${env_key}" "${secret_value}" || return $?
  done
  end-group
}

function main {
  log-multiline "input 'extra-envs'" "${input_extra_envs}"
  log-multiline "input 'extra-envs-from-secrets'" "${input_extra_envs_from_secrets}"

  export-plain-envs || return $?
  export-secret-envs || return $?

  return 0
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
