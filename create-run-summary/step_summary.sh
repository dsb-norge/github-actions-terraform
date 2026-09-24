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
#                          without it (docs/Path-relevance.md §6.5, P8)
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
}

function print_footer {
  printf '\n_Plan / Apply / Destroy: `💫` added `🛠️` changed `💥` destroyed; apply and destroy cells are applied/planned, `?` when the operation did not complete. Time is the sum of the env'"'"'s terraform invocations._\n'
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
  local n_env=0 n_affected=0 n_unaffected=0 n_missing=0 n_applied=0 n_destroyed=0 n_failed=0
  local rows_file
  rows_file=$(mktemp)
  declare -A listed=()

  local verdict genv
  # Metadata is keyed by github-environment (the workflow passes it as the
  # capture's environment name), so rows are matched and labelled by it,
  # exactly as today's rows are.
  # Unit separator, not tab: tab is IFS whitespace, so `read` would collapse an
  # empty verdict field and shift the name into it.
  while IFS=$'\x1f' read -r verdict genv; do
    if [ -z "${genv}" ]; then
      log-warn "skipping a relevance entry without github-environment" 1>&2
      continue
    fi
    listed["${genv}"]="true"
    n_env=$((n_env + 1))
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
    else
      # The matrix job was cancelled or crashed before its metadata upload.
      # Not counted as failed — nothing says it failed — but never absent:
      # a missing row would read as "nothing to see".
      n_missing=$((n_missing + 1))
      printf '| `%s` | <span title="affected, but its job left no metadata: cancelled, crashed or not uploaded">❔</span> | — | — | — | — | [run](%s) |\n' \
        "${genv}" "${run_url}" >>"${rows_file}"
    fi
  done < <(jq -r '.environments[] | [(.verdict // "" | tostring), (.["github-environment"] // .environment // "" | tostring)] | join("\u001f")' "${file}" 2>/dev/null)

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

  local mode reason changed
  mode=$(jq -r '.relevance.mode // "" | tostring' "${file}")
  reason=$(jq -r '.relevance.reason // "" | tostring' "${file}")
  changed=$(jq -r '.relevance.changed_count // 0 | tostring' "${file}")

  local env_word="environments"; [ "${n_env}" -eq 1 ] && env_word="environment"
  local headline
  headline="${n_env} ${env_word} · ${n_affected} affected · ${n_unaffected} not affected · ${n_applied} applied"
  # Destroyed and not-reported appear only when non-zero, like today's
  # destroyed counter: permanent zeros would be noise on almost every run.
  [ "${n_destroyed}" -gt 0 ] && headline="${headline} · ${n_destroyed} destroyed"
  headline="${headline} · ${n_failed} failed"
  [ "${n_missing}" -gt 0 ] && headline="${headline} · ${n_missing} not reported"

  printf '## Terraform run summary\n\n'
  printf '**%s**\n\n' "${headline}"
  if [ "${n_affected}" -eq 0 ]; then
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
  printf '| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |\n'
  printf '|---|:---:|---|---|---|---|---|\n'
  cat "${rows_file}"
  rm -f "${rows_file}"
  print_footer
  # A tooltip does not show on a phone, where this page is often read.
  if [ "${n_unaffected}" -gt 0 ]; then
    printf '\n_Rows of `—`: not affected by this change, so not planned._\n'
  fi
}

# Adds one rendered metadata row's outcome to render_with_relevance's counters.
function count_env {
  local env="${1}"
  [ "${worst_by_env[${env}]:-}" = 'failure' ] && n_failed=$((n_failed + 1))
  [ "${applied_by_env[${env}]:-}" = 'true' ] && n_applied=$((n_applied + 1))
  [ "${destroyed_by_env[${env}]:-}" = 'true' ] && n_destroyed=$((n_destroyed + 1))
  return 0
}

function main {
  log-info "rendering run summary from '${input_metadata_files_pattern:-matrix-job-meta-*.json}' ..."

  ENVIRONMENT_COUNT=0
  FAILED_COUNT=0
  # Redirection, not $(...): a command substitution would run the renderer
  # in a subshell and lose the counts it sets.
  local body_file="${RUNNER_TEMP:-/tmp}/run-summary-$$.md"
  render_summary >"${body_file}"
  local body
  body=$(cat "${body_file}")
  rm -f "${body_file}"

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
