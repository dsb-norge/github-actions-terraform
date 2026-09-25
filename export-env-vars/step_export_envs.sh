#!/bin/env bash
#
# Source for the export-envs step
#
# Makes environment variables available to the subsequent steps of the job by
# appending them to $GITHUB_ENV, in this order:
#   1. every secret whose name starts with a prefix listed in
#      'export-secrets-with-prefixes-json', under its own name, each followed
#      by a copy whose name after the prefix is lower-cased when that prefix
#      is also listed in 'lower-case-copies-for-prefixes-json';
#   2. the plain values of 'extra-envs';
#   3. the secret-sourced values of 'extra-envs-from-secrets'.
# $GITHUB_ENV is last-wins, so a later source overrides an earlier one: both
# maps override the prefix export, and a key in both maps ends up with the
# secret-sourced value.
#
# Plain values are logged; secret values never are. A mapped secret name that
# is missing from the secrets bag fails the step; whatever was appended before
# it stays appended, the step is not transactional. An invalid prefix list
# fails the step before anything is appended.
#
# The lower-case copy exists because GitHub stores secret names upper-cased:
# an environment secret created as TF_VAR_tenant_id reaches the job as
# TF_VAR_TENANT_ID, and Terraform variable names are case-sensitive, so only
# the copy sets a variable named tenant_id.
#
# Required variables (shell-locals set by the action.yml shim, NOT exported):
#   input_extra_envs               - JSON object, env name -> value
#   input_extra_envs_from_secrets  - JSON object, env name -> secret name
#   input_secrets_json             - JSON object, toJSON(secrets)
#
# Optional variables (shell-locals set by the action.yml shim, NOT exported):
#   input_export_secrets_with_prefixes_json - JSON array of non-empty name
#                                             prefixes; empty or '[]' exports
#                                             nothing and logs nothing
#   input_lower_case_copies_for_prefixes_json - JSON array of non-empty name
#                                             prefixes whose prefix-exported
#                                             secrets also get a lower-cased
#                                             copy; empty or '[]' adds none
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

# Prints what is wrong with the prefix list $2 of input $1, or nothing when it
# is a valid list. Slurped, so that two JSON values in a row are rejected
# rather than validated one by one. An empty prefix would select every secret
# in the bag, the workflow's own token included, so it is an error, not a
# wildcard.
function prefix-list-problem {
  local name="${1}" list="${2}" problem
  # A caller's expression that evaluates to the empty string arrives as '',
  # not as the declared default: treat it as the default.
  [ -n "${list//[[:space:]]/}" ] || return 0
  problem=$(echo "${list}" | jq -rs '
    if length != 1 then "must hold exactly one JSON array"
    elif (.[0] | type) != "array" then "must be a JSON array of prefixes, not \(.[0] | type)"
    elif any(.[0][]; type != "string" or . == "") then "must hold non-empty strings only"
    else empty end' 2>/dev/null) || problem="is not valid JSON"
  [ -z "${problem}" ] || echo "input '${name}' ${problem}: ${list}"
}

function export-prefixed-secrets {
  local prefixes_json="${input_export_secrets_with_prefixes_json}"
  local lower_json="${input_lower_case_copies_for_prefixes_json:-}"

  local problem
  for problem in "$(prefix-list-problem export-secrets-with-prefixes-json "${prefixes_json}")" \
    "$(prefix-list-problem lower-case-copies-for-prefixes-json "${lower_json}")"; do
    if [ -n "${problem}" ]; then
      log-error "${problem}"
      return 1
    fi
  done
  [ -n "${lower_json//[[:space:]]/}" ] || lower_json='[]'

  [ -n "${prefixes_json//[[:space:]]/}" ] || return 0

  # The default: nothing to export, and nothing logged, so a caller that does
  # not use prefixes sees the same log as before the input existed.
  [ "$(echo "${prefixes_json}" | jq 'length')" != '0' ] || return 0

  log-multiline "input 'export-secrets-with-prefixes-json'" "${prefixes_json}"

  if [ ! "$(echo "${input_secrets_json}" | jq -r 'type' 2>/dev/null)" == 'object' ]; then
    log-error "input 'secrets-json' is not a JSON object, cannot export secrets by prefix!"
    return 1
  fi

  [ "$(echo "${lower_json}" | jq 'length')" == '0' ] ||
    log-multiline "input 'lower-case-copies-for-prefixes-json'" "${lower_json}"

  local secret_names secret_name secret_value lower_prefix lower_name
  start-group "Making secrets with a listed name prefix available to subsequent actions"
  # Names only, one per line, in 'keys' order. startswith is case-sensitive.
  secret_names=$(echo "${input_secrets_json}" | jq -r --argjson prefixes "$(echo "${prefixes_json}" | jq -c '.')" \
    'keys[] | select(. as $name | any($prefixes[]; . as $prefix | $name | startswith($prefix)))') || return $?
  if [ -z "${secret_names}" ]; then
    log-info "No secret has a listed name prefix."
  fi
  while IFS= read -r secret_name; do
    [ -n "${secret_name}" ] || continue
    log-info "Secret '${secret_name}' has a listed name prefix, reading value ..."
    secret_value=$(echo "${input_secrets_json}" | jq --arg key "${secret_name}" -r '.[$key]') || return $?
    export-secret-environment-variable "${secret_name}" "${secret_value}" || return $?
    lower_prefix=$(echo "${lower_json}" | jq -r --arg name "${secret_name}"       'first(.[] | select(. as $prefix | $name | startswith($prefix))) // empty') || return $?
    [ -n "${lower_prefix}" ] || continue
    lower_name="${lower_prefix}$(printf '%s' "${secret_name#"${lower_prefix}"}" | tr '[:upper:]' '[:lower:]')"
    # A name that is already lower case, or a secret of the lower-cased name,
    # is exported under its own name: no copy.
    ! grep -qxF -- "${lower_name}" <<<"${secret_names}" || continue
    log-info "Exporting a lower-case copy of '${secret_name}' as '${lower_name}' ..."
    export-secret-environment-variable "${lower_name}" "${secret_value}" || return $?
  done <<<"${secret_names}"
  end-group
}

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

  export-prefixed-secrets || return $?
  export-plain-envs || return $?
  export-secret-envs || return $?

  return 0
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
