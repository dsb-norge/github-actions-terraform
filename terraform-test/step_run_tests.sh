#!/bin/env bash
#
# Source for the run-tests step.
#
# Runs 'terraform test' for one test file from the working directory (the
# workspace), keeps the JSON log in a file, and writes a plain-text report
# next to it.
#
# Required environment variables:
#   input_test_file   - Test file name under tests/ (the filter is tests/<name>)
#
# Standard GitHub environment variables used:
#   GITHUB_WORKSPACE  - where the JSON log and the report are written
#   GITHUB_RUN_ID     - prefix of both file names
#
# Outputs:
#   exit-code  - terraform's exit code
#   json       - path of the JSON log
#   summary    - the test_summary message, JSON-quoted
#   report     - path of the text report
#
# Exit code: 0 when terraform exited 0, else 255.
#

set +o nounset

# Load helpers (provides printSection and queryStatus)
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Report
# ============================================================================

# Writes the text report for the JSON log in $1 to $2. The diagnostic lines
# are rendered straight from the log with jq; nothing from the log is held in
# an (exported) variable.
function write_report {
  local json_file="${1}"
  local report_file="${2}"
  local run_result="${3}"
  local exit_code="${4}"
  local summary="${5}"

  {
    echo "Test result for file: ${input_test_file}"
    echo "overall result: ${run_result}"
    echo "exit code: ${exit_code}"
    echo " "
    echo "output: "
  } >"${report_file}"

  local -a runs=()
  readarray -t runs < <(jq '. | select(.type == "test_run") | select(.test_run.progress == "complete" ) | .test_run.run' "${json_file}")

  local run run_status
  for run in "${runs[@]}"; do
    run=$(sed 's/\"//g' <<<"${run}")
    run_status=$(queryStatus "${run}" "${json_file}")
    if [ "${run_status}" == "\"error\"" ]; then
      {
        printf 'Test: "%s" -----> %s ❌ \n' "${run}" "${run_status}"
        echo "See error details below: "
        echo "  "
        # Every diagnostic of the log, not only this run's: the report has
        # always listed them all under each errored run.
        echo "  | File: $(jq '. | select(.type == "diagnostic")| .diagnostic.range["filename"]' "${json_file}")"
        echo "  | Resource: $(jq '. | select(.type == "diagnostic")| .diagnostic["address"]' "${json_file}")"
        echo "  | Message: $(jq '. | select(.type == "diagnostic")| .diagnostic["summary"]' "${json_file}")"
        echo "  "
      } >>"${report_file}"
    elif [ "${run_status}" == "\"skip\"" ]; then
      printf 'Test: "%s" -----> %s ⚠ \n' "${run}" "${run_status}" >>"${report_file}"
    else
      printf 'Test: "%s" -----> %s ✅ \n' "${run}" "${run_status}" >>"${report_file}"
    fi
  done

  printSection "Test summary for file: ${summary}" >>"${report_file}"
}

# ============================================================================
# Main
# ============================================================================

function main {
  # The JSON log and the report are named after the run and the file.
  local timestamp_json timestamp_report
  timestamp_json="$(date +%Y%m%d%H%M%S)"
  local json_file="${GITHUB_WORKSPACE}/${GITHUB_RUN_ID}-${input_test_file}-${timestamp_json}-test-results.json"
  timestamp_report="$(date +%Y%m%d%H%M%S)"
  local report_file="${GITHUB_WORKSPACE}/${GITHUB_RUN_ID}-${input_test_file}-${timestamp_report}-test-report.txt"
  local -a test_cmd=(terraform test "-filter=tests/${input_test_file}" -json)

  log-info "Running test command: ${test_cmd[*]}"
  start-group "'terraform test' "

  # A failing test must not end the step before the outputs are written.
  set +e
  set -o pipefail
  "${test_cmd[@]}" | tee "${json_file}"
  local exit_code=${?}

  log-multiline "Final JSON output" "${json_file}"
  set-output "exit-code" "${exit_code}"
  set-multiline-output 'json' "${json_file}"

  # JSON-quoted on purpose (no -r): callers render the value as they always have.
  local summary
  summary=$(jq '. | select(.type == "test_summary") | .["@message"]' "${json_file}")

  log-info "Test summary: ${summary}"
  set-output "summary" "${summary}"

  local run_result report_exit_code
  if [ "${exit_code}" == "0" ]; then
    log-info 'All tests passed! 🎉'
    run_result="success"
    report_exit_code=0
  else
    log-error "One or more tests failed, exit code: ${exit_code}"
    run_result="failure"
    report_exit_code=-1
  fi

  write_report "${json_file}" "${report_file}" "${run_result}" "${report_exit_code}" "${summary}"

  set-multiline-output 'report' "${report_file}"

  end-group

  [ "${exit_code}" == "0" ] && return 0
  return 255
}

main
_main_exit_code=$?
exit ${_main_exit_code}
