#!/bin/env bash
#
# Action-specific helper functions for create-validation-summary
#
# Provides formatting utilities used by the step script.
#

# Format a step status for the markdown summary table.
# Successful statuses are shown in backticks, failures in <kbd> tags.
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
