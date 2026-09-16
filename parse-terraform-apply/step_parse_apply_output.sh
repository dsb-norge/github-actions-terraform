#!/bin/env bash
#
# Source for the parse-apply-output step
#
# Parses a terraform apply's console output file for the resource counts on
# its summary line, and writes a copy of the console with terraform's
# progress-tick lines removed.
#
# Two summary-line grammars, one per verb:
#   Apply complete! Resources: <A> added, <C> changed, <D> destroyed.
#   Destroy complete! Resources: <D> destroyed.
# Both are anchored at line start AND only the console above the first
# '^Outputs:$' line is scanned. Anchoring alone is not enough: an output
# value rendered as a heredoc ('note = <<EOT' … 'EOT') prints its content
# at column 0, so a value that happens to contain the summary text would
# otherwise be taken for the real line. The real summary always precedes
# the Outputs section.
#
# A failed apply prints no summary line at all — terraform emits it only on
# full success. Every count is then '?' and completed='false'. Never zeros:
# a zero reads as "nothing happened", which is the opposite of the truth
# for a partial apply (docs/Apply-and-destroy-reporting.md P2).
#
# Required environment variables:
#   input_apply_console_file  - Path to the apply console output file
#
# Outputs:
#   add-count, change-count, destroy-count, total-count  - integers or '?'
#   completed              - 'true' | 'false'
#   apply-kind             - 'apply' | 'destroy' | '' (when not completed)
#   filtered-console-file  - path of the tick-free copy (always written)
#

set +o nounset # allow unset variables (graceful handling of empty/missing input)

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# Progress ticks. Two bracket shapes, both real:
#   <addr>: Still creating... [10s elapsed]                     (create, read)
#   <addr>: Still modifying... [id=<id>, 10s elapsed]           (modify, destroy)
# Durations are Go durations truncated to seconds: '10s', '1m0s', '1m10s',
# '1h2m3s'. Drift in terraform's wording makes this filter stop matching
# and the comment degrade to noise rather than break — pinned by a fixture
# shaped like real output (P5).
TICK_REGEX='^[^[:space:]].*: Still (creating|destroying|modifying|reading)\.\.\. \[(id=[^]]*, )?([0-9]+h)?([0-9]+m)?[0-9]+s elapsed\]$'

# ============================================================================
# Main Logic
# ============================================================================

function main {
  log-info "Starting parse-apply-output..."

  local adds='?' changes='?' destroys='?' total='?'
  local completed='false' apply_kind=''

  # Filtered copy sits next to the raw file in RUNNER_TEMP. Written in every
  # branch, so the output path is always valid for the consumer to read.
  local filtered_file
  filtered_file="${RUNNER_TEMP:-/tmp}/$(basename "${input_apply_console_file:-apply-console}" .txt)-filtered.txt"
  : > "${filtered_file}"

  if [ -z "${input_apply_console_file:-}" ]; then
    log-warn "no apply console file given; counts are '?' and completed=false"
  elif [ ! -s "${input_apply_console_file}" ]; then
    log-warn "apply console file '${input_apply_console_file}' is missing or empty; counts are '?' and completed=false"
  else
    log-info "parsing apply console file: ${input_apply_console_file}"

    # grep -v exits 1 when it selects nothing (every line was a tick, or the
    # file was ticks-only) — not an error here.
    grep -vE "${TICK_REGEX}" "${input_apply_console_file}" > "${filtered_file}" || true
    local raw_lines filtered_lines
    raw_lines=$(wc -l < "${input_apply_console_file}")
    filtered_lines=$(wc -l < "${filtered_file}")
    log-info "removed $((raw_lines - filtered_lines)) progress-tick line(s) (${raw_lines} → ${filtered_lines})"

    # Only the console ABOVE the Outputs section can hold the summary line;
    # first match wins. See the file header for why both restrictions exist.
    local summary_line
    summary_line=$(awk '/^Outputs:$/ {exit} {print}' "${input_apply_console_file}" \
      | grep -E '^(Apply|Destroy) complete! Resources: ' | head -n1)

    if [[ "${summary_line}" =~ ^Apply\ complete!\ Resources:\ ([0-9]+)\ added,\ ([0-9]+)\ changed,\ ([0-9]+)\ destroyed\.$ ]]; then
      adds="${BASH_REMATCH[1]}"
      changes="${BASH_REMATCH[2]}"
      destroys="${BASH_REMATCH[3]}"
      completed='true'
      apply_kind='apply'
      log-info "apply completed: ${adds} added, ${changes} changed, ${destroys} destroyed"
    elif [[ "${summary_line}" =~ ^Destroy\ complete!\ Resources:\ ([0-9]+)\ destroyed\.$ ]]; then
      adds=0
      changes=0
      destroys="${BASH_REMATCH[1]}"
      completed='true'
      apply_kind='destroy'
      log-info "destroy completed: ${destroys} destroyed"
    elif [ -n "${summary_line}" ]; then
      log-error "found a summary line but could not parse it: '${summary_line}'"
    else
      log-warn "no 'Apply complete!' / 'Destroy complete!' summary line — apply did not complete"
    fi
  fi

  if [[ "${adds}${changes}${destroys}" =~ ^[0-9]+$ ]]; then
    total=$((adds + changes + destroys))
  fi

  set-output 'add-count' "${adds}"
  set-output 'change-count' "${changes}"
  set-output 'destroy-count' "${destroys}"
  set-output 'total-count' "${total}"
  set-output 'completed' "${completed}"
  set-output 'apply-kind' "${apply_kind}"
  set-output 'filtered-console-file' "${filtered_file}"

  log-info "parse-apply-output completed."
  return 0
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
