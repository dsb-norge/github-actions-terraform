#!/bin/env bash
#
# Source for the summary step.
#
# Renders the run-level rollup — one row per environment — into
# $GITHUB_STEP_SUMMARY from the matrix-job-meta-*.json artifacts.
#
# Deliberately a different shape from the two PR-comment tables (steps as
# rows, envs as columns): envs as rows suits a wide run page, and the
# headline line is the part that survives being read on a phone. It is NOT
# part of the per-env/per-group table-sync invariant
# (docs/Apply-and-destroy-reporting.md §7.9, §8.7).
#
# The Job column links to the run page. Per-job URLs need the Jobs API
# (network, plus actions: read), and this job must never fail — the run
# page is one click from every job.
#
# Required environment variables:
#   input_metadata_files_pattern - Glob for the downloaded artifacts
#
# Optional environment variables:
#   input_relevance_file - Path of the matrix builder's relevance.json. Empty,
#                          missing on disk or unreadable → rendered exactly as
#                          without it (docs/Path-relevance.md §6.5, P8). Its
#                          admission block adds the section of a refused
#                          Dependabot pull request (docs/Dependabot-admission.md §7)
#   input_mode           - 'module' renders a module run's one block instead
#                          (docs/Module-ci.md §7.1); anything else, the project rollup
#   input_module_results_json - module mode: toJSON(needs) of the run summary job,
#                          a shell-local, never exported; written to a file at once
#   input_stage_results_json - {"1": <result>, "2": ..., "3": ...}, the stage
#                          jobs' results; a shell-local, never exported. With
#                          the relevance file it tells a held-back environment
#                          from one that crashed; absent or blank → rendered
#                          exactly as without it (docs/Environment-ordering.md §7.2)
#
# Standard GitHub environment variables used:
#   GITHUB_STEP_SUMMARY - the job summary file; unset → rendered to the log only
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID - the run URL
#
# Exit code: always 0. Reporting must not redden a deploy (P20).
#

set +o nounset

# Load helpers (provides the meta_* and *_cell helpers)
source "${GITHUB_ACTION_PATH}/helpers.sh"

function render_summary {
  shopt -s nullglob
  local files=(${input_metadata_files_pattern:-matrix-job-meta-*.json})
  shopt -u nullglob

  local run_id="${GITHUB_RUN_ID:-}"
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${run_id}"

  # Collect rows keyed by env name so the table is alphabetical regardless
  # of artifact order. Malformed files are skipped with a warning; the
  # other envs still render (P20).
  declare -A row_by_env=()
  declare -A worst_by_env=()
  declare -A applied_by_env=()
  declare -A destroyed_by_env=()
  declare -A tolerated_by_env=()
  # Scheduled plan-only runs whose plan has changes, or cannot be read
  # (docs/Drift-detection.md §3, §4); named in one line each under the table.
  local -a scheduled_changes=() scheduled_unread=() scheduled_drift=() scheduled_pending=() scheduled_ignored=()
  local file env rid
  for file in "${files[@]}"; do
    if ! jq -e '.' "${file}" >/dev/null 2>&1; then
      log-warn "skipping malformed metadata file: ${file}" 1>&2
      continue
    fi
    env=$(jq -r '.metadata.environment // empty' "${file}")
    if [ -z "${env}" ]; then
      log-warn "skipping ${file}: no .metadata.environment" 1>&2
      continue
    fi
    rid=$(jq -r '.workflow.run_id // empty' "${file}")
    [ -n "${rid}" ] && [ -z "${run_id}" ] && run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${rid}"

    local worst_pair worst_emoji worst
    worst_pair=$(worst_outcome "${file}")
    worst_emoji="${worst_pair%%|*}"; worst="${worst_pair##*|}"
    worst_by_env["${env}"]="${worst}"
    # "applied" means the apply step succeeded, full stop — the same signal the
    # head row, the tag and the annotation use, so the four cannot disagree.
    # `outcome` is GitHub's pre-continue-on-error result, so a failed apply
    # under allow-failing-terraform-operations still reads 'failure' here; an
    # earlier comment claimed otherwise and added parse-apply's `completed` as
    # a second condition, which made a successful apply whose output could not
    # be parsed vanish from the headline while its row showed '?/N' (P34).
    if [ "$(meta_step_outcome "${file}" apply)" = 'success' ]; then
      applied_by_env["${env}"]="true"
    fi
    # Same test for the destroy invocation. An env can be both: apply-on-pr and
    # destroy-on-pr in one run is the point of the throwaway-environment setup,
    # and a headline that says only "1 applied" hides the teardown entirely.
    if [ "$(meta_step_outcome "${file}" destroy)" = 'success' ]; then
      destroyed_by_env["${env}"]="true"
    fi
    # Only read with stage results: it names a tolerated failure that released a
    # later stage, which nothing without them can see.
    if [ -n "${STAGE_RESULTS_FILE:-}" ] && tolerated_failure "${file}"; then
      tolerated_by_env["${env}"]="true"
    fi
    case "$(scheduled_plan_state "${file}")" in
      drift)   scheduled_drift+=("${env}") ;;
      drift-pending) scheduled_drift+=("${env}"); scheduled_pending+=("${env}") ;;
      pending) scheduled_pending+=("${env}") ;;
      changes) scheduled_changes+=("${env}") ;;
      unread)  scheduled_unread+=("${env}") ;;
    esac
    local ignored
    ignored="$(scheduled_drift_ignored "${file}")"
    [ -n "${ignored}" ] && scheduled_ignored+=("${env}"$'\t'"${ignored}")

    local time_cell
    time_cell=$(sum_durations \
      "$(meta_step_output "${file}" plan plan-time)" \
      "$(meta_step_output "${file}" apply apply-time)" \
      "$(meta_step_output "${file}" destroy-plan plan-time)" \
      "$(meta_step_output "${file}" destroy apply-time)")

    row_by_env["${env}"]="| \`${env}\` | ${worst_emoji} | $(plan_cell "${file}") | $(apply_cell "${file}") | $(destroy_cell "${file}") | ${time_cell} | [run](${run_url}) |"
  done

  local relevance_file
  relevance_file=$(usable_relevance_file "${input_relevance_file:-}")
  if [ -n "${relevance_file}" ]; then
    render_with_relevance "${relevance_file}" "${run_url}"
    return 0
  fi

  local n_env=${#row_by_env[@]} n_applied=0 n_destroyed=0 n_failed=0
  for env in "${!row_by_env[@]}"; do
    [ "${worst_by_env[${env}]}" = 'failure' ] && n_failed=$((n_failed + 1))
    [ "${applied_by_env[${env}]:-}" = 'true' ] && n_applied=$((n_applied + 1))
    [ "${destroyed_by_env[${env}]:-}" = 'true' ] && n_destroyed=$((n_destroyed + 1))
  done
  ENVIRONMENT_COUNT="${n_env}"
  FAILED_COUNT="${n_failed}"

  printf '## Terraform run summary\n\n'
  if [ "${n_env}" -eq 0 ]; then
    printf '_No environments — the matrix did not run or no metadata artifacts were found._\n\n'
    printf '[Workflow run](%s)\n' "${run_url}"
    return 0
  fi

  local env_word="environments"; [ "${n_env}" -eq 1 ] && env_word="environment"
  # The destroyed count appears only when something was destroyed: most runs
  # never destroy, and a permanent '· 0 destroyed' would be noise on all of them.
  if [ "${n_destroyed}" -gt 0 ]; then
    printf '**%d %s · %d applied · %d destroyed · %d failed**\n\n' "${n_env}" "${env_word}" "${n_applied}" "${n_destroyed}" "${n_failed}"
  else
    printf '**%d %s · %d applied · %d failed**\n\n' "${n_env}" "${env_word}" "${n_applied}" "${n_failed}"
  fi
  printf '| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |\n'
  printf '|---|:---:|---|---|---|---|---|\n'
  while IFS= read -r env; do
    [ -z "${env}" ] && continue
    printf '%s\n' "${row_by_env[${env}]}"
  done < <(printf '%s\n' "${!row_by_env[@]}" | sort)
  print_footer
  print_scheduled_plan_lines
}

function print_footer {
  printf '\n_Plan / Apply / Destroy: `💫` added `🛠️` changed `💥` destroyed; apply and destroy cells are applied/planned, `?` when the operation did not complete. Time is the sum of the env'"'"'s terraform invocations._\n'
}

# The environments whose scheduled plan has changes, or could not be read, in
# one line each (docs/Drift-detection.md §3, §4). Uses render_summary's
# scheduled_* lists (bash dynamic scope). Nothing on any other run.
function print_scheduled_plan_lines {
  local names env count
  if [ "${#scheduled_drift[@]}" -gt 0 ]; then
    names=""
    while IFS= read -r env; do names="${names:+${names}, }\`${env}\`"; done < <(printf '%s\n' "${scheduled_drift[@]}" | sort)
    printf '\n⚠️ **Drift:** %s. Changed outside Terraform; the next apply would change it back.\n' "${names}"
  fi
  if [ "${#scheduled_pending[@]}" -gt 0 ]; then
    names=""
    while IFS= read -r env; do names="${names:+${names}, }\`${env}\`"; done < <(printf '%s\n' "${scheduled_pending[@]}" | sort)
    printf '\n⚠️ **The default branch is not applied:** %s. The scheduled plan has changes.\n' "${names}"
  fi
  if [ "${#scheduled_changes[@]}" -gt 0 ]; then
    names=""
    while IFS= read -r env; do names="${names:+${names}, }\`${env}\`"; done < <(printf '%s\n' "${scheduled_changes[@]}" | sort)
    printf '\n⚠️ **The scheduled plan has changes:** %s. Drift, or a default branch that is not applied.\n' "${names}"
  fi
  if [ "${#scheduled_unread[@]}" -gt 0 ]; then
    names=""
    while IFS= read -r env; do names="${names:+${names}, }\`${env}\`"; done < <(printf '%s\n' "${scheduled_unread[@]}" | sort)
    printf '\n⚠️ **The scheduled plan could not be read:** %s. See the plan in the job log.\n' "${names}"
  fi
  if [ "${#scheduled_ignored[@]}" -gt 0 ]; then
    names=""
    while IFS=$'\t' read -r env count; do
      names="${names:+${names}, }\`${env}\` (${count})"
    done < <(printf '%s\n' "${scheduled_ignored[@]}" | sort)
    printf '\nℹ️ **Drift the plan leaves alone:** %s. Nothing the next apply would change back, so not a finding.\n' "${names}"
  fi
}

# The path of the relevance file when it can be used, else empty. A missing
# file is expected, not an error: the download that fetches it is
# continue-on-error, so a run that uploaded none still reaches this step (P8).
function usable_relevance_file {
  local file="${1}"
  [ -z "${file}" ] && return 0
  if [ ! -f "${file}" ]; then
    log-warn "relevance file not found: ${file}; rendering without relevance" 1>&2
    return 0
  fi
  if ! jq -e '(.environments | type) == "array" and (.relevance | type) == "object"' "${file}" >/dev/null 2>&1; then
    log-warn "${file} is not a relevance document; rendering without relevance" 1>&2
    return 0
  fi
  printf '%s' "${file}"
}

# The summary with relevance: every environment of environments-yml, affected
# or not. Uses row_by_env / worst_by_env / applied_by_env / destroyed_by_env
# from render_summary (bash dynamic scope).
#
# Rows follow the file's order, which is environments-yml order, with the
# affected and unaffected ones interleaved: the caller wrote that order, and
# it keeps a row in the same place from one run to the next whether or not
# the change touched it. Today's alphabetical order only stands in for an
# order the metadata artifacts cannot provide.
function render_with_relevance {
  local file="${1}" run_url="${2}"
  local n_env=0 n_affected=0 n_unaffected=0 n_not_admitted=0 n_missing=0 n_held=0 n_applied=0 n_destroyed=0 n_failed=0
  local rows_file
  rows_file=$(mktemp)
  declare -A listed=()

  # Environments a skipped stage held back (docs/Environment-ordering.md §7.1),
  # keyed by github-environment; empty without stage results.
  declare -A held_stage=() held_cause=() held_result=()
  local -a held_names=() row_names=()
  declare -A env_stage=()
  local h_genv h_stage h_cause h_result
  while IFS=$'\x1f' read -r h_genv h_stage h_cause h_result; do
    [ -z "${h_genv}" ] && continue
    held_stage["${h_genv}"]="${h_stage}"
    held_cause["${h_genv}"]="${h_cause}"
    held_result["${h_genv}"]="${h_result}"
  done < <(held_back_entries "${file}")

  local verdict genv stage first_reason
  # Metadata is keyed by github-environment (the workflow passes it as the
  # capture's environment name), so rows are matched and labelled by it,
  # exactly as today's rows are.
  # Unit separator, not tab: tab is IFS whitespace, so `read` would collapse an
  # empty verdict field and shift the name into it.
  # The last field is the first reason, the rule that decided the verdict: it
  # tells an environment the Dependabot admission refused from one the change
  # does not touch (docs/Dependabot-admission.md §7).
  while IFS=$'\x1f' read -r verdict genv stage first_reason; do
    if [ -z "${genv}" ]; then
      log-warn "skipping a relevance entry without github-environment" 1>&2
      continue
    fi
    listed["${genv}"]="true"
    row_names+=("${genv}")
    [ "${verdict}" = 'run' ] && env_stage["${genv}"]="${stage}"
    n_env=$((n_env + 1))
    # Refused by the Dependabot admission: a skip, but not "not affected",
    # which nobody judged; nothing ran because the pull request was refused
    # (docs/Dependabot-admission.md §7, P14). Other skips on the same run,
    # trigger-events ones, keep the not-affected row.
    if [ "${verdict}" = 'skip' ] && [ "${first_reason}" = "${NOT_ADMITTED_REASON}" ]; then
      n_not_admitted=$((n_not_admitted + 1))
      printf '| `%s` | %s | %s | %s | %s | %s | %s |\n' "${genv}" \
        "${NOT_ADMITTED_CELL}" "${NOT_ADMITTED_CELL}" "${NOT_ADMITTED_CELL}" \
        "${NOT_ADMITTED_CELL}" "${NOT_ADMITTED_CELL}" "${NOT_ADMITTED_CELL}" >>"${rows_file}"
      continue
    fi
    if [ "${verdict}" = 'skip' ]; then
      n_unaffected=$((n_unaffected + 1))
      printf '| `%s` | %s | %s | %s | %s | %s | %s |\n' "${genv}" \
        "${NOT_AFFECTED_CELL}" "${NOT_AFFECTED_CELL}" "${NOT_AFFECTED_CELL}" \
        "${NOT_AFFECTED_CELL}" "${NOT_AFFECTED_CELL}" "${NOT_AFFECTED_CELL}" >>"${rows_file}"
      continue
    fi
    # Anything but 'skip' is affected: the engine fails open, so does this.
    n_affected=$((n_affected + 1))
    if [ -n "${row_by_env[${genv}]:-}" ]; then
      printf '%s\n' "${row_by_env[${genv}]}" >>"${rows_file}"
      count_env "${genv}"
    elif [ -n "${held_stage[${genv}]:-}" ]; then
      # Its stage never ran because an earlier one failed: no job, nothing
      # crashed, and nothing to report but why. The dashes are the unaffected
      # row's, without its "not affected" tooltip, which would be false here.
      n_held=$((n_held + 1))
      held_names+=("${genv}")
      printf '| `%s` | <span title="%s">⏭️</span> | — | — | — | — | — |\n' "${genv}" \
        "$(held_back_title "${held_stage[${genv}]}" "${held_cause[${genv}]}" "${held_result[${genv}]}")" >>"${rows_file}"
    else
      # The matrix job was cancelled or crashed before its metadata upload.
      # Not counted as failed — nothing says it failed — but never absent:
      # a missing row would read as "nothing to see".
      n_missing=$((n_missing + 1))
      printf '| `%s` | <span title="affected, but its job left no metadata: cancelled, crashed or not uploaded">❔</span> | — | — | — | — | [run](%s) |\n' \
        "${genv}" "${run_url}" >>"${rows_file}"
    fi
  done < <(jq -r '.environments[] | [(.verdict // "" | tostring), (.["github-environment"] // .environment // "" | tostring), (.stage // "" | tostring), (if (.reasons | type) == "array" then .reasons[0] // "" else "" end | tostring)] | join("\u001f")' "${file}" 2>/dev/null)

  # Metadata for an environment the file does not list cannot happen when both
  # come from the same run's matrix builder. Render it rather than drop it, and
  # leave N/A/U to the file, which is the decision this summary reports.
  local env
  while IFS= read -r env; do
    [ -z "${env}" ] && continue
    [ -n "${listed[${env}]:-}" ] && continue
    log-warn "metadata for '${env}', which is not in the relevance file; rendered after the listed environments" 1>&2
    printf '%s\n' "${row_by_env[${env}]}" >>"${rows_file}"
    count_env "${env}"
  done < <(printf '%s\n' "${!row_by_env[@]}" | sort)

  ENVIRONMENT_COUNT="${n_env}"
  FAILED_COUNT="${n_failed}"

  local mode reason changed event lines_file
  mode=$(jq -r '.relevance.mode // "" | tostring' "${file}")
  # Who dispatched what, or a schedule nothing took part in (docs/Dispatch-and-triggers.md §5); a file
  # from before the trigger block has neither.
  event=$(jq -r '.trigger.event // "" | tostring' "${file}")
  lines_file=$(mktemp)
  jq -r '.trigger.lines // [] | .[] | tostring' "${file}" >"${lines_file}" 2>/dev/null || : >"${lines_file}"
  reason=$(jq -r '.relevance.reason // "" | tostring' "${file}")
  changed=$(jq -r '.relevance.changed_count // 0 | tostring' "${file}")

  local env_word="environments"; [ "${n_env}" -eq 1 ] && env_word="environment"
  local headline
  headline="${n_env} ${env_word} · ${n_affected} affected · ${n_unaffected} not affected"
  # Only on a refused Dependabot pull request; every other run keeps its headline.
  [ "${n_not_admitted}" -gt 0 ] && headline="${headline} · ${n_not_admitted} not admitted"
  headline="${headline} · ${n_applied} applied"
  # Destroyed and not-reported appear only when non-zero, like today's
  # destroyed counter: permanent zeros would be noise on almost every run.
  [ "${n_destroyed}" -gt 0 ] && headline="${headline} · ${n_destroyed} destroyed"
  [ "${n_held}" -gt 0 ] && headline="${headline} · ${n_held} held back"
  headline="${headline} · ${n_failed} failed"
  [ "${n_missing}" -gt 0 ] && headline="${headline} · ${n_missing} not reported"

  printf '## Terraform run summary\n\n'
  printf '**%s**\n\n' "${headline}"
  # A refused Dependabot pull request skips every environment, so the
  # nothing-to-verify line would claim the change touches none, which nobody
  # judged. It says why nothing ran instead, and the admission section comes
  # before the environments it explains (docs/Dependabot-admission.md §7).
  if admission_refused "${file}"; then
    printf '_Nothing ran: the Dependabot admission refused this pull request._\n\n'
    render_admission_section "${file}"
  # A dispatch or a schedule carries no change; its trigger line says why nothing ran.
  elif [ "${n_affected}" -eq 0 ] && [ "${event}" != 'workflow_dispatch' ] && [ "${event}" != 'schedule' ]; then
    printf '_Nothing needed verifying: no environment is affected by this change._\n\n'
  fi
  # In mode diff the reason is always 'diff' and the count is what matters; in
  # mode all the count explains nothing and the fail-open reason everything.
  if [ "${mode}" = 'diff' ]; then
    local file_word="changed files"; [ "${changed}" = '1' ] && file_word="changed file"
    printf 'Relevance: `diff`, %s %s\n\n' "${changed}" "${file_word}"
  else
    printf 'Relevance: `%s` (%s)\n\n' "${mode}" "${reason}"
  fi
  local line
  while IFS= read -r line; do
    printf '> %s\n\n' "${line}"
  done <"${lines_file}"
  rm -f "${lines_file}"
  printf '| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |\n'
  printf '|---|:---:|---|---|---|---|---|\n'
  cat "${rows_file}"
  rm -f "${rows_file}"
  render_ordering_line "${file}"
  print_footer
  print_scheduled_plan_lines
  # A tooltip does not show on a phone, where this page is often read.
  if [ "${n_not_admitted}" -gt 0 ]; then
    printf '\n_Rows of 🚫: the Dependabot admission refused this pull request, so nothing ran._\n'
  fi
  if [ "${n_unaffected}" -gt 0 ] && { [ "${event}" = 'workflow_dispatch' ] || [ "${event}" = 'schedule' ]; }; then
    printf '\n_Rows of `—`: not part of this run, so not planned._\n'
  elif [ "${n_unaffected}" -gt 0 ]; then
    printf '\n_Rows of `—`: not affected by this change, so not planned._\n'
  fi
}

# The ordering footer (docs/Environment-ordering.md §7.2): one line below the
# table naming what ordering did to this run. Uses render_with_relevance's
# held_*, row_names and env_stage and render_summary's *_by_env maps (bash
# dynamic scope).
#
# With more than one stage it opens with the computed stages, so the effective
# ordering is read, not derived from the configuration (D1, §4.4): a stage
# waits for every environment of the one before, which the declarations do not
# show. Then three sentences: the stages a failure held back, with the
# environments in them; a tolerated failure that released a later stage (D5,
# P10); and a declared dependency left out of the run, for an environment
# granted apply or destroy. The last is the only warning an operator gets that
# a dependency was not verified first (§8), and relevance leaving the
# dependency out is exactly what collapses a run to one stage, so it is not
# dropped with the stages. At one stage, without that sentence, there is no line.
function render_ordering_line {
  local file="${1}"
  [ -z "${STAGE_RESULTS_FILE:-}" ] && return 0
  local -a sentences=()
  declare -A result_of=()
  local s used name
  for s in 1 2 3; do
    result_of[${s}]=$(jq -r --arg s "${s}" '.[$s] // ""' "${STAGE_RESULTS_FILE}")
  done
  used=$(jq -r '(.ordering.stages_used // 1) | tonumber? // 1' "${file}" 2>/dev/null || echo 1)

  # The computed stages, each environment by its row's label in row order. A
  # stage with no environment is left out: it holds nothing and waits for nothing.
  local -a members=()
  if [ "${used}" -gt 1 ]; then
    for s in 1 2 3; do
      members=()
      for name in "${row_names[@]}"; do
        [ "${env_stage[${name}]:-}" = "${s}" ] && members+=("${name}")
      done
      [ ${#members[@]} -gt 0 ] && sentences+=("Stage ${s}: $(backtick_join "${members[@]}").")
    done
  fi

  # Held back. One sentence per failed stage; in practice there is one, since a
  # failure holds back every later stage and so no later one can fail.
  if [ ${#held_names[@]} -gt 0 ]; then
    declare -A stages_by_cause=()
    local key
    for name in "${held_names[@]}"; do
      key="${held_cause[${name}]}|${held_result[${name}]}"
      [[ " ${stages_by_cause[${key}]:-} " == *" ${held_stage[${name}]} "* ]] ||
        stages_by_cause["${key}"]+="${stages_by_cause[${key}]:+ }${held_stage[${name}]}"
    done
    local cause result phrase
    local -a stages=()
    while IFS= read -r key; do
      cause="${key%%|*}"; result="${key#*|}"
      read -r -a stages <<<"$(tr ' ' '\n' <<<"${stages_by_cause[${key}]}" | sort -n | tr '\n' ' ')"
      phrase=$(stage_list "${stages[@]}")
      if [ -n "${cause}" ]; then
        phrase="$(stage_outcome_phrase "${cause}" "${result}"), so ${phrase} did not run."
      else
        phrase="${phrase} did not run."
      fi
      sentences+=("${phrase^}")
    done < <(printf '%s\n' "${!stages_by_cause[@]}" | sort -t'|' -k1,1n)
    sentences+=("Held back: $(backtick_join "${held_names[@]}").")
  fi

  # Released by a tolerated failure: the job was green, so the next stage that
  # ran, ran after it. A stage that did not run was released by nothing, and an
  # empty one is always skipped, so the result alone decides.
  local t released verb
  local -a tolerated=()
  for s in 1 2; do
    tolerated=()
    for name in "${row_names[@]}"; do
      [ "${env_stage[${name}]:-}" = "${s}" ] && [ "${tolerated_by_env[${name}]:-}" = 'true' ] && tolerated+=("${name}")
    done
    [ ${#tolerated[@]} -eq 0 ] && continue
    released=""
    for ((t = s + 1; t <= 3; t++)); do
      if [[ "${result_of[${t}]}" =~ ^(success|failure|cancelled)$ ]]; then
        released="${t}"
        break
      fi
    done
    [ -z "${released}" ] && continue
    verb="allows"; [ ${#tolerated[@]} -gt 1 ] && verb="allow"
    sentences+=("Stage ${s} released stage ${released}; $(backtick_join "${tolerated[@]}") failed but ${verb} failing operations.")
  done

  # A declared dependency not in the run. A held-back environment did nothing,
  # so there is nothing to warn about.
  local me dep why did
  while IFS=$'\x1f' read -r me dep why; do
    [ -z "${me}" ] && continue
    [ -n "${held_stage[${me}]:-}" ] && [ -z "${row_by_env[${me}]:-}" ] && continue
    did="ran"
    if [ "${applied_by_env[${me}]:-}" = 'true' ]; then did="applied"
    elif [ "${destroyed_by_env[${me}]:-}" = 'true' ]; then did="destroyed"; fi
    sentences+=("\`${me}\` ${did}; its dependency \`${dep}\` was not in this run (${why}).")
  done < <(missing_dependencies "${file}")

  [ ${#sentences[@]} -eq 0 ] && return 0
  local stage_word="stages"; [ "${used}" = '1' ] && stage_word="stage"
  local line="" sentence
  for sentence in "${sentences[@]}"; do line+="${line:+ }${sentence}"; done
  printf '\n_Ordering: %s %s. %s_\n' "${used}" "${stage_word}" "${line}"
}

# Adds one rendered metadata row's outcome to render_with_relevance's counters.
function count_env {
  local env="${1}"
  [ "${worst_by_env[${env}]:-}" = 'failure' ] && n_failed=$((n_failed + 1))
  [ "${applied_by_env[${env}]:-}" = 'true' ] && n_applied=$((n_applied + 1))
  [ "${destroyed_by_env[${env}]:-}" = 'true' ] && n_destroyed=$((n_destroyed + 1))
  return 0
}

# One value of the module results file (toJSON(needs)): a job's 'result', or one of its outputs; empty
# when the job or the value is absent, or the file unreadable.
#   $1 the results file, $2 the job, $3 'result' or an output name
function needs_value {
  if [ "${3}" = "result" ]; then
    jq -r --arg j "${2}" '(.[$j].result // "") | tostring' "${1}" 2>/dev/null || true
  else
    jq -r --arg j "${2}" --arg k "${3}" '(.[$j].outputs[$k] // "") | tostring' "${1}" 2>/dev/null || true
  fi
}

# A step's or a job's outcome as a cell.
function outcome_cell {
  case "${1}" in
    success) printf '✅ success' ;;
    failure) printf '❌ failure' ;;
    cancelled) printf '🚫 cancelled' ;;
    skipped) printf '⏭️ skipped' ;;
    '') printf '—' ;;
    *) printf '%s' "${1}" ;;
  esac
}

# The relevance file of a module run when it can be used, else empty.
function usable_module_relevance_file {
  local file="${1}"
  [ -z "${file}" ] && return 0
  if [ ! -f "${file}" ] || ! jq -e '.mode == "module"' "${file}" >/dev/null 2>&1; then
    log-warn "no module decision at '${file}'; rendering without relevance, admission and auto-merge" 1>&2
    return 0
  fi
  printf '%s' "${file}"
}

# The module run's one block (docs/Module-ci.md §7.1). Values come from files through jq, never from
# exported shell variables.
#   $1 the module results file, $2 the usable relevance file or empty
function render_module_summary {
  local results="${1}" relevance="${2}"
  # The headline is the conclusion: its verdict and why, without the "conclusion: <verdict> — " the
  # headline already says and the test count the tests row says.
  local conclusion line why
  conclusion=$(needs_value "${results}" conclusion result)
  line=$(needs_value "${results}" conclusion line)
  why="${line#conclusion: * — }"
  why="${why%; tests: *}"
  [ "${why}" = "${line}" ] && why=""
  case "${conclusion}" in
    success) printf '### ✅ Module CI: green%s\n\n' "${why:+ — ${why}}" ;;
    failure) printf '### ❌ Module CI: red%s\n\n' "${why:+ — ${why}}" ; FAILED_COUNT=1 ;;
    *) printf '### ❔ Module CI: the conclusion did not run (%s)\n\n' "${conclusion:-unknown}" ;;
  esac

  local relevance_line="" merge_line=""
  if [ -n "${relevance}" ]; then
    relevance_line=$(jq -r '[(.notices // [])[] | select(type == "string" and startswith("relevance "))][0] // ""' \
      "${relevance}" 2>/dev/null || true)
    merge_line=$(jq -r '[(.notices // [])[] | select(type == "string" and startswith("auto-merge: "))][0] // ""' \
      "${relevance}" 2>/dev/null || true)
  fi
  [ -n "${relevance_line}" ] && printf '_%s_\n\n' "${relevance_line}"

  local docs_status docs_cell
  docs_status=$(needs_value "${results}" generate-docs status)
  case "${docs_status}" in
    up-to-date) docs_cell='✅ up to date' ;;
    pushed) docs_cell='✅ regenerated and pushed; the run it started decides' ;;
    needs-regeneration) docs_cell='❌ the README needs regenerating' ;;
    failed) docs_cell='❌ failed' ;;
    *) docs_cell=$(outcome_cell "$(needs_value "${results}" generate-docs result)") ;;
  esac

  local affected validate_result
  affected=$(needs_value "${results}" create-matrix affected-count)
  validate_result=$(needs_value "${results}" validate result)
  printf '| Step | Result |\n|---|---|\n'
  printf '| 📝 Docs | %s |\n' "${docs_cell}"
  if [ "${validate_result}" = "skipped" ]; then
    local why='skipped'
    if [ "${docs_status}" = "pushed" ]; then
      why='skipped: the run the docs commit started validates'
    elif [ "${affected}" = "0" ]; then
      why='skipped: the module is not affected by this change'
    fi
    printf '| ✔ Validation | ⏭️ %s |\n' "${why}"
  else
    # One row: what failed, or that every step passed; the validate job's own summary has each step.
    local step outcome failed=() passed=0 cell warnings
    for step in init:Init fmt:Format validate:Validate lint:TFLint; do
      outcome=$(needs_value "${results}" validate "${step%%:*}")
      case "${outcome}" in
        success) passed=$((passed + 1)) ;;
        failure | cancelled) failed+=("${step#*:}") ;;
      esac
    done
    if [ "${#failed[@]}" -gt 0 ]; then
      cell="❌ $(IFS=,; printf '%s' "${failed[*]}" | sed 's/,/, /g') failed"
    elif [ "${passed}" -eq 4 ]; then
      cell='✅ init, fmt, validate and lint passed'
    else
      cell=$(outcome_cell "${validate_result}")
    fi
    warnings=$(needs_value "${results}" validate warning-count)
    [[ "${warnings}" =~ ^[1-9][0-9]*$ ]] && cell+=" · ⚠️ ${warnings} warnings"
    printf '| ✔ Validation | %s |\n' "${cell}"
  fi

  local tests_result tests_cell
  tests_result=$(needs_value "${results}" terraform-test-summary result)
  # Not affected, every file was held back, which the summary job counts as not run; say why instead.
  if [ "${affected}" = "0" ]; then
    tests_cell='⏭️ held back: the module is not affected by this change'
  elif [ "${tests_result}" = "success" ]; then
    local parts=() count name
    for name in passed failed tolerated not-run; do
      count=$(needs_value "${results}" terraform-test-summary "${name}-count")
      [[ "${count}" =~ ^[1-9][0-9]*$ ]] || continue
      case "${name}" in
        passed) parts+=("✅ ${count} passed") ;;
        failed) parts+=("❌ ${count} failed") ;;
        tolerated) parts+=("⚠️ ${count} tolerated") ;;
        not-run) parts+=("${count} not run") ;;
      esac
    done
    tests_cell="no test files"
    if [ "${#parts[@]}" -gt 0 ]; then
      tests_cell=$(IFS='|'; printf '%s' "${parts[*]}")
      tests_cell="${tests_cell//|/ · }"
    fi
  else
    tests_cell=$(outcome_cell "${tests_result}")
  fi
  printf '| 🧪 Tests | %s |\n' "${tests_cell}"

  if [ -n "${merge_line}" ]; then
    local merge_result
    merge_result=$(needs_value "${results}" automerge result)
    case "${merge_result}" in
      success) merge_line+=" — merged ✅" ;;
      failure) merge_line+=" — the merge did not go through; see the PR auto merger job ❌" ;;
    esac
    printf '\n**%s**\n' "${merge_line}"
  fi

  if [ -n "${relevance}" ] && admission_refused "${relevance}"; then
    printf '\n'
    render_admission_section "${relevance}"
  fi
}

function main {
  if [ "${input_mode:-project}" = "module" ]; then
    log-info "rendering the module run summary ..."
    ENVIRONMENT_COUNT=0
    FAILED_COUNT=0
    local results_file module_body relevance
    results_file=$(mktemp)
    printf '%s' "${input_module_results_json:-}" >"${results_file}"
    jq -e 'type == "object"' "${results_file}" >/dev/null 2>&1 || printf '{}' >"${results_file}"
    relevance=$(usable_module_relevance_file "${input_relevance_file:-}")
    module_body="${RUNNER_TEMP:-/tmp}/run-summary-$$.md"
    # Redirection, not $(...): the renderer sets FAILED_COUNT.
    render_module_summary "${results_file}" "${relevance}" >"${module_body}"
    log-multiline "run summary" "$(cat "${module_body}")"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { cat "${module_body}"; printf '\n'; } >>"${GITHUB_STEP_SUMMARY}"
      log-info "appended to the job summary"
    else
      log-warn "GITHUB_STEP_SUMMARY is not set; rendered to the log only"
    fi
    rm -f "${results_file}" "${module_body}"
    set-output 'environment-count' "${ENVIRONMENT_COUNT}"
    set-output 'failed-count' "${FAILED_COUNT}"
    log-info "create-run-summary completed (module mode)."
    return 0
  fi
  log-info "rendering run summary from '${input_metadata_files_pattern:-matrix-job-meta-*.json}' ..."

  ENVIRONMENT_COUNT=0
  FAILED_COUNT=0
  read_stage_results
  # Redirection, not $(...): a command substitution would run the renderer
  # in a subshell and lose the counts it sets.
  local body_file="${RUNNER_TEMP:-/tmp}/run-summary-$$.md"
  render_summary >"${body_file}"
  local body
  body=$(cat "${body_file}")
  rm -f "${body_file}"
  [ -n "${STAGE_RESULTS_FILE}" ] && rm -f "${STAGE_RESULTS_FILE}"

  log-multiline "run summary" "${body}"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n\n' "${body}" >>"${GITHUB_STEP_SUMMARY}"
    log-info "appended to the job summary"
  else
    log-warn "GITHUB_STEP_SUMMARY is not set; rendered to the log only"
  fi

  set-output 'environment-count' "${ENVIRONMENT_COUNT}"
  set-output 'failed-count' "${FAILED_COUNT}"
  log-info "create-run-summary completed (${ENVIRONMENT_COUNT} env(s), ${FAILED_COUNT} failed)."
  return 0
}

main
_main_exit_code=$?
# Always 0: see file header.
exit 0
