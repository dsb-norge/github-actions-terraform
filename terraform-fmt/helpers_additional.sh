#!/bin/env bash
#
# Action-specific helpers for terraform-fmt.
# Auto-loaded by helpers.sh.
#

# Read the module directories terraform recorded in
# '<project-dir>/.terraform/modules/modules.json' into the array named by $1.
#
#   $1 - name of the array variable to populate
#   $2 - path to modules.json
#   $3 - prefix to prepend to each relative directory (usually "$(pwd)/")
#
# NUL-delimited (jq --raw-output0 + read -d '') rather than newline-joined into
# a single string: the previous form iterated that string as '${DIRS[*]}', which
# is not array iteration but word-splitting — so a module path containing a
# space silently visited two directories that do not exist instead of the one
# that does. Requires jq 1.7, ref. docs/Per-goal-environment-variables.md §9.2.
function read-terraform-module-dirs {
  local -n _dirs_out="${1}"
  local _modules_file="${2}"
  local _prefix="${3}"
  local _dir

  _dirs_out=()
  while IFS= read -r -d '' _dir; do
    _dirs_out+=("${_dir}")
  done < <(jq --raw-output0 --arg pwd "${_prefix}" \
    '[ .Modules[].Dir | select( startswith(".terraform") | not) ] | unique | sort | $pwd + .[]' \
    "${_modules_file}")
}

# Apply a JSON environment-variable map to the current shell
# ==========================================================
# Applies the resolved environment for this action's goal, as produced by the
# 'resolve-goal-envs' action. A JSON null unsets the variable rather than
# emptying it — $GITHUB_ENV cannot express that, and the distinction matters for
# anything that treats "" as a meaningful value.
#
# Takes a path, not the JSON itself: the values may be secrets, and nothing here
# may hold the payload in a shell variable while allexport is in scope (ref. the
# ARG_MAX rule in CLAUDE.md). jq reads the file and the loop consumes a stream,
# so only one key and one value transit shell variables at a time.
#
# NUL-delimited (jq --raw-output0, requires jq 1.7) so multiline values such as
# PEM keys and values containing shell metacharacters survive verbatim, with no
# encoding hop and no per-variable subshell. The sentinel marks a JSON null; an
# empty field is a genuine empty-string value.
#
# Call this early in main, BEFORE the action's own exports: there is no
# reserved-name list, so that ordering is what decides who wins. See
# docs/Per-goal-environment-variables.md §6.2 and §6.3.
#
# Locals are underscore-prefixed on purpose — a caller whose variable is named
# 'file', 'key' or 'value' must not collide with them. Not 'readonly' either:
# helpers.sh being sourced twice in one shell would then hard-fail.
_EXTRA_ENVS_UNSET='__DSB_UNSET__'
_EXTRA_ENVS_FILTER='to_entries[] | (.key, (if .value == null then "__DSB_UNSET__" else (.value | tostring) end))'

function apply-extra-envs {
  local _extra_envs_file="${1}" _extra_envs_key _extra_envs_value

  if [ -z "${_extra_envs_file}" ]; then
    log-info "no per-goal environment variables file configured."
    return 0
  fi
  if [ ! -f "${_extra_envs_file}" ]; then
    log-error "the per-goal environment variables file '${_extra_envs_file}' does not exist!"
    return 1
  fi

  start-group "applying per-goal environment variables"
  while IFS= read -r -d '' _extra_envs_key && IFS= read -r -d '' _extra_envs_value; do
    if [ "${_extra_envs_value}" == "${_EXTRA_ENVS_UNSET}" ]; then
      log-info "unsetting '${_extra_envs_key}'"
      unset "${_extra_envs_key}"
    else
      log-info "setting '${_extra_envs_key}'"
      export "${_extra_envs_key}=${_extra_envs_value}"
    fi
  done < <(jq --raw-output0 "${_EXTRA_ENVS_FILTER}" "${_extra_envs_file}")
  end-group

  return 0
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
