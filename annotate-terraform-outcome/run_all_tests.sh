#!/bin/env bash
#
# Tests for step_annotate.sh
#
# Asserts on two side effects: the ::notice / ::error workflow commands on
# stdout, and the block appended to a temp file bound to GITHUB_STEP_SUMMARY.
# (docs/Apply-and-destroy-reporting.md §7.8, §10.4)
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# The step's output, one file per run of this suite: a fixed path in /tmp is
# shared with every other suite that uses it, and suites run in parallel.
_test_output=$(mktemp)
trap 'rm -f "${_test_output}"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

OUT_FILE="${_test_output}"

setup() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/step-summary.md"
  : >"${GITHUB_STEP_SUMMARY}"

  # A rendered block as create-validation-summary writes it.
  SUMMARY_BLOCK="${RUNNER_TEMP}/tf-comment-dev-step-summary.md"
  cat >"${SUMMARY_BLOCK}" <<'EOF'
### Terraform validation summary for environment: `dev`
|  | Step | Result |
|:---:|---|---|
| <span title="Plan">📖</span> | Plan | `success` |
| <span title="Apply">🐙</span> | Apply | `success` |

[Job log](https://github.com/example/repo/actions/runs/1/job/2#logs)
EOF

  export input_environment_name="dev"
  export input_step_summary_file="${SUMMARY_BLOCK}"
  export input_status_apply=""
  export input_apply_count_add="?"
  export input_apply_count_change="?"
  export input_apply_count_destroy="?"
  export input_apply_time=""
  export input_status_destroy=""
  export input_destroy_count_destroy="?"
  export input_destroy_time=""
  # The plan inputs as a push run's plan-only environment hands them over: no warning.
  export input_event_name="push"
  export input_apply_granted="false"
  export input_status_plan="success"
  export input_plan_count_total="0"
  export input_plan_count_add="0"; export input_plan_count_change="0"; export input_plan_count_destroy="0"
  export input_plan_count_import="0"; export input_plan_count_move="0"; export input_plan_count_remove="0"
  export input_plan_has_output_only_changes="false"
  export input_plan_complete="true"
  export input_plan_class=""; export input_plan_count_drift=""; export input_plan_has_pending_changes=""
}

# A scheduled plan-only run's environment (docs/Drift-detection.md §3).
scheduled_plan() {
  export input_event_name="schedule"
  export input_apply_granted="false"
  export input_status_plan="success"
}

teardown() {
  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${RUNNER_TEMP}"
}

run_step() {
  (
    set -eo pipefail
    set -o allexport
    source "${_this_script_dir}/step_annotate.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

assert() {
  local name="${1}"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "$@"; then
    echo -e "${GREEN}✓ PASSED${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo "--- step output ---"; cat "${OUT_FILE}" 2>/dev/null || true
    echo "--- GITHUB_STEP_SUMMARY ---"; cat "${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
    echo "--- end ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

count_cmd() { grep -c "^::${1}" "${OUT_FILE}" 2>/dev/null || true; }

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}     ANNOTATE-TERRAFORM-OUTCOME STEP TESTS   ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# D1 — apply succeeded → exactly one ::notice with env, counts and time
# ----------------------------------------------------------------------
setup
export input_status_apply="success"
export input_apply_count_add="3"; export input_apply_count_change="1"; export input_apply_count_destroy="0"
export input_apply_time="1:07"
run_step
assert "D1: exits 0" test "${LAST_EXIT}" -eq 0
assert "D1: exactly one ::notice" test "$(count_cmd notice)" -eq 1
assert "D1: no ::error" test "$(count_cmd error)" -eq 0
assert "D1: notice is byte-exact" \
  grep -qxF '::notice title=Apply succeeded::dev — 3 added, 1 changed, 0 destroyed in 1:07' "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# P32 — an apply that adopted objects says so; one that did not stays quiet
# ----------------------------------------------------------------------
setup
export input_status_apply="success"
export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
export input_apply_count_import="2"; export input_apply_time="0:12"
run_step
assert "P32: the notice names the imports, last and only when there are any" \
  grep -qxF '::notice title=Apply succeeded::dev — 1 added, 0 changed, 0 destroyed, 2 imported in 0:12' "${OUT_FILE}"
teardown

setup
export input_status_apply="success"
export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
export input_apply_count_import="0"; export input_apply_time="0:12"
run_step
assert "P32: zero imports are not mentioned at all" \
  bash -c "! grep -q 'imported' '${OUT_FILE}'"
teardown

# An unset import count must not reach `[ -ne ]` bare: that prints
# "integer expression expected" into the job log. Reported in review.
setup
export input_status_apply="success"
export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
export input_apply_time="0:12"
unset input_apply_count_import
run_step
assert "unset import count produces no shell error in the log" \
  bash -c "! grep -qi 'integer expression expected' '${_test_output}' 2>/dev/null && ! grep -qi 'integer expression expected' '${OUT_FILE}'"
assert "unset import count is simply not mentioned" \
  bash -c "! grep -q 'imported' '${OUT_FILE}'"
teardown

# ----------------------------------------------------------------------
# D2 — apply failed → exactly one ::error naming the partial-state risk
# ----------------------------------------------------------------------
setup
export input_status_apply="failure"
run_step
assert "D2: exits 0 (reporting never fails the job)" test "${LAST_EXIT}" -eq 0
assert "D2: exactly one ::error" test "$(count_cmd error)" -eq 1
assert "D2: no ::notice" test "$(count_cmd notice)" -eq 0
assert "D2: error is byte-exact and names partial application" \
  grep -qxF "::error title=Apply failed::dev — apply did not complete (outcome 'failure'); infrastructure may be partially applied" "${OUT_FILE}"
teardown

# cancelled is a failure too
setup
export input_status_apply="cancelled"
run_step
assert "D2: cancelled apply → ::error with the outcome named" \
  grep -q "::error title=Apply failed::dev — apply did not complete (outcome 'cancelled')" "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# D3 — apply did not run → no apply annotation at all
# ----------------------------------------------------------------------
setup
run_step
assert "D3: exits 0" test "${LAST_EXIT}" -eq 0
assert "D3: no ::notice" test "$(count_cmd notice)" -eq 0
assert "D3: no ::error" test "$(count_cmd error)" -eq 0
teardown

# 'skipped' is not empty but must not be reported as a failure either — the
# workflow passes steps.apply.outcome, which is 'skipped' when the if: was
# false. Skipped means "did not run".
setup
export input_status_apply="skipped"
run_step
assert "D3: skipped apply → no annotation (did not run)" \
  bash -c "[ \$(grep -c '^::' '${OUT_FILE}' 2>/dev/null || true) -eq 0 ]"
teardown

# ----------------------------------------------------------------------
# D4 — the step summary gains the block; existing content is preserved
# ----------------------------------------------------------------------
setup
printf '## Earlier step wrote this\n\n' >"${GITHUB_STEP_SUMMARY}"
run_step
assert "D4: earlier content preserved (appended, never truncated)" \
  grep -q '^## Earlier step wrote this$' "${GITHUB_STEP_SUMMARY}"
assert "D4: block appended verbatim" \
  bash -c "grep -q '^### Terraform validation summary for environment: \`dev\`$' '${GITHUB_STEP_SUMMARY}' && grep -qF '| <span title=\"Apply\">🐙</span> | Apply | \`success\` |' '${GITHUB_STEP_SUMMARY}'"
assert "D4: earlier content comes first" \
  bash -c "[ \$(grep -n 'Earlier step' '${GITHUB_STEP_SUMMARY}' | cut -d: -f1) -lt \$(grep -n 'Terraform validation summary' '${GITHUB_STEP_SUMMARY}' | cut -d: -f1) ]"
assert "D4: block ends with the [Job log] footer, then a blank line" \
  bash -c "tail -n 3 '${GITHUB_STEP_SUMMARY}' | head -n1 | grep -q '^\[Job log\]('"
teardown

# ----------------------------------------------------------------------
# D5 — GITHUB_STEP_SUMMARY unset → no crash; annotations still emitted
# ----------------------------------------------------------------------
setup
unset GITHUB_STEP_SUMMARY
export input_status_apply="success"; export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
run_step
assert "D5: exits 0 without GITHUB_STEP_SUMMARY" test "${LAST_EXIT}" -eq 0
assert "D5: annotation still emitted" test "$(count_cmd notice)" -eq 1
assert "D5: says the summary was skipped" grep -q "GITHUB_STEP_SUMMARY is not set" "${OUT_FILE}"
export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/x.md"
teardown

# ----------------------------------------------------------------------
# D6 — env name with '::' and '%' → workflow-command escaping
# ----------------------------------------------------------------------
setup
export input_environment_name='we::ird%env'
export input_status_apply="success"; export input_apply_count_add="0"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
run_step
assert "D6: '%' in the message is escaped as %25" grep -q 'we::ird%25env' "${OUT_FILE}"
assert "D6: the line is still one well-formed command (exactly one '::notice' prefix)" \
  bash -c "[ \$(grep -c '^::notice title=Apply succeeded::' '${OUT_FILE}') -eq 1 ]"
teardown

# ----------------------------------------------------------------------
# D7 — block content mirrors the head; [Job log] footer, no Links row
# ----------------------------------------------------------------------
setup
run_step
assert "D7: block has the footer, not a Links row" \
  bash -c "grep -q '^\[Job log\](' '${GITHUB_STEP_SUMMARY}' && ! grep -q '| Links |' '${GITHUB_STEP_SUMMARY}'"
assert "D7: block is valid markdown table (header + alignment row present)" \
  bash -c "grep -qF '|  | Step | Result |' '${GITHUB_STEP_SUMMARY}' && grep -qF '|:---:|---|---|' '${GITHUB_STEP_SUMMARY}'"
teardown

# ----------------------------------------------------------------------
# D8 — block size stays small (P19)
# ----------------------------------------------------------------------
setup
run_step
assert "D8: block < 8 KiB" test "$(wc -c <"${GITHUB_STEP_SUMMARY}")" -lt 8192
teardown

# ----------------------------------------------------------------------
# D9 — destroy succeeded, apply did not run → only the destroy annotation
# ----------------------------------------------------------------------
setup
export input_status_destroy="success"; export input_destroy_count_destroy="4"; export input_destroy_time="0:44"
run_step
assert "D9: exactly one annotation" bash -c "[ \$(grep -c '^::' '${OUT_FILE}') -eq 1 ]"
assert "D9: it is the destroy notice, byte-exact" \
  grep -qxF '::notice title=Destroy succeeded::dev — 4 destroyed in 0:44' "${OUT_FILE}"
teardown

setup
export input_status_destroy="failure"
run_step
assert "D9: destroy failure wording" \
  grep -qxF "::error title=Destroy failed::dev — destroy did not complete (outcome 'failure'); infrastructure may be partially destroyed" "${OUT_FILE}"
teardown

# Both ran → two annotations, apply first.
setup
export input_status_apply="success"; export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
export input_status_destroy="success"; export input_destroy_count_destroy="1"
run_step
assert "both ran → two notices, apply before destroy" \
  bash -c "[ \$(grep -c '^::notice' '${OUT_FILE}') -eq 2 ] && [ \$(grep -n 'Apply succeeded' '${OUT_FILE}' | cut -d: -f1) -lt \$(grep -n 'Destroy succeeded' '${OUT_FILE}' | cut -d: -f1) ]"
teardown

# ----------------------------------------------------------------------
# Counts that are not numbers render as '?' — a failed apply's '?' counts,
# or an unwired 'N/A', must never become a number.
# ----------------------------------------------------------------------
setup
export input_status_apply="success"; export input_apply_count_add="N/A"; export input_apply_count_change=""; export input_apply_count_destroy="?"
run_step
assert "non-numeric counts render as '?'" \
  grep -qF '::notice title=Apply succeeded::dev — ? added, ? changed, ? destroyed' "${OUT_FILE}"
assert "no ' in ' suffix when time is empty" \
  bash -c "! grep -q ' in $' '${OUT_FILE}' && ! grep -q 'destroyed in ' '${OUT_FILE}'"
teardown

# ----------------------------------------------------------------------
# Missing / empty summary file → fallback block, exit 0
# ----------------------------------------------------------------------
setup
export input_step_summary_file="${RUNNER_TEMP}/does-not-exist.md"
run_step
assert "missing summary file: exits 0" test "${LAST_EXIT}" -eq 0
assert "missing summary file: fallback block written" \
  bash -c "grep -q 'Summary not available' '${GITHUB_STEP_SUMMARY}' && grep -q 'environment: \`dev\`' '${GITHUB_STEP_SUMMARY}'"
teardown

setup
export input_step_summary_file=""
run_step
assert "empty summary path: exits 0 with fallback block" \
  bash -c "[ ${LAST_EXIT} -eq 0 ] && grep -q 'Summary not available' '${GITHUB_STEP_SUMMARY}'"
teardown

# ----------------------------------------------------------------------
# S — a scheduled plan-only run warns about a plan with changes
# (docs/Drift-detection.md §3)
# ----------------------------------------------------------------------
setup
scheduled_plan
export input_plan_count_total="3"; export input_plan_count_add="2"; export input_plan_count_change="1"
run_step
assert "S1: exits 0" test "${LAST_EXIT}" -eq 0
assert "S1: exactly one ::warning" test "$(count_cmd warning)" -eq 1
assert "S1: the warning names the non-zero counts, byte-exact" \
  grep -qxF '::warning title=Plan has changes::dev — the scheduled plan has 3 changes (2 to add, 1 to change): drift, or a default branch that is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_count_total="1"; export input_plan_count_destroy="1"
run_step
assert "S2: one change reads in the singular" \
  grep -qxF '::warning title=Plan has changes::dev — the scheduled plan has 1 change (1 to destroy): drift, or a default branch that is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_count_total="2"; export input_plan_count_import="1"; export input_plan_count_move="1"
run_step
assert "S3: imports and moves are counted like any other change" \
  grep -qxF '::warning title=Plan has changes::dev — the scheduled plan has 2 changes (1 to import, 1 to move): drift, or a default branch that is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_has_output_only_changes="true"
run_step
assert "S4: a plan that changes only outputs says so" \
  grep -qxF '::warning title=Plan has changes::dev — the scheduled plan changes only outputs: drift, or a default branch that is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_complete="?"; export input_plan_count_total="?"
run_step
assert "S5: counts that cannot be read are a warning of their own" \
  grep -qxF "::warning title=Plan not read::dev — the scheduled plan's changes could not be read; see the plan in the job log" "${OUT_FILE}"
assert "S5: and only that one" test "$(count_cmd warning)" -eq 1
teardown

setup
scheduled_plan
export input_plan_complete="false"; export input_plan_count_total="1"; export input_plan_count_add="1"
run_step
assert "S6: a targeted or deferred plan (plan-complete false) has valid counts" \
  grep -qxF '::warning title=Plan has changes::dev — the scheduled plan has 1 change (1 to add): drift, or a default branch that is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_count_total="0"
run_step
assert "S7: a clean scheduled plan is silent" test "$(count_cmd warning)" -eq 0
teardown

setup
scheduled_plan
export input_apply_granted="true"; export input_plan_count_total="3"; export input_plan_count_add="3"
run_step
assert "S8: a scheduled reconcile, which applies what it plans, is silent" test "$(count_cmd warning)" -eq 0
teardown

setup
scheduled_plan
export input_status_plan="failure"; export input_plan_count_total="?"
run_step
assert "S9: a failed plan is not a plan with changes" test "$(count_cmd warning)" -eq 0
teardown

for event in push pull_request workflow_dispatch ""; do
  setup
  export input_event_name="${event}"
  export input_plan_count_total="3"; export input_plan_count_add="3"
  run_step
  assert "S10: no warning on event '${event:-<none>}'" test "$(count_cmd warning)" -eq 0
  teardown
done

setup
scheduled_plan
export input_environment_name="prod,eu:1"
export input_plan_count_total="1"; export input_plan_count_add="1"
run_step
assert "S11: the environment name is escaped in the message only, as the other annotations do" \
  grep -qxF '::warning title=Plan has changes::prod,eu:1 — the scheduled plan has 1 change (1 to add): drift, or a default branch that is not applied' "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# SC — with the plan's class (docs/Drift-detection.md §4), the warning says
# which: drift, or a default branch that is not applied
# ----------------------------------------------------------------------
setup
scheduled_plan
export input_plan_class="drift"; export input_plan_count_drift="2"; export input_plan_has_pending_changes="false"
export input_plan_count_total="2"; export input_plan_count_change="2"
run_step
assert "SC1: drift is a warning of its own, byte-exact" \
  grep -qxF '::warning title=Drift::dev — the scheduled plan finds 2 resources changed outside Terraform, which the next apply would change back' "${OUT_FILE}"
assert "SC1: and only that one" test "$(count_cmd warning)" -eq 1
teardown

setup
scheduled_plan
export input_plan_class="drift"; export input_plan_count_drift="1"; export input_plan_has_pending_changes="true"
export input_plan_count_total="2"; export input_plan_count_add="2"
run_step
assert "SC2: drift beside changes of its own says both, in the singular" \
  grep -qxF '::warning title=Drift::dev — the scheduled plan finds 1 resource changed outside Terraform, which the next apply would change back, and has changes of its own: the default branch is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_class="pending"; export input_plan_count_drift="0"; export input_plan_has_pending_changes="true"
export input_plan_count_total="3"; export input_plan_count_add="2"; export input_plan_count_change="1"
run_step
assert "SC3: pending changes say the default branch is not applied" \
  grep -qxF '::warning title=Default branch not applied::dev — the scheduled plan has 3 changes (2 to add, 1 to change): the default branch is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_class="pending"; export input_plan_count_drift="0"; export input_plan_has_pending_changes="true"
export input_plan_has_output_only_changes="true"
run_step
assert "SC4: pending output changes alone say so" \
  grep -qxF '::warning title=Default branch not applied::dev — the scheduled plan changes only outputs: the default branch is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_class="clean"; export input_plan_count_drift="0"; export input_plan_has_pending_changes="false"
run_step
assert "SC5: a clean plan is silent" test "$(count_cmd warning)" -eq 0
teardown

setup
scheduled_plan
export input_plan_class="unknown"; export input_plan_count_drift="?"; export input_plan_has_pending_changes="?"
export input_plan_count_total="1"; export input_plan_count_add="1"
run_step
assert "SC6: a plan whose counts stand but that cannot be classified keeps the stopgap's wording" \
  grep -qxF '::warning title=Plan has changes::dev — the scheduled plan has 1 change (1 to add): drift, or a default branch that is not applied' "${OUT_FILE}"
teardown

setup
scheduled_plan
export input_plan_class="unknown"; export input_plan_count_drift="?"; export input_plan_has_pending_changes="?"
export input_plan_complete="?"; export input_plan_count_total="?"
run_step
assert "SC7: counts that cannot be read stay 'Plan not read'" \
  grep -qxF "::warning title=Plan not read::dev — the scheduled plan's changes could not be read; see the plan in the job log" "${OUT_FILE}"
teardown

setup
export input_event_name="push"
export input_plan_class="drift"; export input_plan_count_drift="2"; export input_plan_has_pending_changes="false"
export input_plan_count_total="2"; export input_plan_count_change="2"
run_step
assert "SC8: drift in a push's plan is not warned about: the push applies it" test "$(count_cmd warning)" -eq 0
teardown

setup
scheduled_plan
export input_plan_class="drift"; export input_plan_count_drift="x"; export input_plan_has_pending_changes="false"
export input_plan_count_total="2"; export input_plan_count_change="2"
run_step
assert "SC9: a drift count that is not a number keeps the stopgap's wording" \
  grep -qxF '::warning title=Plan has changes::dev — the scheduled plan has 2 changes (2 to change): drift, or a default branch that is not applied' "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
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
