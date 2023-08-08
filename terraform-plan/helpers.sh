#!/bin/env bash

# Helper consts
_action_name='terraform-plan'

# Helper functions
function _log { echo "${1}${_action_name}: ${2}"; }
function log-info { _log "" "${*}"; }
function log-error { _log "ERROR: " "${*}"; }
function start-group { echo "::group::${_action_name}: ${*}"; }
function end-group { echo "::endgroup::"; }
function log-json {
  start-group "${1}"
  echo "${2}"
  end-group
}

# log-info "'helpers.sh' loaded."
