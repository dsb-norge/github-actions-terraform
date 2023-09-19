#!/bin/env bash

# Helper consts
_action_name="$(basename "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)")"

# Helper functions
function _log { echo "${1}${_action_name}: ${2}"; }
function log-info { _log "" "${*}"; }
function log-debug { _log "DEBUG: " "${*}"; }
function log-warn { _log "WARN: " "${*}"; }
function log-error { _log "ERROR: " "${*}"; }
function start-group { echo "::group::${_action_name}: ${*}"; }
function end-group { echo "::endgroup::"; }
function log-multiline {
  start-group "${1}"
  echo "${2}"
  end-group
}
function mask-value { echo "::add-mask::${*}"; }
function set-output { echo "${1}=${2}" >>$GITHUB_OUTPUT; }
function set-multiline-output {
  local outputName outputValue delimiter
  outputName="${1}"
  outputValue="${2}"
  delimiter=$(echo $RANDOM | md5sum | head -c 20)
  echo "${outputName}<<\"${delimiter}\"" >>$GITHUB_OUTPUT
  echo "${outputValue}" >>$GITHUB_OUTPUT
  echo "\"${delimiter}\"" >>$GITHUB_OUTPUT
}
function ws-path {
  local inPath
  inPath="${1}"
  realpath --relative-to="${GITHUB_WORKSPACE}" "${inPath}"
}

log-info "'$(basename ${BASH_SOURCE[0]})' loaded."

if [ -f "${GITHUB_ACTION_PATH}/helpers_additional.sh" ]; then
  source "${GITHUB_ACTION_PATH}/helpers_additional.sh"
fi
