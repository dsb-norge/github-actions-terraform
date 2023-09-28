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
function rm-field { ENVIRONMENT_OBJ=$(echo "${ENVIRONMENT_OBJ}" | jq --arg key_name "$1" 'del(.[$key_name])'); }
function _jjq { echo ${ENV_VARS} | base64 --decode | jq -r ${*}; }
function fail-field {
  DO_EXIT=1
  start-group "ERROR: ${1}"
  echo "$(_jjq '.')"
  end-group
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
