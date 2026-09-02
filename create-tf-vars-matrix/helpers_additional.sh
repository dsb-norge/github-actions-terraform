#!/bin/env bash

# work with json mess
# ==========================================================
function get-input-val { echo "${INPUTS_JSON}" | jq -r --arg name "${1}" '.[$name] | select( . != null )'; }
function get-yaml-input-as-json { echo "${YML_INPUTS_AS_JSON[${1}]}"; }
function _jq { echo ${INPUT_ENVIRONMENT} | base64 --decode | jq -r ${*}; }
function has-field { if [[ "$(echo "${ENVIRONMENT_OBJ}" | jq --arg name "$1" 'has($name)')" == 'true' ]]; then true; else false; fi; }
function is-yml-input { if [[ " ${YML_INPUTS[*]} " =~ " ${1} " ]]; then true; else false; fi; }
function set-field { ENVIRONMENT_OBJ=$(echo "${ENVIRONMENT_OBJ}" | jq --arg name "$1" --arg value "$2" '.[$name] = $value'); }
function set-field-from-json { ENVIRONMENT_OBJ=$(echo "${ENVIRONMENT_OBJ}" | jq --arg name "$1" --argjson json_value "$2" '.[$name] = $json_value'); }
function set-bool-field-true { set-field-from-json "$1" "true"; } # really just an alias
function set-bool-field-false { set-field-from-json "$1" "false"; } # really just an alias
function get-val { echo "${ENVIRONMENT_OBJ}" | jq -r --arg name "${1}" '.[$name] | select( . != null )'; }
# Reads a '*-yml' field off the environment object and converts it from YAML to
# JSON. The value stored there is the YAML text the caller wrote, so it has to
# be parsed before it can reach 'jq --argjson' — which reports only 'invalid
# JSON text passed to --argjson', naming neither the field nor the environment.
function get-val-as-json {
  local field="${1}" raw json
  raw="$(get-val "${field}")"
  if ! json="$(printf '%s' "${raw}" | yq e -o=json - 2>/dev/null)"; then
    log-error "the environment's '${field}' is not valid yaml!"
    log-multiline "value of '${field}'" "${raw}"
    return 1
  fi
  printf '%s' "${json}"
}
function rm-field { ENVIRONMENT_OBJ=$(echo "${ENVIRONMENT_OBJ}" | jq --arg key_name "$1" 'del(.[$key_name])'); }
function _jjq { echo ${ENV_VARS} | base64 --decode | jq -r ${*}; }
function fail-field {
  DO_EXIT=1
  start-group "ERROR: ${1}"
  echo "$(_jjq '.')"
  end-group
}

# merge and normalize yml fields
# ==========================================================

# The goal keys valid in the per-goal environment-variable maps. Same
# vocabulary a caller writes in 'goals-yml', except that 'all' is not a goal:
# it is shorthand expanded inside each workflow step's 'if:', so there is
# nothing to attach per-goal values to. The every-goal layer is the plain
# 'extra-envs-yml'. Kept in sync with the 'resolve-goal-envs' action and
# docs/Per-goal-environment-variables.md §2.2 — the resolver hard-fails on
# keys outside this list, which is what makes 'all:' fail loudly here rather
# than being silently dropped.
GOAL_KEYS=(
  init
  format
  validate
  lint
  plan
  apply
  destroy-plan
  destroy
)

# Merge a global '*-yml' field value ($1) with an environment-specific one
# ($2), environment wins.
#
# 'add' is a shallow merge: correct for the flat scalar maps, and the only
# thing jq defines for arrays — 'pr-auto-merge-from-actors-yml' is a YAML
# array and '*' errors on arrays outright. '*' recurses into objects while
# replacing scalars, which is what the nested per-goal maps need: a
# per-environment override of one goal must not discard that goal's other
# keys. The two are provably identical for flat objects of scalars, so the
# array case is the only one that forces the dispatch. '*' also preserves
# null leaves, which the "a null value unsets the variable" semantics depend
# on. Ref. docs/Per-goal-environment-variables.md §9.5.
function merge-yml-field-json {
  printf '%s\n%s\n' "${1}" "${2}" | jq -s '
    if   (.[0] == null) then .[1]
    elif (.[1] == null) then .[0]
    elif ((.[0] | type) == "array") then add
    else .[0] * .[1]
    end
  '
}

# Normalize a per-goal environment-variable map ($1) so that every goal key
# exists, defaulting to an empty object.
#
# Without this, 'toJSON(matrix.vars.extra-envs-per-goal.plan)' in the workflow
# renders the four-character string 'null' for an absent key, which then
# reaches the resolver's jq as invalid input. Unknown keys are passed through
# untouched — rejecting them is the resolver's job, so the caller gets one
# error message from one place.
function normalize-goal-keys-json {
  local in_json="${1}" keys_json
  [ -z "${in_json}" ] && in_json='{}'
  keys_json=$(printf '%s\n' "${GOAL_KEYS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  printf '%s\n' "${in_json}" | jq -c --argjson keys "${keys_json}" '
    ( . // {} )
    | if type != "object" then . else
        reduce $keys[] as $k (.; if has($k) then . else .[$k] = {} end)
      end
  '
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
