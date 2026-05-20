#!/bin/env bash
#
# Aggregator script for the action-tests workflow.
#
# Reads per-action result-*.json files (produced by the test matrix), combines
# them with the no-tests-list (from discover-actions.sh), builds a single
# markdown summary, and upserts a PR comment via the GitHub API.
#
# See docs/Testing-in-ci.md §5 (result.json shape) and §6 (comment shape +
# upsert mechanics) for the contract this implements.
#
# Required environment:
#   RESULTS_DIR         - directory containing result-*.json files
#   NO_TESTS_LIST       - JSON array of action names without tests
#   PR_NUMBER           - pull request number
#   GITHUB_REPOSITORY   - "<owner>/<repo>"
#   GITHUB_SERVER_URL   - e.g. "https://github.com"
#   GITHUB_RUN_ID       - the workflow run id (for footer link)
#   GITHUB_SHA          - the PR head sha (for footer)
#   GH_TOKEN            - token with pull-requests: write (used by `gh`)
#
# Optional environment:
#   GITHUB_STEP_SUMMARY - when set (always set in GitHub Actions), the body
#                         is also appended here so the run page renders the
#                         same table without anyone having to open a comment.
#   DRY_RUN=true        - skip the PR comment upsert (step summary + notice
#                         annotation still happen). Useful for local testing.
#

set -o nounset
set -o pipefail
set -o errexit

declare -gr COMMENT_MARKER='<!-- action-tests-summary -->'

function status_icon {
  case "${1}" in
    success)   echo '✅' ;;
    failure)   echo '❌' ;;
    cancelled) echo '⚠️' ;;
    skipped)   echo '⏭️' ;;
    *)         echo '❓' ;;
  esac
}

function status_label {
  case "${1}" in
    success)   echo 'Pass' ;;
    failure)   echo 'Fail' ;;
    cancelled) echo 'Cancelled' ;;
    skipped)   echo 'Skipped' ;;
    *)         echo "${1}" ;;
  esac
}

# Render the "Tests" column: "N / N" or "?" when counts are null.
function tests_cell {
  local passed="${1}" run="${2}"
  if [[ "${passed}" == "null" || "${run}" == "null" ]]; then
    echo '?'
  else
    echo "${passed} / ${run}"
  fi
}

# Build the markdown body and print to stdout.
function build_body {
  local results_json="${1}" no_tests_json="${2}"

  local total_suites total_run total_passed total_failed bad_outcomes
  total_suites="$(echo "${results_json}" | jq 'length')"
  total_run="$(echo "${results_json}"    | jq '[.[]."tests-run"    | select(. != null)] | add // 0')"
  total_passed="$(echo "${results_json}" | jq '[.[]."tests-passed" | select(. != null)] | add // 0')"
  total_failed="$(echo "${results_json}" | jq '[.[]."tests-failed" | select(. != null)] | add // 0')"
  bad_outcomes="$(echo "${results_json}" | jq '[.[] | select(.outcome != "success")] | length')"

  local tested_count not_tested_count
  tested_count="${total_suites}"
  not_tested_count="$(echo "${no_tests_json}" | jq 'length')"

  printf '%s\n' "${COMMENT_MARKER}"
  printf '### 🧪 Action test results\n\n'
  if [[ "${bad_outcomes}" -gt 0 ]]; then
    printf '**Total: %s tests across %s suites — %s passed, %s failed, %s suite(s) not passing**\n\n' \
      "${total_run}" "${total_suites}" "${total_passed}" "${total_failed}" "${bad_outcomes}"
  else
    printf '**Total: %s tests across %s suites — %s passed, %s failed**\n\n' \
      "${total_run}" "${total_suites}" "${total_passed}" "${total_failed}"
  fi

  printf '**Tested (%s)**\n\n' "${tested_count}"
  if [[ "${tested_count}" -eq 0 ]]; then
    printf '_No suites ran._\n\n'
  else
    printf '| Action | Result | Tests | Details |\n'
    printf '|---|:---:|:---:|---|\n'
    # Sort alphabetically by action name.
    while IFS= read -r row; do
      local action outcome run passed job_url
      action="$(  echo "${row}" | jq -r '.action')"
      outcome="$( echo "${row}" | jq -r '.outcome')"
      run="$(     echo "${row}" | jq -r '."tests-run"')"
      passed="$(  echo "${row}" | jq -r '."tests-passed"')"
      job_url="$( echo "${row}" | jq -r '."job-url" // empty')"

      local icon label cell details
      icon="$(status_icon "${outcome}")"
      label="$(status_label "${outcome}")"
      cell="$(tests_cell "${passed}" "${run}")"
      if [[ -n "${job_url}" ]]; then
        details="[job log](${job_url})"
      else
        details="—"
      fi

      printf '| %s | %s %s | %s | %s |\n' \
        "${action}" "${icon}" "${label}" "${cell}" "${details}"
    done < <(echo "${results_json}" | jq -c 'sort_by(.action) | .[]')
    printf '\n'
  fi

  printf '**Not tested yet (%s)** — modernization candidates\n\n' "${not_tested_count}"
  if [[ "${not_tested_count}" -eq 0 ]]; then
    printf '_Empty — every action has a test suite._\n\n'
  else
    printf '<details><summary>Show list</summary>\n\n'
    echo "${no_tests_json}" | jq -r '.[] | "- " + .'
    printf '\n</details>\n\n'
  fi

  printf '_Run: [workflow run](%s/%s/actions/runs/%s) · Commit: `%s`_\n' \
    "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}" "${GITHUB_SHA:0:7}"
}

# Load and combine result-*.json files into a single JSON array.
function load_results {
  local dir="${1}"
  if ! compgen -G "${dir}/result-*.json" > /dev/null; then
    echo '[]'
    return 0
  fi
  jq -s '.' "${dir}"/result-*.json
}

# List existing comments with our marker. Returns JSON array of {id, created_at}.
function list_marker_comments {
  gh api --paginate "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
    | jq --arg marker "${COMMENT_MARKER}" \
        '[.[] | select(.body | startswith($marker)) | {id, created_at}]'
}

# Upsert the body via gh api.
function upsert_comment {
  local body_file="${1}"

  local matches count
  matches="$(list_marker_comments)"
  count="$(echo "${matches}" | jq 'length')"

  if [[ "${count}" -eq 0 ]]; then
    echo "No existing comment found — posting fresh." >&2
    gh api -X POST "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
      -F "body=@${body_file}" >/dev/null
    return 0
  fi

  # When multiple matches exist (defensive — shouldn't happen), keep the oldest
  # and delete the rest, then edit the oldest in place.
  local keep_id
  keep_id="$(echo "${matches}" | jq -r 'sort_by(.created_at) | .[0].id')"

  if [[ "${count}" -gt 1 ]]; then
    echo "Found ${count} marker comments — keeping oldest (id=${keep_id}), deleting the rest." >&2
    echo "${matches}" \
      | jq -r --arg keep "${keep_id}" 'sort_by(.created_at) | .[1:][] | .id' \
      | while IFS= read -r del_id; do
          gh api -X DELETE "/repos/${GITHUB_REPOSITORY}/issues/comments/${del_id}" || true
        done
  fi

  echo "Editing existing comment in place (id=${keep_id})." >&2
  gh api -X PATCH "/repos/${GITHUB_REPOSITORY}/issues/comments/${keep_id}" \
    -F "body=@${body_file}" >/dev/null
}

# Emit a single ::notice or ::error annotation summarizing the run, so the
# GitHub run-page annotations panel shows the headline even on green runs.
#
# A run is "red" if any suite has tests-failed > 0 OR any suite's outcome
# is anything other than "success" (covers format-drift, crashes, cancels
# — cases where counts are null but the suite did not pass).
function emit_headline_annotation {
  local results_json="${1}"
  local total_suites total_run total_passed total_failed bad_outcomes
  total_suites="$(echo "${results_json}" | jq 'length')"
  total_run="$(echo "${results_json}"    | jq '[.[]."tests-run"    | select(. != null)] | add // 0')"
  total_passed="$(echo "${results_json}" | jq '[.[]."tests-passed" | select(. != null)] | add // 0')"
  total_failed="$(echo "${results_json}" | jq '[.[]."tests-failed" | select(. != null)] | add // 0')"
  bad_outcomes="$(echo "${results_json}" | jq '[.[] | select(.outcome != "success")] | length')"

  local level title message
  if [[ "${total_failed}" -gt 0 || "${bad_outcomes}" -gt 0 ]]; then
    level=error
    title='Action tests: failures'
    message="${total_run} tests across ${total_suites} suites — ${total_passed} passed, ${total_failed} failed, ${bad_outcomes} suite(s) not passing"
  else
    level=notice
    title='Action tests: all green'
    message="${total_run} tests across ${total_suites} suites — ${total_passed} passed, ${total_failed} failed"
  fi
  echo "::${level} title=${title}::${message}"
}

function main {
  : "${RESULTS_DIR:?RESULTS_DIR is required}"
  : "${NO_TESTS_LIST:?NO_TESTS_LIST is required}"
  : "${PR_NUMBER:?PR_NUMBER is required}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  : "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL is required}"
  : "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
  : "${GITHUB_SHA:?GITHUB_SHA is required}"

  local results_json
  results_json="$(load_results "${RESULTS_DIR}")"

  local body_file
  body_file="$(mktemp)"
  build_body "${results_json}" "${NO_TESTS_LIST}" > "${body_file}"

  echo "=== Comment body (begin) ===" >&2
  cat "${body_file}" >&2
  echo "=== Comment body (end) ===" >&2

  # Append the same body to the run-page step summary (if running in GitHub
  # Actions). The HTML marker on the first line renders as nothing.
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "${body_file}" >> "${GITHUB_STEP_SUMMARY}"
    echo "Appended summary to \$GITHUB_STEP_SUMMARY." >&2
  fi

  emit_headline_annotation "${results_json}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "DRY_RUN=true — skipping comment upsert." >&2
    rm -f "${body_file}"
    return 0
  fi

  : "${GH_TOKEN:?GH_TOKEN is required for comment upsert (set DRY_RUN=true to skip)}"
  upsert_comment "${body_file}"
  rm -f "${body_file}"
}

main
_main_exit_code=$?
exit ${_main_exit_code}
