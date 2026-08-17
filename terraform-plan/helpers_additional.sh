#!/bin/env bash
#
# Action-specific helpers for terraform-plan.
# Auto-loaded by helpers.sh.
#

# Format an integer seconds count as 'mm:ss'.
# Minutes are zero-padded only to width 1 (so '0:07', '1:23'); seconds are
# always zero-padded to width 2. Minutes may exceed 99 — CI plans rarely
# do, but the format degrades gracefully (e.g. '120:05'). No hours field
# on purpose: keeps the renderer trivial and the display unambiguous.
function format-duration-mmss {
  local total="${1:-0}"
  local minutes=$((total / 60))
  local seconds=$((total % 60))
  printf '%d:%02d' "${minutes}" "${seconds}"
}

# Split a whitespace-delimited argument string into the array named by $1.
#
#   $1 - name of the array variable to populate
#   $2 - the argument string (may be empty, may contain newlines)
#
# The 'extra-global-args' / 'extra-plan-args' inputs are documented as strings
# of arguments the caller injects verbatim, so splitting on whitespace is their
# contract and is preserved here. What changes is everything around it: the
# command used to be assembled into one string and then re-split by the shell
# at invocation time, which also glob-expanded every element against the
# working directory and turned an empty input into an empty argv element in
# some shells. Splitting once, here, and invoking as "${cmd[@]}" keeps the
# caller's words intact while the paths the action itself builds are never
# split or expanded.
#
# Note: quoting inside the argument string is NOT shell-parsed —
# '-var=msg=a b' is two arguments, not one. Honoring quotes would mean 'eval'
# or 'xargs', both of which change behaviour for existing callers (an
# unbalanced apostrophe currently passes through fine and would start failing).
function split-args-to-array {
  local -n _args_out="${1}"
  # Newlines and tabs are whitespace for this purpose too; 'read' without -d
  # would otherwise stop at the first newline and silently drop the rest.
  local _str="${2//[$'\n\t']/ }"

  _args_out=()
  read -r -a _args_out <<<"${_str}"
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
  local _extra_envs_file="${1}" _extra_envs_key _extra_envs_value _extra_envs_type

  if [ -z "${_extra_envs_file}" ]; then
    log-info "no per-goal environment variables file configured."
    return 0
  fi
  if [ ! -f "${_extra_envs_file}" ]; then
    log-error "the per-goal environment variables file '${_extra_envs_file}' does not exist!"
    return 1
  fi

  # Validated before anything is applied. Without this an unparseable, empty or
  # truncated file applies nothing at all and the step carries on as if it had —
  # the consequence then surfaces as an OOM or a wrong-credentials error far
  # from its cause, which is the failure mode this whole feature exists to
  # avoid. resolve-goal-envs already guarantees a JSON object; this is the last
  # line of defence, and cheap.
  if ! _extra_envs_type=$(jq -r 'type' "${_extra_envs_file}" 2>/dev/null); then
    log-error "the per-goal environment variables file '${_extra_envs_file}' is not valid JSON!"
    return 1
  fi
  if [ ! "${_extra_envs_type}" == 'object' ]; then
    log-error "the per-goal environment variables file '${_extra_envs_file}' must hold a JSON object, got '${_extra_envs_type:-nothing}'!"
    return 1
  fi

  start-group "applying per-goal environment variables"
  while IFS= read -r -d '' _extra_envs_key && IFS= read -r -d '' _extra_envs_value; do
    # 'export' cannot be relied on to reject a bad name: given the key 'FOO=BAR'
    # and the value 'x' it happily assigns 'BAR=x' to FOO — silently setting a
    # different variable than the caller asked for. Hence the explicit check.
    if [[ ! "${_extra_envs_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log-error "'${_extra_envs_key}' is not a valid environment variable name!"
      end-group
      return 1
    fi
    if [ "${_extra_envs_value}" == "${_EXTRA_ENVS_UNSET}" ]; then
      log-info "unsetting '${_extra_envs_key}'"
      if ! unset "${_extra_envs_key}"; then
        log-error "'${_extra_envs_key}' is not a usable environment variable name!"
        end-group
        return 1
      fi
    else
      log-info "setting '${_extra_envs_key}'"
      # Still guarded: a readonly variable makes 'export' fail even though the
      # name itself is valid.
      if ! export "${_extra_envs_key}=${_extra_envs_value}"; then
        log-error "'${_extra_envs_key}' is not a usable environment variable name!"
        end-group
        return 1
      fi
    fi
  done < <(jq --raw-output0 "${_EXTRA_ENVS_FILTER}" "${_extra_envs_file}")
  end-group

  return 0
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
