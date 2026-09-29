#!/bin/env bash
#
# Source for the report step
#
# Judges the action from the outcomes of the steps before it, publishes the outputs, writes one
# line to the step summary, and fails the action on 'failed' and 'needs-regeneration'.
#
# The terraform-docs steps run with continue-on-error, so this step is the action's verdict.
# Each writes num_changed before it pushes or checks for a diff, and not at all when
# terraform-docs itself fails. So with push 'false', a failed step with a positive num_changed
# failed its fail-on-diff check: its README needs regenerating. Every other failure, and any
# failure with push 'true', is 'failed'.
#
# Files counted:
#   push 'true'  - a successful step's num_changed: the files its commit pushed.
#   push 'false' - a step's num_changed when it succeeded or failed on a diff: the files that
#                  need regenerating.
# An empty or non-numeric num_changed counts as zero.
#
# Status, the first that holds:
#   failed              - a step before the report failed or was cancelled, other than a diff
#   needs-regeneration  - push 'false' and at least one file needs regenerating
#   pushed              - push 'true' and at least one file changed, so a commit was pushed
#   up-to-date          - nothing to change
#
# 'pushed' and 'needs-regeneration' are also published as outputs of their own, true even when
# a later failure makes the status 'failed': a push that happened is still a push.
#
# Required environment variables:
#   input_push                   - 'true' or 'false', as the action's push input
#   input_inject_outcome         - outcome of the inject-config-files step
#   input_validate_outcome       - outcome of the validate-root-readme step
#   input_examples_outcome       - outcome of the generate-example-docs step
#   input_examples_num_changed   - its num_changed output (empty when it did not run)
#   input_project_outcome        - outcome of the generate-project-docs step
#   input_project_num_changed    - its num_changed output (empty when it did not run)
#

set -o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Helper Functions (step-local)
# ============================================================================

# Print a count as '1 file' / '2 files'.
function files_phrase {
  if [[ "${1}" -eq 1 ]]; then echo "1 file"; else echo "${1} files"; fi
}

# Read one terraform-docs step's outcome into the totals.
#   $1 - label for the log and the failure reason
#   $2 - the step's outcome
#   $3 - the step's num_changed output
# Adds to _total_files and _reasons, sets _regenerate.
function judge_docs_step {
  local label="${1}" outcome="${2}" num_changed="${3}"
  local count=0

  if [[ -n "${num_changed}" ]]; then
    if [[ "${num_changed}" =~ ^[0-9]+$ ]]; then
      count=$((10#${num_changed}))
    else
      log-warn "${label}: num_changed '${num_changed}' is not a number, counting it as 0."
    fi
  fi

  case "${outcome}" in
    success)
      log-info "${label}: succeeded, ${count} file(s) changed."
      if [[ "${input_push}" != "true" && "${count}" -gt 0 ]]; then
        # fail-on-diff should have failed the step; the files still need regenerating.
        _regenerate="true"
      fi
      _total_files=$((_total_files + count))
      ;;
    failure)
      if [[ "${input_push}" != "true" && "${count}" -gt 0 ]]; then
        log-info "${label}: ${count} file(s) differ from what terraform-docs generates."
        _regenerate="true"
        _total_files=$((_total_files + count))
      else
        log-error "${label}: terraform-docs failed."
        _reasons+=("terraform-docs failed for the ${label}")
      fi
      ;;
    cancelled)
      log-error "${label}: terraform-docs was cancelled."
      _reasons+=("terraform-docs was cancelled for the ${label}")
      ;;
    *)
      log-info "${label}: did not run (outcome '${outcome}')."
      ;;
  esac
}

# Set _status, _summary and _pushed from the totals.
function decide_status {
  local phrase
  phrase="$(files_phrase "${_total_files}")"

  _pushed="false"
  if [[ "${input_push}" == "true" && "${_total_files}" -gt 0 ]]; then
    _pushed="true"
  fi

  if [[ ${#_reasons[@]} -gt 0 ]]; then
    local joined
    joined="$(printf '%s; ' "${_reasons[@]}")"
    _status="failed"
    _summary="📝 Docs: failed (${joined%; })"
  elif [[ "${_regenerate}" == "true" ]]; then
    _status="needs-regeneration"
    _summary="📝 Docs: README needs regenerating (${phrase}) — run terraform-docs, or push to a pull request where CI regenerates it"
  elif [[ "${_pushed}" == "true" ]]; then
    _status="pushed"
    _summary="📝 Docs: regenerated and pushed (${phrase})"
  else
    _status="up-to-date"
    _summary="📝 Docs: up to date"
  fi
}

# ============================================================================
# Main Logic
# ============================================================================

function main {
  _total_files=0
  _regenerate="false"
  _reasons=()

  case "${input_push:-}" in
    true | false) ;;
    *) _reasons+=("input 'push' must be 'true' or 'false', got '${input_push:-}'") ;;
  esac
  # Past the check, anything but 'true' judges as not pushing, as the action's expressions do.
  input_push="${input_push:-false}"

  case "${input_inject_outcome:-}" in
    success) ;;
    *) [[ ${#_reasons[@]} -gt 0 ]] || _reasons+=("injecting the default terraform-docs config failed") ;;
  esac

  case "${input_validate_outcome:-}" in
    failure | cancelled) _reasons+=("README delimiters are invalid, see the log") ;;
  esac

  judge_docs_step "examples" "${input_examples_outcome:-}" "${input_examples_num_changed:-}"
  judge_docs_step "module" "${input_project_outcome:-}" "${input_project_num_changed:-}"

  decide_status

  log-info "Total files: ${_total_files}"
  log-info "Status: ${_status}"
  set-output "number-of-files-changed" "${_total_files}"
  set-output "pushed" "${_pushed}"
  set-output "needs-regeneration" "${_regenerate}"
  set-output "status" "${_status}"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "${_summary}" >>"${GITHUB_STEP_SUMMARY}"
  fi

  case "${_status}" in
    failed)
      echo "::error title=terraform-docs failed::${_summary}"
      return 1
      ;;
    needs-regeneration)
      echo "::error title=README needs regenerating::${_summary}"
      return 1
      ;;
  esac
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
