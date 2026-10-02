#!/bin/env bash
#
# Action-specific helpers for create-run-summary.
# Auto-loaded by helpers.sh.
#

# One cell of an unaffected environment's row. Every cell carries the tooltip,
# not just the first: a reader hovers the cell they are looking at.
NOT_AFFECTED_CELL='<span title="not affected">—</span>'

# ----------------------------------------------------------------------------
# Dependabot admission (docs/Dependabot-admission.md §7)
# ----------------------------------------------------------------------------

# The reason the engine gives every environment of a refused Dependabot pull
# request (docs/Dependabot-admission.md §5.2, §9), read from reasons[0].
NOT_ADMITTED_REASON='admission: not admitted'

# One cell of a not-admitted environment's row, the aggregator's cell: a dash
# would say the change does not touch it, which nobody judged.
NOT_ADMITTED_CELL='<span title="not admitted: the Dependabot admission refused this pull request">🚫</span>'

# True when the relevance file says the Dependabot admission refused this run:
# it applies, is not Dependabot's push run, and did not admit. A file without
# the block (written before the admission existed) or with any other shape is
# not refused, so it renders exactly as before; a run is only called refused
# when the engine says so in as many words.
#   $1 the relevance file
function admission_refused {
  jq -e '(.admission | type) == "object"
         and .admission.applies == true and .admission.push_run == false and .admission.admitted == false' \
    "${1}" >/dev/null 2>&1
}

# The admission section of a refused run: the heading, what happened, and the
# table of every changed dependency and problem with its result, as the
# engine's admission head renders it (comments.admission_report) but without
# the help, which the admission comment carries (D15). Rendered by jq straight
# from the file, so the inventory never sits in a shell variable under
# allexport. Into a temp file first, so a block jq cannot read leaves no half
# a table: the section is then left out with a warning, never the step failed.
#   $1 the relevance file
function render_admission_section {
  local table
  table=$(mktemp)
  if ! jq -r '
      .admission
      | "| Dependency | Change | Result |", "|---|---|---|",
        ((.dependencies // [])[]
         | [(.checks // [])[] | select(.ok | not)] as $failed
         | (if .kind == "provider"
            then "provider `\(.address | tostring | ltrimstr("registry.terraform.io/"))`"
            else "module `\(.address)`" end) as $label
         | (if ($failed | length) == 0 then "✅ admitted"
            else "❌ " + ($failed | map(.detail | tostring) | join("; ")) end) as $result
         | "| \($label) | \(.from) → \(.to) | \($result) |"),
        ((.problems // [])[] | "| the change | — | ❌ \(.detail) |")' "${1}" >"${table}" 2>/dev/null; then
    log-warn "the admission block of ${1} could not be read; its section is left out" 1>&2
    rm -f "${table}"
    return 0
  fi
  printf '### 🚫 Dependabot pull request not admitted\n\n'
  printf 'No Terraform ran: the Dependabot admission refused this pull request. The pull request'"'"'s admission comment says what to do.\n\n'
  cat "${table}"
  printf '\n'
  rm -f "${table}"
}

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

# ----------------------------------------------------------------------------
# Environment ordering (docs/Environment-ordering.md §7)
# ----------------------------------------------------------------------------

# The stage results the workflow passes (stage-results-json), normalised to an
# object of result strings in a temp file whose path is left in
# STAGE_RESULTS_FILE; empty when the input is absent, blank or not an object,
# which renders exactly as before ordering. The value is a shell-local the shim
# captured before allexport; it reaches jq through a here-string, never argv.
function read_stage_results {
  STAGE_RESULTS_FILE=""
  local raw="${input_stage_results_json:-}"
  [[ "${raw}" =~ ^[[:space:]]*$ ]] && return 0
  local file
  file=$(mktemp)
  if ! jq -ce 'if type == "object" then with_entries(select(.value | type == "string")) else error("not an object") end' \
    <<<"${raw}" >"${file}" 2>/dev/null; then
    log-warn "stage-results-json is not a JSON object of stage results; rendering without ordering" 1>&2
    rm -f "${file}"
    return 0
  fi
  STAGE_RESULTS_FILE="${file}"
}

# The run entries of a relevance file that a skipped stage held back, one per
# line in the file's order: github-environment, stage, and the stage that held
# it back with that stage's result (both empty when no earlier stage failed or
# was cancelled), joined by the unit separator. Nothing without stage results.
#
# A stage job skipped for having no environments and one skipped because an
# earlier stage failed both report 'skipped'; only the builder's row count
# tells them apart (P5). Stage 1 is never held back: nothing runs before it, so
# a skipped stage 1 is a cancelled run, reported as it always was.
function held_back_entries {
  local relevance_file="${1}"
  [ -z "${STAGE_RESULTS_FILE:-}" ] && return 0
  jq -r --slurpfile sr "${STAGE_RESULTS_FILE}" '
    $sr[0] as $results
    | (.counts.by_stage // {}) as $by
    | .environments[]
    | select(.verdict == "run")
    | ((.stage // 1) | tonumber? // 1) as $stage
    | select($stage >= 2
             and ($results[$stage | tostring] // "") == "skipped"
             and ((($by[$stage | tostring] // 0) | tonumber? // 0) > 0))
    | ([range(1; $stage) | select(($results[tostring] // "") as $r | $r == "failure" or $r == "cancelled")] | first) as $cause
    | [(.["github-environment"] // .environment // "" | tostring), ($stage | tostring),
       (if $cause then ($cause | tostring) else "" end), (if $cause then $results[$cause | tostring] else "" end)]
    | join("\u001f")' "${relevance_file}" 2>/dev/null || true
}

# 'stage 1 failed' or 'stage 1 was cancelled'.
#   $1 stage, $2 its result
function stage_outcome_phrase {
  if [ "${2}" = 'cancelled' ]; then printf 'stage %s was cancelled' "${1}"; else printf 'stage %s failed' "${1}"; fi
}

# The held-back outcome cell's tooltip: 'held back: stage 2; stage 1 failed',
# or 'held back: stage 2' when the results name no cause.
#   $1 stage, $2 the stage that held it back (may be empty), $3 that stage's result
function held_back_title {
  local title="held back: stage ${1}"
  [ -n "${2}" ] && title+="; $(stage_outcome_phrase "${2}" "${3}")"
  printf '%s' "${title}"
}

# 'stage 2', 'stages 2 and 3', 'stages 1, 2 and 3'.
#   $@ stage numbers, ascending
function stage_list {
  if [ ${#} -eq 1 ]; then printf 'stage %s' "${1}"; return 0; fi
  local -a all=("${@}")
  local last="${all[-1]}" head="" s
  for s in "${all[@]:0:${#all[@]}-1}"; do head+="${head:+, }${s}"; done
  printf 'stages %s and %s' "${head}" "${last}"
}

# Names backticked and joined with ', '.
function backtick_join {
  local out="" name
  for name in "${@}"; do out+="${out:+, }\`${name}\`"; done
  printf '%s' "${out}"
}

# True when the metadata shows a Terraform operation that failed while
# allow-failing-terraform-operations was set: the failure that keeps the job
# green, and so releases the next stage (D5, P10).
function tolerated_failure {
  jq -e '
    (.matrix_context.vars["allow-failing-terraform-operations"] // false) as $allow
    | ($allow == true or $allow == "true")
      and any(("init", "verify-lock", "fmt", "validate", "lint", "plan", "apply", "destroy-plan", "destroy") as $s
              | (.steps[$s] // {}) | if type == "object" then (.outcome // "") else "" end; . == "failure")' \
    "${1}" >/dev/null 2>&1
}

# The declared dependencies left out of the run, for every run entry granted
# apply or destroy, one per line: the entry's github-environment, the
# dependency's github-environment, and the engine's reason for leaving it out.
# The engine names a dependency by its environment; every row here is labelled
# by github-environment, so the name is mapped to the label its row carries.
function missing_dependencies {
  jq -r '
    (reduce .environments[] as $e ({}; .[($e.environment // "" | tostring)] = ($e["github-environment"] // $e.environment // "" | tostring))) as $label
    | .environments[]
    | select(.verdict == "run" and ((.goals // []) | type == "array" and any(.[]; . == "apply" or . == "destroy")))
    | (.["github-environment"] // .environment // "" | tostring) as $me
    | (.reasons // [])[]
    | strings
    | capture("^ordering: depends-on '\''(?<dep>.*)'\'' not in this run \\((?<why>.*)\\)$")
    | [$me, ($label[.dep] // .dep), .why]
    | join("\u001f")' "${1}" 2>/dev/null || true
}
