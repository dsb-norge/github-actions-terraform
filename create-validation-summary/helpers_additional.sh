#!/bin/env bash
#
# Action-specific helper functions for create-validation-summary
#
# Provides formatting utilities used by the step script.
#

# Format a step status for the markdown summary table.
# Successful statuses are shown in backticks, failures in <kbd> tags.
#
# NOTE: this text representation (`success` / <kbd>failure</kbd>) is an
# intentional divergence from the grouped head, which uses emoji
# (✅/❌/…). The per-env head has one wide "Result" column where text reads
# well; the grouped head has many narrow per-env columns where emoji stay
# compact. Keep them different — see docs/Workflow-pr-comments.md §5.1/§5.3.
#
# Arguments:
#   $1 - status string (e.g., "success", "failure", "skipped")
# Output:
#   Formatted markdown string written to stdout
function format-status {
  local status="${1}"
  if [ "${status}" == 'success' ]; then
    echo "\`${status}\`"
  else
    echo "<kbd>${status}</kbd>"
  fi
}

# Render the column-1 step-icon cell with a hover tooltip (the label is the
# step name). Kept byte-identical to the grouped head's helper of the same
# name (aggregate-validation-summaries/helpers_additional.sh) so the two
# validation tables render col-1 the same way.
function _render_step_icon_cell {
  local emoji="${1}"
  local label="${2}"
  echo "<span title=\"${label}\">${emoji}</span>"
}

# Render a mm:ss time cell. A real duration is backtick-wrapped; empty or
# the literal 'N/A' (the action.yml input default) renders the em-dash. Both
# carry the unit tooltip — same shape the grouped head uses.
function _render_time_cell {
  local v="${1:-}"
  local title='mm:ss (minutes:seconds)'
  if [ -z "${v}" ] || [ "${v}" = 'N/A' ]; then
    echo "<span title=\"${title}\">—</span>"
  else
    echo "<span title=\"${title}\">\`${v}\`</span>"
  fi
}

# Render one "applied / planned" badge for the Apply / Destroy details rows.
#   $1 emoji, $2 applied count, $3 planned count, $4 past-tense verb,
#   $5 whether the operation completed ('true' or anything else)
# The numerator is '?' whenever the operation did not complete, whatever
# count arrived: terraform prints no summary line for a failed apply, and a
# zero there would read as "nothing happened" for an infrastructure that
# may be half applied (docs/Apply-and-destroy-reporting.md P2, §8.3).
# Either side that is not numeric renders as '?'.
function _render_ratio_badge {
  local emoji="${1}" applied="${2}" planned="${3}" verb="${4}" completed="${5}"
  local num='?' den='?'
  if [ "${completed}" = 'true' ] && [[ "${applied}" =~ ^[0-9]+$ ]]; then num="${applied}"; fi
  if [[ "${planned}" =~ ^[0-9]+$ ]]; then den="${planned}"; fi
  echo "<span title=\"Applied / planned\">\`${emoji} ${num}/${den}\` ${verb}</span>"
}

# Plain-text 'applied/planned' for the apply and destroy tag <summary> lines.
# Same '?' rules as _render_ratio_badge, but no markup: the text sits inside
# a raw HTML block, where backticks and <span> would render literally.
#   $1 applied count, $2 planned count, $3 completed ('true' or anything else)
function _ratio_text {
  local applied="${1}" planned="${2}" completed="${3}"
  local num='?' den='?'
  if [ "${completed}" = 'true' ] && [[ "${applied}" =~ ^[0-9]+$ ]]; then num="${applied}"; fi
  if [[ "${planned}" =~ ^[0-9]+$ ]]; then den="${planned}"; fi
  echo "${num}/${den}"
}

# True when the value is a positive integer — the gate for every warnings
# row. 0, empty, 'N/A' and '?' all fail it.
function _is_positive_int {
  [[ "${1:-0}" =~ ^[0-9]+$ ]] && [ "${1}" -gt 0 ]
}

# Parse the env's goals (a JSON array in ${input_goals_json}) into the two
# on-PR flags. Malformed or empty JSON yields neither flag — no Mode row, no
# banner, no crash: the goals are informational here, and a broken input
# must not take the whole comment down with it.
#   Sets: GOALS_APPLY_ON_PR / GOALS_DESTROY_ON_PR to 'true' or ''.
function _parse_on_pr_goals {
  GOALS_APPLY_ON_PR=""
  GOALS_DESTROY_ON_PR=""
  local goals="${input_goals_json:-}"
  [ -z "${goals}" ] && return 0
  if ! printf '%s' "${goals}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log-warn "goals-json is not a JSON array; ignoring it" 1>&2
    return 0
  fi
  printf '%s' "${goals}" | jq -e 'index("apply-on-pr") != null'   >/dev/null 2>&1 && GOALS_APPLY_ON_PR="true"
  printf '%s' "${goals}" | jq -e 'index("destroy-on-pr") != null' >/dev/null 2>&1 && GOALS_DESTROY_ON_PR="true"
  return 0
}

# The Mode row (docs/Apply-and-destroy-reporting.md §8.2): rendered from the
# goals, independently of any outcome, so it is on the PR the moment the
# workflow starts and stays whether the apply succeeded, failed or never ran.
# Prints the row WITH a leading newline, or nothing when neither flag is set.
function _render_mode_row {
  [ -z "${GOALS_APPLY_ON_PR}" ] && [ -z "${GOALS_DESTROY_ON_PR}" ] && return 0
  local icon="" value=""
  local title='This environment mutates infrastructure on pull request'
  if [ -n "${GOALS_APPLY_ON_PR}" ]; then
    icon+="🐙"
    value+="<span title=\"${title}\">applies on PR</span>"
  fi
  if [ -n "${GOALS_DESTROY_ON_PR}" ]; then
    icon+="☠"
    [ -n "${value}" ] && value+="<br>"
    value+="<span title=\"${title}\">destroys on PR</span>"
  fi
  printf '\n| %s | Mode | %s |' "$(_render_step_icon_cell "${icon}" "Mode")" "${value}"
}

# The plan-tag banner (§8.5): a blockquote between the heading and the
# plan-block when the env mutates on PR. No anchor to the apply comment —
# the plan tag is POSTed before the apply tag exists; the head's Links row
# carries the anchor instead. Prints with a trailing blank line, or nothing.
function _render_plan_tag_banner {
  local out=""
  if [ -n "${GOALS_APPLY_ON_PR}" ]; then
    out+="> 🐙 This environment applies on pull request — the plan below was applied to real infrastructure. The result is in the 🐙 apply comment."$'\n'
  fi
  if [ -n "${GOALS_DESTROY_ON_PR}" ]; then
    out+="> ☠ This environment destroys on pull request — the destroy plan was applied to real infrastructure. The result is in the ☠ destroy comment."$'\n'
  fi
  [ -n "${out}" ] && printf '%s\n' "${out}"
  return 0
}

# Copy an apply console to a tempfile with everything from the first
# '^Outputs:$' line to EOF removed, unless the caller opted in to keep it.
# terraform apply prints every non-sensitive output's actual VALUE there —
# something terraform plan never does — so posting it would publish values
# the plan comment has always kept hidden (docs/Apply-and-destroy-reporting.md P3).
#   $1 source file, $2 'true' to keep the section
#   Sets STRIP_RESULT_FILE to the path to render from (the source itself
#   when nothing was stripped) and OUTPUTS_STRIPPED to 'true' when a section
#   was removed. Results travel through globals on purpose: called via
#   $(...) they would be set in a subshell and lost.
function _strip_outputs_section {
  local src="${1}" keep="${2:-false}"
  STRIP_RESULT_FILE="${src}"
  OUTPUTS_STRIPPED=""
  [ -z "${src}" ] || [ ! -f "${src}" ] && return 0
  if [ "${keep}" = 'true' ] || ! grep -q '^Outputs:$' "${src}"; then
    return 0
  fi
  STRIP_RESULT_FILE="${RUNNER_TEMP:-/tmp}/$(basename "${src}" .txt)-no-outputs-$$.txt"
  awk '/^Outputs:$/ {exit} {print}' "${src}" >"${STRIP_RESULT_FILE}"
  OUTPUTS_STRIPPED="true"
}

# A step whose if: was false has the outcome STRING 'skipped', not ''. Both
# mean "did not run" here. Gating on non-empty alone rendered three skipped
# blocks on every plan-only environment in the first real run — breaking the
# byte-identical invariant (docs/Apply-and-destroy-reporting.md §2, P30).
function _op_ran { [ -n "${1:-}" ] && [ "${1}" != 'skipped' ]; }
