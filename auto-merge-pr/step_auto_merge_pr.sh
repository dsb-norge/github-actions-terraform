#!/bin/env bash
#
# Source for the auto-merge-pr step
#
# Merges a pull request using admin privileges when eligibility conditions are met,
# pinned to what the run evaluated (docs/Auto-merge.md §6): the base the plans saw
# must still be the base branch's tip, and GitHub must find the head the run planned.
# Uses GitHub event context data to determine PR state instead of additional API calls.
#
# Required environment variables:
#   GITHUB_TOKEN                     - GitHub token with admin privileges
#   input_repo_ref                   - Repository reference (owner/repo)
#   input_pr_number                  - Pull request number
#   input_github_event_context_json  - JSON containing github.event context
#   input_head_sha                   - The pull request's head SHA the run planned
#   input_merge_sha                  - The run's github.sha, the event's merge commit
#
# The github event context JSON should contain:
#   .pull_request.state     - PR state (should be "open")
#   .pull_request.draft     - Whether PR is a draft (should be false)
#   .pull_request.mergeable - Whether PR can be merged (should be true or null for pending)
#   .pull_request.base.ref  - The base branch
#

set -o errexit
set -o nounset
set -o pipefail

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# A merge attempt's result: merged, failed (worth another attempt), or refused
# because what the run planned is no longer what would be merged (never retried)
MERGE_OK=0
MERGE_FAILED=1
MERGE_REFUSED=2

# ============================================================================
# Helper Functions
# ============================================================================

# Safely parse JSON field, returns default if field is missing/null
# Handles boolean false correctly by using jq's type checking
function get_json_field() {
  local json="${1}"
  local field="${2}"
  local default="${3:-}"

  local value
  # Use jq to get the raw value, handling null explicitly
  # The -e flag makes jq exit with 1 if result is null/false, so we avoid it here
  value=$(echo "${json}" | jq -r "if ${field} == null then \"__NULL__\" else ${field} end" 2>/dev/null) || value=""

  if [[ -z "${value}" || "${value}" == "__NULL__" ]]; then
    echo "${default}"
  else
    echo "${value}"
  fi
}

# Validate JSON structure has required fields
function validate_event_context() {
  local json="${1}"

  # Check if we have the pull_request object
  local has_pr
  has_pr=$(echo "${json}" | jq -e '.pull_request' >/dev/null 2>&1 && echo "true" || echo "false")

  if [[ "${has_pr}" != "true" ]]; then
    log-error "Missing required 'pull_request' field in github event context"
    return 1
  fi

  # Check for required fields within pull_request
  local has_state has_draft
  has_state=$(echo "${json}" | jq -e '.pull_request | has("state")' 2>/dev/null) || has_state="false"
  has_draft=$(echo "${json}" | jq -e '.pull_request | has("draft")' 2>/dev/null) || has_draft="false"

  if [[ "${has_state}" != "true" ]]; then
    log-error "Missing required 'pull_request.state' field in github event context"
    return 1
  fi

  if [[ "${has_draft}" != "true" ]]; then
    log-error "Missing required 'pull_request.draft' field in github event context"
    return 1
  fi

  # Note: mergeable can be null if GitHub hasn't computed it yet, so we don't require it
  return 0
}

# True for a full commit SHA, SHA-1 or SHA-256, as GitHub prints them
function is_commit_sha() {
  [[ "${1}" =~ ^[0-9a-f]{40}$ || "${1}" =~ ^[0-9a-f]{64}$ ]]
}

# The merge is not made: an error annotation, so the refusal shows on the job
# and the pull request stays open for a person (docs/Auto-merge.md §7)
function refuse() {
  echo "::error title=Auto-merge refused::$(escape-annotation-message "${1}")"
}

# Execute the merge command. --match-head-commit makes GitHub refuse the merge
# when the pull request's head is no longer the one the run planned.
function execute_merge() {
  local pr_number="${1}"
  local repo_ref="${2}"
  local head_sha="${3}"

  gh pr merge "${pr_number}" --admin --rebase --delete-branch --repo "${repo_ref}" --match-head-commit "${head_sha}"
}

# Check current PR mergeable status via API: MERGEABLE, CONFLICTING or UNKNOWN,
# as GitHub reports it
function get_pr_mergeable_status() {
  local pr_number="${1}"
  local repo_ref="${2}"

  gh pr view "${pr_number}" --repo "${repo_ref}" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN"
}

# The pull request's head now, or nothing when it cannot be read
function get_pr_head_sha() {
  local pr_number="${1}"
  local repo_ref="${2}"
  local sha

  sha=$(gh pr view "${pr_number}" --repo "${repo_ref}" --json headRefOid --jq '.headRefOid' 2>/dev/null) || sha=""
  if is_commit_sha "${sha}"; then echo "${sha}"; fi
}

# Refuse when the base branch moved after the run planned the pull request. A
# pull-request run plans the event's merge commit, the head merged with the base
# as it was then; a rebase merge lands the head on the base as it is now. So the
# base the plans saw, the merge commit's first parent, must still be the base
# branch's tip. A lookup that fails refuses too: the check cannot be skipped.
# Returns MERGE_OK when the base is unchanged, MERGE_REFUSED otherwise.
function check_base_unchanged() {
  local repo_ref="${1}"
  local base_ref="${2}"
  local merge_sha="${3}"
  local planned_base base_tip

  planned_base=$(gh api "repos/${repo_ref}/commits/${merge_sha}" --jq '.parents[0].sha' 2>/dev/null) || planned_base=""
  if ! is_commit_sha "${planned_base}"; then
    refuse "Could not read the base this run planned the pull request on (the first parent of the merge commit ${merge_sha:0:7}), so the pull request was not merged."
    return ${MERGE_REFUSED}
  fi

  base_tip=$(gh api "repos/${repo_ref}/branches/${base_ref}" --jq '.commit.sha' 2>/dev/null) || base_tip=""
  if ! is_commit_sha "${base_tip}"; then
    refuse "Could not read the tip of the base branch '${base_ref}', so whether it moved after this run planned the pull request is unknown; the pull request was not merged."
    return ${MERGE_REFUSED}
  fi

  if [[ "${planned_base}" != "${base_tip}" ]]; then
    refuse "The base branch '${base_ref}' moved after this run planned the pull request (planned on ${planned_base:0:7}, now ${base_tip:0:7}), so the merged result was never planned. The next run, after the pull request is brought up to date, decides."
    return ${MERGE_REFUSED}
  fi

  log-info "Base branch '${base_ref}' is still at ${base_tip:0:7}, the base this run planned on"
  return ${MERGE_OK}
}

# One merge attempt: the base check, then the merge pinned to the planned head
# Returns MERGE_OK, MERGE_FAILED or MERGE_REFUSED
function attempt_merge() {
  local pr_number="${1}"
  local repo_ref="${2}"
  local base_ref="${3}"
  local head_sha="${4}"
  local merge_sha="${5}"

  local base_result=0
  check_base_unchanged "${repo_ref}" "${base_ref}" "${merge_sha}" || base_result=$?
  if [[ ${base_result} -ne ${MERGE_OK} ]]; then
    return ${MERGE_REFUSED}
  fi

  local merge_output
  local merge_exit_code=0
  merge_output=$(execute_merge "${pr_number}" "${repo_ref}" "${head_sha}" 2>&1) || merge_exit_code=$?
  if [[ -n "${merge_output}" ]]; then
    log-info "${merge_output}"
  fi
  if [[ ${merge_exit_code} -eq 0 ]]; then
    return ${MERGE_OK}
  fi
  log-warn "Merge failed with exit code: ${merge_exit_code}"

  # A moved head is told by the head itself, not by the wording of GitHub's
  # refusal; the wording is the fallback when the head cannot be read
  local head_now
  head_now=$(get_pr_head_sha "${pr_number}" "${repo_ref}")
  if [[ -n "${head_now}" && "${head_now}" != "${head_sha}" ]] ||
    { [[ -z "${head_now}" ]] && grep -qi 'head branch was modified' <<<"${merge_output}"; }; then
    local now="${head_now:0:7}"
    refuse "The pull request's head moved after this run planned it (planned ${head_sha:0:7}, now ${now:-unknown}), so it was not merged; the run for the new head decides."
    return ${MERGE_REFUSED}
  fi

  return ${MERGE_FAILED}
}

# Attempt merge with retry logic for pending mergeable status. A conflict, or a
# refusal because the head or the base moved, is final: retrying could only
# merge something this run never planned.
function merge_with_retry() {
  local pr_number="${1}"
  local repo_ref="${2}"
  local base_ref="${3}"
  local head_sha="${4}"
  local merge_sha="${5}"
  local max_attempts="${MERGE_RETRY_MAX_ATTEMPTS:-5}"
  local retry_delay="${MERGE_RETRY_DELAY:-5}"
  local attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    log-info "Merge attempt ${attempt}/${max_attempts}"

    # Check current mergeable status before attempting merge
    if [[ ${attempt} -gt 1 ]]; then
      local current_mergeable
      current_mergeable=$(get_pr_mergeable_status "${pr_number}" "${repo_ref}")
      log-info "Current mergeable status: ${current_mergeable}"

      if [[ "${current_mergeable}" == "CONFLICTING" ]]; then
        refuse "The pull request conflicts with the base branch '${base_ref}' (mergeable: ${current_mergeable}), so it was not merged."
        return 1
      fi

      if [[ "${current_mergeable}" == "MERGEABLE" ]]; then
        log-info "PR is now confirmed mergeable"
      fi
    fi

    local result=0
    attempt_merge "${pr_number}" "${repo_ref}" "${base_ref}" "${head_sha}" "${merge_sha}" || result=$?
    if [[ ${result} -eq ${MERGE_OK} ]]; then
      log-info "Successfully merged PR #${pr_number}"
      return 0
    fi
    if [[ ${result} -eq ${MERGE_REFUSED} ]]; then
      log-error "Not retrying: the merge was refused"
      return 1
    fi

    log-warn "Merge attempt ${attempt} failed"

    if [[ ${attempt} -lt ${max_attempts} ]]; then
      log-info "Waiting ${retry_delay} seconds before retry..."
      sleep ${retry_delay}
    fi

    ((attempt++))
  done

  log-error "Failed to merge PR after ${max_attempts} attempts"
  return 1
}

# Extract PR info for debugging from event context
function get_pr_debug_info() {
  local event_context_json="${1}"

  # Extract relevant fields from the event context
  echo "${event_context_json}" | jq '{
    title: .pull_request.title,
    state: .pull_request.state,
    draft: .pull_request.draft,
    mergeable: .pull_request.mergeable,
    mergeable_state: .pull_request.mergeable_state,
    head_sha: .pull_request.head.sha,
    base_ref: .pull_request.base.ref
  }'
}

# ============================================================================
# Main Logic
# ============================================================================

function main() {
  local repo_ref="${input_repo_ref:-}"
  local pr_number="${input_pr_number:-}"
  local event_context_json="${input_github_event_context_json:-}"
  local head_sha="${input_head_sha:-}"
  local merge_sha="${input_merge_sha:-}"

  # Validate required inputs
  if [[ -z "${repo_ref}" ]]; then
    log-error "Missing required input: repository reference"
    return 1
  fi

  if [[ -z "${pr_number}" ]]; then
    log-error "Missing required input: PR number"
    return 1
  fi

  if [[ -z "${event_context_json}" ]]; then
    log-error "Missing required input: github event context JSON"
    return 1
  fi

  # The merge is pinned to what the run planned; without the pins there is nothing to pin it to
  if [[ -z "${head_sha}" ]]; then
    log-error "Missing required input: head-sha, the pull request's head SHA this run planned; not merging"
    return 1
  fi
  if ! is_commit_sha "${head_sha}"; then
    log-error "Input head-sha '${head_sha}' is not a full commit SHA; not merging"
    return 1
  fi

  if [[ -z "${merge_sha}" ]]; then
    log-error "Missing required input: merge-sha, the run's github.sha (the event's merge commit); not merging"
    return 1
  fi
  if ! is_commit_sha "${merge_sha}"; then
    log-error "Input merge-sha '${merge_sha}' is not a full commit SHA; not merging"
    return 1
  fi

  start-group "Validating PR state from event context"

  # Validate event context structure
  if ! validate_event_context "${event_context_json}"; then
    end-group
    return 1
  fi

  # Extract PR information from event context
  local pr_state pr_is_draft pr_mergeable base_ref

  pr_state=$(get_json_field "${event_context_json}" '.pull_request.state' "unknown")
  pr_is_draft=$(get_json_field "${event_context_json}" '.pull_request.draft' "unknown")
  pr_mergeable=$(get_json_field "${event_context_json}" '.pull_request.mergeable' "null")
  base_ref=$(get_json_field "${event_context_json}" '.pull_request.base.ref' "")

  log-info "Repository: ${repo_ref}"
  log-info "PR #${pr_number}"
  log-info "PR state: ${pr_state}"
  log-info "PR is draft: ${pr_is_draft}"
  log-info "PR mergeable: ${pr_mergeable}"
  log-info "Base branch: ${base_ref:-<none>}"
  log-info "Planned head: ${head_sha}"
  log-info "Merge commit: ${merge_sha}"

  # Check PR state
  if [[ "${pr_state}" != "open" ]]; then
    log-error "PR is not in an open state (state: ${pr_state})"
    end-group
    return 1
  fi

  # Check if draft
  if [[ "${pr_is_draft}" == "true" ]]; then
    log-error "PR is a draft and should not be merged automatically"
    end-group
    return 1
  fi

  # Check mergeable status
  # Note: mergeable can be null if GitHub hasn't computed it yet
  # In that case, we let the merge command handle the check
  if [[ "${pr_mergeable}" == "false" ]]; then
    log-error "PR is in a non-mergeable state (mergeable: ${pr_mergeable})"
    end-group
    return 1
  fi

  if [[ -z "${base_ref}" ]]; then
    log-error "Missing required 'pull_request.base.ref' field in github event context, so the base cannot be checked; not merging"
    end-group
    return 1
  fi

  if [[ "${pr_mergeable}" == "null" ]]; then
    log-warn "PR mergeable status is pending computation - will attempt merge with retry logic"
  fi

  end-group

  start-group "Merge PR #${pr_number}"

  # Use retry logic when mergeable status is null (pending), otherwise single attempt
  if [[ "${pr_mergeable}" == "null" ]]; then
    log-info "Using retry logic due to pending mergeable status"
    if merge_with_retry "${pr_number}" "${repo_ref}" "${base_ref}" "${head_sha}" "${merge_sha}"; then
      end-group
      return 0
    else
      local exit_code=$?
      # Show additional PR info for debugging
      log-info "PR details for debugging:"
      get_pr_debug_info "${event_context_json}" || true
      end-group
      return ${exit_code}
    fi
  else
    local result=0
    attempt_merge "${pr_number}" "${repo_ref}" "${base_ref}" "${head_sha}" "${merge_sha}" || result=$?
    if [[ ${result} -eq ${MERGE_OK} ]]; then
      log-info "Successfully merged PR #${pr_number}"
      end-group
      return 0
    else
      log-error "Failed to merge PR"

      # Show additional PR info for debugging
      log-info "PR details for debugging:"
      get_pr_debug_info "${event_context_json}" || true

      end-group
      return 1
    fi
  fi
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
