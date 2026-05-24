#!/bin/env bash
#
# Source for the pr-comment step.
#
# Single-comment primitive for a PR or issue comment thread, identified
# by an HTML marker substring on the comment body. Two modes:
#
#   upsert  - find by marker; PATCH if exists, POST if not. Self-heals
#             duplicate markers by keeping the oldest and deleting the
#             rest. Skips the PATCH entirely when the existing body's
#             embedded hash matches the new body (so subscribers aren't
#             re-pinged for no-op runs).
#   delete  - DELETE every comment whose body contains the marker.
#
# Required environment variables:
#   input_repo          - "owner/name"
#   input_issue_number  - PR or issue number
#   input_mode          - "upsert" | "delete"
#   input_marker        - HTML marker substring (e.g. "<!-- tf:head:env:prod -->")
#   input_body          - markdown body (required when mode=upsert)
#   GH_TOKEN  (or GITHUB_TOKEN)  - token for `gh` API calls
#

# Allow unset variables so optional inputs can be checked explicitly.
set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# State
# ============================================================================

OUTPUT_COMMENT_ID=""
OUTPUT_ACTION=""

# Tracks degraded mode (gh api list failed). In degraded mode the action
# best-effort POSTs (for upsert) or no-ops (for delete) since we can't
# safely identify existing comments.
DEGRADED_MODE="false"

# Path to a temp file holding the normalized PR-comments JSON (flat array
# across pagination pages). We route the comments list through a file
# instead of a shell variable because under 'set -o allexport' (the shim's
# default), every variable is exported to the env of subsequent subprocess
# forks — and a PR with a few plan-tag comments (each up to 65k chars)
# can easily push envp past ARG_MAX, causing the next `jq` fork to
# exit 126 with "Argument list too long". Same trap as create-validation-
# summary's plan-extract block (which already uses tail -c into a file).
COMMENTS_FILE=""

# Newline-delimited "created_at|id" entries matching the marker substring.
MATCHING_ENTRIES=""

# ============================================================================
# Validation
# ============================================================================

function validate_inputs {
  local missing=""
  [ -z "${input_repo:-}" ] && missing+=" input_repo"
  [ -z "${input_issue_number:-}" ] && missing+=" input_issue_number"
  [ -z "${input_mode:-}" ] && missing+=" input_mode"
  [ -z "${input_marker:-}" ] && missing+=" input_marker"

  if [ -n "${missing}" ]; then
    log-error "Missing required input(s):${missing}"
    return 1
  fi

  case "${input_mode}" in
    upsert)
      if [ -z "${input_body:-}" ]; then
        log-error "input_body is required when mode=upsert"
        return 1
      fi
      ;;
    delete)
      : # body not required
      ;;
    *)
      log-error "Invalid mode '${input_mode}' — expected 'upsert' or 'delete'"
      return 1
      ;;
  esac

  return 0
}

# ============================================================================
# List existing comments and find candidates by marker
# ============================================================================

function list_and_find_candidates {
  start-group "List PR comments and find marker matches"

  # Route through tempfiles, never shell variables — see COMMENTS_FILE
  # comment above for the ARG_MAX rationale.
  local raw_file
  raw_file=$(mktemp)
  if ! _gh_list_pr_comments "${input_repo}" "${input_issue_number}" >"${raw_file}" 2>&1; then
    log-warn "Failed to list comments: $(cat "${raw_file}")"
    log-warn "Entering degraded mode."
    DEGRADED_MODE="true"
    rm -f "${raw_file}"
    end-group
    return 0
  fi

  # --paginate yields multiple separate JSON arrays when there are multiple
  # pages. jq -s 'add // []' flattens them into a single array.
  COMMENTS_FILE=$(mktemp)
  if ! jq -s 'add // []' <"${raw_file}" >"${COMMENTS_FILE}" 2>/dev/null; then
    log-warn "Failed to normalize comments JSON — entering degraded mode."
    DEGRADED_MODE="true"
    rm -f "${raw_file}" "${COMMENTS_FILE}"
    COMMENTS_FILE=""
    end-group
    return 0
  fi
  rm -f "${raw_file}"

  local total
  total=$(jq 'length' <"${COMMENTS_FILE}")
  log-info "Thread has ${total} comment(s) total."

  # Match by marker substring (anywhere in body). Tag as "<created_at>|<id>"
  # so a subsequent lexicographic sort gives oldest-first (created_at is
  # ISO-8601 and lex-sortable).
  MATCHING_ENTRIES=$(jq -r --arg m "${input_marker}" '
      .[]
      | select(.body | contains($m))
      | "\(.created_at)|\(.id)"
    ' <"${COMMENTS_FILE}" 2>/dev/null) || MATCHING_ENTRIES=""

  local count=0
  if [ -n "${MATCHING_ENTRIES}" ]; then
    count=$(echo "${MATCHING_ENTRIES}" | wc -l | tr -d ' ')
  fi
  log-info "Found ${count} comment(s) matching marker."

  end-group
}

# ============================================================================
# Upsert mode
# ============================================================================

function do_upsert {
  start-group "Upsert"

  local full_body
  full_body=$(_render_full_body "${input_marker}" "${input_body}")

  local body_file
  body_file=$(mktemp)
  printf '%s' "${full_body}" >"${body_file}"

  if [ "${DEGRADED_MODE}" = "true" ]; then
    log-warn "Degraded mode — posting fresh."
    _post_fresh "${body_file}"
    rm -f "${body_file}"
    end-group
    return 0
  fi

  if [ -z "${MATCHING_ENTRIES}" ]; then
    log-info "No existing match — posting fresh."
    _post_fresh "${body_file}"
    rm -f "${body_file}"
    end-group
    return 0
  fi

  # Sort matches by created_at ASC (oldest first).
  local sorted
  sorted=$(echo "${MATCHING_ENTRIES}" | sort)
  local keep_entry
  keep_entry=$(echo "${sorted}" | head -n1)
  local keep_id="${keep_entry##*|}"
  local keep_created="${keep_entry%%|*}"

  # Delete duplicates (every match except the keeper).
  local entry created cid
  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    created="${entry%%|*}"
    cid="${entry##*|}"
    if [ "${cid}" = "${keep_id}" ]; then
      continue
    fi
    log-info "  duplicate marker comment (id=${cid}, created=${created}) — deleting"
    if ! _gh_delete_comment "${input_repo}" "${cid}" >/dev/null 2>&1; then
      log-warn "  failed to delete duplicate id=${cid} — continuing"
    fi
  done <<<"${sorted}"

  log-info "Patching keeper (id=${keep_id}, created=${keep_created})."
  if _gh_patch_comment "${input_repo}" "${keep_id}" "${body_file}" >/dev/null 2>&1; then
    OUTPUT_COMMENT_ID="${keep_id}"
    OUTPUT_ACTION="updated"
  else
    log-warn "PATCH failed — falling back to POST fresh."
    _post_fresh "${body_file}"
  fi

  rm -f "${body_file}"
  end-group
}

function _post_fresh {
  local body_file="${1}"
  local new_id
  if new_id=$(_gh_post_comment "${input_repo}" "${input_issue_number}" "${body_file}" 2>&1); then
    log-info "Posted: comment id=${new_id}"
    OUTPUT_COMMENT_ID="${new_id}"
    OUTPUT_ACTION="created"
  else
    log-warn "Failed to post: ${new_id}"
    OUTPUT_COMMENT_ID=""
    OUTPUT_ACTION="post-failed"
  fi
}

# ============================================================================
# Delete mode
# ============================================================================

function do_delete {
  start-group "Delete"

  if [ "${DEGRADED_MODE}" = "true" ]; then
    log-warn "Degraded mode — cannot identify comments to delete. No-op."
    OUTPUT_ACTION="not-found"
    end-group
    return 0
  fi

  if [ -z "${MATCHING_ENTRIES}" ]; then
    log-info "No matching comments to delete."
    OUTPUT_ACTION="not-found"
    end-group
    return 0
  fi

  local entry created cid last_id=""
  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    created="${entry%%|*}"
    cid="${entry##*|}"
    log-info "  deleting (id=${cid}, created=${created})"
    if ! _gh_delete_comment "${input_repo}" "${cid}" >/dev/null 2>&1; then
      log-warn "  failed to delete id=${cid} — continuing"
    else
      last_id="${cid}"
    fi
  done <<<"${MATCHING_ENTRIES}"

  OUTPUT_COMMENT_ID="${last_id}"
  OUTPUT_ACTION="deleted"
  end-group
}

# ============================================================================
# Main
# ============================================================================

function main {
  log-info "Starting pr-comment..."
  log-info "Repo:         ${input_repo:-<unset>}"
  log-info "Issue number: ${input_issue_number:-<unset>}"
  log-info "Mode:         ${input_mode:-<unset>}"
  log-info "Marker:       ${input_marker:-<unset>}"

  validate_inputs || return 1

  list_and_find_candidates

  case "${input_mode}" in
    upsert) do_upsert ;;
    delete) do_delete ;;
  esac

  set-output "comment-id" "${OUTPUT_COMMENT_ID}"
  set-output "action" "${OUTPUT_ACTION}"
  log-info "Done. action=${OUTPUT_ACTION} comment-id=${OUTPUT_COMMENT_ID}"

  # Clean up the temp file holding the normalized PR-comments JSON.
  [ -n "${COMMENTS_FILE:-}" ] && rm -f "${COMMENTS_FILE}"
  return 0
}

main
_main_exit_code=$?
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return ${_main_exit_code}
else
  exit ${_main_exit_code}
fi
