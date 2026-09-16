#!/bin/env bash
#
# Action-specific helper functions for create-validation-summary
#
# Provides formatting utilities used by the step script.
#

# Format a step status for the markdown summary table.
# Successful statuses are shown in backticks, failures in <kbd> tags.
#
# NOTE: this text representation (`success` / <kbd>failure</kbd>) is an
# intentional divergence from the grouped head, which uses emoji
# (✅/❌/…). The per-env head has one wide "Result" column where text reads
# well; the grouped head has many narrow per-env columns where emoji stay
# compact. Keep them different — see docs/Workflow-pr-comments.md §5.1/§5.3.
#
# Arguments:
#   $1 - status string (e.g., "success", "failure", "skipped")
# Output:
#   Formatted markdown string written to stdout
function format-status {
  local status="${1}"
  if [ "${status}" == 'success' ]; then
    echo "\`${status}\`"
  else
    echo "<kbd>${status}</kbd>"
  fi
}

# Render the column-1 step-icon cell with a hover tooltip (the label is the
# step name). Kept byte-identical to the grouped head's helper of the same
# name (aggregate-validation-summaries/helpers_additional.sh) so the two
# validation tables render col-1 the same way.
function _render_step_icon_cell {
  local emoji="${1}"
  local label="${2}"
  echo "<span title=\"${label}\">${emoji}</span>"
}

# Render a mm:ss time cell. A real duration is backtick-wrapped; empty or
# the literal 'N/A' (the action.yml input default) renders the em-dash. Both
# carry the unit tooltip — same shape the grouped head uses.
function _render_time_cell {
  local v="${1:-}"
  local title='mm:ss (minutes:seconds)'
  if [ -z "${v}" ] || [ "${v}" = 'N/A' ]; then
    echo "<span title=\"${title}\">—</span>"
  else
    echo "<span title=\"${title}\">\`${v}\`</span>"
  fi
}

# Render one "applied / planned" badge for the Apply / Destroy details rows.
#   $1 emoji, $2 applied count, $3 planned count, $4 past-tense verb,
#   $5 whether the operation completed ('true' or anything else)
# The numerator is '?' whenever the operation did not complete, whatever
# count arrived: terraform prints no summary line for a failed apply, and a
# zero there would read as "nothing happened" for an infrastructure that
# may be half applied (docs/Apply-and-destroy-reporting.md P2, §8.3).
# Either side that is not numeric renders as '?'.
function _render_ratio_badge {
  local emoji="${1}" applied="${2}" planned="${3}" verb="${4}" completed="${5}"
  local num='?' den='?'
  if [ "${completed}" = 'true' ] && [[ "${applied}" =~ ^[0-9]+$ ]]; then num="${applied}"; fi
  if [[ "${planned}" =~ ^[0-9]+$ ]]; then den="${planned}"; fi
  echo "<span title=\"Applied / planned\">\`${emoji} ${num}/${den}\` ${verb}</span>"
}

# True when the value is a positive integer — the gate for every warnings
# row. 0, empty, 'N/A' and '?' all fail it.
function _is_positive_int {
  [[ "${1:-0}" =~ ^[0-9]+$ ]] && [ "${1}" -gt 0 ]
}
