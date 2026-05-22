#!/bin/env bash
#
# Source for the aggregate step.
#
# Reconciles per-group PR comments according to the desired set computed
# from matrix-job-meta-*.json artifacts. See docs/Workflow-pr-comments.md
# §4.6 for the full algorithm.
#
# Required environment variables:
#   input_metadata_files_pattern  - Glob for downloaded artifacts
#                                   (e.g. "matrix-job-meta-*.json")
#   input_pr_number               - The PR number to act on
#   GITHUB_REPOSITORY             - "owner/repo" (set by GitHub Actions)
#   GITHUB_SERVER_URL             - "https://github.com" (set by GitHub Actions)
#   GITHUB_RUN_ID                 - Workflow run ID (set by GitHub Actions)
#   GITHUB_WORKFLOW               - Workflow display name (set by GitHub Actions)
#   GITHUB_ACTOR                  - The actor who triggered the run
#   GITHUB_EVENT_NAME             - The event that triggered the run
#   GH_TOKEN  (or GITHUB_TOKEN)   - Token used by the `gh` CLI for api calls
#

# Allow unset variables so we can do graceful fallback for optional inputs.
set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# State (filled in by main; module-level for testability)
# ============================================================================

# desired_groups[group_name]="env1\nenv2\n..." — newline-delimited list of envs
declare -gA DESIRED_GROUPS=()

# desired_meta[<group_name>/<env_name>]="<absolute path to metadata file>"
declare -gA DESIRED_META=()

# existing_group_comments[group_name]="<id1>\n<id2>\n..." — newline-
# delimited list of every PR comment currently matching our family marker
# for that group. Multiple IDs per group can happen when an earlier run
# orphaned duplicates; the upsert pass picks the oldest to keep (stable
# identity) and deletes the rest.
declare -gA EXISTING_GROUP_COMMENTS=()

# per_env_anchor[env_name]="#issuecomment-<id>" — resolved at step 2,
# used to build the Links row's `log extract` lines. Missing entries mean
# the env has no per-env comment posted yet; the Links cell drops the line.
declare -gA PER_ENV_ANCHOR=()

# per_env_job_url[env_name]="https://github.com/.../actions/runs/<run_id>/job/<check_run_id>#logs"
# Resolved at step 2 via the Jobs API (gh api .../runs/<id>/jobs). Missing
# entries mean the env's matrix job couldn't be matched by name; the Links
# cell drops the `job log` line in that case rather than emit a wrong link.
declare -gA PER_ENV_JOB_URL=()

# Tracks degraded mode (gh api list failed). When true, the upsert pass
# skips its delete branch and posts fresh bodies instead — the grouped
# table is always visible, even if we can't be sure what's already on the
# PR. Duplicates from this degraded mode will self-heal on the next clean
# run (the duplicate-deleted branch of the upsert algorithm).
DEGRADED_MODE="false"

# Tracks each group processed for the groups-processed-json output.
PROCESSED_RESULTS_JSON='[]'

# ============================================================================
# Step 1: Build desired set from artifacts
# ============================================================================

function build_desired_set {
  start-group "Step 1: Build desired set from metadata files"

  shopt -s nullglob
  local files=(${input_metadata_files_pattern})
  shopt -u nullglob

  if [ ${#files[@]} -eq 0 ]; then
    log-info "No metadata files matched '${input_metadata_files_pattern}'."
    log-info "Empty desired set — will run in sweep-only mode (still need to clean up any orphans)."
    end-group
    return 0
  fi

  log-info "Found ${#files[@]} metadata file(s)."

  local file env group
  for file in "${files[@]}"; do
    if ! jq -e '.' "${file}" >/dev/null 2>&1; then
      log-warn "Skipping malformed metadata file: ${file}"
      continue
    fi

    env=$(jq -r '.metadata.environment // empty' "${file}")
    group=$(jq -r '.matrix_context.vars["pr-comment-group"] // empty' "${file}")

    if [ -z "${env}" ]; then
      log-warn "Skipping ${file}: no .metadata.environment"
      continue
    fi

    if [ -z "${group}" ] || [ "${group}" = "null" ]; then
      log-debug "Env '${env}' has no pr-comment-group — not part of any desired group"
      continue
    fi

    log-info "Env '${env}' belongs to group '${group}'"

    # Append env to the group's list, store its metadata file path.
    if [ -n "${DESIRED_GROUPS[${group}]:-}" ]; then
      DESIRED_GROUPS[${group}]+=$'\n'"${env}"
    else
      DESIRED_GROUPS[${group}]="${env}"
    fi
    DESIRED_META["${group}/${env}"]="${file}"
  done

  if [ ${#DESIRED_GROUPS[@]} -eq 0 ]; then
    log-info "No envs declared a pr-comment-group — desired set is empty"
  else
    log-info "Desired set: ${#DESIRED_GROUPS[@]} group(s)"
    local g
    for g in "${!DESIRED_GROUPS[@]}"; do
      log-info "  group '${g}': $(echo "${DESIRED_GROUPS[${g}]}" | tr '\n' ',' | sed 's/,$//')"
    done
  fi

  end-group
}

# ============================================================================
# Step 2 helpers: resolve per-env matrix job URLs
# ============================================================================

# Queries the GitHub Jobs API for the current workflow run and builds a map
# of <env-name> → <job html_url + #logs anchor>. Matrix jobs in the
# terraform-ci-cd reusable workflow have GitHub-rendered name format
# `Terraform (<env>)`; we parse the env name out of that pattern.
#
# Best-effort: if the API call fails or the regex doesn't match, the env
# is simply omitted from PER_ENV_JOB_URL and the Links cell will drop the
# `job log` line for that env rather than render a wrong URL.
function _resolve_per_env_job_urls {
  local run_id="${GITHUB_RUN_ID:-}"
  if [ -z "${run_id}" ]; then
    log-warn "GITHUB_RUN_ID not set — cannot resolve per-env matrix job URLs"
    return 0
  fi

  local jobs_raw
  if ! jobs_raw=$(_gh_list_run_jobs "${GITHUB_REPOSITORY}" "${run_id}" 2>&1); then
    log-warn "Failed to list run jobs (id=${run_id}): ${jobs_raw}"
    log-warn "Links row will omit the 'job log' line for all envs."
    return 0
  fi

  # _gh_list_run_jobs uses --paginate with --jq '.jobs', so multi-page
  # output is one JSON array per page. jq -s flattens these.
  local all_jobs
  if ! all_jobs=$(echo "${jobs_raw}" | jq -s 'add // []' 2>/dev/null); then
    log-warn "Failed to parse jobs JSON; Links row will omit 'job log' for all envs."
    return 0
  fi

  local total
  total=$(echo "${all_jobs}" | jq 'length')
  log-info "Resolving per-env job URLs from ${total} job record(s) in run ${run_id}..."

  local line name html_url env
  while IFS=$'\t' read -r name html_url; do
    [ -z "${name}" ] && continue
    # Matrix job names rendered by GitHub as "<job_name> (<matrix_value>)".
    # When this reusable workflow is called from another workflow, the
    # caller's job name is prepended (e.g. "tf / Terraform (dsb-norge)"),
    # so the regex is NOT anchored at start — only at end, so the trailing
    # "(<env>)" capture is unambiguous.
    if [[ "${name}" =~ Terraform[[:space:]]\((.+)\)$ ]]; then
      env="${BASH_REMATCH[1]}"
      PER_ENV_JOB_URL[${env}]="${html_url}#logs"
      log-debug "  env '${env}' → ${PER_ENV_JOB_URL[${env}]}"
    fi
  done < <(echo "${all_jobs}" | jq -r '.[] | "\(.name)\t\(.html_url)"' 2>/dev/null)

  log-info "Resolved ${#PER_ENV_JOB_URL[@]} per-env job URL(s)."
}

# ============================================================================
# Step 2: List existing PR state
# ============================================================================

function list_pr_state {
  start-group "Step 2: List existing PR comments and matrix job URLs"

  # Resolve per-env matrix job URLs first (independent of PR comment listing —
  # if comments listing fails we still want best-effort job URLs for the
  # Links row's `job log` line).
  _resolve_per_env_job_urls

  local comments_json
  if ! comments_json=$(_gh_list_pr_comments "${GITHUB_REPOSITORY}" "${input_pr_number}" 2>&1); then
    log-warn "Failed to list PR comments: ${comments_json}"
    log-warn "Entering degraded mode — upsert will post fresh bodies instead of editing in place."
    DEGRADED_MODE="true"
    end-group
    return 0
  fi

  # When --paginate returns multiple pages concatenated, the result may be
  # multiple separate JSON arrays. Combine via jq -s 'add' to get a single
  # flat array regardless.
  local normalized
  if ! normalized=$(echo "${comments_json}" | jq -s 'add // []' 2>/dev/null); then
    log-warn "Failed to normalize PR comments JSON — entering degraded mode"
    DEGRADED_MODE="true"
    end-group
    return 0
  fi

  local total
  total=$(echo "${normalized}" | jq 'length')
  log-info "PR has ${total} comment(s) total."

  # Find existing group comments by HTML marker on the first line of the
  # body: '<!-- terraform-validation-summary-group:<group> -->'. Multiple
  # IDs per group are tolerated (and self-healed in the upsert pass).
  # Group name is parsed by stripping the family prefix and the trailing
  # ' -->' marker close.
  #
  # Legacy comments from the pre-marker era (body starts with the H3
  # heading rather than the marker) are not matched here — they sit
  # untouched on the PR and the upsert pass posts a fresh marked comment
  # alongside them. This is the documented "no-migration" trade-off
  # (docs/Workflow-pr-comments.md §2.1).
  local group_lines
  group_lines=$(echo "${normalized}" \
    | jq -r --arg fam "${GROUP_COMMENT_MARKER_FAMILY}" '
        .[]
        | select(.body | startswith($fam))
        | .id as $id
        | .created_at as $created
        | (.body | split("\n")[0] | sub($fam; "") | sub(" -->.*$"; "")) as $g
        | "\($id)\t\($created)\t\($g)"
      ' 2>/dev/null) || group_lines=""

  if [ -n "${group_lines}" ]; then
    local line cid created gname
    while IFS=$'\t' read -r cid created gname; do
      [ -z "${cid}" ] && continue
      # Pack as "<created_at>|<id>" so a later 'sort' gives the oldest first
      # — created_at is ISO-8601, lexicographically sortable. The upsert
      # pass picks the head of the sorted list to keep, deletes the rest.
      if [ -n "${EXISTING_GROUP_COMMENTS[${gname}]:-}" ]; then
        EXISTING_GROUP_COMMENTS[${gname}]+=$'\n'"${created}|${cid}"
      else
        EXISTING_GROUP_COMMENTS[${gname}]="${created}|${cid}"
      fi
      log-info "  existing group comment: '${gname}' (id=${cid}, created=${created})"
    done <<<"${group_lines}"
  else
    log-info "  no existing group comments on PR"
  fi

  # Build per-env anchor map. For each env in any desired group, look for a
  # comment whose body starts with the env's exact per-env prefix. If 2+
  # match (rare; should self-heal via comment-on-pr@v2's delete-by-prefix on
  # the next per-env run), pick the comment with the highest numeric id
  # (newest, GitHub IDs are monotonic) and log a warning.
  local group env
  for group in "${!DESIRED_GROUPS[@]}"; do
    while IFS= read -r env; do
      [ -z "${env}" ] && continue
      local per_env_prefix
      per_env_prefix=$(_per_env_prefix "${env}")

      local matched_ids
      matched_ids=$(echo "${normalized}" \
        | jq -r --arg p "${per_env_prefix}" '.[] | select(.body | startswith($p)) | .id' \
          2>/dev/null) || matched_ids=""

      # Count lines safely: grep -c returns exit 1 with no matches which
      # would otherwise trigger a fallback that appends a stray "0".
      local count=0
      if [ -n "${matched_ids}" ]; then
        count=$(echo "${matched_ids}" | wc -l | tr -d ' ')
      fi

      if [ "${count}" = "0" ]; then
        log-debug "  env '${env}': no per-env comment posted — Links cell will show only job log"
      elif [ "${count}" = "1" ]; then
        PER_ENV_ANCHOR[${env}]="#issuecomment-${matched_ids}"
        log-info "  env '${env}': resolved log-extract anchor to ${PER_ENV_ANCHOR[${env}]}"
      else
        local newest
        newest=$(echo "${matched_ids}" | sort -nr | head -n1)
        PER_ENV_ANCHOR[${env}]="#issuecomment-${newest}"
        log-warn "  env '${env}': ${count} per-env comments match (race / stale duplicates); using newest id=${newest}"
      fi
    done <<<"${DESIRED_GROUPS[${group}]}"
  done

  end-group
}

# ============================================================================
# Step 3: Render one group's comment body
# ============================================================================

# Renders the full body for one group. Writes to stdout.
# Args:
#   $1  - group name
#   $2  - newline-delimited list of envs (already alphabetically sorted)
function render_group_body {
  local group_name="${1}"
  local envs_nl="${2}"
  local marker prefix
  marker=$(_group_marker "${group_name}")
  prefix=$(_group_prefix "${group_name}")

  local -a envs=()
  while IFS= read -r e; do
    [ -n "${e}" ] && envs+=("${e}")
  done <<<"${envs_nl}"

  # ---- Header row: "|  | Step | env1 | env2 | ... |" ----
  local header="|  | Step |"
  local sep="|:---:|---|"
  local env
  for env in "${envs[@]}"; do
    header+=" ${env} |"
    sep+=":---:|"
  done

  # ---- Step rows ----
  local rows=""
  local row_def step_id emoji label
  for row_def in "${GROUPED_TABLE_STEP_ROWS[@]}"; do
    step_id="${row_def%%|*}"
    local rest="${row_def#*|}"
    emoji="${rest%%|*}"
    label="${rest##*|}"

    local row="| $(_render_step_icon_cell "${emoji}" "${label}") | ${label} |"
    for env in "${envs[@]}"; do
      local outcome
      outcome=$(_extract_step_outcome "${group_name}" "${env}" "${step_id}")
      row+=" $(_render_status_cell "${outcome}") |"
    done
    rows+="${row}"$'\n'
  done

  # ---- Plan Details row ----
  local plan_details_row="| $(_render_step_icon_cell "📊" "Plan details") | Plan details |"
  for env in "${envs[@]}"; do
    local meta_file="${DESIRED_META[${group_name}/${env}]:-}"
    local c_add c_change c_destroy c_import c_move c_remove
    c_add=$(_extract_plan_count "${meta_file}" "count-add")
    c_change=$(_extract_plan_count "${meta_file}" "count-change")
    c_destroy=$(_extract_plan_count "${meta_file}" "count-destroy")
    c_import=$(_extract_plan_count "${meta_file}" "count-import")
    c_move=$(_extract_plan_count "${meta_file}" "count-move")
    c_remove=$(_extract_plan_count "${meta_file}" "count-remove")
    plan_details_row+=" $(_render_plan_details_cell "${c_add}" "${c_change}" "${c_destroy}" "${c_import}" "${c_move}" "${c_remove}") |"
  done

  # ---- Links row ----
  local links_row="| $(_render_step_icon_cell "🔗" "Links") | Links |"
  for env in "${envs[@]}"; do
    # Resolved per-env job URL (Jobs API, step 2). Empty when not resolvable;
    # _render_links_cell drops the line in that case (we don't emit wrong URLs).
    local job_log_url="${PER_ENV_JOB_URL[${env}]:-}"
    local anchor="${PER_ENV_ANCHOR[${env}]:-}"
    links_row+=" $(_render_links_cell "${anchor}" "${job_log_url}") |"
  done

  # ---- Footer ----
  local first_env_meta_file
  first_env_meta_file=$(_first_meta_file_for_group "${group_name}")
  local footer
  footer=$(_render_footer "${first_env_meta_file}")

  # ---- Assembly ----
  # The HTML marker is line 1 and the load-bearing identity for upserts —
  # see docs/Workflow-pr-comments.md §2. The H3 'prefix' line follows; it
  # is still rendered (visible to readers) but no longer used for comment
  # identification, so the H3 wording can be tweaked freely as long as
  # the marker is unchanged.
  printf '%s\n%s\n%s\n%s\n%s%s\n%s\n\n%s\n' \
    "${marker}" \
    "${prefix}" \
    "${header}" \
    "${sep}" \
    "${rows}" \
    "${plan_details_row}" \
    "${links_row}" \
    "${footer}"
}

# ----------------------------------------------------------------------------
# Render helpers (private)
# ----------------------------------------------------------------------------

# Extract step outcome from a matrix-job-meta file. Returns "" if step not present.
function _extract_step_outcome {
  local group="${1}" env="${2}" step_id="${3}"
  local file="${DESIRED_META[${group}/${env}]:-}"
  [ -z "${file}" ] || [ ! -f "${file}" ] && { echo ""; return; }
  jq -r --arg s "${step_id}" '.steps[$s].outcome // ""' "${file}" 2>/dev/null || echo ""
}

# Extract a single plan count from a metadata file. Empty when parse-plan
# either didn't run or its output is missing the field.
function _extract_plan_count {
  local file="${1}" key="${2}"
  [ -z "${file}" ] || [ ! -f "${file}" ] && { echo ""; return; }
  local val
  val=$(jq -r --arg k "${key}" '.steps["parse-plan"].outputs[$k] // ""' "${file}" 2>/dev/null || echo "")
  [ "${val}" = "null" ] && val=""
  echo "${val}"
}

# Pick any one metadata file from a group (for sourcing actor/event/workflow
# in the footer — they're the same across the run).
function _first_meta_file_for_group {
  local group="${1}"
  local first_env
  first_env=$(echo "${DESIRED_GROUPS[${group}]}" | head -n1)
  echo "${DESIRED_META[${group}/${first_env}]:-}"
}

# Render the footer line. Mirrors create-validation-summary's v0.24+ footer
# (docs/Workflow-pr-comments.md §4.1): a single [Job log](url) line. The
# pusher/action/workflow data is discoverable on the linked run page and in
# the PR conversation timeline — restating it on every comment was noise.
function _render_footer {
  local file="${1}"
  local run_id=""
  if [ -n "${file}" ] && [ -f "${file}" ]; then
    run_id=$(jq -r '.workflow.run_id // ""' "${file}")
  fi
  run_id="${run_id:-${GITHUB_RUN_ID:-0}}"
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${run_id}"
  echo "[Job log](${run_url})"
}

# ============================================================================
# Step 4: Orphan-delete pass — drop marker comments whose group is no
# longer in the desired set. Desired groups themselves are handled by the
# upsert pass below (PATCH-in-place + dedupe).
# ============================================================================

function orphan_delete_pass {
  start-group "Step 4: Delete orphan group comments"

  if [ "${DEGRADED_MODE}" = "true" ]; then
    log-warn "Degraded mode — skipping orphan delete pass."
    end-group
    return 0
  fi

  if [ ${#EXISTING_GROUP_COMMENTS[@]} -eq 0 ]; then
    log-info "No existing group comments — nothing to clean up."
    end-group
    return 0
  fi

  local existing_group entry created cid
  for existing_group in "${!EXISTING_GROUP_COMMENTS[@]}"; do
    # Only orphan if the group is NOT in the desired set. Desired groups
    # are kept (one survivor) by the upsert pass.
    if [ -n "${DESIRED_GROUPS[${existing_group}]:-}" ]; then
      continue
    fi
    # Delete every comment for this orphan group — markers from prior
    # double-posts could accumulate here too.
    while IFS= read -r entry; do
      [ -z "${entry}" ] && continue
      created="${entry%%|*}"
      cid="${entry##*|}"
      log-info "  deleting orphan group comment '${existing_group}' (id=${cid}, created=${created})"
      if _gh_delete_comment "${GITHUB_REPOSITORY}" "${cid}" >/dev/null 2>&1; then
        _record_processed "${existing_group}" "${cid}" "orphan-deleted"
      else
        log-warn "  failed to delete comment id=${cid} (group '${existing_group}') — continuing"
      fi
    done <<<"${EXISTING_GROUP_COMMENTS[${existing_group}]}"
  done

  end-group
}

# ============================================================================
# Step 5: Upsert pass — for every desired group, either PATCH the
# oldest existing marker comment (stable identity across runs, no
# re-pinging of subscribers) or POST a fresh one. Duplicate marker
# comments for the same group are deleted in the same pass so the
# system is self-healing — if a prior run posted twice (e.g. degraded
# mode + later recovery), the next clean run leaves exactly one comment
# per group.
# ============================================================================

function upsert_pass {
  if [ ${#DESIRED_GROUPS[@]} -eq 0 ]; then
    log-info "Step 5: Upsert group comments — no desired groups, nothing to upsert."
    return 0
  fi

  log-info "Step 5: Upsert group comments (${#DESIRED_GROUPS[@]} group(s))"

  # Sort group names for deterministic output ordering.
  local -a sorted_groups=()
  while IFS= read -r g; do sorted_groups+=("${g}"); done < <(printf '%s\n' "${!DESIRED_GROUPS[@]}" | sort)

  local group envs_sorted body body_file
  for group in "${sorted_groups[@]}"; do
    start-group "Step 5: Upsert group '${group}'"

    # Sort envs alphabetically within the group (docs/Workflow-pr-comments.md §4.2)
    envs_sorted=$(echo "${DESIRED_GROUPS[${group}]}" | sort)
    log-info "Rendering (envs: $(echo "${envs_sorted}" | tr '\n' ',' | sed 's/,$//'))"

    body=$(render_group_body "${group}" "${envs_sorted}")
    body_file=$(mktemp)
    printf '%s' "${body}" >"${body_file}"

    log-info "Body:"
    echo "${body}"

    _upsert_one_group "${group}" "${body_file}"

    rm -f "${body_file}"
    end-group
  done
}

# Upsert a single group's comment. Picks the oldest existing marker
# comment (lowest created_at, since GitHub IDs are monotonic but the
# created_at field is the canonical timestamp) to keep, deletes any
# others, then PATCHes the keeper. If none exist, POSTs fresh.
#
# In degraded mode (PR comments listing failed) we don't know what
# exists, so we always POST fresh — duplicates will self-heal on the
# next clean run via this same dedupe branch.
function _upsert_one_group {
  local group="${1}" body_file="${2}"

  if [ "${DEGRADED_MODE}" = "true" ]; then
    log-warn "Degraded mode — posting fresh (cannot list existing comments to upsert)."
    _post_fresh "${group}" "${body_file}"
    return
  fi

  local entries="${EXISTING_GROUP_COMMENTS[${group}]:-}"
  if [ -z "${entries}" ]; then
    log-info "No existing marker comment for '${group}' — posting fresh."
    _post_fresh "${group}" "${body_file}"
    return
  fi

  # Sort entries by created_at (ISO-8601, lexicographic). Oldest first.
  local sorted_entries
  sorted_entries=$(echo "${entries}" | sort)
  local keep_entry
  keep_entry=$(echo "${sorted_entries}" | head -n1)
  local keep_id="${keep_entry##*|}"
  local keep_created="${keep_entry%%|*}"

  # Delete every entry except the keeper.
  local entry created cid
  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    created="${entry%%|*}"
    cid="${entry##*|}"
    if [ "${cid}" = "${keep_id}" ]; then
      continue
    fi
    log-info "  duplicate '${group}' marker comment (id=${cid}, created=${created}) — deleting"
    if _gh_delete_comment "${GITHUB_REPOSITORY}" "${cid}" >/dev/null 2>&1; then
      _record_processed "${group}" "${cid}" "duplicate-deleted"
    else
      log-warn "  failed to delete duplicate id=${cid} for '${group}' — continuing"
    fi
  done <<<"${sorted_entries}"

  # PATCH the keeper.
  log-info "Editing existing comment in place (id=${keep_id}, created=${keep_created})."
  if _gh_patch_comment "${GITHUB_REPOSITORY}" "${keep_id}" "${body_file}" >/dev/null 2>&1; then
    _record_processed "${group}" "${keep_id}" "patched"
  else
    log-warn "PATCH failed for '${group}' (id=${keep_id}) — posting fresh as fallback."
    _post_fresh "${group}" "${body_file}"
  fi
}

# Internal: POST a fresh comment for a group. Used by _upsert_one_group
# on the "no existing comment" and "degraded mode" branches.
function _post_fresh {
  local group="${1}" body_file="${2}"
  local new_id
  if new_id=$(_gh_post_comment "${GITHUB_REPOSITORY}" "${input_pr_number}" "${body_file}" 2>&1); then
    log-info "posted: comment id=${new_id}"
    _record_processed "${group}" "${new_id}" "posted"
  else
    log-warn "failed to post comment for group '${group}': ${new_id}"
    _record_processed "${group}" "0" "post-failed"
  fi
}

# ============================================================================
# Output helpers
# ============================================================================

function _record_processed {
  local group="${1}" comment_id="${2}" action="${3}"
  PROCESSED_RESULTS_JSON=$(echo "${PROCESSED_RESULTS_JSON}" | jq \
    --arg g "${group}" --arg id "${comment_id}" --arg a "${action}" \
    '. + [{"group": $g, "comment-id": $id, "action": $a}]')
}

# ============================================================================
# Main
# ============================================================================

function main {
  log-info "Starting aggregate-validation-summaries..."
  log-info "Pattern:    ${input_metadata_files_pattern:-<unset>}"
  log-info "PR number:  ${input_pr_number:-<unset>}"
  log-info "Repository: ${GITHUB_REPOSITORY:-<unset>}"

  if [ -z "${input_pr_number:-}" ]; then
    log-error "input_pr_number is required"
    return 1
  fi
  if [ -z "${GITHUB_REPOSITORY:-}" ]; then
    log-error "GITHUB_REPOSITORY is required (set by GitHub Actions)"
    return 1
  fi

  build_desired_set
  list_pr_state
  orphan_delete_pass
  upsert_pass

  set-multiline-output "groups-processed-json" "${PROCESSED_RESULTS_JSON}"
  log-info "Done. Processed ${#DESIRED_GROUPS[@]} group(s)."
  return 0
}

main
_main_exit_code=$?
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return ${_main_exit_code}
else
  exit ${_main_exit_code}
fi
