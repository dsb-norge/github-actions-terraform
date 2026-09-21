#!/bin/env bash
#
# Tests for step_summary.sh
#
# Fixture metadata files are written into a temp dir; the step is sourced
# in a subshell with GITHUB_STEP_SUMMARY bound to a temp file; assertions
# read that file. (docs/Apply-and-destroy-reporting.md §7.9, §10.5)
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

OUT_FILE=/tmp/test_output_run_summary.txt

setup() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/step-summary.md"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="dsb-norge/test-repo"
  export GITHUB_RUN_ID="999"
  export input_metadata_files_pattern="matrix-job-meta-*.json"
  : >"${GITHUB_STEP_SUMMARY}"
  cd "${RUNNER_TEMP}"
}

teardown() {
  cd /
  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${RUNNER_TEMP}"
}

# write_meta <env> [plan-outcome] [plan-counts a:c:d] [plan-time] [ops-json-fragment]
write_meta() {
  local env="${1}" plan_outcome="${2:-success}" counts="${3:-0:0:0}" plan_time="${4:-}" ops="${5:-}"
  IFS=':' read -r a c d <<<"${counts}"
  local pt=""; [ -n "${plan_time}" ] && pt="\"plan-time\": \"${plan_time}\""
  cat >"${RUNNER_TEMP}/matrix-job-meta-${env}.json" <<JSON
{
  "metadata": {"environment": "${env}", "schema_version": "2.0.0"},
  "workflow": {"run_id": "999"},
  "matrix_context": {"vars": {"goals": ["all"]}},
  "steps": {
    "init": {"outcome": "success", "conclusion": "success", "outputs": {}},
    "plan": {"outcome": "${plan_outcome}", "conclusion": "${plan_outcome}", "outputs": {${pt}}},
    "parse-plan": {"outcome": "success", "conclusion": "success", "outputs": {"count-add": "${a}", "count-change": "${c}", "count-destroy": "${d}"}}${ops:+,${ops}}
  }
}
JSON
}
ops_apply() { # <outcome> <completed> <a> <c> <d> <time>
  printf '"apply": {"outcome":"%s","conclusion":"%s","outputs":{"apply-time":"%s"}},"parse-apply": {"outcome":"success","conclusion":"success","outputs":{"count-add":"%s","count-change":"%s","count-destroy":"%s","completed":"%s"}}' \
    "${1}" "${1}" "${6:-}" "${3:-0}" "${4:-0}" "${5:-0}" "${2:-true}"
}
ops_destroy() { # <outcome> <completed> <d> <planned-d> <time>
  printf '"destroy-plan": {"outcome":"success","conclusion":"success","outputs":{}},"parse-destroy-plan": {"outcome":"success","conclusion":"success","outputs":{"count-destroy":"%s"}},"destroy": {"outcome":"%s","conclusion":"%s","outputs":{"apply-time":"%s"}},"parse-destroy-apply": {"outcome":"success","conclusion":"success","outputs":{"count-destroy":"%s","completed":"%s"}}' \
    "${4:-0}" "${1}" "${1}" "${5:-}" "${3:-0}" "${2:-true}"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_summary.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

get_output() { grep "^${1}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-; }
row() { grep -F "| \`${1}\` |" "${GITHUB_STEP_SUMMARY}" | head -n1; }
# row_has <env> <substring>: called directly by assert so it runs in this
# shell — a `bash -c` child would not see the row() function.
row_has() { local r; r="$(row "${1}")"; [[ "${r}" == *"${2}"* ]] || { echo "  row: ${r}"; return 1; }; }

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

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}        CREATE-RUN-SUMMARY STEP TESTS        ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# G1 + G2 — three envs, mixed outcomes: one row each, alphabetical; headline
# ----------------------------------------------------------------------
setup
write_meta "charlie" success "1:0:0" "0:04" "$(ops_apply success true 1 0 0 1:07)"
write_meta "alpha"   failure "0:0:0" "9:49"
write_meta "bravo"   success "2:1:0" "0:30"
run_step
assert "G1: exits 0" test "${LAST_EXIT}" -eq 0
assert "G1: one row per env" test "$(grep -c '^| `' "${GITHUB_STEP_SUMMARY}")" -eq 3
assert "G1: rows are alphabetical (alpha, bravo, charlie)" \
  bash -c "grep -oE '^\| \`[a-z]+\`' '${GITHUB_STEP_SUMMARY}' | tr -d '|\` ' | tr '\n' ' ' | grep -q '^alpha bravo charlie \$'"
assert "G2: headline counts envs, applied and failed" \
  grep -qxF '**3 environments · 1 applied · 1 failed**' "${GITHUB_STEP_SUMMARY}"
assert "G2: environment-count / failed-count outputs" \
  bash -c "[ \"\$(grep '^environment-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 3 ] && [ \"\$(grep '^failed-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 1 ]"
assert "G1: header row + alignment row present" \
  bash -c "grep -qxF '| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |' '${GITHUB_STEP_SUMMARY}' && grep -qxF '|---|:---:|---|---|---|---|---|' '${GITHUB_STEP_SUMMARY}'"
assert "G1: charlie row is byte-exact (applied env)" \
  test "$(row charlie)" = '| `charlie` | <span title="every step that ran succeeded">✅</span> | `💫 1` `🛠️ 0` `💥 0` | `💫 1/1` `🛠️ 0/0` `💥 0/0` | — | `1:11` | [run](https://github.com/dsb-norge/test-repo/actions/runs/999) |'
assert "G1: alpha row is byte-exact (failed plan, no apply)" \
  test "$(row alpha)" = '| `alpha` | <span title="a step failed or was cancelled">❌</span> | `💫 0` `🛠️ 0` `💥 0` | — | — | `9:49` | [run](https://github.com/dsb-norge/test-repo/actions/runs/999) |'
teardown

# ----------------------------------------------------------------------
# G3 — zero metadata files → "no environments" block, exit 0
# ----------------------------------------------------------------------
setup
run_step
assert "G3: exits 0 with no artifacts" test "${LAST_EXIT}" -eq 0
assert "G3: renders the no-environments block" grep -q '_No environments' "${GITHUB_STEP_SUMMARY}"
assert "G3: still links the run" grep -q '\[Workflow run\](https://github.com/dsb-norge/test-repo/actions/runs/999)' "${GITHUB_STEP_SUMMARY}"
assert "G3: environment-count is 0" test "$(get_output environment-count)" = "0"
teardown

# ----------------------------------------------------------------------
# G4 — malformed file skipped with a warning; others render; exit 0
# ----------------------------------------------------------------------
setup
write_meta "good" success "1:0:0"
echo '{not json' >"${RUNNER_TEMP}/matrix-job-meta-broken.json"
echo '{"metadata": {}}' >"${RUNNER_TEMP}/matrix-job-meta-noenv.json"
run_step
assert "G4: exits 0" test "${LAST_EXIT}" -eq 0
assert "G4: malformed file warned about" grep -q 'skipping malformed metadata file' "${OUT_FILE}"
assert "G4: env-less file warned about" grep -q 'no .metadata.environment' "${OUT_FILE}"
assert "G4: the good env still renders" test -n "$(row good)"
assert "G4: headline counts only the good env" grep -qxF '**1 environment · 0 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
teardown

# ----------------------------------------------------------------------
# G5 — GITHUB_STEP_SUMMARY unset → no crash, exit 0, rendered to the log
# ----------------------------------------------------------------------
setup
write_meta "e" success
unset GITHUB_STEP_SUMMARY
run_step
assert "G5: exits 0 without GITHUB_STEP_SUMMARY" test "${LAST_EXIT}" -eq 0
assert "G5: says so, and still renders to the log" \
  bash -c "grep -q 'GITHUB_STEP_SUMMARY is not set' '${OUT_FILE}' && grep -q '## Terraform run summary' '${OUT_FILE}'"
export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/x.md"
teardown

# ----------------------------------------------------------------------
# G6 — env with no apply → Apply cell '—', not 0/0
# ----------------------------------------------------------------------
setup
write_meta "e" success "0:0:0" "0:10"
run_step
assert "G6: Apply cell is '—' when apply did not run" row_has e '| `💫 0` `🛠️ 0` `💥 0` | — | — |'
teardown

# skipped apply is also '—'
setup
write_meta "e" success "0:0:0" "" '"apply": {"outcome":"skipped","conclusion":"skipped","outputs":{}}'
run_step
assert "G6: skipped apply → '—'" row_has e '| — | — |'
teardown

# ----------------------------------------------------------------------
# P2 — failed apply → '?/N', never '0/N'; counted as failed, not applied
# ----------------------------------------------------------------------
setup
write_meta "e" success "9:0:0" "0:10" "$(ops_apply failure false '?' '?' '?' 2:00)"
run_step
assert "P2: failed apply renders ?/9" row_has e '`💫 ?/9` `🛠️ ?/0` `💥 ?/0`'
assert "P2: worst outcome is ❌ and it counts as failed, not applied" \
  grep -qxF '**1 environment · 0 applied · 1 failed**' "${GITHUB_STEP_SUMMARY}"
rm -f "${RUNNER_TEMP}"/matrix-job-meta-*.json
write_meta "z" success "5:0:0" "" "$(ops_apply failure false 0 0 0)"
run_step
assert "P2: parser zeros + completed=false → still ?/5, never 0/5" row_has z '`💫 ?/5`'
teardown

# ----------------------------------------------------------------------
# Destroy cell and Time sum
# ----------------------------------------------------------------------
setup
write_meta "e" success "0:0:0" "0:30" "$(ops_apply success true 0 0 0 0:20),$(ops_destroy success true 3 3 0:40)"
run_step
assert "Destroy cell renders destroyed/planned" row_has e '| `💥 3/3` |'
assert "Time is the sum of plan+apply+destroy (0:30+0:20+0:40 = 1:30)" row_has e '| `1:30` |'
assert "Headline counts the destroy as well as the apply" \
  grep -qxF '**1 environment · 1 applied · 1 destroyed · 0 failed**' "${GITHUB_STEP_SUMMARY}"
teardown

# A destroy that did not complete is not counted, and the counter stays out of
# the headline entirely when nothing was destroyed.
setup
write_meta "e" success "0:0:0" "0:30" "$(ops_apply success true 1 0 0 0:20),$(ops_destroy failure false 0 3 0:10)"
run_step
assert "Failed destroy is not counted as destroyed" \
  grep -qxF '**1 environment · 1 applied · 1 failed**' "${GITHUB_STEP_SUMMARY}"
teardown

setup
write_meta "e" success "0:0:0" "0:30" "$(ops_apply success true 1 0 0 0:20)"
run_step
assert "No destroy anywhere → no destroyed counter in the headline" \
  grep -qxF '**1 environment · 1 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
teardown

# P34, rollup half: an apply that succeeded but whose output could not be
# parsed still counts as applied. The cell shows '?' because the counts are
# unknown; the headline must not also drop the environment, or the run page
# disagrees with the comment, the tag and the annotation.
setup
write_meta "e" success "0:0:0" "0:30" "$(ops_apply success false '?' '?' '?' 0:20)"
run_step
assert "P34: unparsed-but-successful apply still counts in the headline" \
  grep -qxF '**1 environment · 1 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
assert "P34: ... and its cell still shows the counts as unknown" row_has e '`💫 ?/'
teardown

# A failed apply must not count, even under allow-failing-terraform-operations:
# `outcome` is GitHub's pre-continue-on-error result, so it still reads failure.
setup
write_meta "e" success "0:0:0" "0:30" "$(ops_apply failure false '?' '?' '?' 0:20)"
run_step
assert "a failed apply is never counted as applied" \
  bash -c "! grep -qE '1 applied' '${GITHUB_STEP_SUMMARY}'"
teardown

setup
write_meta "e" success "0:0:0"
run_step
assert "Time is '—' when no invocation recorded a duration" row_has e '| — | [run]'
teardown

# ----------------------------------------------------------------------
# G7 — older artifact without apply keys → renders as no apply, no crash
# ----------------------------------------------------------------------
setup
cat >"${RUNNER_TEMP}/matrix-job-meta-old.json" <<'JSON'
{"metadata": {"environment": "old"}, "workflow": {"run_id": "999"},
 "steps": {"init": {"outcome": "success", "outputs": {}}, "plan": {"outcome": "success", "outputs": {}}}}
JSON
run_step
assert "G7: pre-feature artifact → exits 0" test "${LAST_EXIT}" -eq 0
assert "G7: renders with '—' cells" row_has old '| — | — | — | — | [run]'
teardown

# ----------------------------------------------------------------------
# G8 — 20 envs → well under the 1 MiB cap
# ----------------------------------------------------------------------
setup
for i in $(seq -w 1 20); do write_meta "env-${i}" success "1:1:1" "1:00" "$(ops_apply success true 1 1 1 1:00)"; done
run_step
assert "G8: 20 envs render 20 rows" test "$(grep -c '^| `env-' "${GITHUB_STEP_SUMMARY}")" -eq 20
assert "G8: block far below 1 MiB" test "$(wc -c <"${GITHUB_STEP_SUMMARY}")" -lt 65536
assert "G8: headline" grep -qxF '**20 environments · 20 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
teardown

# Existing summary content is appended to, never truncated.
setup
printf '## Something earlier\n\n' >"${GITHUB_STEP_SUMMARY}"
write_meta "e" success
run_step
assert "existing GITHUB_STEP_SUMMARY content is preserved" \
  bash -c "head -n1 '${GITHUB_STEP_SUMMARY}' | grep -q '^## Something earlier$' && grep -q '## Terraform run summary' '${GITHUB_STEP_SUMMARY}'"
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
