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
    # "applied" means the apply step succeeded AND terraform printed its
    # summary line — a step outcome alone is not enough under
    # allow-failing-terraform-operations.
    if [ "$(meta_step_outcome "${file}" apply)" = 'success' ] && [ "$(meta_step_output "${file}" parse-apply completed)" = 'true' ]; then
      applied_by_env["${env}"]="true"
    fi

    local time_cell
    time_cell=$(sum_durations \
      "$(meta_step_output "${file}" plan plan-time)" \
      "$(meta_step_output "${file}" apply apply-time)" \
      "$(meta_step_output "${file}" destroy-plan plan-time)" \
      "$(meta_step_output "${file}" destroy apply-time)")

    row_by_env["${env}"]="| \`${env}\` | ${worst_emoji} | $(plan_cell "${file}") | $(apply_cell "${file}") | $(destroy_cell "${file}") | ${time_cell} | [run](${run_url}) |"
  done

  local n_env=${#row_by_env[@]} n_applied=0 n_failed=0
  for env in "${!row_by_env[@]}"; do
    [ "${worst_by_env[${env}]}" = 'failure' ] && n_failed=$((n_failed + 1))
    [ "${applied_by_env[${env}]:-}" = 'true' ] && n_applied=$((n_applied + 1))
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
  printf '**%d %s · %d applied · %d failed**\n\n' "${n_env}" "${env_word}" "${n_applied}" "${n_failed}"
  printf '| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |\n'
  printf '|---|:---:|---|---|---|---|---|\n'
  while IFS= read -r env; do
    [ -z "${env}" ] && continue
    printf '%s\n' "${row_by_env[${env}]}"
  done < <(printf '%s\n' "${!row_by_env[@]}" | sort)
  printf '\n_Plan / Apply / Destroy: `💫` added `🛠️` changed `💥` destroyed; apply and destroy cells are applied/planned, `?` when the operation did not complete. Time is the sum of the env'"'"'s terraform invocations._\n'
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
