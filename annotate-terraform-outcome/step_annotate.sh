#!/bin/env bash
#
# Source for the annotate step.
#
# Two side effects, both aimed at the GitHub run page rather than the PR:
#
#   1. Appends the environment's rendered block to $GITHUB_STEP_SUMMARY.
#      The block is create-validation-summary's step-summary-file — the
#      head's table with a [Job log] footer — so this action renders
#      nothing itself and cannot drift from the PR comment.
#   2. Emits one ::notice (success) or ::error (anything else) workflow
#      command for the apply step, and one for the destroy step, when the
#      step ran. Nothing for a step that did not run.
#
# Never fails the job: reporting must not redden a deploy. Every problem
# is a log-warn and a fallback.
#
# Required environment variables:
#   input_environment_name    - Name of the environment (in every message)
#
# Optional environment variables:
#   input_step_summary_file   - Path of the rendered block; missing → fallback block
#   input_status_apply        - Apply outcome; empty = did not run
#   input_apply_count_{add,change,destroy}, input_apply_time
#   input_status_destroy      - Destroy outcome; empty = did not run
#   input_destroy_count_destroy, input_destroy_time
#
# Standard GitHub environment variables used:
#   GITHUB_STEP_SUMMARY - the job summary file; unset → summary skipped, annotations still emitted
#

set +o nounset

# Load helpers (provides the escape-* and count-or-question-mark helpers)
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Annotations
# ============================================================================

# One workflow command for one operation.
#   $1 verb ('Apply' | 'Destroy'), $2 outcome, $3 counts sentence, $4 time,
#   $5 partial-state wording ('applied' | 'destroyed')
function annotate_operation {
  local verb="${1}" outcome="${2}" counts="${3}" time="${4}" partial="${5}"
  # Empty: the workflow never reached the step. 'skipped': its if: was
  # false. Either way the operation did not run, and there is nothing to
  # report — a skipped apply is not a failed one.
  [ -z "${outcome}" ] || [ "${outcome}" = 'skipped' ] && return 0

  local env_msg
  env_msg="$(escape-annotation-message "${input_environment_name}")"
  local when=""
  [ -n "${time}" ] && [ "${time}" != 'N/A' ] && when=" in ${time}"

  if [ "${outcome}" = 'success' ]; then
    echo "::notice title=$(escape-annotation-property "${verb} succeeded")::${env_msg} — ${counts}${when}"
  else
    echo "::error title=$(escape-annotation-property "${verb} failed")::${env_msg} — ${verb,,} did not complete (outcome '${outcome}'); infrastructure may be partially ${partial}"
  fi
}

# ============================================================================
# Step summary
# ============================================================================

function write_step_summary {
  if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    log-warn "GITHUB_STEP_SUMMARY is not set; skipping the job summary block"
    return 0
  fi

  if [ -n "${input_step_summary_file:-}" ] && [ -s "${input_step_summary_file}" ]; then
    # Appended, never truncated — other steps may have written before us.
    {
      cat "${input_step_summary_file}"
      printf '\n\n'
    } >>"${GITHUB_STEP_SUMMARY}"
    log-info "appended $(wc -c <"${input_step_summary_file}") bytes to the job summary"
  else
    log-warn "step summary file '${input_step_summary_file:-<unset>}' is missing or empty; writing a fallback block"
    {
      printf '### Terraform validation summary for environment: `%s`\n\n' "${input_environment_name}"
      printf 'Summary not available 🤷‍♀️\n\n'
    } >>"${GITHUB_STEP_SUMMARY}"
  fi
}

# ============================================================================
# Main
# ============================================================================

function main {
  log-info "annotating outcome for environment '${input_environment_name}' ..."

  local a_add a_change a_destroy d_destroy
  a_add=$(count-or-question-mark "${input_apply_count_add:-}")
  a_change=$(count-or-question-mark "${input_apply_count_change:-}")
  a_destroy=$(count-or-question-mark "${input_apply_count_destroy:-}")
  d_destroy=$(count-or-question-mark "${input_destroy_count_destroy:-}")

  # Imports are named only when there are any: terraform omits the segment
  # unless import blocks are in play, and this notice is the run-page summary
  # of exactly what the apply did (P32).
  local apply_counts="${a_add} added, ${a_change} changed, ${a_destroy} destroyed"
  if [[ "${input_apply_count_import:-0}" =~ ^[0-9]+$ ]] && [ "${input_apply_count_import:-0}" -ne 0 ]; then
    apply_counts="${apply_counts}, ${input_apply_count_import} imported"
  fi
  annotate_operation "Apply" "${input_status_apply:-}" \
    "${apply_counts}" "${input_apply_time:-}" "applied"
  annotate_operation "Destroy" "${input_status_destroy:-}" \
    "${d_destroy} destroyed" "${input_destroy_time:-}" "destroyed"

  write_step_summary

  log-info "annotate completed."
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
