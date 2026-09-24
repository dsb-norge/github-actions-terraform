#!/bin/env bash
#
# Action-specific helpers for create-run-summary.
# Auto-loaded by helpers.sh.
#

# One cell of an unaffected environment's row. Every cell carries the tooltip,
# not just the first: a reader hovers the cell they are looking at.
NOT_AFFECTED_CELL='<span title="not affected">—</span>'

# One step output from a metadata file; empty when absent or JSON null.
function meta_step_output {
  local file="${1}" step="${2}" key="${3}"
  local v
  v=$(jq -r --arg s "${step}" --arg k "${key}" '.steps[$s].outputs[$k] // ""' "${file}" 2>/dev/null || echo "")
  [ "${v}" = "null" ] && v=""
  printf '%s' "${v}"
}

# One step outcome from a metadata file; empty when the step is absent.
function meta_step_outcome {
  local file="${1}" step="${2}"
  jq -r --arg s "${step}" '.steps[$s].outcome // ""' "${file}" 2>/dev/null || echo ""
}

# 'N' for a non-negative integer, '?' for anything else.
function count_or_q {
  local v="${1:-}"
  if [[ "${v}" =~ ^[0-9]+$ ]]; then printf '%s' "${v}"; else printf '?'; fi
}

# Worst outcome across the validation and mutating steps, as an emoji with a
# tooltip. failure/cancelled anywhere wins; then success; then '—' when the
# env has no recorded outcome at all (e.g. a job cancelled before init).
#   Prints "<emoji>|<worst>" — split on '|' by the caller.
function worst_outcome {
  local file="${1}"
  local worst="" o
  for step in init verify-lock fmt validate lint plan apply destroy-plan destroy; do
    o=$(meta_step_outcome "${file}" "${step}")
    case "${o}" in
      failure|cancelled) worst="failure" ;;
      success) [ -z "${worst}" ] && worst="success" ;;
    esac
  done
  case "${worst}" in
    failure) printf '<span title="a step failed or was cancelled">❌</span>|failure' ;;
    success) printf '<span title="every step that ran succeeded">✅</span>|success' ;;
    *)       printf '<span title="no step outcome recorded">—</span>|none' ;;
  esac
}

# Sum of mm:ss durations given as arguments (empty / 'N/A' ignored), as mm:ss;
# '—' when none was numeric.
function sum_durations {
  local total=0 any="" d m s
  for d in "$@"; do
    if [[ "${d}" =~ ^([0-9]+):([0-9]{2})$ ]]; then
      m="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[2]}"
      total=$((total + 10#${m} * 60 + 10#${s})); any="true"
    fi
  done
  if [ -z "${any}" ]; then printf '—'; else printf '`%d:%02d`' $((total / 60)) $((total % 60)); fi
}

# Plan cell: '`💫 A` `🛠️ C` `💥 D`' from parse-plan, or '—'.
function plan_cell {
  local file="${1}"
  local a c d
  a=$(meta_step_output "${file}" parse-plan count-add)
  c=$(meta_step_output "${file}" parse-plan count-change)
  d=$(meta_step_output "${file}" parse-plan count-destroy)
  if [ -z "${a}${c}${d}" ]; then printf '—'; return; fi
  printf '`💫 %s` `🛠️ %s` `💥 %s`' "$(count_or_q "${a}")" "$(count_or_q "${c}")" "$(count_or_q "${d}")"
}

# Apply cell: applied/planned badges, '?' numerators when apply did not
# complete (docs/Apply-and-destroy-reporting.md P2); '—' when apply did not run.
function apply_cell {
  local file="${1}"
  local outcome; outcome=$(meta_step_outcome "${file}" apply)
  if [ -z "${outcome}" ] || [ "${outcome}" = 'skipped' ]; then printf '—'; return; fi
  local completed a c d pa pc pd
  completed=$(meta_step_output "${file}" parse-apply completed)
  a=$(meta_step_output "${file}" parse-apply count-add); c=$(meta_step_output "${file}" parse-apply count-change); d=$(meta_step_output "${file}" parse-apply count-destroy)
  pa=$(meta_step_output "${file}" parse-plan count-add); pc=$(meta_step_output "${file}" parse-plan count-change); pd=$(meta_step_output "${file}" parse-plan count-destroy)
  [ "${completed}" = 'true' ] || { a='?'; c='?'; d='?'; }
  printf '`💫 %s/%s` `🛠️ %s/%s` `💥 %s/%s`' \
    "$(count_or_q "${a}")" "$(count_or_q "${pa}")" "$(count_or_q "${c}")" "$(count_or_q "${pc}")" "$(count_or_q "${d}")" "$(count_or_q "${pd}")"
}

# Destroy cell: destroyed/planned, or '—' when destroy did not run.
function destroy_cell {
  local file="${1}"
  local outcome; outcome=$(meta_step_outcome "${file}" destroy)
  if [ -z "${outcome}" ] || [ "${outcome}" = 'skipped' ]; then printf '—'; return; fi
  local completed d pd
  completed=$(meta_step_output "${file}" parse-destroy-apply completed)
  d=$(meta_step_output "${file}" parse-destroy-apply count-destroy)
  pd=$(meta_step_output "${file}" parse-destroy-plan count-destroy)
  [ "${completed}" = 'true' ] || d='?'
  printf '`💥 %s/%s`' "$(count_or_q "${d}")" "$(count_or_q "${pd}")"
}
