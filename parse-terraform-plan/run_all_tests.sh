#!/bin/env bash
#
# Test runner for step_parse_plan_output.sh
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# The step's output, one file per run of this suite: a fixed path in /tmp is
# shared with every other suite that uses it, and suites run in parallel.
_test_output=$(mktemp)
trap 'rm -f "${_test_output}"' EXIT

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# Helper to get an output value from GITHUB_OUTPUT
get_output() {
  local key="${1}"
  grep "^${key}=" "${GITHUB_OUTPUT}" | cut -d= -f2-
}

# Generic test runner function
# Usage: run_test <test_name> <imports> <adds> <changes> <destroys> <moves> <removes> [<expected_has_output_only_changes> [<expected_plan_complete>]]
# 8th argument defaults to "false" — most plans aren't output-only.
# 9th argument defaults to what a complete plan gives: empty for console counts
# (no JSON plan given), '?' when the counts are '?', 'true' otherwise.
run_test() {
  local test_name="${1}"
  local expected_imports="${2}"
  local expected_adds="${3}"
  local expected_changes="${4}"
  local expected_destroys="${5}"
  local expected_moves="${6}"
  local expected_removes="${7}"
  local expected_has_output_only_changes="${8:-false}"
  local expected_plan_complete=''
  if [ $# -ge 9 ]; then
    expected_plan_complete="${9}"
  elif [ -n "${input_plan_json_file:-}" ]; then
    expected_plan_complete='true'
    [ "${expected_imports}" = '?' ] && expected_plan_complete='?'
  fi

  TESTS_RUN=$((TESTS_RUN + 1))

  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"

  # Set up fresh GITHUB_OUTPUT. TEST_ACTION_DIR runs a copy of the action
  # instead, for the tests that replace one of its helpers.
  local action_dir="${TEST_ACTION_DIR:-${_this_script_dir}}"
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${action_dir}"
  export GITHUB_WORKSPACE="${action_dir}"

  # Run step in a subshell
  local exit_code
  (
    set -o allexport
    source "${action_dir}/step_parse_plan_output.sh"
  ) > "${_test_output}" 2>&1
  exit_code=$?

  # Assertions
  local actual_imports actual_adds actual_changes actual_destroys actual_moves actual_removes actual_total
  actual_imports=$(get_output "import-count")
  actual_adds=$(get_output "add-count")
  actual_changes=$(get_output "change-count")
  actual_destroys=$(get_output "destroy-count")
  actual_moves=$(get_output "move-count")
  actual_removes=$(get_output "remove-count")
  actual_total=$(get_output "total-count")
  local actual_has_output_only_changes
  actual_has_output_only_changes=$(get_output "has-output-only-changes")
  # Expected total derived from the per-category expectations so existing
  # run_test callers don't need to pass it explicitly. When any expectation
  # is the parse-failed sentinel '?', expected_total is also '?'.
  local expected_total='?'
  if [[ "${expected_imports}${expected_adds}${expected_changes}${expected_destroys}${expected_moves}${expected_removes}" =~ ^[0-9]+$ ]]; then
    expected_total=$((expected_imports + expected_adds + expected_changes + expected_destroys + expected_moves + expected_removes))
  fi

  local failed=0
  local failures=""

  if [[ "${exit_code}" -ne 0 ]]; then
    failed=1
    failures+="  exit code: expected 0, got ${exit_code}\n"
  fi
  if [[ "${actual_imports}" != "${expected_imports}" ]]; then
    failed=1
    failures+="  import-count: expected '${expected_imports}', got '${actual_imports}'\n"
  fi
  if [[ "${actual_adds}" != "${expected_adds}" ]]; then
    failed=1
    failures+="  add-count: expected '${expected_adds}', got '${actual_adds}'\n"
  fi
  if [[ "${actual_changes}" != "${expected_changes}" ]]; then
    failed=1
    failures+="  change-count: expected '${expected_changes}', got '${actual_changes}'\n"
  fi
  if [[ "${actual_destroys}" != "${expected_destroys}" ]]; then
    failed=1
    failures+="  destroy-count: expected '${expected_destroys}', got '${actual_destroys}'\n"
  fi
  if [[ "${actual_moves}" != "${expected_moves}" ]]; then
    failed=1
    failures+="  move-count: expected '${expected_moves}', got '${actual_moves}'\n"
  fi
  if [[ "${actual_removes}" != "${expected_removes}" ]]; then
    failed=1
    failures+="  remove-count: expected '${expected_removes}', got '${actual_removes}'\n"
  fi
  if [[ "${actual_total}" != "${expected_total}" ]]; then
    failed=1
    failures+="  total-count: expected '${expected_total}' (sum of categories), got '${actual_total}'\n"
  fi
  if [[ "${actual_has_output_only_changes}" != "${expected_has_output_only_changes}" ]]; then
    failed=1
    failures+="  has-output-only-changes: expected '${expected_has_output_only_changes}', got '${actual_has_output_only_changes}'\n"
  fi
  # A JSON plan given means the counts are the JSON plan's, even when they are
  # '?'; without one they are the console's.
  local expected_counts_source='console' actual_counts_source
  [ -n "${input_plan_json_file:-}" ] && expected_counts_source='json'
  actual_counts_source=$(get_output "counts-source")
  if [[ "${actual_counts_source}" != "${expected_counts_source}" ]]; then
    failed=1
    failures+="  counts-source: expected '${expected_counts_source}', got '${actual_counts_source}'\n"
  fi
  # Present in every run, empty for console counts: the line must exist.
  if ! grep -q '^plan-complete=' "${GITHUB_OUTPUT}"; then
    failed=1
    failures+="  plan-complete: expected '${expected_plan_complete}', but the output was not published\n"
  elif [[ "$(get_output "plan-complete")" != "${expected_plan_complete}" ]]; then
    failed=1
    failures+="  plan-complete: expected '${expected_plan_complete}', got '$(get_output "plan-complete")'\n"
  fi

  if [[ ${failed} -eq 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}:"
    echo -e "${failures}"
    echo "--- Step output ---"
    cat "${_test_output}"
    echo "--- End step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
}

# A check on the log of the step run_test ran last. Counts as a test.
# Usage: assert_last_log <test_name> <extended regex>
assert_last_log() {
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${1}${NC}"
  if grep -q -E -- "${2}" "${_test_output}"; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: the step's log has no line matching '${2}'"
    echo "--- Step output ---"
    cat "${_test_output}"
    echo "--- End step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# JSON-plan test: run_test with 'plan-json-file' set, unset again afterwards so
# the console tests never see it.
# Usage: run_json_test <test_name> <console file> <JSON file> <expectations as run_test takes them>
run_json_test() {
  local test_name="${1}"
  export input_plan_console_file="${2}"
  export input_plan_json_file="${3}"
  shift 3
  run_test "${test_name}" "$@"
  unset input_plan_json_file
}

# Console tests run without a JSON plan, as every caller did before there was one.
unset input_plan_json_file

# --------------------------------------------------
# Test cases using test-data files
# --------------------------------------------------

# Test 1: No changes plan
export input_plan_console_file="${_this_script_dir}/test-data/plan_0_changes.log"
#                   imports adds changes destroys moves removes
run_test "No changes plan" \
  "0" "0" "0" "0" "0" "0"

# Test 2: Plan with adds, changes, and removed resources (not destroyed)
export input_plan_console_file="${_this_script_dir}/test-data/plan_14_add_21_change_0_destroy_14_removed_and_not_destroyed.log"
#                   imports adds changes destroys moves removes
run_test "14 add, 21 change, 0 destroy, 14 removed" \
  "0" "14" "21" "0" "0" "14"

# Test 3: Plan with adds, changes, destroys, and moves
export input_plan_console_file="${_this_script_dir}/test-data/plan_1_add_1_change_5_destroy_2_move.log"
#                   imports adds changes destroys moves removes
run_test "1 add, 1 change, 5 destroy, 2 move" \
  "0" "1" "1" "5" "2" "0"

# Test 4: Plan with only changes
export input_plan_console_file="${_this_script_dir}/test-data/plan_1_change.log"
#                   imports adds changes destroys moves removes
run_test "0 add, 1 change, 0 destroy" \
  "0" "0" "1" "0" "0" "0"

# Test 5: Output-only changes (no resource changes)
# Resource counts are all 0 BUT has-output-only-changes flips to 'true' so
# consumers can render the plan extract instead of short-circuiting to
# "no changes" (the changes-to-outputs section lives inside the extract).
export input_plan_console_file="${_this_script_dir}/test-data/plan_output_only_changes.log"
#                   imports adds changes destroys moves removes  has-output-only-changes
run_test "Output-only changes (no resource changes)" \
  "0" "0" "0" "0" "0" "0" "true"

# Test 6: Output-only changes in a plan that also defers a data source read.
# Regression guard. Terraform prints "…without changing any real infrastructure."
# only for a plan with no resource actions at all. A deferred data read
# ("# data.x.y will be read during apply") counts as an action, so Terraform
# instead emits the normal action list plus "Plan: 0 to add, 0 to change,
# 0 to destroy." and no such sentence — while outputs are still the only thing
# that changes. Detection therefore keys off the "Changes to Outputs:" header,
# not the sentence; keying off the sentence rendered these plans as
# "Plan: no changes ✅" with the output diff hidden.
export input_plan_console_file="${_this_script_dir}/test-data/plan_output_only_changes_with_data_read.log"
#                   imports adds changes destroys moves removes  has-output-only-changes
run_test "Output-only changes alongside a deferred data source read" \
  "0" "0" "0" "0" "0" "0" "true"

# Test 7: Deferred data source read, no output changes.
# Same "Plan: 0 to add, 0 to change, 0 to destroy." shape as test 6 but with no
# "Changes to Outputs:" section, so the flag must stay false and consumers keep
# rendering "no changes" — a data read changes nothing.
#
# The fixture also carries the literal words "Changes to Outputs:" indented
# inside a heredoc attribute value. That guards the anchor in the detection
# grep: Terraform always prints the real header unindented, so an unanchored
# match would report output-only changes for a plan that has none.
export input_plan_console_file="${_this_script_dir}/test-data/plan_0_changes_with_data_read.log"
#                   imports adds changes destroys moves removes  has-output-only-changes
run_test "Deferred data source read without output changes" \
  "0" "0" "0" "0" "0" "0" "false"

# Test 8: Resource changes *and* output changes.
# The flag is gated on every resource count being zero, so a plan that touches
# both must not claim to be output-only — it already renders its extract on the
# strength of a non-zero total, under the "N changes" summary rather than the
# "output-only changes" one.
export input_plan_console_file="${_this_script_dir}/test-data/plan_1_change_with_output_changes.log"
#                   imports adds changes destroys moves removes  has-output-only-changes
run_test "Resource changes alongside output changes are not output-only" \
  "0" "0" "1" "0" "0" "0" "false"

# Test 9: Empty input (no file specified)
export input_plan_console_file=""
#                   imports adds changes destroys moves removes
run_test "Empty input file path yields fallback values" \
  "?" "?" "?" "?" "?" "?"

# Test 10: Non-existent file (empty file = file exists but is empty)
_empty_file=$(mktemp)
export input_plan_console_file="${_empty_file}"
#                   imports adds changes destroys moves removes
run_test "Empty file yields fallback values" \
  "?" "?" "?" "?" "?" "?"
rm -f "${_empty_file}"

# --------------------------------------------------
# R1–R17: real console output, captured by contract-tests/run.sh from the
# scenarios under contract-tests/scenarios/ (provenance and terraform version
# in test-data/README.md). One fixture per plan shape; the contract tests
# prove these are still what terraform prints. Wording found on capture:
#   - imports are a segment of the "Plan:" line, FIRST: "Plan: 1 to import, 1 to add, …"
#   - moves and removals have NO segment on the "Plan:" line; they are counted
#     from "has moved to" / "will no longer be managed by Terraform"
#   - an output-only plan has no "Plan:" line at all
#   - a -refresh-only plan with nothing drifted says "No changes. Your
#     infrastructure still matches the configuration."
# --------------------------------------------------
#                                                       imports adds changes destroys moves removes [output-only]
export input_plan_console_file="${_this_script_dir}/test-data/plan_adds_only.log"
run_test "R1: adds only"                                  "0" "2" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_change_in_place.log"
run_test "R2: change in place, plus an output change → not output-only" \
                                                          "0" "0" "1" "0" "0" "0" "false"
export input_plan_console_file="${_this_script_dir}/test-data/plan_replace.log"
run_test "R3: replace = 1 to add + 1 to destroy"          "0" "1" "0" "1" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_destroys_only.log"
run_test "R4: destroys only"                              "0" "0" "0" "1" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_import_block.log"
run_test "R5: import block — 'N to import' leads the Plan line" \
                                                          "1" "1" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_moved_block.log"
run_test "R6: moved block — counted from 'has moved to'"  "0" "0" "0" "0" "1" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_removed_block_forget.log"
run_test "R7: removed block (forget) — counted from 'will no longer be managed'" \
                                                          "0" "0" "0" "0" "0" "1"
export input_plan_console_file="${_this_script_dir}/test-data/plan_no_changes.log"
run_test "R8: no changes"                                 "0" "0" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_outputs_only.log"
run_test "R9: outputs only — no Plan line, output-only flag" \
                                                          "0" "0" "0" "0" "0" "0" "true"
export input_plan_console_file="${_this_script_dir}/test-data/plan_refresh_only.log"
run_test "R10: -refresh-only with nothing drifted"        "0" "0" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_destroy_plan_applied.log"
run_test "R11: a -destroy plan"                           "0" "0" "0" "2" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_failed_provisioner.log"
run_test "R12: the plan of an apply that later fails is an ordinary plan" \
                                                          "0" "2" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_interrupted.log"
run_test "R13: the plan of an apply later interrupted"    "0" "1" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_check_warnings.log"
run_test "R14: a check-block warning after the Plan line" "0" "0" "1" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_progress_ticks.log"
run_test "R15: a slow create's plan"                      "0" "1" "0" "0" "0" "0"
export input_plan_console_file="${_this_script_dir}/test-data/plan_moved_block_with_change.log"
run_test "R16: a move rendered as '(moved from' on a changed resource" \
                                                          "0" "0" "1" "0" "1" "0" "false"
export input_plan_console_file="${_this_script_dir}/test-data/plan_destroy_plan_empty.log"
run_test "R17: an empty -destroy plan — 'No objects need to be destroyed.'" \
                                                          "0" "0" "0" "0" "0" "0" "false"

# --------------------------------------------------
# H1: Terraform 1.14+ appends 'Actions: N to invoke.' to the 'Plan:' line
# (#37689). The per-segment regexes read 'N to add' / 'to change' / 'to
# destroy' one at a time, so the extra sentence is invisible to them — pinned
# so that stays true. The apply parser needed a fix for the same suffix on its
# summary line (P38). Hand-written: no built-in action type exists to capture
# from.
# --------------------------------------------------
export input_plan_console_file="${_this_script_dir}/test-data/plan_with_actions.log"
run_test "H1: 'Actions: 2 to invoke.' after the Plan line's counts" \
                                                          "0" "1" "0" "0" "0" "0"

# --------------------------------------------------
# J1–J7: the console halves of the JSON-plan fixture pairs
# (test-data/plan_json_*.{log,json}, provenance in test-data/README.md): each
# console was captured together with 'terraform show -json' of the same saved
# plan. Pinned here as the console parser reads them.
#
# J1 is a known miscount, pinned on purpose. One resource value reads
# "No changes allowed; Plan: 0 to add, 0 to change, 0 to destroy.", which the
# unanchored 'No changes.' search matches, so a plan that imports 1, adds 3,
# changes 2 and destroys 3 reads as none of those. Only the move and the
# removal survive, because each is counted from its own resource line. The
# console text holds resource values; it cannot be trusted for the counts,
# which is why a caller whose counts decide anything passes the JSON plan
# (JS1–JS7 count the same plans from it). Without a JSON plan the console
# parser stays exactly as it was, miscount included.
# --------------------------------------------------
#                                                       imports adds changes destroys moves removes [output-only]
export input_plan_console_file="${_this_script_dir}/test-data/plan_json_injected_summary.log"
run_test "J1: a value that reads like a summary zeroes the console's import, add, change and destroy" \
                                                          "0" "0" "0" "0" "1" "1" "false"
export input_plan_console_file="${_this_script_dir}/test-data/plan_json_no_changes.log"
run_test "J2: no changes"                                 "0" "0" "0" "0" "0" "0" "false"
export input_plan_console_file="${_this_script_dir}/test-data/plan_json_outputs_only.log"
run_test "J3: an added output and nothing else"           "0" "0" "0" "0" "0" "0" "true"
export input_plan_console_file="${_this_script_dir}/test-data/plan_json_destroy_plan.log"
run_test "J4: a -destroy plan"                            "0" "0" "0" "4" "0" "0" "false"
export input_plan_console_file="${_this_script_dir}/test-data/plan_json_data_read.log"
run_test "J5: a deferred data-source read beside resource changes" \
                                                          "0" "2" "1" "1" "0" "0" "false"
export input_plan_console_file="${_this_script_dir}/test-data/plan_json_targeted_incomplete.log"
run_test "J6: a -target plan reads as an ordinary one"    "0" "0" "1" "0" "0" "0" "false"
export input_plan_console_file="${_this_script_dir}/test-data/plan_json_errored.log"
run_test "J7: an errored plan's partial Plan line is read as the plan's counts" \
                                                          "0" "0" "1" "0" "0" "0" "false"

# --------------------------------------------------
# JS1–JS7: the same seven plans counted from their JSON plan ('plan-json-file').
# From each resource_changes entry with mode "managed": add = actions hold
# "create", change = actions are ["update"], destroy = actions hold "delete"
# (a replacement counts under add and destroy), import = change.importing,
# move = previous_address differs from address, remove = actions hold
# "forget". Data sources and no-ops count nowhere. An errored plan is every
# count '?'. A plan that says it is not complete keeps its counts and reports
# plan-complete 'false'; every other one here is complete (the default the
# ninth run_test argument checks).
# --------------------------------------------------
_td="${_this_script_dir}/test-data"
#                                                       imports adds changes destroys moves removes [output-only [plan-complete]]
run_json_test "JS1: the value that forged the console's counts changes nothing in the JSON plan's" \
  "${_td}/plan_json_injected_summary.log" "${_td}/plan_json_injected_summary.json" \
                                                          "1" "3" "2" "3" "1" "1" "false"
run_json_test "JS2: no changes — every resource and the output a no-op" \
  "${_td}/plan_json_no_changes.log" "${_td}/plan_json_no_changes.json" \
                                                          "0" "0" "0" "0" "0" "0" "false"
run_json_test "JS3: an added output and nothing else is output-only" \
  "${_td}/plan_json_outputs_only.log" "${_td}/plan_json_outputs_only.json" \
                                                          "0" "0" "0" "0" "0" "0" "true"
run_json_test "JS4: a -destroy plan — the output's delete does not make it output-only" \
  "${_td}/plan_json_destroy_plan.log" "${_td}/plan_json_destroy_plan.json" \
                                                          "0" "0" "0" "4" "0" "0" "false"
run_json_test "JS5: a deferred data-source read counts nowhere" \
  "${_td}/plan_json_data_read.log" "${_td}/plan_json_data_read.json" \
                                                          "0" "2" "1" "1" "0" "0" "false"
run_json_test "JS6: a -target plan (complete: false) keeps its counts, and says it is not complete" \
  "${_td}/plan_json_targeted_incomplete.log" "${_td}/plan_json_targeted_incomplete.json" \
                                                          "0" "0" "1" "0" "0" "0" "false" "false"
assert_last_log "JS6: the log warns it may not be the whole plan" "does not say it is complete .*it may not be the whole plan"
run_json_test "JS7: an errored plan (errored: true) is every count unknown, plan-complete too" \
  "${_td}/plan_json_errored.log" "${_td}/plan_json_errored.json" \
                                                          "?" "?" "?" "?" "?" "?" "false" "?"
assert_last_log "JS7: the log says the plan errored" "the plan errored \(errored: true\)"

# --------------------------------------------------
# JS8–JS14: a JSON plan that cannot be counted is every count '?', and never
# falls back to the console — the console beside each of these is a readable
# plan with changes.
# --------------------------------------------------
_derived="$(mktemp -d)"
_console="${_td}/plan_json_injected_summary.log"
#                                                       imports adds changes destroys moves removes
run_json_test "JS8: a JSON plan that does not exist" \
  "${_console}" "${_derived}/no-such-plan.json"          "?" "?" "?" "?" "?" "?"
assert_last_log "JS8: the log names the missing file" "no-such-plan.json' cannot be counted: the file does not exist"
: >"${_derived}/empty.json"
run_json_test "JS9: an empty JSON plan file" \
  "${_console}" "${_derived}/empty.json"                 "?" "?" "?" "?" "?" "?"
assert_last_log "JS9: the log says the file is empty" "empty.json' cannot be counted: the file is empty"
# What 'terraform show -json … >file 2>&1' produced when terraform printed a
# warning: a valid document followed by the warning, which is not JSON.
{ cat "${_td}/plan_json_injected_summary.json"; printf '\nWarning: a warning terraform printed on stderr\n'; } >"${_derived}/stderr_mixed_in.json"
run_json_test "JS10: stderr mixed into the file makes it unreadable, not the console's counts" \
  "${_console}" "${_derived}/stderr_mixed_in.json"       "?" "?" "?" "?" "?" "?"
assert_last_log "JS10: the log carries jq's parse error" "cannot be counted: jq failed on it: jq: parse error"
mkdir -p "${_derived}/a-directory.json"
run_json_test "JS11: a path that is a directory" \
  "${_console}" "${_derived}/a-directory.json"           "?" "?" "?" "?" "?" "?"
assert_last_log "JS11: the log says it is not a regular file" "a-directory.json' cannot be counted: it is not a regular file"
printf '%s' '{"hello":"world"}' >"${_derived}/not_a_plan.json"
run_json_test "JS12: JSON that is not a Terraform plan (no format_version)" \
  "${_console}" "${_derived}/not_a_plan.json"            "?" "?" "?" "?" "?" "?"
jq -c '.format_version = "2.0"' "${_td}/plan_json_no_changes.json" >"${_derived}/format_2.json"
run_json_test "JS13: a JSON plan format other than 1.x" \
  "${_console}" "${_derived}/format_2.json"              "?" "?" "?" "?" "?" "?"
cat "${_td}/plan_json_no_changes.json" "${_td}/plan_json_no_changes.json" >"${_derived}/two_documents.json"
run_json_test "JS14: two JSON documents in one file" \
  "${_console}" "${_derived}/two_documents.json"         "?" "?" "?" "?" "?" "?"
# A file the step may not read. Root reads it regardless, so only checked
# when the suite does not run as root.
if [ "$(id -u)" -ne 0 ]; then
  cp "${_td}/plan_json_no_changes.json" "${_derived}/unreadable.json"
  chmod 000 "${_derived}/unreadable.json"
  run_json_test "JS15: a JSON plan file that cannot be read" \
    "${_console}" "${_derived}/unreadable.json"          "?" "?" "?" "?" "?" "?"
  assert_last_log "JS15: the log says it cannot be read" "unreadable.json' cannot be counted: it cannot be read"
  chmod 600 "${_derived}/unreadable.json"
fi

# --------------------------------------------------
# JS16–JS26: each rule on its own, on a real plan changed in one place.
# --------------------------------------------------
jq -c '.errored = true | .complete = true' "${_td}/plan_json_no_changes.json" >"${_derived}/errored_only.json"
run_json_test "JS16: errored alone, with complete true, is every count unknown" \
  "${_console}" "${_derived}/errored_only.json"          "?" "?" "?" "?" "?" "?"
jq -c '.complete = false' "${_td}/plan_json_injected_summary.json" >"${_derived}/incomplete_only.json"
run_json_test "JS17: complete false alone keeps the counts, plan-complete false" \
  "${_console}" "${_derived}/incomplete_only.json"       "1" "3" "2" "3" "1" "1" "false" "false"
jq -c 'del(.complete) | del(.errored)' "${_td}/plan_json_injected_summary.json" >"${_derived}/no_completeness_keys.json"
run_json_test "JS18: a plan that does not say whether it is complete is counted, but not complete" \
  "${_console}" "${_derived}/no_completeness_keys.json"  "1" "3" "2" "3" "1" "1" "false" "false"
assert_last_log "JS18: the log warns it may not be the whole plan" "does not say it is complete .*it may not be the whole plan"
jq -c '.complete = "true"' "${_td}/plan_json_injected_summary.json" >"${_derived}/complete_as_string.json"
run_json_test "JS18a: only a literal true is complete, not the string \"true\"" \
  "${_console}" "${_derived}/complete_as_string.json"    "1" "3" "2" "3" "1" "1" "false" "false"
run_json_test "JS18b: a complete plan says so" \
  "${_console}" "${_td}/plan_json_injected_summary.json" "1" "3" "2" "3" "1" "1" "false" "true"
export input_plan_console_file="${_console}"
run_test "JS18c: console counts leave plan-complete empty: the console cannot tell" \
                                                          "0" "0" "0" "0" "1" "1" "false" ""
jq -c 'del(.resource_changes) | del(.output_changes)' "${_td}/plan_json_no_changes.json" >"${_derived}/no_resources.json"
run_json_test "JS19: a configuration with no resources has no resource_changes at all" \
  "${_console}" "${_derived}/no_resources.json"          "0" "0" "0" "0" "0" "0"
jq -c '(.resource_changes[] | select(.address == "terraform_data.replace_me") | .change.actions) = ["create","delete"]' \
  "${_td}/plan_json_injected_summary.json" >"${_derived}/create_before_destroy.json"
run_json_test "JS20: a create_before_destroy replacement counts under add and destroy" \
  "${_console}" "${_derived}/create_before_destroy.json" "1" "3" "2" "3" "1" "1"
jq -c '(.resource_changes[] | select(.address == "random_string.imported[0]") | .change.actions) = ["no-op"]' \
  "${_td}/plan_json_injected_summary.json" >"${_derived}/import_only.json"
run_json_test "JS21: an import that changes nothing counts as an import only" \
  "${_console}" "${_derived}/import_only.json"           "1" "2" "2" "2" "1" "1"
jq -c '(.resource_changes[] | select(.address == "terraform_data.new_name") | .change.actions) = ["no-op"]' \
  "${_td}/plan_json_injected_summary.json" >"${_derived}/move_only.json"
run_json_test "JS22: a move that changes nothing counts as a move only" \
  "${_console}" "${_derived}/move_only.json"             "1" "3" "1" "3" "1" "1"
jq -c '(.resource_changes[] | select(.address == "terraform_data.new_name") | .previous_address) = "terraform_data.new_name"' \
  "${_td}/plan_json_injected_summary.json" >"${_derived}/previous_is_current.json"
run_json_test "JS23: a previous_address equal to the address is not a move" \
  "${_console}" "${_derived}/previous_is_current.json"   "1" "3" "2" "3" "0" "1"
# Data-source entries with every marker a managed resource could carry: none
# of them counts, because only managed resources do.
jq -c '.resource_changes += [
    {"address":"data.x.a","mode":"data","change":{"actions":["delete"]}},
    {"address":"data.x.b","mode":"data","change":{"actions":["create"]}},
    {"address":"data.x.c","mode":"data","change":{"actions":["update"]}},
    {"address":"data.x.d","mode":"data","previous_address":"data.x.old","change":{"actions":["forget"],"importing":{"id":"x"}}}
  ]' "${_td}/plan_json_destroy_plan.json" >"${_derived}/data_entries.json"
run_json_test "JS24: data sources count nowhere, whatever their actions" \
  "${_console}" "${_derived}/data_entries.json"          "0" "0" "0" "4" "0" "0"
jq -c '(.resource_changes[] | select(.address == "terraform_data.update_me") | .change) |= del(.actions)' \
  "${_td}/plan_json_injected_summary.json" >"${_derived}/no_actions.json"
run_json_test "JS25: a managed change without a list of actions is every count unknown" \
  "${_console}" "${_derived}/no_actions.json"            "?" "?" "?" "?" "?" "?"
jq -c '(.resource_changes[] | select(.address == "terraform_data.update_me") | .change.actions) = ["update", 7]' \
  "${_td}/plan_json_injected_summary.json" >"${_derived}/action_not_a_string.json"
run_json_test "JS25b: a managed change with an action that is not a string is every count unknown" \
  "${_console}" "${_derived}/action_not_a_string.json"   "?" "?" "?" "?" "?" "?"
jq -c '.resource_changes = {"terraform_data.x": .resource_changes[0]}' \
  "${_td}/plan_json_injected_summary.json" >"${_derived}/resource_changes_object.json"
run_json_test "JS25c: resource_changes that is not a list is every count unknown" \
  "${_console}" "${_derived}/resource_changes_object.json" "?" "?" "?" "?" "?" "?"
jq -c '.output_changes = [{"actions":["update"]}]' \
  "${_td}/plan_json_no_changes.json" >"${_derived}/output_changes_list.json"
run_json_test "JS25d: output_changes that is not an object is every count unknown" \
  "${_console}" "${_derived}/output_changes_list.json"   "?" "?" "?" "?" "?" "?"
jq -c '(.resource_changes[0].change) = "not an object"' \
  "${_td}/plan_json_injected_summary.json" >"${_derived}/change_not_an_object.json"
run_json_test "JS25e: a document jq cannot walk is every count unknown" \
  "${_console}" "${_derived}/change_not_an_object.json"  "?" "?" "?" "?" "?" "?"
assert_last_log "JS25e: the log carries jq's message" "cannot be counted: jq failed on it: jq: error"
# The JSON analogue of test 6: a deferred data-source read and an output change,
# no managed change. The read is no resource change, so the plan is output-only.
jq -c '(.resource_changes[] | select(.mode == "managed") | .change.actions) = ["no-op"]' \
  "${_td}/plan_json_data_read.json" >"${_derived}/outputs_with_data_read.json"
run_json_test "JS26: output changes beside a deferred data-source read are output-only" \
  "${_console}" "${_derived}/outputs_with_data_read.json" "0" "0" "0" "0" "0" "0" "true"

# --------------------------------------------------
# JS27–JS28: with a JSON plan, the console is not read for the counts at all.
# --------------------------------------------------
run_json_test "JS27: the JSON plan's counts, whatever the console beside it says" \
  "${_td}/plan_no_changes.log" "${_td}/plan_json_injected_summary.json" \
                                                          "1" "3" "2" "3" "1" "1" "false"
run_json_test "JS28: the JSON plan's output-only flag, although the console has no 'Changes to Outputs:'" \
  "" "${_td}/plan_json_outputs_only.json"                "0" "0" "0" "0" "0" "0" "true"

# --------------------------------------------------
# JS29–JS30: the step takes nothing from the counting on trust. A copy of the
# action whose counting helper answers malformed lines: every count is '?'.
# --------------------------------------------------
_stub_action="${_derived}/stub-action"
mkdir -p "${_stub_action}"
cp "${_this_script_dir}/helpers.sh" "${_this_script_dir}/step_parse_plan_output.sh" "${_stub_action}/"
printf '%s\n' 'function plan-json-counts { printf "ok\t3\t2\t1\n"; }' >"${_stub_action}/helpers_additional.sh"
export TEST_ACTION_DIR="${_stub_action}"
run_json_test "JS29: an 'ok' with missing counts is every count unknown" \
  "${_console}" "${_td}/plan_json_no_changes.json"       "?" "?" "?" "?" "?" "?"
printf '%s\n' 'function plan-json-counts { printf "ok\t3\tx\t1\t0\t0\t0\tfalse\ttrue\n"; }' >"${_stub_action}/helpers_additional.sh"
run_json_test "JS29a: an 'ok' with a count that is not a number is every count unknown" \
  "${_console}" "${_td}/plan_json_no_changes.json"       "?" "?" "?" "?" "?" "?"
printf '%s\n' 'function plan-json-counts { printf "ok\t3\t2\t1\t0\t0\t0\tyes\ttrue\n"; }' >"${_stub_action}/helpers_additional.sh"
run_json_test "JS29b: an 'ok' whose outputs flag is neither true nor false is every count unknown" \
  "${_console}" "${_td}/plan_json_no_changes.json"       "?" "?" "?" "?" "?" "?"
printf '%s\n' 'function plan-json-counts { printf "ok\t3\t2\t1\t0\t0\t0\tfalse\tmaybe\n"; }' >"${_stub_action}/helpers_additional.sh"
run_json_test "JS29c: an 'ok' whose complete flag is neither true nor false is every count unknown" \
  "${_console}" "${_td}/plan_json_no_changes.json"       "?" "?" "?" "?" "?" "?" "false" "?"
printf '%s\n' 'function plan-json-counts { printf "ok\t3\t2\t1\t0\t0\t0\tfalse\ttrue\n"; }' >"${_stub_action}/helpers_additional.sh"
run_json_test "JS29d: control — the same stub, well formed, is counted" \
  "${_console}" "${_td}/plan_json_no_changes.json"       "0" "3" "2" "1" "0" "0" "false" "true"
printf '%s\n' 'function plan-json-counts { :; }' >"${_stub_action}/helpers_additional.sh"
run_json_test "JS30: no answer at all is every count unknown" \
  "${_console}" "${_td}/plan_json_no_changes.json"       "?" "?" "?" "?" "?" "?"
assert_last_log "JS30: the log says what the counting returned" "cannot be counted: the counting returned ''"
printf '%s\n' 'function plan-json-counts { printf "ok\t0\t0\t0\t0\t0\t0\tfalse\ttrue\n"; echo "jq: error: stub" >&2; return 5; }' >"${_stub_action}/helpers_additional.sh"
run_json_test "JS30a: a counting that fails is every count unknown, whatever it printed first" \
  "${_console}" "${_td}/plan_json_no_changes.json"       "?" "?" "?" "?" "?" "?"
unset TEST_ACTION_DIR
rm -rf "${_derived}"

# --------------------------------------------------
# JS31–JS35: the drift fixtures counted, beside their classification below.
# --------------------------------------------------
#                                                       imports adds changes destroys moves removes
run_json_test "JS31: a resource deleted outside Terraform is one to add" \
  "${_td}/plan_json_drift_deleted.log" "${_td}/plan_json_drift_deleted.json" \
                                                          "0" "1" "0" "0" "0" "0"
run_json_test "JS32: the same beside a resource of its own is two to add" \
  "${_td}/plan_json_drift_with_own_changes.log" "${_td}/plan_json_drift_with_own_changes.json" \
                                                          "0" "2" "0" "0" "0" "0"
run_json_test "JS33: a new resource beside an unchanged one" \
  "${_td}/plan_json_pending_create.log" "${_td}/plan_json_pending_create.json" \
                                                          "0" "1" "0" "0" "0" "0"
run_json_test "JS34: an unapplied moved block is one move" \
  "${_td}/plan_json_moved_unapplied.log" "${_td}/plan_json_moved_unapplied.json" \
                                                          "0" "0" "0" "0" "1" "0"
run_json_test "JS35: an unapplied import block is one import" \
  "${_td}/plan_json_import_unapplied.log" "${_td}/plan_json_import_unapplied.json" \
                                                          "1" "0" "0" "0" "0" "0"
run_json_test "JS36: attribute drift changed back and a deleted resource created again" \
  "${_td}/plan_json_drift_attributes.log" "${_td}/plan_json_drift_attributes.json" \
                                                          "0" "1" "1" "0" "0" "0"
run_json_test "JS37: drift under ignore_changes alone changes nothing" \
  "${_td}/plan_json_drift_ignored.log" "${_td}/plan_json_drift_ignored.json" \
                                                          "0" "0" "0" "0" "0" "0"

# --------------------------------------------------
# DC1–DC20: the classification of a JSON plan (docs/Drift-detection.md §4,
# D3, D4). drift: an address in resource_drift that also has a planned action
# (anything but no-op and read); pending: any other change; clean: none. The
# fingerprint is the SHA-256 of the sorted lines '<address> <actions>',
# '<address> moved-from <previous>', '<address> importing', 'output <name>
# <actions>' and '<address> drifted', each ending in a newline; empty for clean
# and unknown. The recorded plans were planned against a hand-written local
# state (test-data/README.md); the rest are derived from them in one place.
# --------------------------------------------------
# Usage: run_class_test <name> <JSON plan or ''> <plan-class> <count-drift> <count-drift-ignored>
#                       <has-pending-changes> <drift-addresses> [<fingerprint line>...]
run_class_test() {
  local test_name="${1}" json_file="${2}" expected_class="${3}" expected_drift="${4}" expected_ignored="${5}"
  local expected_pending="${6}" expected_addresses="${7}"
  shift 7
  local expected_fingerprint=''
  [ $# -gt 0 ] && expected_fingerprint="$(printf '%s\n' "$@" | sha256sum | cut -d' ' -f1)"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  local action_dir="${TEST_ACTION_DIR:-${_this_script_dir}}"
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${action_dir}" GITHUB_WORKSPACE="${action_dir}"
  export input_plan_console_file="${_td}/plan_json_no_changes.log"
  if [ -n "${json_file}" ]; then export input_plan_json_file="${json_file}"; else unset input_plan_json_file; fi
  local exit_code
  (
    set -o allexport
    source "${action_dir}/step_parse_plan_output.sh"
  ) >"${_test_output}" 2>&1
  exit_code=$?
  unset input_plan_json_file
  local failures='' name expected actual
  [ "${exit_code}" -eq 0 ] || failures+="  exit code: expected 0, got ${exit_code}\n"
  for name in plan-class count-drift count-drift-ignored has-pending-changes drift-addresses plan-fingerprint; do
    case "${name}" in
      plan-class) expected="${expected_class}" ;;
      count-drift) expected="${expected_drift}" ;;
      count-drift-ignored) expected="${expected_ignored}" ;;
      has-pending-changes) expected="${expected_pending}" ;;
      drift-addresses) expected="${expected_addresses}" ;;
      plan-fingerprint) expected="${expected_fingerprint}" ;;
    esac
    if ! grep -q "^${name}=" "${GITHUB_OUTPUT}"; then
      failures+="  ${name}: expected '${expected}', but the output was not published\n"
    elif [[ "$(get_output "${name}")" != "${expected}" ]]; then
      failures+="  ${name}: expected '${expected}', got '$(get_output "${name}")'\n"
    fi
  done
  if [ -z "${failures}" ]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}:"
    echo -e "${failures}"
    echo "--- Step output ---"
    cat "${_test_output}"
    echo "--- End step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -f "${GITHUB_OUTPUT}"
}

_derived="$(mktemp -d)"
_deleted="${_td}/plan_json_drift_deleted.json"
#                                                          class   drift ignored pending addresses
run_class_test "DC1: a resource deleted outside Terraform, which the plan creates again, is drift" \
  "${_deleted}"                                            drift   1     0       false   '["local_file.probe"]' \
  "local_file.probe create" "local_file.probe drifted"
run_class_test "DC2: drift beside a change of its own is drift, with pending changes" \
  "${_td}/plan_json_drift_with_own_changes.json"           drift   1     0       true    '["local_file.probe"]' \
  "local_file.probe create" "local_file.probe drifted" "terraform_data.extra create"
run_class_test "DC3: a change and no drift is pending" \
  "${_td}/plan_json_pending_create.json"                   pending 0     0       true    '[]' \
  "terraform_data.extra create"
run_class_test "DC4: an unapplied moved block alone is pending" \
  "${_td}/plan_json_moved_unapplied.json"                  pending 0     0       true    '[]' \
  "terraform_data.new moved-from terraform_data.old"
run_class_test "DC5: an unapplied import block alone is pending" \
  "${_td}/plan_json_import_unapplied.json"                 pending 0     0       true    '[]' \
  "random_string.imported importing"
run_class_test "DC6: no changes is clean, without a fingerprint" \
  "${_td}/plan_json_no_changes.json"                       clean   0     0       false   '[]'
run_class_test "DC7: output changes alone are pending" \
  "${_td}/plan_json_outputs_only.json"                     pending 0     0       true    '[]' \
  "output extra create"
run_class_test "DC8: every kind of change has its line; no-ops and data reads none" \
  "${_td}/plan_json_injected_summary.json"                 pending 0     0       true    '[]' \
  "output o update" "random_string.imported[0] delete,create" "random_string.imported[0] importing" \
  "terraform_data.created create" "terraform_data.delete_me[0] delete" "terraform_data.forget_me[0] forget" \
  "terraform_data.new_name moved-from terraform_data.old_name[0]" "terraform_data.new_name update" \
  "terraform_data.replace_me delete,create" "terraform_data.update_me update"
jq -c '(.resource_changes[] | select(.address == "local_file.probe") | .change.actions) = ["no-op"]' \
  "${_deleted}" >"${_derived}/drift_ignored.json"
run_class_test "DC9: drift no planned action reverts (ignore_changes) is clean, and counted apart" \
  "${_derived}/drift_ignored.json"                         clean   0     1       false   '[]'
jq -c '(.resource_drift[0].change.actions) = ["update"] | (.resource_changes[0].change.actions) = ["update"]' \
  "${_deleted}" >"${_derived}/drift_updated.json"
run_class_test "DC10: an attribute changed outside Terraform that the plan changes back is drift" \
  "${_derived}/drift_updated.json"                         drift   1     0       false   '["local_file.probe"]' \
  "local_file.probe drifted" "local_file.probe update"
jq -c '.resource_changes |= reverse | .resource_drift |= reverse' \
  "${_td}/plan_json_drift_with_own_changes.json" >"${_derived}/reordered.json"
run_class_test "DC11: the fingerprint does not depend on the order of the plan" \
  "${_derived}/reordered.json"                             drift   1     0       true    '["local_file.probe"]' \
  "local_file.probe create" "local_file.probe drifted" "terraform_data.extra create"
jq -c '.resource_changes += [{"address":"terraform_data.unrelated","mode":"managed","change":{"actions":["no-op"]}}]' \
  "${_deleted}" >"${_derived}/unrelated_no_op.json"
run_class_test "DC12: an unrelated no-op resource does not change the fingerprint" \
  "${_derived}/unrelated_no_op.json"                       drift   1     0       false   '["local_file.probe"]' \
  "local_file.probe create" "local_file.probe drifted"
jq -c '.output_changes = {"o": {"actions": ["update"]}}' "${_deleted}" >"${_derived}/drift_and_outputs.json"
run_class_test "DC13: output changes beside drift are not changes of its own: reverting drift changes outputs" \
  "${_derived}/drift_and_outputs.json"                     drift   1     0       false   '["local_file.probe"]' \
  "local_file.probe create" "local_file.probe drifted" "output o update"
jq -c '.resource_drift += [{"address":"data.x.y","mode":"data","change":{"actions":["update"]}}]' \
  "${_deleted}" >"${_derived}/data_drift.json"
run_class_test "DC14: a data source in resource_drift counts nowhere" \
  "${_derived}/data_drift.json"                            drift   1     0       false   '["local_file.probe"]' \
  "local_file.probe create" "local_file.probe drifted"
jq -c '.resource_drift = [range(0; 150) as $i | .resource_drift[0] | .address = "module.storage.azurerm_storage_account.account[\"\($i + 1000)\"]"]
       | .resource_changes = [.resource_drift[] | {address, mode: "managed", change: {actions: ["update"]}}]' \
  "${_deleted}" >"${_derived}/many_drifted.json"
_many="$(jq -c '[range(0; 150) | "module.storage.azurerm_storage_account.account[\"\(. + 1000)\"]"] | sort | .[0:50]' -n)"
_many_lines=()
while IFS= read -r _line; do _many_lines+=("${_line}"); done < <(jq -r -n \
  '[range(0; 150) | "module.storage.azurerm_storage_account.account[\"\(. + 1000)\"]" | (. + " drifted"), (. + " update")] | sort[]')
run_class_test "DC15: the drifted addresses are capped at 3000 bytes of JSON; count-drift has them all" \
  "${_derived}/many_drifted.json"                          drift   150   0       false   "${_many}" "${_many_lines[@]}"
run_class_test "DC16: an errored plan is unknown" \
  "${_td}/plan_json_errored.json"                          unknown '?'   '?'     '?'     ''
run_class_test "DC17: a JSON plan that cannot be read is unknown" \
  "${_derived}/no-such-plan.json"                          unknown '?'   '?'     '?'     ''
run_class_test "DC18: console counts are not classified: every output is empty" \
  ''                                                       ''      ''    ''      ''      ''
jq -c '.resource_drift = {"local_file.probe": .resource_drift[0]}' "${_deleted}" >"${_derived}/drift_not_a_list.json"
run_class_test "DC19: resource_drift that is not a list is unknown; the counts still stand" \
  "${_derived}/drift_not_a_list.json"                      unknown '?'   '?'     '?'     ''
assert_last_log "DC19: the log says why the plan cannot be classified" "cannot be classified: its resource_drift is not a list"
jq -c 'del(.resource_drift)' "${_td}/plan_json_pending_create.json" >"${_derived}/no_drift_key.json"
run_class_test "DC20: a plan without resource_drift has no drift" \
  "${_derived}/no_drift_key.json"                          pending 0     0       true    '[]' \
  "terraform_data.extra create"
# DC20a–DC20b: real attribute drift, recorded with the GitHub provider: one
# value changed by hand and planned back, one changed by hand under
# ignore_changes, one deleted by hand and planned again; then the ignored one
# changed alone, which Terraform plans as "No changes".
run_class_test "DC20a: attribute drift a planned update reverts is drift; drift under ignore_changes is ignored" \
  "${_td}/plan_json_drift_attributes.json"                 drift   2     1       false \
  '["github_actions_variable.deleted","github_actions_variable.reverted"]' \
  "github_actions_variable.deleted create" "github_actions_variable.deleted drifted" \
  "github_actions_variable.reverted drifted" "github_actions_variable.reverted update"
run_class_test "DC20b: drift under ignore_changes alone is clean, and counted apart" \
  "${_td}/plan_json_drift_ignored.json"                    clean   0     1       false   '[]'

# DC21–DC27: nothing the classification answers is taken on trust. A copy of
# the action whose classifying helpers are replaced; the counts stay real.
_stub_action="${_derived}/stub-action"
mkdir -p "${_stub_action}"
cp "${_this_script_dir}/helpers.sh" "${_this_script_dir}/step_parse_plan_output.sh" "${_stub_action}/"
export TEST_ACTION_DIR="${_stub_action}"
stub_classify() {
  { cat "${_this_script_dir}/helpers_additional.sh"; printf '%s\n' "$@"; } >"${_stub_action}/helpers_additional.sh"
}
stub_classify 'function plan-json-classify { printf "ok\tdrift\t1\t0\n"; }'
run_class_test "DC21: an 'ok' with values missing is unknown" \
  "${_deleted}"                                            unknown '?'   '?'     '?'     ''
assert_last_log "DC21: the log says what the classification returned" "cannot be classified: the classification returned 'ok"
stub_classify 'function plan-json-classify { printf "ok\tstale\t1\t0\tfalse\t[]\n"; }'
run_class_test "DC22: an 'ok' with a class that is not one is unknown" \
  "${_deleted}"                                            unknown '?'   '?'     '?'     ''
stub_classify 'function plan-json-classify { printf "ok\tdrift\tone\t0\tfalse\t[]\n"; }'
run_class_test "DC22a: an 'ok' with a count that is not a number is unknown" \
  "${_deleted}"                                            unknown '?'   '?'     '?'     ''
stub_classify 'function plan-json-classify { printf "ok\tdrift\t1\t0\tyes\t[]\n"; }'
run_class_test "DC22b: an 'ok' whose pending flag is neither true nor false is unknown" \
  "${_deleted}"                                            unknown '?'   '?'     '?'     ''
stub_classify 'function plan-json-classify { printf "ok\tdrift\t1\t0\tfalse\tlocal_file.probe\n"; }'
run_class_test "DC22c: an 'ok' whose addresses are not a JSON list is unknown" \
  "${_deleted}"                                            unknown '?'   '?'     '?'     ''
stub_classify 'function plan-json-classify { echo "jq: error: stub" >&2; return 5; }'
run_class_test "DC23: a classification that fails is unknown" \
  "${_deleted}"                                            unknown '?'   '?'     '?'     ''
assert_last_log "DC23: the log carries jq's message" "cannot be classified: jq failed on it: jq: error: stub"
stub_classify 'function plan-json-fingerprint { echo "jq: error: stub" >&2; return 5; }'
run_class_test "DC24: a fingerprint that cannot be taken is unknown" \
  "${_deleted}"                                            unknown '?'   '?'     '?'     ''
assert_last_log "DC24: the log says so" "cannot be classified: its fingerprint cannot be taken: jq: error: stub"
stub_classify 'function plan-json-fingerprint { echo "not-a-hash"; }'
run_class_test "DC25: a fingerprint that is not a SHA-256 is unknown" \
  "${_deleted}"                                            unknown '?'   '?'     '?'     ''
stub_classify 'function plan-json-fingerprint { echo "not-a-hash"; }'
run_class_test "DC26: a clean plan takes no fingerprint" \
  "${_td}/plan_json_no_changes.json"                       clean   0     0       false   '[]'
unset TEST_ACTION_DIR
rm -rf "${_derived}"

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "========================================"
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "========================================"

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
