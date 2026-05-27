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
