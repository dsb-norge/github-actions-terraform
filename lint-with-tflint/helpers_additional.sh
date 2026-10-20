#!/bin/env bash
#
# Action-specific helpers for lint-with-tflint.
# Auto-loaded by helpers.sh.
#

# Read the local module directories terraform recorded in a root's
# '.terraform/modules/modules.json', and the key each is reached through, into
# the arrays named by $1 and $2. The root comes first; the rest follow sorted.
#
#   $1 - name of the array variable to populate with directories
#   $2 - name of the array variable to populate with their keys ("" for the root)
#   $3 - path to modules.json
#   $4 - the root's absolute path; relative 'Dir' values are resolved against it
#
# A directory reached through several keys (a module called from two places)
# is listed once, with its shortest key: lint-with-tflint derives that
# directory's manifest from the entries at and below that key.
#
# NUL-delimited (jq --raw-output0 + read -d '') rather than newline-joined into
# a single string: the previous form iterated that string as '${DIRS[*]}', which
# is not array iteration but word-splitting — so a module path containing a
# space silently visited two directories that do not exist instead of the one
# that does. Requires jq 1.7, ref. docs/Per-goal-environment-variables.md §9.2.
function read-terraform-module-dirs {
  local -n _dirs_out="${1}"
  local -n _keys_out="${2}"
  local _modules_file="${3}"
  local _root="${4}"
  local _dir _key _out_file _err_file

  _dirs_out=()
  _keys_out=()
  _out_file="$(mktemp)"
  _err_file="$(mktemp)"

  # jq's exit code is checked rather than piping straight into the read loop:
  # an unparseable modules.json, or one without a '.Modules' array, otherwise
  # yields zero directories and the caller reports success having checked
  # nothing at all.
  if ! jq --raw-output0 --arg root "${_root}" '
    [ .Modules[] | select(.Dir | startswith(".terraform") | not) ]
    | group_by(.Dir)
    | map({dir: .[0].Dir, key: (map(.Key // "") | min_by(length))})
    | sort_by(.key != "", .dir)
    | .[]
    | (if .dir == "." then $root elif (.dir | startswith("/")) then .dir else $root + "/" + .dir end), .key' \
    "${_modules_file}" >"${_out_file}" 2>"${_err_file}"; then
    log-error "failed to read directories from the terraform modules file '${_modules_file}':"
    log-error "$(cat "${_err_file}")"
    rm -f "${_out_file}" "${_err_file}"
    return 1
  fi

  while IFS= read -r -d '' _dir && IFS= read -r -d '' _key; do
    _dirs_out+=("${_dir}")
    _keys_out+=("${_key}")
  done <"${_out_file}"

  rm -f "${_out_file}" "${_err_file}"
  return 0
}

# Write the manifest a module directory is linted against: the root's entries
# at and below the directory's key, that prefix stripped, every 'Dir' made
# absolute. tflint reads it through TF_DATA_DIR, so a module directory is
# inspected against exactly the modules the root installed, without an init of
# its own (docs/Linting.md).
#
#   $1 - path to the root's modules.json
#   $2 - the directory's key
#   $3 - the root's absolute path
#   $4 - the data directory to write '<dir>/modules/modules.json' into
function write-derived-manifest {
  local _modules_file="${1}" _key="${2}" _root="${3}" _data_dir="${4}"
  mkdir -p "${_data_dir}/modules" || return 1
  jq --arg key "${_key}" --arg root "${_root}" '
    {Modules: [ .Modules[]
      | select(.Key == $key or (.Key | startswith($key + ".")))
      | .Key |= (if . == $key then "" else ltrimstr($key + ".") end)
      | .Dir |= (if startswith("/") then . else $root + "/" + . end) ]}' \
    "${_modules_file}" >"${_data_dir}/modules/modules.json"
}

# The var files a root is linted with, into the array named by $1: every
# '*.tfvars' directly in the root except 'terraform.tfvars' and '*.auto.tfvars',
# which tflint loads by itself. Sorted, absolute.
#
#   $1 - name of the array variable to populate
#   $2 - the root's absolute path
function read-root-var-files {
  local -n _var_files_out="${1}"
  local _root="${2}" _file _name
  _var_files_out=()
  for _file in "${_root}"/*.tfvars; do
    [ -f "${_file}" ] || continue
    _name="$(basename "${_file}")"
    [ "${_name}" == 'terraform.tfvars' ] && continue
    [[ "${_name}" == *.auto.tfvars ]] && continue
    _var_files_out+=("${_file}")
  done
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

  # How many entries must end up applied. 'length' works on any jq, which is
  # the point: it is the cross-check that catches a jq too old for
  # --raw-output0 (ref. docs/Per-goal-environment-variables.md §9.2). Without
  # it, such a jq makes the read loop consume nothing and the step continues
  # having applied nothing — silently, and only on the runner images where it
  # happens to be old.
  local _extra_envs_expected _extra_envs_applied=0
  if ! _extra_envs_expected=$(jq -r 'length' "${_extra_envs_file}"); then
    log-error "unable to count the entries in '${_extra_envs_file}'!"
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
    _extra_envs_applied=$((_extra_envs_applied + 1))
  done < <(jq --raw-output0 "${_EXTRA_ENVS_FILTER}" "${_extra_envs_file}")

  if [ ! "${_extra_envs_applied}" == "${_extra_envs_expected}" ]; then
    log-error "applied ${_extra_envs_applied} of ${_extra_envs_expected} environment variable(s) from '${_extra_envs_file}'!"
    log-error "this usually means jq is older than 1.7 and does not support '--raw-output0' — check the runner image."
    end-group
    return 1
  fi
  end-group

  return 0
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
