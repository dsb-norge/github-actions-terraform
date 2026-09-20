#!/bin/env bash
#
# Source for the parse-apply-output step
#
# Parses a terraform apply's console output file for the resource counts on
# its summary line, and writes a copy of the console with terraform's
# progress-tick lines removed.
#
# Two summary-line grammars, one per verb:
#   Apply complete! Resources: [<I> imported, ]<A> added, <C> changed, <D> destroyed.[ Actions: <N> invoked[, <M> failed].]
#   Destroy complete! Resources: <D> destroyed.
#
# The segment list is open-ended: terraform adds verbs as the language grows
# ('imported' arrived with import blocks) and places them in its own order. Each
# verb is therefore matched on its own, the way parse-terraform-plan reads the
# 'Plan:' line, and an unrecognised segment is logged rather than treated as a
# parse failure — a finished apply must never be reported as a failed one.
# Only the resources group — up to its full stop — is split into segments.
# Terraform 1.14+ appends an 'Actions:' sentence on the same line (#37689);
# it counts action invocations, not resources, and is ignored. Splitting the
# whole line once took '0 destroyed. Actions: 2 invoked' for an unknown
# segment and warned on every such apply (P38).
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
# What this parser does NOT decide is whether the apply succeeded. That is
# the step's exit code, carried by the workflow as the step outcome; the
# renderers derive every status cell, annotation and headline from it and
# treat these counts as decoration, '?' when unavailable
# (docs/Apply-and-destroy-reporting.md §14). Given the exit code, the parser
# can name the one situation worth a human look: terraform exited 0 but its
# console was not recognised — a new wording, most likely. That is a
# ::warning on the run page asking for the console to be reported, never a
# changed count and never a failed step.
#
# Required environment variables:
#   input_apply_console_file  - Path to the apply console output file
#
# Optional environment variables:
#   input_apply_exitcode      - terraform apply's raw exit code (terraform-apply's
#                               `exitcode`). Only read for the mismatch warning;
#                               empty disables it.
#
# Outputs:
#   import-count, add-count, change-count, destroy-count, total-count  - integers or '?'
#   completed              - 'true' when a summary line parsed, else 'false'.
#                            Says whether the COUNTS are available — not
#                            whether the apply succeeded.
#   apply-kind             - 'apply' | 'destroy' | '' (when not completed)
#   filtered-console-file  - path of the tick-free copy (always written)
#

set +o nounset # allow unset variables (graceful handling of empty/missing input)

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# Progress ticks. Two bracket shapes, both real:
#   <addr>: Still creating... [10s elapsed]                     (create, read; and the
#                                                                ephemeral open/renew/close)
#   <addr>: Still modifying... [id=<id>, 10s elapsed]           (modify, destroy)
# Durations are Go durations truncated to seconds — '10s', '1m0s', '1h2m3s'
# up to 1.11; zero-padded minutes from 1.12 — '00m10s', '60m10s' (P35).
# Ephemeral resources (1.10+) tick with 'opening', 'renewing' and 'closing'
# (P39). Drift in terraform's wording makes this filter stop matching and
# the comment degrade to noise rather than break — pinned by fixtures shaped
# like real output (P5).
TICK_REGEX='^[^[:space:]].*: Still (creating|destroying|modifying|reading|opening|renewing|closing)\.\.\. \[(id=[^]]*, )?([0-9]+h)?([0-9]+m)?[0-9]+s elapsed\]$'

# ============================================================================
# Main Logic
# ============================================================================

function main {
  log-info "Starting parse-apply-output..."

  local imports='?' adds='?' changes='?' destroys='?' total='?'
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

    # The resources group ends at its first full stop; whatever follows (the
    # 1.14+ 'Actions:' sentence) is not a resource count.
    if [[ "${summary_line}" =~ ^(Apply|Destroy)\ complete!\ Resources:\ ([^.]+)\.(.*)$ ]]; then
      # Capture before matching anything else — a nested [[ =~ ]] overwrites BASH_REMATCH.
      local complete_verb="${BASH_REMATCH[1]}" segments="${BASH_REMATCH[2]}" trailer="${BASH_REMATCH[3]}"
      [ -n "${trailer}" ] && log-info "ignoring what follows the resource counts on the summary line:${trailer}"
      imports=0
      adds=0
      changes=0
      destroys=0
      if [[ "${segments}" =~ ([0-9]+)\ imported ]]; then imports="${BASH_REMATCH[1]}"; fi
      if [[ "${segments}" =~ ([0-9]+)\ added ]]; then adds="${BASH_REMATCH[1]}"; fi
      if [[ "${segments}" =~ ([0-9]+)\ changed ]]; then changes="${BASH_REMATCH[1]}"; fi
      if [[ "${segments}" =~ ([0-9]+)\ destroyed ]]; then destroys="${BASH_REMATCH[1]}"; fi
      completed='true'
      if [ "${complete_verb}" = 'Destroy' ]; then apply_kind='destroy'; else apply_kind='apply'; fi

      # A verb we do not know is worth saying out loud — its resources are real
      # and go uncounted — but it must never turn a finished apply into a
      # reported failure, which is the whole reason this is segment-based.
      # Out loud means the run page, not only this log (§14): the summary
      # line proves the apply finished, whatever the exit code says.
      local unknown
      unknown=$(printf '%s' "${segments}" | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
        | grep -vE '^[0-9]+ (imported|added|changed|destroyed)$' || true)
      if [ -n "${unknown}" ]; then
        local unknown_list
        unknown_list=$(printf '%s' "${unknown}" | paste -sd';' -)
        log-warn "unrecognised segment(s) in the summary line, not counted: ${unknown_list}"
        warn-output-not-recognised "the '${complete_verb} complete!' line carries segment(s) this parser does not know — '${unknown_list}' — and they are not counted. Please report the apply console output (${input_apply_console_file}) so the parser can learn the new verb."
      fi

      log-info "${apply_kind} completed: ${imports} imported, ${adds} added, ${changes} changed, ${destroys} destroyed"
      if [ -n "${input_apply_exitcode:-}" ] && [ "${input_apply_exitcode}" != '0' ]; then
        log-info "terraform exited ${input_apply_exitcode} after printing its summary line; the counts are terraform's, the outcome is the step's"
      fi
    elif [ -n "${summary_line}" ]; then
      log-error "found a summary line but could not parse it: '${summary_line}'"
    else
      log-warn "no 'Apply complete!' / 'Destroy complete!' summary line — counts are '?' and completed=false"
    fi

    # Exit 0 without a recognised summary line is the mismatch worth a human
    # look: a failed apply prints no summary line, but a successful one always
    # does — unless terraform's wording changed. The outcome stays the step's
    # (success); the counts render '?'; this is what gets the console reported.
    if [ "${input_apply_exitcode:-}" = '0' ] && [ "${completed}" != 'true' ]; then
      warn-output-not-recognised "terraform apply exited 0 but no 'Apply complete!' / 'Destroy complete!' summary line was recognised in its console, so the counts render as '?'. The apply is reported as succeeded — that is the exit code's call. Please report the apply console output (${input_apply_console_file}) so the parser can learn the new wording."
    fi
  fi

  # Imports belong in the total: an apply that only adopted existing objects has
  # zero added/changed/destroyed, and a total of 0 renders as
  # 'Apply: no changes ✅' when five resources just came under management.
  if [[ "${imports}${adds}${changes}${destroys}" =~ ^[0-9]+$ ]]; then
    total=$((imports + adds + changes + destroys))
  fi

  set-output 'import-count' "${imports}"
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
