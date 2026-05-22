#!/bin/env bash
#
# Action-specific helpers for aggregate-validation-summaries.
#
# Production-only helpers (no test-only code). Sourced automatically
# by helpers.sh.
#

# Family marker shared by every per-group comment this action manages.
# Lives on the first line of the body as an HTML comment so it's invisible
# to readers. The per-group marker (built via _group_marker) extends this
# with the group name and a trailing ' -->', allowing a single PR to host
# multiple group comments and have each one upserted independently.
# Renders to nothing in the GitHub Markdown view.
# See docs/Workflow-pr-comments.md §2.
declare -gr GROUP_COMMENT_MARKER_FAMILY='<!-- terraform-validation-summary-group:'

# Per-env comment prefix template (uses backtick-delimited env name so
# partial matches can't collide).
# See docs/Workflow-pr-comments.md §2.
function _per_env_prefix {
  local env_name="${1}"
  echo "### Terraform validation summary for environment: \`${env_name}\`"
}

# Specific group comment H3 heading (rendered immediately after the marker
# at the top of the body). Kept for visible identification — users still
# see "for group: \`<group>\`" — but no longer load-bearing for upsert
# identity. The marker (_group_marker) is the load-bearing handle.
function _group_prefix {
  local group_name="${1}"
  echo "### Terraform validation summary for group: \`${group_name}\`"
}

# Per-group HTML marker. Unique per group so multiple groups on the same
# PR can be upserted independently.
function _group_marker {
  local group_name="${1}"
  echo "${GROUP_COMMENT_MARKER_FAMILY}${group_name} -->"
}

# Map a GitHub Actions step outcome string to the (emoji, title) pair used
# in the grouped table's status cells.
# Outcomes: success | failure | cancelled | skipped | '' (missing)
# Output written to stdout: "<emoji>|<title>" — split on '|' by caller.
# See docs/Workflow-pr-comments.md §4.3.
function _status_emoji_and_title {
  local outcome="${1}"
  case "${outcome}" in
    success)   echo "✅|success" ;;
    failure)   echo "❌|failure" ;;
    cancelled) echo "🚫|cancelled" ;;
    skipped)   echo "⏭️|skipped" ;;
    *)         echo "—|not applicable" ;;
  esac
}

# Render a status cell for the grouped table (column-2 emoji wrapped in
# <span title="..."> so desktop browsers surface a hover tooltip).
function _render_status_cell {
  local outcome="${1}"
  local pair emoji title
  pair=$(_status_emoji_and_title "${outcome}")
  emoji="${pair%%|*}"
  title="${pair##*|}"
  echo "<span title=\"${title}\">${emoji}</span>"
}

# Render the column-1 step-icon cell with a tooltip (label is the step name).
function _render_step_icon_cell {
  local emoji="${1}"
  local label="${2}"
  echo "<span title=\"${label}\">${emoji}</span>"
}

# Row definitions for the grouped table.
# Format: "<step-id-in-matrix-meta>|<emoji>|<label>".
# The step-id matches the keys under `steps:` in a matrix-job-meta-*.json
# file (set by capture-matrix-job-meta from GitHub's steps context).
# See .github/workflows/terraform-ci-cd-default.yml: id: init, verify-lock,
# fmt, validate, lint, plan.
declare -gar GROUPED_TABLE_STEP_ROWS=(
  "init|⚙️|Initialization"
  "verify-lock|🔒|Lock file"
  "fmt|🖌|Format and Style"
  "validate|✔|Validate"
  "lint|🧹|TFLint"
  "plan|📖|Plan"
)

# Render the Plan Details cell for a single env in the grouped table.
# Cell content is wrapped in <div align="left">...</div> so the badge stack
# anchors to the left edge of the otherwise center-aligned column (see
# docs/Workflow-pr-comments.md §4.4).
# Echos "N/A" when no parse-plan data is available for the env.
function _render_plan_details_cell {
  local count_add="${1}"
  local count_change="${2}"
  local count_destroy="${3}"
  local count_import="${4}"
  local count_move="${5}"
  local count_remove="${6}"

  # All-empty means parse-plan didn't run for this env -> N/A
  if [ -z "${count_add}" ] && [ -z "${count_change}" ] && [ -z "${count_destroy}" ]; then
    echo "N/A"
    return 0
  fi

  local cell="<div align=\"left\">"
  cell+="<span title=\"Resources to be added\">\`💫 ${count_add:-0}\` add</span>"
  cell+="<br><span title=\"Resources to be changed\">\`🛠️ ${count_change:-0}\` change</span>"
  cell+="<br><span title=\"Resources to be destroyed\">\`💥 ${count_destroy:-0}\` destroy</span>"

  if [ -n "${count_move}" ] && [ "${count_move}" != "0" ]; then
    cell+="<br><span title=\"Resources to be moved\">\`🔀 ${count_move}\` move</span>"
  fi
  if [ -n "${count_import}" ] && [ "${count_import}" != "0" ]; then
    cell+="<br><span title=\"Resources to be imported\">\`📥 ${count_import}\` import</span>"
  fi
  if [ -n "${count_remove}" ] && [ "${count_remove}" != "0" ]; then
    cell+="<br><span title=\"Resources to be removed\">\`⛓️‍💥 ${count_remove}\` remove</span>"
  fi

  cell+="</div>"
  echo "${cell}"
}

# Render the Plan time cell for a single env in the grouped table.
# Empty input → "—" (matches the existing 'not applicable' fallback from
# _status_emoji_and_title for missing data). Non-empty values are wrapped
# in backticks for a monospace look that aligns with the rest of the
# data badges in the table.
# Both branches wrap the cell in <span title="mm:ss (minutes:seconds)"> so
# desktop-hover discloses the value's unit — even on the em-dash branch,
# where the dash itself communicates absence and the tooltip explains
# what would otherwise be there.
function _render_plan_time_cell {
  local v="${1:-}"
  local title='mm:ss (minutes:seconds)'
  if [ -z "${v}" ]; then
    echo "<span title=\"${title}\">—</span>"
    return
  fi
  echo "<span title=\"${title}\">\`${v}\`</span>"
}

# Render the Links cell for a single env (0-2 lines, <br>-separated).
# Each argument may be empty — the corresponding line is omitted. Both empty
# yields an empty cell rather than a row of stray pipes.
# See docs/Workflow-pr-comments.md §4.5.
function _render_links_cell {
  local log_extract_anchor="${1}"
  local job_log_url="${2}"

  local -a lines=()
  if [ -n "${log_extract_anchor}" ]; then
    lines+=("[log extract](${log_extract_anchor})")
  fi
  if [ -n "${job_log_url}" ]; then
    lines+=("[job log](${job_log_url})")
  fi

  if [ ${#lines[@]} -eq 0 ]; then
    echo ""
    return
  fi

  local out="${lines[0]}"
  local i
  for ((i = 1; i < ${#lines[@]}; i++)); do
    out+="<br>${lines[$i]}"
  done
  echo "${out}"
}

# gh-api wrappers. Production code calls these; tests can shadow them by
# putting a fake `gh` script earlier on PATH. Keeping the wrappers thin
# means the test surface is just the `gh` invocations.

function _gh_list_pr_comments {
  local repo="${1}" pr="${2}"
  # --paginate to get all comments regardless of page count
  gh api --paginate "repos/${repo}/issues/${pr}/comments"
}

# Lists jobs for a workflow run. Each page is an object {total_count, jobs: [...]}.
# We extract just the jobs array per page so the caller can combine them via
# jq -s 'add'.
function _gh_list_run_jobs {
  local repo="${1}" run_id="${2}"
  gh api --paginate "repos/${repo}/actions/runs/${run_id}/jobs" --jq '.jobs'
}

function _gh_delete_comment {
  local repo="${1}" comment_id="${2}"
  gh api -X DELETE "repos/${repo}/issues/comments/${comment_id}"
}

# Posts a comment, returns the new comment ID on stdout.
# Body is passed via a temp file (-F body=@file) so multi-line content
# is preserved and not subject to shell quoting.
function _gh_post_comment {
  local repo="${1}" pr="${2}" body_file="${3}"
  gh api -X POST "repos/${repo}/issues/${pr}/comments" -F "body=@${body_file}" --jq '.id'
}

# Edits an existing comment in place. Body file convention matches
# _gh_post_comment so callers can use the same temp file for either op.
function _gh_patch_comment {
  local repo="${1}" comment_id="${2}" body_file="${3}"
  gh api -X PATCH "repos/${repo}/issues/comments/${comment_id}" -F "body=@${body_file}" --jq '.id'
}
