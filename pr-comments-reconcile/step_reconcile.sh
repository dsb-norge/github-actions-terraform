#!/bin/env bash
#
# Source for the pr-comments-reconcile step.
#
# Bulk seed + GC primitive. Reconciles a set of "head" comments (long-lived,
# identified by HTML marker, PATCHed in place across runs) to the desired
# state, and prunes "tag" comments (run-scoped) that fail a keep-predicate.
#
# Required environment variables:
#   input_repo          - "owner/name"
#   input_issue_number  - PR or issue number
#   input_heads_yml     - YAML list of {marker, body} entries (declared
#                         order is preserved when POSTing new ones)
#   input_gc_yml        - YAML list of {marker-prefix, keep-marker-substring}
#                         entries. Comments matching marker-prefix and NOT
#                         containing keep-marker-substring are DELETEd.
#   GH_TOKEN  (or GITHUB_TOKEN)  - token for `gh` API calls
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# State
# ============================================================================

# JSON array of all comments on the thread, flattened across pagination.
COMMENTS_JSON='[]'

# JSON arrays parsed from input_heads_yml / input_gc_yml.
HEADS_JSON='[]'
GC_JSON='[]'

# Tracks degraded mode (gh api list failed). In degraded mode heads are
# POSTed best-effort; GC is skipped.
DEGRADED_MODE="false"

# Accumulates per-head result records: {marker, action, comment-id}.
RECONCILE_RESULTS='[]'

# ============================================================================
# Validation + YAML parsing
# ============================================================================

function validate_inputs {
  local missing=""
  [ -z "${input_repo:-}" ] && missing+=" input_repo"
  [ -z "${input_issue_number:-}" ] && missing+=" input_issue_number"
  if [ -n "${missing}" ]; then
    log-error "Missing required input(s):${missing}"
    return 1
  fi
  return 0
}

function parse_yaml_inputs {
  start-group "Parse heads-yml / gc-yml"

  # Treat empty / unset as an empty list. yq blows up on an empty string,
  # so handle that case explicitly.
  local heads_raw="${input_heads_yml:-}"
  local gc_raw="${input_gc_yml:-}"

  if [ -z "${heads_raw}" ] || [ "${heads_raw}" = "[]" ]; then
    HEADS_JSON='[]'
  else
    if ! HEADS_JSON=$(echo "${heads_raw}" | yq -o=j '.' 2>&1); then
      log-error "Failed to parse heads-yml as YAML: ${HEADS_JSON}"
      return 1
    fi
  fi

  if [ -z "${gc_raw}" ] || [ "${gc_raw}" = "[]" ]; then
    GC_JSON='[]'
  else
    if ! GC_JSON=$(echo "${gc_raw}" | yq -o=j '.' 2>&1); then
      log-error "Failed to parse gc-yml as YAML: ${GC_JSON}"
      return 1
    fi
  fi

  local n_heads n_gc
  n_heads=$(echo "${HEADS_JSON}" | jq 'length')
  n_gc=$(echo "${GC_JSON}" | jq 'length')
  log-info "Parsed ${n_heads} head(s), ${n_gc} GC rule(s)."

  end-group
  return 0
}

# ============================================================================
# List existing comments
# ============================================================================

function list_existing_comments {
  start-group "List PR comments"

  local raw
  if ! raw=$(_gh_list_pr_comments "${input_repo}" "${input_issue_number}" 2>&1); then
    log-warn "Failed to list comments: ${raw}"
    log-warn "Entering degraded mode — heads will be POSTed best-effort; GC skipped."
    DEGRADED_MODE="true"
    end-group
    return 0
  fi

  if ! COMMENTS_JSON=$(echo "${raw}" | jq -s 'add // []' 2>/dev/null); then
    log-warn "Failed to normalize comments JSON — entering degraded mode"
    DEGRADED_MODE="true"
    end-group
    return 0
  fi

  local total
  total=$(echo "${COMMENTS_JSON}" | jq 'length')
  log-info "Thread has ${total} comment(s) total."

  end-group
}

# ============================================================================
# Heads pass — sequential upsert in declared order
# ============================================================================

function heads_pass {
  local n
  n=$(echo "${HEADS_JSON}" | jq 'length')
  if [ "${n}" -eq 0 ]; then
    log-info "No heads to reconcile."
    return 0
  fi

  log-info "Reconciling ${n} head(s) in declared order..."

  local i marker body
  for ((i = 0; i < n; i++)); do
    marker=$(echo "${HEADS_JSON}" | jq -r ".[${i}].marker // empty")
    body=$(echo "${HEADS_JSON}" | jq -r ".[${i}].body // empty")
    if [ -z "${marker}" ]; then
      log-warn "  head[${i}] has no marker — skipping"
      continue
    fi
    start-group "Head [${i}]: ${marker}"
    _upsert_head "${marker}" "${body}"
    end-group
  done
}

# Upsert a single head. Mirrors the single-comment primitive in pr-comment,
# kept as an internal function here so reconcile can operate on the
# already-fetched COMMENTS_JSON (one list call for the whole pass).
function _upsert_head {
  local marker="${1}" user_body="${2}"

  local full_body body_file
  full_body=$(_render_full_body "${marker}" "${user_body}")
  body_file=$(mktemp)
  printf '%s' "${full_body}" >"${body_file}"

  if [ "${DEGRADED_MODE}" = "true" ]; then
    log-warn "Degraded mode — posting fresh."
    _post_head_fresh "${marker}" "${body_file}"
    rm -f "${body_file}"
    return
  fi

  # Find matches by marker substring.
  local entries
  entries=$(echo "${COMMENTS_JSON}" \
    | jq -r --arg m "${marker}" '.[] | select(.body | contains($m)) | "\(.created_at)|\(.id)"' \
      2>/dev/null) || entries=""

  if [ -z "${entries}" ]; then
    log-info "  no existing match — POST fresh."
    _post_head_fresh "${marker}" "${body_file}"
    rm -f "${body_file}"
    return
  fi

  # Sort by created_at ASC, oldest first.
  local sorted keep_entry keep_id
  sorted=$(echo "${entries}" | sort)
  keep_entry=$(echo "${sorted}" | head -n1)
  keep_id="${keep_entry##*|}"

  # Delete duplicates.
  local entry created cid
  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    cid="${entry##*|}"
    [ "${cid}" = "${keep_id}" ] && continue
    log-info "  duplicate marker (id=${cid}) — deleting"
    _gh_delete_comment "${input_repo}" "${cid}" >/dev/null 2>&1 \
      || log-warn "  failed to delete duplicate id=${cid}"
  done <<<"${sorted}"

  log-info "  patching keeper (id=${keep_id})"
  if _gh_patch_comment "${input_repo}" "${keep_id}" "${body_file}" >/dev/null 2>&1; then
    _record_result "${marker}" "updated" "${keep_id}"
  else
    log-warn "  PATCH failed — falling back to POST fresh."
    _post_head_fresh "${marker}" "${body_file}"
  fi
  rm -f "${body_file}"
}

function _post_head_fresh {
  local marker="${1}" body_file="${2}"
  local new_id
  if new_id=$(_gh_post_comment "${input_repo}" "${input_issue_number}" "${body_file}" 2>&1); then
    log-info "  posted: id=${new_id}"
    _record_result "${marker}" "created" "${new_id}"
  else
    log-warn "  POST failed: ${new_id}"
    _record_result "${marker}" "post-failed" ""
  fi
}

function _record_result {
  local marker="${1}" action="${2}" comment_id="${3}"
  RECONCILE_RESULTS=$(echo "${RECONCILE_RESULTS}" | jq \
    --arg m "${marker}" --arg a "${action}" --arg id "${comment_id}" \
    '. + [{"marker": $m, "action": $a, "comment-id": $id}]')
}

# ============================================================================
# GC pass — prune comments matching each rule's marker-prefix unless they
# also contain keep-marker-substring.
# ============================================================================

function gc_pass {
  local n
  n=$(echo "${GC_JSON}" | jq 'length')
  if [ "${n}" -eq 0 ]; then
    log-info "No GC rules to apply."
    return 0
  fi

  if [ "${DEGRADED_MODE}" = "true" ]; then
    log-warn "Degraded mode — skipping GC pass (cannot enumerate comments safely)."
    return 0
  fi

  log-info "Applying ${n} GC rule(s)..."

  local i prefix keep
  for ((i = 0; i < n; i++)); do
    prefix=$(echo "${GC_JSON}" | jq -r ".[${i}][\"marker-prefix\"] // empty")
    keep=$(echo "${GC_JSON}" | jq -r ".[${i}][\"keep-marker-substring\"] // empty")
    if [ -z "${prefix}" ]; then
      log-warn "  GC rule[${i}] has no marker-prefix — skipping"
      continue
    fi
    start-group "GC rule [${i}]: prefix='${prefix}' keep='${keep}'"
    _gc_one_rule "${prefix}" "${keep}"
    end-group
  done
}

function _gc_one_rule {
  local prefix="${1}" keep="${2}"

  local victims
  if [ -z "${keep}" ]; then
    # No keep substring: prune EVERY comment matching the prefix.
    victims=$(echo "${COMMENTS_JSON}" \
      | jq -r --arg p "${prefix}" '.[] | select(.body | contains($p)) | .id' 2>/dev/null) || victims=""
  else
    victims=$(echo "${COMMENTS_JSON}" \
      | jq -r --arg p "${prefix}" --arg k "${keep}" \
          '.[] | select((.body | contains($p)) and (.body | contains($k) | not)) | .id' \
          2>/dev/null) || victims=""
  fi

  if [ -z "${victims}" ]; then
    log-info "  no GC victims for this rule."
    return 0
  fi

  local cid count=0
  while IFS= read -r cid; do
    [ -z "${cid}" ] && continue
    count=$((count + 1))
    log-info "  deleting (id=${cid})"
    _gh_delete_comment "${input_repo}" "${cid}" >/dev/null 2>&1 \
      || log-warn "  failed to delete id=${cid} — continuing"
  done <<<"${victims}"
  log-info "  GC'd ${count} comment(s)."
}

# ============================================================================
# Main
# ============================================================================

function main {
  log-info "Starting pr-comments-reconcile..."
  log-info "Repo:         ${input_repo:-<unset>}"
  log-info "Issue number: ${input_issue_number:-<unset>}"

  validate_inputs || return 1
  parse_yaml_inputs || return 1
  list_existing_comments
  # GC runs BEFORE heads so stale tags (e.g. plan-extract comments from
  # prior runs) disappear from the PR conversation as early as possible
  # during a re-run — outdated plan output is a worse signal than the
  # transient "stale final" state on heads (which we briefly show before
  # PATCHing them to a Running placeholder). Also robust to partial
  # failures: even if heads_pass crashes later, stale tags are gone.
  gc_pass
  heads_pass

  set-multiline-output "reconcile-json" "${RECONCILE_RESULTS}"
  log-info "Done."
  return 0
}

main
_main_exit_code=$?
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return ${_main_exit_code}
else
  exit ${_main_exit_code}
fi
