#!/bin/env bash
#
# Source for the parse-plan-output step
#
# Outputs the number of resources a Terraform plan adds, changes, destroys,
# imports, moves and removes, plus a flag for plans that change outputs but no
# resources.
#
# The counts come from the JSON plan ('terraform show -json') when one is
# given, and from the plan's console output otherwise. The console text holds
# resource values, and a value that reads like a summary line forges the
# console's counts; nothing in a resource's values can change the JSON plan's.
# A JSON plan that is absent, unreadable or errored makes every count '?'; it
# never falls back to the console. An incomplete one ("complete": false, as
# with -target) is counted, and says so in plan-complete.
#
# Required environment variables:
#   input_plan_console_file  - Path to the plan console output file
#
# Optional environment variables:
#   input_plan_json_file     - Path to the JSON plan. Empty: count from the
#                              console, as before the JSON plan was read.
#

set +o nounset # allow unset variables (graceful handling of empty/missing input)

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Main Logic
# ============================================================================

# Sets main's plan_class, count_drift, count_drift_ignored, has_pending_changes,
# drift_addresses and plan_fingerprint from the JSON plan, or leaves them
# unknown with a warning. Nothing it is handed is taken on trust.
function classify-json-plan {
  local result='' err_file c_status='' c_class='' c_drift='' c_ignored='' c_pending='' c_addresses='' fingerprint=''
  err_file="$(mktemp)"
  if ! result="$(plan-json-classify "${input_plan_json_file}" 2>"${err_file}")"; then
    result="unknown"$'\t'"jq failed on it: $(head -c 300 "${err_file}")"
  fi
  IFS=$'\t' read -r c_status c_class c_drift c_ignored c_pending c_addresses <<<"${result}"
  if [ "${c_status}" = 'ok' ] && [[ "${c_class}" =~ ^(drift|pending|clean)$ ]] && [[ "${c_drift}" =~ ^[0-9]+$ ]] \
    && [[ "${c_ignored}" =~ ^[0-9]+$ ]] && [[ "${c_pending}" =~ ^(true|false)$ ]] && [[ "${c_addresses}" == '['*']' ]]; then
    if [ "${c_class}" != 'clean' ] && ! fingerprint="$(plan-json-fingerprint "${input_plan_json_file}" 2>"${err_file}")"; then
      c_status='unknown' c_class="its fingerprint cannot be taken: $(head -c 300 "${err_file}")"
    elif [ "${c_class}" != 'clean' ] && [[ ! "${fingerprint}" =~ ^[0-9a-f]{64}$ ]]; then
      c_status='unknown' c_class="its fingerprint came back as '${fingerprint}'"
    fi
  elif [ "${c_status}" != 'unknown' ]; then
    c_status='unknown' c_class="the classification returned '${result}'"
  fi
  rm -f "${err_file}"
  if [ "${c_status}" != 'ok' ]; then
    log-warn "the JSON plan cannot be classified: ${c_class}"
    return 0
  fi
  plan_class="${c_class}" count_drift="${c_drift}" count_drift_ignored="${c_ignored}"
  has_pending_changes="${c_pending}" drift_addresses="${c_addresses}" plan_fingerprint="${fingerprint}"
  log-info "the JSON plan is ${plan_class}: ${count_drift} drifted and reverted, ${count_drift_ignored} drifted and not reverted; changes of its own: ${has_pending_changes}"
}

function main {
  log-info "Starting parse-plan-output..."

  # Fallback output values when parsing fails
  local imports='?'
  local adds='?'
  local changes='?'
  local destroys='?'
  local moves='?'
  local removes='?'
  # Tracks "this plan changes outputs but no resources". Independent of
  # count-total because both "really no changes" and "output-only changes" set
  # every resource count to 0 — callers need this flag to tell them apart and
  # decide whether to render the plan extract. Determined after the counts are
  # known; see the detection block near the end of main.
  local has_output_only_changes='false'
  # Which of the two sources the counts came from, published so a consumer that
  # must not trust console counts (the auto-merge evaluation) can tell.
  local counts_source='console'
  local json_outputs_change='false'
  # Whether the JSON plan is the whole plan: 'true' only when it says
  # "complete": true, '?' when it could not be counted, empty when the counts
  # come from the console, which cannot tell. Apart from the counts, so a
  # targeted plan keeps its real counts in the comment while a consumer that
  # needs the whole plan (auto-merge) refuses anything but 'true'.
  local plan_complete=''
  # The classification of a JSON plan (docs/Drift-detection.md §4): drift,
  # pending, clean, or unknown with every other value '?' or empty. All empty
  # for console counts, which cannot tell drift from a change.
  local plan_class='' count_drift='' count_drift_ignored='' has_pending_changes='' drift_addresses='' plan_fingerprint=''

  if [ -n "${input_plan_json_file:-}" ]; then
    counts_source='json'
    plan_class='unknown' count_drift='?' count_drift_ignored='?' has_pending_changes='?'
    plan_complete='?'
    log-info "counting from the JSON plan: ${input_plan_json_file}"

    local json_reason='' json_result='' json_err_file=''
    if [ ! -e "${input_plan_json_file}" ]; then
      json_reason="the file does not exist ('terraform show -json' did not write it)"
    elif [ ! -f "${input_plan_json_file}" ]; then
      json_reason="it is not a regular file"
    elif [ ! -r "${input_plan_json_file}" ]; then
      json_reason="it cannot be read"
    elif [ ! -s "${input_plan_json_file}" ]; then
      json_reason="the file is empty"
    else
      json_err_file="$(mktemp)"
      if ! json_result="$(plan-json-counts "${input_plan_json_file}" 2>"${json_err_file}")"; then
        json_reason="jq failed on it: $(head -c 300 "${json_err_file}")"
        json_result=''
      fi
      rm -f "${json_err_file}"
    fi

    local json_status='' json_rest=''
    IFS=$'\t' read -r json_status json_rest <<<"${json_result}"
    if [ "${json_status}" = 'ok' ]; then
      local j_add j_change j_destroy j_import j_move j_remove j_outputs j_complete j_count j_well_formed='true'
      IFS=$'\t' read -r j_add j_change j_destroy j_import j_move j_remove j_outputs j_complete <<<"${json_rest}"
      for j_count in "${j_add}" "${j_change}" "${j_destroy}" "${j_import}" "${j_move}" "${j_remove}"; do
        [[ "${j_count}" =~ ^[0-9]+$ ]] || j_well_formed='false'
      done
      [[ "${j_outputs}" == 'true' || "${j_outputs}" == 'false' ]] || j_well_formed='false'
      [[ "${j_complete}" == 'true' || "${j_complete}" == 'false' ]] || j_well_formed='false'
      if [ "${j_well_formed}" = 'true' ]; then
        adds="${j_add}"
        changes="${j_change}"
        destroys="${j_destroy}"
        imports="${j_import}"
        moves="${j_move}"
        removes="${j_remove}"
        json_outputs_change="${j_outputs}"
        plan_complete="${j_complete}"
        log-info "the JSON plan: ${adds} to add, ${changes} to change, ${destroys} to destroy, ${imports} to import, ${moves} to move, ${removes} to remove; outputs change: ${json_outputs_change}; complete: ${plan_complete}"
        if [ "${plan_complete}" != 'true' ]; then
          log-warn "the JSON plan does not say it is complete (as with -target or deferred changes): it may not be the whole plan."
        fi
        classify-json-plan
      else
        json_reason="the counting returned '${json_rest}'"
      fi
    elif [ "${json_status}" = 'unknown' ]; then
      json_reason="${json_rest}"
    elif [ -z "${json_reason}" ]; then
      json_reason="the counting returned '${json_result}'"
    fi
    if [ -n "${json_reason}" ]; then
      log-warn "every count is unknown ('?'): the JSON plan '${input_plan_json_file}' cannot be counted: ${json_reason}"
    fi

  elif [ ! -z "${input_plan_console_file:-}" ]; then
    log-info "parsing plan output file: ${input_plan_console_file}"

    if [ -s "${input_plan_console_file}" ]; then

      # Parse the Plan: line or detect "No changes." / output-only changes
      if grep -q "No changes." "${input_plan_console_file}"; then
        imports=0
        adds=0
        changes=0
        destroys=0
      elif grep -q "without changing any real infrastructure" "${input_plan_console_file}"; then
        # Terraform's wholly-empty-plan branch: it prints this sentence in place
        # of a "Plan:" summary line, so there is nothing to parse and every
        # resource count is zero. The output-only flag is not set here — the
        # count-based detection near the end of main owns that decision.
        log-info "detected plan with no resource actions and no 'Plan:' line"
        imports=0
        adds=0
        changes=0
        destroys=0
      else
        imports=0 # not always in the plan string
        local plan_line
        plan_line=$(grep "Plan: " "${input_plan_console_file}")
        if [ -n "$plan_line" ]; then
          if [[ $plan_line =~ ([0-9]+)\ to\ import ]]; then
            imports=${BASH_REMATCH[1]}
          fi
          if [[ $plan_line =~ ([0-9]+)\ to\ add ]]; then
            adds=${BASH_REMATCH[1]}
          else
            log-error "failed to parse, unable to find the number of resources to add in the plan file"
          fi
          if [[ $plan_line =~ ([0-9]+)\ to\ change ]]; then
            changes=${BASH_REMATCH[1]}
          else
            log-error "failed to parse, unable to find the number of resources that will be changed in the plan file"
          fi
          if [[ $plan_line =~ ([0-9]+)\ to\ destroy ]]; then
            destroys=${BASH_REMATCH[1]}
          else
            log-error "failed to parse, unable to find the number of resources to destroy in the plan file"
          fi
        else
          log-error "failed to parse, unable to find plan details in the plan file"
        fi
      fi

      # Count both types of move operations:
      # 1. "has moved to" - simple move without changes
      # 2. "(moved from" - move with in-place update
      # grep -c exits 0 on match, 1 on no match, 2+ on error
      local has_moved_count moved_from_count grep_rc_1 grep_rc_2
      set +e
      has_moved_count=$(grep -c "has moved to" "${input_plan_console_file}")
      grep_rc_1=$?
      moved_from_count=$(grep -c "(moved from" "${input_plan_console_file}")
      grep_rc_2=$?
      set -e
      if [ $grep_rc_1 -le 1 ] && [ $grep_rc_2 -le 1 ]; then
        moves=$((has_moved_count + moved_from_count))
      else
        log-error "failed to parse, unexpected error when counting moved resources in the plan file"
      fi

      # Count resources to be removed from state (no longer managed by Terraform).
      # Each such resource has a comment line like:
      #   # <resource_address> will no longer be managed by Terraform
      # We match lines starting with '#' to avoid counting summary warning lines like:
      #   Warning: Some objects will no longer be managed by Terraform
      # grep -c exits 0 on match, 1 on no match, 2+ on error
      local removed_count grep_rc
      set +e
      removed_count=$(grep -c "# .* will no longer be managed by Terraform" "${input_plan_console_file}")
      grep_rc=$?
      set -e
      if [ $grep_rc -le 1 ]; then
        removes=$removed_count
      else
        log-error "failed to parse, unexpected error when counting resources to be removed from the plan file"
      fi

    else
      log-error "plan console output file '${input_plan_console_file}' is empty!"
    fi
  fi

  # Sum across every category. Computed here (single source of truth) so a
  # future new count type only needs to be added to this sum once and every
  # consumer picks it up — GitHub Actions expressions can't do arithmetic.
  # Falls back to the literal '?' when any individual category did, so callers
  # can distinguish "really no changes" (0) from "parse failed".
  local total='?'
  if [[ "${adds}${changes}${destroys}${imports}${moves}${removes}" =~ ^[0-9]+$ ]]; then
    total=$((adds + changes + destroys + imports + moves + removes))
  fi

  # From the JSON plan, output-only means an output_changes entry that is not
  # a no-op, and no counted resource change: a data source read counts nowhere,
  # as below. Gated on total==0 for the same reason as below.
  #
  # From the console, output-only detection keys off the "Changes to Outputs:"
  # header, not off Terraform's "…without changing any real infrastructure."
  # sentence.
  #
  # That sentence is printed only when the plan holds no resource actions at
  # all. A plan that defers a data source — "# data.x.y will be read during
  # apply", emitted for a check block or for config that depends on values not
  # yet known — does hold an action, so Terraform renders the normal action
  # list plus "Plan: 0 to add, 0 to change, 0 to destroy." and no sentence,
  # even though outputs are the only thing that will actually change. Keying
  # off the sentence missed those plans, and consumers rendered them as
  # "no changes" while the output diff sat unseen inside the plan extract.
  #
  # Gating on total==0 keeps plans that touch both resources and outputs out of
  # this branch: they already render their extract on the strength of a
  # non-zero total. The header is anchored because Terraform always prints it
  # unindented, whereas a resource diff can carry the same words indented
  # inside a heredoc or a string attribute.
  if [ "${counts_source}" = 'json' ]; then
    if [ "${total}" = '0' ] && [ "${json_outputs_change}" = 'true' ]; then
      log-info "detected output-only changes in the JSON plan (outputs change, no resource changes)"
      has_output_only_changes='true'
    fi
  elif [ "${total}" = '0' ] && grep -q '^Changes to Outputs:' "${input_plan_console_file}"; then
    log-info "detected output-only changes (outputs change, no resource changes)"
    has_output_only_changes='true'
  fi

  set-output 'counts-source' "${counts_source}"
  set-output 'plan-complete' "${plan_complete}"
  set-output 'import-count' "${imports}"
  set-output 'add-count' "${adds}"
  set-output 'change-count' "${changes}"
  set-output 'destroy-count' "${destroys}"
  set-output 'move-count' "${moves}"
  set-output 'remove-count' "${removes}"
  set-output 'total-count' "${total}"
  set-output 'has-output-only-changes' "${has_output_only_changes}"
  set-output 'plan-class' "${plan_class}"
  set-output 'count-drift' "${count_drift}"
  set-output 'count-drift-ignored' "${count_drift_ignored}"
  set-output 'has-pending-changes' "${has_pending_changes}"
  set-output 'drift-addresses' "${drift_addresses}"
  set-output 'plan-fingerprint' "${plan_fingerprint}"

  log-info "parse-plan-output completed."
  return 0
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
