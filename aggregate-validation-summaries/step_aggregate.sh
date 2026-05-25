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

  # Route through tempfiles, never shell variables — under 'set -o
  # allexport' a large captured response gets exported to subprocess env
  # and pushes envp past ARG_MAX on the next `jq` fork (exit 126,
  # "Argument list too long").
  local jobs_raw_file
  jobs_raw_file=$(mktemp)
  if ! _gh_list_run_jobs "${GITHUB_REPOSITORY}" "${run_id}" >"${jobs_raw_file}" 2>&1; then
    log-warn "Failed to list run jobs (id=${run_id}): $(cat "${jobs_raw_file}")"
    log-warn "Links row will omit the 'job log' line for all envs."
    rm -f "${jobs_raw_file}"
    return 0
  fi

  # _gh_list_run_jobs uses --paginate with --jq '.jobs', so multi-page
  # output is one JSON array per page. jq -s flattens these.
  local all_jobs_file
  all_jobs_file=$(mktemp)
  if ! jq -s 'add // []' <"${jobs_raw_file}" >"${all_jobs_file}" 2>/dev/null; then
    log-warn "Failed to parse jobs JSON; Links row will omit 'job log' for all envs."
    rm -f "${jobs_raw_file}" "${all_jobs_file}"
    return 0
  fi
  rm -f "${jobs_raw_file}"

  local total
  total=$(jq 'length' <"${all_jobs_file}")
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
  done < <(jq -r '.[] | "\(.name)\t\(.html_url)"' <"${all_jobs_file}" 2>/dev/null)
  rm -f "${all_jobs_file}"

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

  # Route through tempfiles, never shell variables — under 'set -o
  # allexport' a large captured response gets exported to subprocess env
  # and pushes envp past ARG_MAX on the next `jq` fork (exit 126,
  # "Argument list too long"). Real symptom on production PR with
  # multiple plan-tag comments approaching the 65k-per-body cap.
  local comments_raw_file
  comments_raw_file=$(mktemp)
  if ! _gh_list_pr_comments "${GITHUB_REPOSITORY}" "${input_pr_number}" >"${comments_raw_file}" 2>&1; then
    log-warn "Failed to list PR comments: $(cat "${comments_raw_file}")"
    log-warn "Entering degraded mode — upsert will post fresh bodies instead of editing in place."
    DEGRADED_MODE="true"
    rm -f "${comments_raw_file}"
    end-group
    return 0
  fi

  # When --paginate returns multiple pages concatenated, the result may be
  # multiple separate JSON arrays. Combine via jq -s 'add' to get a single
  # flat array regardless. Result kept on disk; only the path travels as
  # a shell variable.
  local normalized_file
  normalized_file=$(mktemp)
  if ! jq -s 'add // []' <"${comments_raw_file}" >"${normalized_file}" 2>/dev/null; then
    log-warn "Failed to normalize PR comments JSON — entering degraded mode"
    DEGRADED_MODE="true"
    rm -f "${comments_raw_file}" "${normalized_file}"
    end-group
    return 0
  fi
  rm -f "${comments_raw_file}"

  local total
  total=$(jq 'length' <"${normalized_file}")
  log-info "PR has ${total} comment(s) total."

  # Find existing group comments by HTML marker on the first line of the
  # body: '<!-- tf:head:group:<group> -->'. Multiple IDs per group are
  # tolerated (and self-healed in the upsert pass). Group name is parsed
  # by stripping the family prefix and the trailing ' -->' marker close.
  local group_lines
  group_lines=$(jq -r --arg fam "${GROUP_COMMENT_MARKER_FAMILY}" '
      .[]
      | select(.body | startswith($fam))
      | .id as $id
      | .created_at as $created
      | (.body | split("\n")[0] | sub($fam; "") | sub(" -->.*$"; "")) as $g
      | "\($id)\t\($created)\t\($g)"
    ' <"${normalized_file}" 2>/dev/null) || group_lines=""

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

  # Build per-env anchor map. For each env in any desired group, look for
  # the env's per-env plan tag by HTML marker substring; anchor the group
  # head's Links column at that comment so reviewers jump to the env's
  # plan output. Scope by env + GITHUB_RUN_ID (matches any attempt of the
  # current run) so stale tags from prior runs that escaped cleanup don't
  # mis-anchor the Links row. Within a single run, multiple attempts of
  # the same env should leave just one tag (the matrix job's delete-first
  # step purges prior ones before POSTing), but the newest-by-id
  # tiebreaker handles the unlikely case where two coexist.
  local run_id="${GITHUB_RUN_ID:-0}"
  local group env
  for group in "${!DESIRED_GROUPS[@]}"; do
    while IFS= read -r env; do
      [ -z "${env}" ] && continue
      local plan_tag_prefix
      plan_tag_prefix="<!-- tf:tag:plan:${env}:run-id-${run_id}:"

      local matched_ids
      matched_ids=$(jq -r --arg m "${plan_tag_prefix}" '.[] | select(.body | contains($m)) | .id' \
          <"${normalized_file}" 2>/dev/null) || matched_ids=""

      # Count lines safely: grep -c returns exit 1 with no matches which
      # would otherwise trigger a fallback that appends a stray "0".
      local count=0
      if [ -n "${matched_ids}" ]; then
        count=$(echo "${matched_ids}" | wc -l | tr -d ' ')
      fi

      if [ "${count}" = "0" ]; then
        log-debug "  env '${env}': no plan tag found for run ${run_id} — Links cell will show only job log"
      elif [ "${count}" = "1" ]; then
        PER_ENV_ANCHOR[${env}]="#issuecomment-${matched_ids}"
        log-info "  env '${env}': resolved log-extract anchor to ${PER_ENV_ANCHOR[${env}]}"
      else
        local newest
        newest=$(echo "${matched_ids}" | sort -nr | head -n1)
        PER_ENV_ANCHOR[${env}]="#issuecomment-${newest}"
        log-warn "  env '${env}': ${count} plan tags match for run ${run_id}; using newest id=${newest}"
      fi
    done <<<"${DESIRED_GROUPS[${group}]}"
  done

  rm -f "${normalized_file}"
  end-group
}

# ============================================================================
# Step 3: Render one group's comment body
# ============================================================================

# Renders the user-visible portion of one group's body (H3 + table + footer).
# Writes to stdout. The caller wraps this with the HTML marker + a
# `<!-- comment-hash:<sha> -->` line via _render_full_body before
# POSTing/PATCHing, so re-runs with unchanged content hash-short-circuit
# the PATCH and don't re-ping subscribers.
# Args:
#   $1  - group name
#   $2  - newline-delimited list of envs (already alphabetically sorted)
function render_group_body {
  local group_name="${1}"
  local envs_nl="${2}"
  local prefix
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

  # ---- Warnings row ----
  # Positioned between step rows and Plan details so reviewers scan
  # top-to-bottom: "did each step pass" → "any warnings" → "what changes
  # are planned". Cell shape is "⚠️ N" (or "—" for zero/missing); the
  # warning bodies themselves live in the per-env plan-tag comment via
  # create-validation-summary. See docs/Plan-warnings.md §6.
  local warnings_row="| $(_render_step_icon_cell "⚠️" "Warnings") | Warnings |"
  for env in "${envs[@]}"; do
    local meta_file="${DESIRED_META[${group_name}/${env}]:-}"
    local wc
    wc=$(_extract_warning_count "${meta_file}")
    warnings_row+=" $(_render_warning_count_cell "${wc}") |"
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

  # ---- Plan time row ----
  # Sits below Plan details so timing reads as supplementary plan info,
  # not as a step-status row alongside init/fmt/validate/lint/plan.
  local plan_time_row="| $(_render_step_icon_cell "⏱" "Plan time") | Plan time |"
  for env in "${envs[@]}"; do
    local meta_file="${DESIRED_META[${group_name}/${env}]:-}"
    local pt
    pt=$(_extract_plan_time "${meta_file}")
    plan_time_row+=" $(_render_plan_time_cell "${pt}") |"
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
  # Returns the user-visible portion (H3 + table + footer). The HTML
  # marker (load-bearing for upsert identity, see Workflow-pr-comments.md
  # §2) and the inline comment-hash line are prepended by _render_full_body
  # in _upsert_one_group / _post_fresh.
  # 'rows' ends with a trailing newline; the rest are plain rows with no
  # trailing newline, so the format string supplies the line breaks.
  printf '%s\n%s\n%s\n%s%s\n%s\n%s\n%s\n\n%s\n' \
    "${prefix}" \
    "${header}" \
    "${sep}" \
    "${rows}" \
    "${warnings_row}" \
    "${plan_details_row}" \
    "${plan_time_row}" \
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

# Extract the total warning count across all three parse-terraform-warnings
# invocations (init / validate / plan) from a matrix-job-meta file. Returns
# the sum as a string. Missing step outputs are treated as 0. Returns "0"
# when the meta file is missing entirely or none of the steps ran — the
# rendering helper (_render_warning_count_cell) then displays "—".
#
# Step IDs are 'parse-init-warnings', 'parse-validate-warnings',
# 'parse-plan-warnings' — must match the IDs set in
# .github/workflows/terraform-ci-cd-default.yml.
function _extract_warning_count {
  local file="${1}"
  [ -z "${file}" ] || [ ! -f "${file}" ] && { echo "0"; return; }
  jq -r '
    (.steps["parse-init-warnings"].outputs["warning-count"] // "0" | tonumber? // 0) +
    (.steps["parse-validate-warnings"].outputs["warning-count"] // "0" | tonumber? // 0) +
    (.steps["parse-plan-warnings"].outputs["warning-count"] // "0" | tonumber? // 0)
  ' "${file}" 2>/dev/null || echo "0"
}

# Extract the plan-time (mm:ss) emitted by terraform-plan from the metadata
# file. Empty when terraform-plan didn't run for this env or the file is
# from a prior version that didn't expose the output. The caller's
# rendering helper (_render_plan_time_cell) maps empty → "—".
function _extract_plan_time {
  local file="${1}"
  [ -z "${file}" ] || [ ! -f "${file}" ] && { echo ""; return; }
  local val
  val=$(jq -r '.steps.plan.outputs["plan-time"] // ""' "${file}" 2>/dev/null || echo "")
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

# Render the footer line for the per-group head: a single [Workflow log](url)
# pointing at the workflow run page. The per-env heads' [Job log] footer
# (in create-validation-summary) targets a specific job's #logs anchor; this
# one targets the run page that aggregates every job, so the label differs.
function _render_footer {
  local file="${1}"
  local run_id=""
  if [ -n "${file}" ] && [ -f "${file}" ]; then
    run_id=$(jq -r '.workflow.run_id // ""' "${file}")
  fi
  run_id="${run_id:-${GITHUB_RUN_ID:-0}}"
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${run_id}"
  echo "[Workflow log](${run_url})"
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

  local group envs_sorted marker body
  for group in "${sorted_groups[@]}"; do
    start-group "Step 5: Upsert group '${group}'"

    # Sort envs alphabetically within the group (docs/Workflow-pr-comments.md §4.2)
    envs_sorted=$(echo "${DESIRED_GROUPS[${group}]}" | sort)
    log-info "Rendering (envs: $(echo "${envs_sorted}" | tr '\n' ',' | sed 's/,$//'))"

    marker=$(_group_marker "${group}")
    body=$(render_group_body "${group}" "${envs_sorted}")

    # Log the assembled body (marker + hash marker + user body) so the
    # ##[group] block shows exactly what gets written on PATCH/POST and
    # so byte-exact tests can grep the marker line in step output.
    log-info "Body:"
    _render_full_body "${marker}" "${body}"
    echo

    _upsert_one_group "${group}" "${marker}" "${body}"

    end-group
  done
}

# Upsert a single group's comment. Picks the oldest existing marker
# comment (lowest created_at, since GitHub IDs are monotonic but the
# created_at field is the canonical timestamp) to keep, deletes any
# others, then PATCHes the keeper. If none exist, POSTs fresh. Skips the
# PATCH entirely when the existing comment's embedded comment-hash
# matches the new body — no updated_at churn, no subscriber re-ping on
# no-op runs.
#
# In degraded mode (PR comments listing failed) we don't know what
# exists, so we always POST fresh — duplicates will self-heal on the
# next clean run via this same dedupe branch.
function _upsert_one_group {
  local group="${1}" marker="${2}" user_body="${3}"

  if [ "${DEGRADED_MODE}" = "true" ]; then
    log-warn "Degraded mode — posting fresh (cannot list existing comments to upsert)."
    _post_fresh "${group}" "${marker}" "${user_body}"
    return
  fi

  local entries="${EXISTING_GROUP_COMMENTS[${group}]:-}"
  if [ -z "${entries}" ]; then
    log-info "No existing marker comment for '${group}' — posting fresh."
    _post_fresh "${group}" "${marker}" "${user_body}"
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

  # Compose the full body (marker + blank + user body) and PATCH.
  local body_file
  body_file=$(mktemp)
  _render_full_body "${marker}" "${user_body}" >"${body_file}"

  log-info "Editing existing comment in place (id=${keep_id}, created=${keep_created})."
  if _gh_patch_comment "${GITHUB_REPOSITORY}" "${keep_id}" "${body_file}" >/dev/null 2>&1; then
    _record_processed "${group}" "${keep_id}" "patched"
  else
    log-warn "PATCH failed for '${group}' (id=${keep_id}) — posting fresh as fallback."
    rm -f "${body_file}"
    _post_fresh "${group}" "${marker}" "${user_body}"
    return
  fi
  rm -f "${body_file}"
}

# Internal: POST a fresh comment for a group. Used by _upsert_one_group
# on the "no existing comment", "degraded mode", and "PATCH-failed
# fallback" branches.
function _post_fresh {
  local group="${1}" marker="${2}" user_body="${3}"
  local body_file
  body_file=$(mktemp)
  _render_full_body "${marker}" "${user_body}" >"${body_file}"
  local new_id
  if new_id=$(_gh_post_comment "${GITHUB_REPOSITORY}" "${input_pr_number}" "${body_file}" 2>&1); then
    log-info "posted: comment id=${new_id}"
    _record_processed "${group}" "${new_id}" "posted"
  else
    log-warn "failed to post comment for group '${group}': ${new_id}"
    _record_processed "${group}" "0" "post-failed"
  fi
  rm -f "${body_file}"
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
