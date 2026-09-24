#!/bin/env bash
#
# Action-specific helpers for aggregate-validation-summaries.
#
# Production-only helpers (no test-only code). Sourced automatically
# by helpers.sh.
#

# Family marker shared by every per-group head comment this action manages.
# Lives on the first line of the body as an HTML comment so it's invisible
# to readers. The per-group marker (built via _group_marker) extends this
# with the group name and a trailing ' -->', allowing a single PR to host
# multiple group comments and have each one upserted independently.
# Renders to nothing in the GitHub Markdown view.
# See docs/Workflow-pr-comments.md for the heads + tags model.
declare -gr GROUP_COMMENT_MARKER_FAMILY='<!-- tf:head:group:'

# Specific group comment H3 heading (rendered immediately after the marker
# at the top of the body). Kept for visible identification — users still
# see "for group: \`<group>\`" — but no longer load-bearing for upsert
# identity. The marker (_group_marker) is the load-bearing handle.
#   $2 'true' when any env in the group mutates infrastructure on the pull
#      request — the group then gets the shorter title, for the same reason the
#      per-env head does: it did more than validate.
function _group_prefix {
  local group_name="${1}" any_mode="${2:-false}"
  local title="Terraform validation summary"
  [ "${any_mode}" = 'true' ] && title="Terraform summary"
  echo "### ${title} for group: \`${group_name}\`"
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

# Row definitions for the grouped table's always-present step rows.
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

# The mutating operations, each a four-row block (status · warnings ·
# details · time) appended after Plan time in execution order. Presence is
# group-wide: a block renders when ANY env in the group has an outcome for
# its step; envs without render '—' / 'N/A'.
# Format: "<step-id>|<emoji>|<label>|<warnings-step-id>|<time-output-name>"
# Kept in sync with create-validation-summary's _render_*_block functions
# (docs/Apply-and-destroy-reporting.md §8.1, P9; enforced by test F1).
declare -gar GROUPED_TABLE_OP_BLOCKS=(
  "apply|🐙|Apply|parse-apply-warnings|apply-time"
  "destroy-plan|☠📖|Destroy plan|parse-destroy-plan-warnings|plan-time"
  "destroy|☠|Destroy|parse-destroy-warnings|apply-time"
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

# Render a Warnings cell for a single env in the grouped table.
# Empty input (no parse-warnings data) → "—" (matches the not-applicable
# fallback used by _render_plan_time_cell and _status_emoji_and_title's
# default branch). 0 → "—" too, since "no warnings" is not interesting.
# Non-zero numeric → "⚠️ N" inside a tooltip-bearing span so the row
# stays scannable in the grouped table. $2 is the tooltip; it defaults to
# the original init+validate+plan wording so the existing row is unchanged.
function _render_warning_count_cell {
  local v="${1:-}"
  local title="${2:-Warnings from init+validate+plan}"
  if [ -z "${v}" ] || [ "${v}" = "0" ]; then
    echo "<span title=\"${title}\">—</span>"
    return
  fi
  echo "<span title=\"${title}\">⚠️ ${v}</span>"
}

# One "applied / planned" badge — byte-identical to create-validation-
# summary's _render_ratio_badge. The numerator is '?' whenever the operation
# did not complete, whatever count arrived (docs/Apply-and-destroy-reporting.md P2).
function _render_ratio_badge {
  local emoji="${1}" applied="${2}" planned="${3}" verb="${4}" completed="${5}"
  local num='?' den='?'
  if [ "${completed}" = 'true' ] && [[ "${applied}" =~ ^[0-9]+$ ]]; then num="${applied}"; fi
  if [[ "${planned}" =~ ^[0-9]+$ ]]; then den="${planned}"; fi
  echo "<span title=\"Applied / planned\">\`${emoji} ${num}/${den}\` ${verb}</span>"
}

# Apply details cell: three applied/planned badges. "N/A" when parse-apply
# left no data at all for the env (the step did not run).
function _render_apply_details_cell {
  local a_add="${1}" a_change="${2}" a_destroy="${3}" p_add="${4}" p_change="${5}" p_destroy="${6}" completed="${7}"
  if [ -z "${a_add}" ] && [ -z "${a_change}" ] && [ -z "${a_destroy}" ] && [ -z "${completed}" ]; then
    echo "N/A"
    return 0
  fi
  local cell="<div align=\"left\">"
  cell+="$(_render_ratio_badge "💫" "${a_add}" "${p_add}" "added" "${completed}")"
  cell+="<br>$(_render_ratio_badge "🛠️" "${a_change}" "${p_change}" "changed" "${completed}")"
  cell+="<br>$(_render_ratio_badge "💥" "${a_destroy}" "${p_destroy}" "destroyed" "${completed}")"
  cell+="</div>"
  echo "${cell}"
}

# Destroy details cell: a single destroyed/planned badge.
function _render_destroy_details_cell {
  local d_destroy="${1}" p_destroy="${2}" completed="${3}"
  if [ -z "${d_destroy}" ] && [ -z "${completed}" ]; then
    echo "N/A"
    return 0
  fi
  echo "<div align=\"left\">$(_render_ratio_badge "💥" "${d_destroy}" "${p_destroy}" "destroyed" "${completed}")</div>"
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

# Render the Links cell for a single env (0-5 lines, <br>-separated), in
# the order the operations run: plan tag, apply tag, destroy-plan tag,
# destroy tag, job log. Each argument may be empty — that line is omitted.
# All empty yields an empty cell rather than a row of stray pipes.
# See docs/Workflow-pr-comments.md §4.5.
function _render_links_cell {
  local log_extract_anchor="${1}"
  local job_log_url="${2}"
  local apply_anchor="${3:-}"
  local destroy_plan_anchor="${4:-}"
  local destroy_anchor="${5:-}"

  local -a lines=()
  if [ -n "${log_extract_anchor}" ]; then
    lines+=("[log extract](${log_extract_anchor})")
  fi
  if [ -n "${apply_anchor}" ]; then
    lines+=("[apply log](${apply_anchor})")
  fi
  if [ -n "${destroy_plan_anchor}" ]; then
    lines+=("[destroy plan log](${destroy_plan_anchor})")
  fi
  if [ -n "${destroy_anchor}" ]; then
    lines+=("[destroy log](${destroy_anchor})")
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

# ============================================================================
# Body assembly helper
# ============================================================================
#
# Mirror of pr-comment / pr-comments-reconcile — kept duplicated per the
# action-implementation-guide.md self-containment convention. When
# touching one, audit the others (pr-comment/helpers_additional.sh,
# pr-comments-reconcile/helpers_additional.sh).

# Assemble the full rendered body: <marker>\n\n<user-body>. The HTML
# marker is line 1 (load-bearing for upsert identity); a blank separator
# line follows; then the visible body.
function _render_full_body {
  local marker="${1}"
  local user_body="${2}"
  printf '%s\n\n%s' "${marker}" "${user_body}"
}

# Mode cell for one env in the grouped table (docs/Apply-and-destroy-reporting.md
# §8.2, §8.8): '🐙' / '☠' / '🐙☠' from the env's goals, '—' when the env does
# not mutate on PR. Driven by goals, not outcomes, so a group mixing an
# applying env with plan-only envs shows exactly which column is the
# dangerous one before any apply has happened.
#   $1 'true' when goals contain apply-on-pr, $2 'true' for destroy-on-pr
function _render_mode_cell {
  local apply_on_pr="${1}" destroy_on_pr="${2}"
  local title='This environment mutates infrastructure on pull request'
  local icon=""
  [ "${apply_on_pr}" = 'true' ] && icon+="🐙"
  [ "${destroy_on_pr}" = 'true' ] && icon+="☠"
  if [ -z "${icon}" ]; then
    echo "<span title=\"${title}\">—</span>"
  else
    echo "<span title=\"${title}\">${icon}</span>"
  fi
}

# Every cell of an environment path relevance left out of the run: no job ran
# for it, so there is no outcome, count or link to show. The tooltip says why,
# where a bare '—' would read as "not applicable" (docs/Path-relevance.md §6.2).
declare -gr NOT_AFFECTED_CELL='<span title="not affected by this pull request">—</span>'

# The footer line naming a group's unaffected members, backticked and joined
# with ', ' in the order given; nothing when there are none.
#   $@ environment names
function _render_not_affected_line {
  [ ${#} -eq 0 ] && return 0
  local out="" name
  for name in "${@}"; do
    out+="${out:+, }\`${name}\`"
  done
  echo "➖ Not affected by this pull request: ${out}"
}

# A step whose if: was false has the outcome STRING 'skipped', not ''. Both
# mean "did not run" here. Gating on non-empty alone rendered three skipped
# blocks on every plan-only environment in the first real run — breaking the
# byte-identical invariant (docs/Apply-and-destroy-reporting.md §2, P30).
function _op_ran { [ -n "${1:-}" ] && [ "${1}" != 'skipped' ]; }
