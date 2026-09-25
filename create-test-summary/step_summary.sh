#!/bin/env bash
#
# Source for the summary step.
#
# Renders the Terraform tests summary (docs/Terraform-tests.md §6): one body
# for the pull-request head comment and the same body, without the workflow
# link, for the run's step summary. Rows come from the matrix, the per-job
# metadata files (terraform-test-meta-*.json) and the not-run list; job
# links, job conclusions and times from the Jobs API.
#
# Required environment variables: none; every input degrades on its own.
#
# Optional environment variables:
#   input_metadata_files_pattern - Glob of the downloaded metadata files
#                                  (default terraform-test-meta-*.json)
#   input_tests_matrix_json      - Shell-local, NOT exported: the shim's
#                                  capture of toJSON(inputs.tests-matrix-json)
#   input_not_run_file           - relevance.json, or a JSON array of
#                                  {file, lane, reason}
#   input_jobs_json_file         - The run's jobs; when empty the Jobs API is
#                                  called with GH_TOKEN
#   input_run_url                - Footer link; default the run's URL
#   input_output_file_suffix     - Distinguishes the output files of two
#                                  invocations in one job
#   GH_TOKEN                     - For the Jobs API
#
# Standard GitHub environment variables used:
#   GITHUB_STEP_SUMMARY - the body (without the footer) is appended to it
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_ACTOR,
#   GITHUB_WORKFLOW, RUNNER_TEMP
#
# Exit code: always 0. A reporting job must never redden a run (§6.1).
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# '<!-- tf:head:tests:<caller> -->': the calling workflow's name reduced to
# [A-Za-z0-9_-], scoped per caller so two workflows on one pull request do
# not fight over one head (§6.3, P19).
function head_marker {
  local caller="${GITHUB_WORKFLOW:-}"
  caller="${caller//[^A-Za-z0-9_-]/}"
  printf '<!-- tf:head:tests:%s -->' "${caller}"
}

function main {
  local suffix="${input_output_file_suffix:-}"
  suffix="${suffix//[^A-Za-z0-9._-]/}"
  local work_dir="${RUNNER_TEMP:-/tmp}/create-test-summary${suffix:+-${suffix}}"
  rm -rf "${work_dir}"
  mkdir -p "${work_dir}"

  local body_file="${work_dir}/body.md"
  local step_summary_file="${work_dir}/step-summary.md"

  start-group "Inputs"
  local matrix_file="${work_dir}/matrix.json"
  write_matrix_file "${matrix_file}"
  # The capture is read; nothing below needs it, and a large matrix must not
  # linger in a variable a later assignment could export.
  unset input_tests_matrix_json
  log-info "matrix rows: $(jq 'length' "${matrix_file}")"

  local not_run_file="${work_dir}/not-run.json"
  write_not_run_file "${not_run_file}"
  log-info "not-run entries: $(jq 'length' "${not_run_file}")"

  shopt -s nullglob
  local files=(${input_metadata_files_pattern:-terraform-test-meta-*.json})
  shopt -u nullglob
  local meta_file="${work_dir}/meta.json"
  collect_metadata "${meta_file}" "${files[@]}"
  log-info "metadata files: ${#files[@]} found, $(jq 'length' "${meta_file}") usable"

  local jobs_file="${work_dir}/jobs.json" links_ok="true"
  if ! resolve_jobs_file "${jobs_file}"; then
    links_ok="false"
    jobs_file=""
  fi
  end-group

  start-group "Rows"
  local rows_file="${work_dir}/rows.json"
  if ! build_rows "${matrix_file}" "${meta_file}" "${jobs_file}" "${rows_file}"; then
    log-warn "the rows could not be built; rendering from nothing"
    printf '{"nsets":1,"rows":[],"wall":null}' >"${rows_file}"
  fi
  local slug
  while IFS= read -r slug; do
    [ -n "${slug}" ] && log-warn "metadata for '${slug}', which is not in the matrix; rendered anyway"
  done < <(jq -r '.rows[] | select(.orphan) | .slug' "${rows_file}")
  while IFS= read -r slug; do
    [ -n "${slug}" ] && log-warn "no metadata for '${slug}'; rendered from its job's conclusion"
  done < <(jq -r '.rows[] | select(.nometa) | .slug' "${rows_file}")
  end-group

  # The budget order of §6.4: render, measure, and apply the next trim step
  # until the body fits. Level 4 is the guard past the spec's steps.
  start-group "Body"
  local level chars
  for level in 0 1 2 3 4; do
    render_body "${rows_file}" "${not_run_file}" "${level}" "${links_ok}" true "${body_file}"
    chars=$(jq -Rs 'length' "${body_file}")
    if [ "${chars}" -le "${BODY_BUDGET_CHARS}" ]; then
      break
    fi
    log-info "body is ${chars} characters at trim level ${level}; trimming further"
  done
  log-info "body: ${chars} characters at trim level ${level}"
  render_body "${rows_file}" "${not_run_file}" "${level}" "${links_ok}" false "${step_summary_file}"
  end-group

  local failed tolerated passed not_run
  failed=$(jq '[.rows[] | select(.category == "failed")] | length' "${rows_file}")
  tolerated=$(jq '[.rows[] | select(.category == "tolerated")] | length' "${rows_file}")
  passed=$(jq '[.rows[] | select(.category == "passed")] | length' "${rows_file}")
  not_run=$(jq 'length' "${not_run_file}")

  log-multiline "Terraform tests summary" "$(cat "${body_file}")"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { cat "${step_summary_file}"; printf '\n'; } >>"${GITHUB_STEP_SUMMARY}"
    log-info "appended to the job summary"
  else
    log-warn "GITHUB_STEP_SUMMARY is not set; rendered to the log only"
  fi

  # One headline annotation so the checks pane says something without
  # opening a job (§6.6).
  local parts=()
  [ "${failed}" -gt 0 ] && parts+=("${failed} failed")
  [ "${tolerated}" -gt 0 ] && parts+=("${tolerated} tolerated")
  [ "${passed}" -gt 0 ] && parts+=("${passed} passed")
  [ "${not_run}" -gt 0 ] && parts+=("${not_run} not run")
  local message="no test files"
  if [ "${#parts[@]}" -gt 0 ]; then
    message=$(IFS=','; printf '%s' "${parts[*]}")
    message="${message//,/, }"
  fi
  if [ "${failed}" -gt 0 ]; then
    echo "::error title=Terraform tests::${message}"
  elif [ "${tolerated}" -gt 0 ]; then
    echo "::warning title=Terraform tests::${message}"
  else
    echo "::notice title=Terraform tests::${message}"
  fi

  set-output 'body-file' "${body_file}"
  set-output 'step-summary-file' "${step_summary_file}"
  set-output 'failed-count' "${failed}"
  set-output 'tolerated-count' "${tolerated}"
  set-output 'passed-count' "${passed}"
  set-output 'not-run-count' "${not_run}"
  set-output 'head-marker' "$(head_marker)"
  log-info "create-test-summary completed (${failed} failed, ${tolerated} tolerated, ${passed} passed, ${not_run} not run)."
  return 0
}

main
_main_exit_code=$?
# Always 0: see file header.
exit 0
