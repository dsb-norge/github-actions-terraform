#!/bin/env bash
#
# Source for the auto-merge-pr step
#
# Merges a pull request using admin privileges when eligibility conditions are met.
# Uses GitHub event context data to determine PR state instead of additional API calls.
#
# Required environment variables:
#   GITHUB_TOKEN                     - GitHub token with admin privileges
#   input_repo_ref                   - Repository reference (owner/repo)
#   input_pr_number                  - Pull request number
#   input_github_event_context_json  - JSON containing github.event context
#
# The github event context JSON should contain:
#   .pull_request.state     - PR state (should be "open")
#   .pull_request.draft     - Whether PR is a draft (should be false)
#   .pull_request.mergeable - Whether PR can be merged (should be true or null for pending)
#

set -o errexit
set -o nounset
set -o pipefail

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

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

# Execute the merge command
function execute_merge() {
  local pr_number="${1}"
  local repo_ref="${2}"

  gh pr merge "${pr_number}" --admin --rebase --delete-branch --repo "${repo_ref}"
}

# Check current PR mergeable status via API
function get_pr_mergeable_status() {
  local pr_number="${1}"
  local repo_ref="${2}"

  gh pr view "${pr_number}" --repo "${repo_ref}" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN"
}

# Attempt merge with retry logic for pending mergeable status
function merge_with_retry() {
  local pr_number="${1}"
  local repo_ref="${2}"
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

      if [[ "${current_mergeable}" == "NOT_MERGEABLE" ]]; then
        log-error "PR is not mergeable (status: ${current_mergeable})"
        return 1
      fi

      if [[ "${current_mergeable}" == "MERGEABLE" ]]; then
        log-info "PR is now confirmed mergeable"
      fi
    fi

    # Attempt the merge
    local merge_output
    local merge_exit_code=0
    merge_output=$(execute_merge "${pr_number}" "${repo_ref}" 2>&1) || merge_exit_code=$?

    if [[ ${merge_exit_code} -eq 0 ]]; then
      log-info "Successfully merged PR #${pr_number}"
      return 0
    fi

    log-warn "Merge attempt ${attempt} failed with exit code: ${merge_exit_code}"
    log-warn "Output: ${merge_output}"

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

  start-group "Validating PR state from event context"

  # Validate event context structure
  if ! validate_event_context "${event_context_json}"; then
    end-group
    return 1
  fi

  # Extract PR information from event context
  local pr_state pr_is_draft pr_mergeable

  pr_state=$(get_json_field "${event_context_json}" '.pull_request.state' "unknown")
  pr_is_draft=$(get_json_field "${event_context_json}" '.pull_request.draft' "unknown")
  pr_mergeable=$(get_json_field "${event_context_json}" '.pull_request.mergeable' "null")

  log-info "Repository: ${repo_ref}"
  log-info "PR #${pr_number}"
  log-info "PR state: ${pr_state}"
  log-info "PR is draft: ${pr_is_draft}"
  log-info "PR mergeable: ${pr_mergeable}"

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

  if [[ "${pr_mergeable}" == "null" ]]; then
    log-warn "PR mergeable status is pending computation - will attempt merge with retry logic"
  fi

  end-group

  start-group "Merge PR #${pr_number}"

  # Use retry logic when mergeable status is null (pending), otherwise single attempt
  if [[ "${pr_mergeable}" == "null" ]]; then
    log-info "Using retry logic due to pending mergeable status"
    if merge_with_retry "${pr_number}" "${repo_ref}"; then
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
    if execute_merge "${pr_number}" "${repo_ref}" 2>&1; then
      log-info "Successfully merged PR #${pr_number}"
      end-group
      return 0
    else
      local exit_code=$?
      log-error "Failed to merge PR with exit code: ${exit_code}"

      # Show additional PR info for debugging
      log-info "PR details for debugging:"
      get_pr_debug_info "${event_context_json}" || true

      end-group
      return ${exit_code}
    fi
  fi
}

# Run main function
main
_main_exit_code=$?
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced - return to allow caller to capture exit code
  return ${_main_exit_code}
else
  # Script is being executed directly - exit with the code
  exit ${_main_exit_code}
fi
