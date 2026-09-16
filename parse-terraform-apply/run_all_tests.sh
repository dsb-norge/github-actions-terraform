#!/bin/env bash
#
# Test runner for step_parse_apply_output.sh
#
# Fixture-driven. Every file under test-data/ is shaped like real terraform
# apply output — including the failure shapes, which is where the parser
# has to be most careful: a failed apply prints no summary line, and the
# parser must report that as '?' / completed=false, never as zeros.
# (docs/Apply-and-destroy-reporting.md §7.2, §10.2.)
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

DATA_DIR="${_this_script_dir}/test-data"

get_output() {
  grep "^${1}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-
}

# Run the step against ${input_apply_console_file}. Leaves GITHUB_OUTPUT and
# RUNNER_TEMP in place for the assertions that follow.
run_step() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${_this_script_dir}"
  (
    set -o allexport
    source "${_this_script_dir}/step_parse_apply_output.sh"
  ) > /tmp/test_output_parse_apply.txt 2>&1
  LAST_EXIT=$?
}

cleanup() {
  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${RUNNER_TEMP}"
}

# Count assertions for one fixture.
# Usage: run_count_test <name> <fixture> <add> <change> <destroy> <completed> <kind>
# total is derived from the three counts ('?' if any is '?').
run_count_test() {
  local name="${1}" fixture="${2}"
  local e_add="${3}" e_change="${4}" e_destroy="${5}" e_completed="${6}" e_kind="${7}"
  local e_total='?'
  if [[ "${e_add}${e_change}${e_destroy}" =~ ^[0-9]+$ ]]; then
    e_total=$((e_add + e_change + e_destroy))
  fi

  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"

  if [ -n "${fixture}" ]; then
    export input_apply_console_file="${DATA_DIR}/${fixture}"
  else
    export input_apply_console_file=""
  fi
  run_step

  local failures=""
  [[ "${LAST_EXIT}" -eq 0 ]] || failures+="  exit code: expected 0, got ${LAST_EXIT}\n"
  local k v
  for k in "add-count:${e_add}" "change-count:${e_change}" "destroy-count:${e_destroy}" \
           "total-count:${e_total}" "completed:${e_completed}" "apply-kind:${e_kind}"; do
    v=$(get_output "${k%%:*}")
    [[ "${v}" == "${k#*:}" ]] || failures+="  ${k%%:*}: expected '${k#*:}', got '${v}'\n"
  done
  # filtered-console-file must always be a readable path
  local ff; ff=$(get_output filtered-console-file)
  [[ -n "${ff}" && -f "${ff}" ]] || failures+="  filtered-console-file: expected an existing file, got '${ff}'\n"

  if [[ -z "${failures}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}:"
    echo -e "${failures}"
    echo "--- Step output ---"; cat /tmp/test_output_parse_apply.txt; echo "--- End step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  cleanup
}

# Free-form assertion after a run_step the caller performed.
assert() {
  local name="${1}"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "$@"; then
    echo -e "${GREEN}✓ PASSED${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo "--- Step output ---"; cat /tmp/test_output_parse_apply.txt; echo "--- GITHUB_OUTPUT ---"; cat "${GITHUB_OUTPUT}"; echo "--- End ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}       PARSE-TERRAFORM-APPLY STEP TESTS      ${NC}"
echo -e "${YELLOW}============================================${NC}"

# --------------------------------------------------------------------------
# B1–B5, B7–B9: count parsing
#                                                        add change destroy completed kind
# --------------------------------------------------------------------------
run_count_test "B1: apply complete, 1 added"            apply_complete_1_add_0_change_0_destroy.log   1   0   0  true  apply
run_count_test "B2: apply complete, no changes"         apply_complete_0_changes.log                  0   0   0  true  apply
run_count_test "B3: destroy complete, 3 destroyed"      destroy_complete_3_destroyed.log              0   0   3  true  destroy
run_count_test "B4: partial failure → '?', not zeros"   apply_failed_partial.log                      '?' '?' '?' false ""
run_count_test "B5: immediate failure → '?', not zeros" apply_failed_immediately.log                  '?' '?' '?' false ""
run_count_test "B7: empty file → '?', exit 0"           empty.log                                     '?' '?' '?' false ""
run_count_test "B7: no file given → '?', exit 0"        ""                                            '?' '?' '?' false ""
run_count_test "B8: parses through a trailing Outputs: section" apply_complete_with_outputs.log       1   0   0  true  apply
run_count_test "B9: three-digit counts"                 apply_large_counts.log                        150 200 100 true apply
run_count_test "B10: non-ASCII resource names"          apply_non_ascii.log                           2   0   0  true  apply
run_count_test "B11: 'Apply complete!' inside an output value is not the summary line" \
                                                        apply_summary_text_inside_output_value.log    1   0   0  true  apply
run_count_test "B6: ticks fixture counts"               apply_with_progress_ticks.log                 2   1   0  true  apply

# --------------------------------------------------------------------------
# B4 detail: a missing file path (not just empty) is also '?' and exit 0.
# --------------------------------------------------------------------------
export input_apply_console_file="${DATA_DIR}/does-not-exist.log"
run_step
assert "B4/B7: non-existent path → exit 0" test "${LAST_EXIT}" -eq 0
assert "B4/B7: non-existent path → completed=false" test "$(get_output completed)" = "false"
assert "B4/B7: non-existent path → filtered file still written (empty)" \
  bash -c "f=\$(grep '^filtered-console-file=' '${GITHUB_OUTPUT}' | cut -d= -f2-); [ -f \"\$f\" ] && [ ! -s \"\$f\" ]"
cleanup

# --------------------------------------------------------------------------
# B6: progress-tick filtering — zero 'Still …' lines remain, every other
# line preserved in order (P5).
# --------------------------------------------------------------------------
export input_apply_console_file="${DATA_DIR}/apply_with_progress_ticks.log"
run_step
FILTERED="$(get_output filtered-console-file)"
assert "B6: no 'Still creating/modifying/reading…' line survives the filter" \
  bash -c "! grep -qE 'Still (creating|destroying|modifying|reading)' '${FILTERED}'"
assert "B6: every non-tick line is preserved, in order" \
  bash -c "diff <(grep -vE ': Still (creating|destroying|modifying|reading)\.\.\. \[' '${input_apply_console_file}') '${FILTERED}' >/dev/null"
assert "B6: the summary line survives" grep -q '^Apply complete! Resources: 2 added' "${FILTERED}"
assert "B6: the '… complete after' lines survive" test "$(grep -c 'complete after' "${FILTERED}")" -eq 4
# 7× creating (incl. the '1h0m10s' form), 1× modifying (id form), 1× reading
assert "B6: exactly 9 tick lines were removed" \
  test "$(( $(wc -l < "${input_apply_console_file}") - $(wc -l < "${FILTERED}") ))" -eq 9
assert "B6: the hour-form tick '[1h0m10s elapsed]' was removed" \
  bash -c "! grep -q '1h0m10s elapsed' '${FILTERED}'"
assert "B6: the id-form tick '[id=…, 10s elapsed]' was removed" \
  bash -c "! grep -q 'Still modifying' '${FILTERED}'"
cleanup

# 'Still destroying…' carries the id in the bracket before the elapsed time.
export input_apply_console_file="${DATA_DIR}/destroy_complete_3_destroyed.log"
run_step
FILTERED="$(get_output filtered-console-file)"
assert "B6: 'Still destroying… [id=…, 10s elapsed]' is filtered too" \
  bash -c "! grep -q 'Still destroying' '${FILTERED}'"
assert "B6: 'Destroying…' and 'Destruction complete' lines are kept" \
  test "$(grep -c 'Destroying\.\.\.\|Destruction complete' "${FILTERED}")" -eq 6
cleanup

# The filtered file is a distinct path, not the input rewritten in place.
export input_apply_console_file="${DATA_DIR}/apply_with_progress_ticks.log"
run_step
assert "B6: filtered file is a separate file under RUNNER_TEMP, input untouched" \
  bash -c "f=\$(grep '^filtered-console-file=' '${GITHUB_OUTPUT}' | cut -d= -f2-); [[ \"\$f\" == '${RUNNER_TEMP}'/* ]] && grep -q 'Still creating' '${input_apply_console_file}'"
cleanup

# --------------------------------------------------------------------------
# B10: UTF-8 survives the filter byte-for-byte
# --------------------------------------------------------------------------
export input_apply_console_file="${DATA_DIR}/apply_non_ascii.log"
run_step
FILTERED="$(get_output filtered-console-file)"
assert "B10: non-ASCII resource names survive filtering" grep -q 'Ærlig Ørn Åsen' "${FILTERED}"
assert "B10: emoji in resource keys survive filtering" grep -q 'Økonomi 💰' "${FILTERED}"
assert "B10: filtered file is valid UTF-8" bash -c "iconv -f UTF-8 -t UTF-8 '${FILTERED}' >/dev/null 2>&1"
cleanup

# --------------------------------------------------------------------------
# B12: ANSI-coloured output. terraform renders the summary as
# "[reset][bold][green]\nApply complete! …" — the newline sits BETWEEN the
# colour codes and the text, so the summary line itself is clean at column
# 0 and parses even with colour on. The -no-color flag terraform-apply
# passes is therefore for the rendered COMMENT (escape bytes elsewhere in
# the console would show as literal 'ESC[0m' in the code fence), not for
# this parser. Both facts are pinned here so nobody "fixes" either.
# --------------------------------------------------------------------------
run_count_test "B12: ANSI-coloured console still parses (colour codes precede a newline)" \
                                                        apply_ansi_coloured.log                       1   0   0  true  apply
export input_apply_console_file="${DATA_DIR}/apply_ansi_coloured.log"
run_step
assert "B12: … but escape bytes reach the filtered file — hence -no-color upstream" \
  bash -c "grep -q \$'\\x1b\\[' \"\$(grep '^filtered-console-file=' '${GITHUB_OUTPUT}' | cut -d= -f2-)\""
cleanup

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "========================================"
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "========================================"

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
fi
exit 0
