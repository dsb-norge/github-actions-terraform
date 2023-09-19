#!/bin/env bash

# Make environment variable available to subsequent actions
# ==========================================================
function export-environment-variable {
  local envName envValue
  envName="${1}"
  envValue="${2}"
  log-info "Exporting environment variable '${envName}' -> '${envValue}'"
  _export-env "$@"
}
function export-secret-environment-variable {
  local envName
  envName="${1}"
  log-info "Exporting environment variable '${envName}'"
  _export-env "$@"
}
function _export-env {
  local envName envValue delimiter
  envName="${1}"
  envValue="${2}"
  delimiter=$(echo $RANDOM | md5sum | head -c 20)

  # supports multiline strings
  echo "${envName}<<\"${delimiter}\"" >>$GITHUB_ENV
  echo "${envValue}" >>$GITHUB_ENV
  echo "\"${delimiter}\"" >>$GITHUB_ENV
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
