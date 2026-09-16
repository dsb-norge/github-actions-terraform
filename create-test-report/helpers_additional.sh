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
