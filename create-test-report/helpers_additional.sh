#!/bin/env bash
#
# Action-specific helper functions for create-test-report.
# Auto-loaded by helpers.sh.
#

# Format a step status for the markdown summary table.
# Successful statuses are shown in backticks, everything else in <kbd>.
# Same shape as create-validation-summary's per-env head so the two
# module-ci comments read alike.
#
# Arguments:
#   $1 - status string (e.g. "success", "failure", "skipped")
function format-status {
  local status="${1}"
  if [ "${status}" == 'success' ]; then
    echo "\`${status}\`"
  else
    echo "<kbd>${status}</kbd>"
  fi
}

# Byte-budgeted tail that always lands on a line boundary.
#
# The legacy action used a bare `tail -c 65000`, which can cut mid-codepoint
# (corrupting the rendered comment when the report holds multi-byte chars —
# the ✅/❌ marks terraform-test writes into it, for one) and mid-line
# (leaving a dangling fragment at the top of the block). `tail -c` is
# byte-safe on the total length; piping through `sed 1d` drops the first,
# possibly-partial line, which is always whole bytes because a newline is
# one ASCII byte. Files within budget pass through unchanged, so the
# non-capped output is byte-identical to the legacy action's.
#
# Arguments:
#   $1 - file path
#   $2 - byte budget
function line_anchored_tail {
  local file="${1}"
  local budget="${2}"
  [ "${budget}" -le 0 ] && return 0
  [ -z "${file}" ] && return 0
  [ ! -f "${file}" ] && return 0
  local file_size
  file_size=$(wc -c <"${file}")
  if [ "${file_size}" -le "${budget}" ]; then
    cat "${file}"
    return
  fi
  tail -c "${budget}" "${file}" | sed '1d'
}

# Environment variables whose values never go into a pull request comment.
#
# GitHub masks secrets in job logs, not in text posted through the API, and
# terraform quotes some of these values in its error messages: every azurerm
# provider error names the subscription as `Subscription: "<id>"`. The module
# CI sets the first three from secrets at workflow level, so every step sees
# them; the rest are the other credential inputs of the azurerm and azapi
# providers and backend.
REDACTED_ENV_VARS=(
  ARM_SUBSCRIPTION_ID
  ARM_TENANT_ID
  ARM_CLIENT_ID
  ARM_CLIENT_SECRET
  ARM_CLIENT_CERTIFICATE_PASSWORD
  ARM_OIDC_TOKEN
  ARM_OIDC_REQUEST_TOKEN
  ARM_ACCESS_KEY
  ARM_SAS_TOKEN
)

# Replace, in place, every occurrence of a non-empty REDACTED_ENV_VARS value
# with '***', which is what GitHub prints for a masked value in a log.
#
# The match is literal: the value is quoted in the pattern, so glob characters
# in a secret match only themselves. The variable is passed by name (nameref),
# so a body of up to 65k never goes through a subshell or onto argv.
#
# Arguments:
#   $1 - name of the variable to redact
function redact-known-values {
  local -n _redact_target="${1}"
  local _name _value
  for _name in "${REDACTED_ENV_VARS[@]}"; do
    _value="${!_name:-}"
    [ -z "${_value}" ] && continue
    _redact_target="${_redact_target//"${_value}"/***}"
  done
}
