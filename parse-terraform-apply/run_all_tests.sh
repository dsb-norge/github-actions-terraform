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
  # Optional 8th argument. Terraform omits the 'imported' segment entirely when
  # no import blocks are in play, so the default is what that yields: 0 once a
  # summary line parsed, '?' when none did.
  local e_import="${8:-}"
  if [ -z "${e_import}" ]; then
    if [ "${e_completed}" = 'true' ]; then e_import=0; else e_import='?'; fi
  fi
  local e_total='?'
  if [[ "${e_import}${e_add}${e_change}${e_destroy}" =~ ^[0-9]+$ ]]; then
    e_total=$((e_import + e_add + e_change + e_destroy))
  fi

  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"

  if [ -n "${fixture}" ]; then
    export input_apply_console_file="${DATA_DIR}/${fixture}"
  else
    export input_apply_console_file=""
  fi
  # Optional 9th argument: the exit code handed to the parser. Empty — the
  # default — keeps the mismatch warning out of the count tests.
  export input_apply_exitcode="${9:-}"
  run_step

  local failures=""
  [[ "${LAST_EXIT}" -eq 0 ]] || failures+="  exit code: expected 0, got ${LAST_EXIT}\n"
  local k v
  for k in "import-count:${e_import}" "add-count:${e_add}" "change-count:${e_change}" "destroy-count:${e_destroy}" \
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
# B13-B14: the summary line is an open-ended list of "<N> <verb>" segments.
# Terraform puts 'N imported' BEFORE 'added' when import blocks are in play,
# and adds verbs as the language grows. A pattern anchored to exactly
# "added, changed, destroyed" reported a completed apply as a failed one —
# the inverse of what this action exists to do — so each verb is matched on
# its own and an unknown segment is a warning, never a parse failure.
#                                                        add change destroy completed kind  import
# --------------------------------------------------------------------------
run_count_test "B13: 'N imported' segment before 'added'" apply_complete_with_imports.log              0   1   0  true  apply 5
run_count_test "B14: unknown segment does not fail the parse" apply_complete_unknown_segment.log       0   0   0  true  apply 3

# B14 detail: the unrecognised segment is reported, and its wording names it.
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "${BLUE}TEST ${TESTS_RUN}: B14: unknown segment is logged as a warning${NC}"
export input_apply_console_file="${DATA_DIR}/apply_complete_unknown_segment.log"
run_step
if grep -q "unrecognised segment" /tmp/test_output_parse_apply.txt &&
   grep -q "2 forgotten" /tmp/test_output_parse_apply.txt; then
  echo -e "${GREEN}  PASS${NC}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}  FAIL${NC} expected a warning naming '2 forgotten'"
  sed -n '1,12p' /tmp/test_output_parse_apply.txt | sed 's/^/       /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# B15: an import-only apply must not be mistaken for a no-op — count-total
# carries the imports, so the renderer does not print 'Apply: no changes'.
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "${BLUE}TEST ${TESTS_RUN}: B15: import-only apply has a non-zero total${NC}"
_imp_only=$(mktemp)
printf 'Apply complete! Resources: 4 imported, 0 added, 0 changed, 0 destroyed.\n' >"${_imp_only}"
export input_apply_console_file="${_imp_only}"
run_step
_tot=$(get_output total-count)
if [[ "${_tot}" == "4" ]]; then
  echo -e "${GREEN}  PASS${NC}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}  FAIL${NC} total-count: expected '4', got '${_tot}'"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# --------------------------------------------------------------------------
# R1–R17: real console output, captured by contract-tests/run.sh from the
# scenarios under contract-tests/scenarios/ (provenance and terraform version
# in test-data/README.md). One fixture per summary shape the parser must
# accept; the contract tests prove these are still what terraform prints.
#                                                        add change destroy completed kind  import
# --------------------------------------------------------------------------
run_count_test "R1: adds only"                          apply_adds_only.log                           2   0   0  true  apply
run_count_test "R2: change in place (+ outputs)"        apply_change_in_place.log                     0   1   0  true  apply
run_count_test "R3: replace = 1 added + 1 destroyed"    apply_replace.log                             1   0   1  true  apply
run_count_test "R4: destroys only, on an apply line"    apply_destroys_only.log                       0   0   1  true  apply
run_count_test "R5: import block — 'imported' before 'added' (P32)" \
                                                        apply_import_block.log                        1   0   0  true  apply 1
run_count_test "R6: moved block — nothing on the summary line" \
                                                        apply_moved_block.log                         0   0   0  true  apply
run_count_test "R7: removed block (forget) — nothing on the summary line" \
                                                        apply_removed_block_forget.log                0   0   0  true  apply
run_count_test "R8: no changes"                         apply_no_changes.log                          0   0   0  true  apply
run_count_test "R9: outputs only (+ Outputs section)"   apply_outputs_only.log                        0   0   0  true  apply
run_count_test "R10: -refresh-only plan applied"        apply_refresh_only.log                        0   0   0  true  apply
run_count_test "R11: a saved -destroy plan applied prints 'Apply complete!' (P33)" \
                                                        apply_destroy_plan_applied.log                0   0   2  true  apply
run_count_test "R12: 'terraform destroy' prints 'Destroy complete!'" \
                                                        destroy_command_complete.log                  0   0   1  true  destroy
run_count_test "R13: failed provisioner → '?', not zeros" apply_failed_provisioner.log                '?' '?' '?' false ""
run_count_test "R14: declined at the prompt ('Apply cancelled.') → '?'" \
                                                        apply_cancelled_at_prompt.log                 '?' '?' '?' false ""
run_count_test "R15: interrupted (SIGINT) → '?'"        apply_interrupted.log                         '?' '?' '?' false ""
run_count_test "R16: a check-block warning before the summary line" \
                                                        apply_check_warnings.log                      0   1   0  true  apply
run_count_test "R17: a real progress tick ('[00m10s elapsed]', P35)" \
                                                        apply_progress_ticks.log                      1   0   0  true  apply

# R17 detail: the real tick shape is filtered (P5 pinned against real output,
# not a hand-written line — the elapsed format has already changed once).
export input_apply_console_file="${DATA_DIR}/apply_progress_ticks.log"
run_step
FILTERED="$(get_output filtered-console-file)"
assert "R17: the real '[00m10s elapsed]' tick is removed" \
  bash -c "grep -q 'Still creating... \[00m10s elapsed\]' '${input_apply_console_file}' && ! grep -q 'Still creating' '${FILTERED}'"
cleanup

# --------------------------------------------------------------------------
# §14 — the outcome invariant (docs/Apply-and-destroy-reporting.md §14).
# The parser never decides the outcome; given the exit code it names the
# one mismatch worth a human look, as a ::warning on the run page.
# --------------------------------------------------------------------------
warning_count() { grep -c '^::warning title=Terraform output not recognised::' /tmp/test_output_parse_apply.txt 2>/dev/null || true; }

# exit 0 + no summary line → success is the step's call; counts '?'; ONE warning
run_count_test "§14: exit 0 + no summary line → counts '?' (the outcome is the step's)" \
                                                        apply_failed_provisioner.log                  '?' '?' '?' false "" "" 0
export input_apply_console_file="${DATA_DIR}/apply_failed_provisioner.log"; export input_apply_exitcode="0"
run_step
assert "§14: exit 0 + no summary line → exactly one 'Terraform output not recognised' warning" \
  test "$(warning_count)" -eq 1
assert "§14: … the warning asks for the console to be reported and names the file" \
  bash -c "grep '^::warning title=Terraform output not recognised::' /tmp/test_output_parse_apply.txt | grep -q 'Please report the apply console output (${input_apply_console_file})'"
assert "§14: … and says the apply is still reported as succeeded" \
  bash -c "grep '^::warning' /tmp/test_output_parse_apply.txt | grep -q 'reported as succeeded'"
assert "§14: … the step still exits 0" test "${LAST_EXIT}" -eq 0
cleanup

# exit 1 + no summary line → the ordinary failed apply; nothing to warn about
export input_apply_console_file="${DATA_DIR}/apply_failed_provisioner.log"; export input_apply_exitcode="1"
run_step
assert "§14: exit 1 + no summary line → no warning (a failed apply prints none)" test "$(warning_count)" -eq 0
cleanup

# no exit code given → the check is off
export input_apply_console_file="${DATA_DIR}/apply_failed_provisioner.log"; export input_apply_exitcode=""
run_step
assert "§14: no exit code given → no warning" test "$(warning_count)" -eq 0
cleanup

# exit 1 + a complete summary line → terraform's counts, no warning; the
# failure is the step's to report (create-validation-summary / annotate).
run_count_test "§14: exit 1 + a complete summary line → counts are terraform's, completed=true" \
                                                        apply_adds_only.log                           2   0   0  true  apply "" 1
export input_apply_console_file="${DATA_DIR}/apply_adds_only.log"; export input_apply_exitcode="1"
run_step
assert "§14: exit 1 + a complete summary line → no warning; the log names the split" \
  bash -c "[ \$(grep -c '^::warning' /tmp/test_output_parse_apply.txt 2>/dev/null || true) -eq 0 ] && grep -q 'the counts are terraform.s, the outcome is the step.s' /tmp/test_output_parse_apply.txt"
cleanup

# exit 0 + unknown verb → completed, known verbs counted, ONE warning naming the verb
run_count_test "§14: exit 0 + unknown verb → completed, known verbs counted" \
                                                        apply_complete_unknown_segment.log            0   0   0  true  apply 3 0
export input_apply_console_file="${DATA_DIR}/apply_complete_unknown_segment.log"; export input_apply_exitcode="0"
run_step
assert "§14: exit 0 + unknown verb → exactly one warning, naming '2 forgotten'" \
  bash -c "[ \$(grep -c '^::warning title=Terraform output not recognised::' /tmp/test_output_parse_apply.txt) -eq 1 ] && grep '^::warning' /tmp/test_output_parse_apply.txt | grep -q \"'2 forgotten'\""
cleanup

# the unknown-verb warning does not need the exit code: the line proves the apply finished
export input_apply_console_file="${DATA_DIR}/apply_complete_unknown_segment.log"; export input_apply_exitcode=""
run_step
assert "§14: unknown verb warns even without an exit code" test "$(warning_count)" -eq 1
cleanup

# workflow-command escaping: a '%' in the path must not break the command
_pct_dir=$(mktemp -d); _pct_file="${_pct_dir}/100%25done.log"; cp "${DATA_DIR}/apply_failed_provisioner.log" "${_pct_file}"
export input_apply_console_file="${_pct_file}"; export input_apply_exitcode="0"
run_step
assert "§14: '%' in the console path is escaped as %25 in the warning" \
  bash -c "grep '^::warning' /tmp/test_output_parse_apply.txt | grep -q '100%2525done.log'"
cleanup; rm -rf "${_pct_dir}"
export input_apply_exitcode=""

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
