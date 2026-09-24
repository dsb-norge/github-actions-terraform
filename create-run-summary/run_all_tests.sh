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
# §14 — the outcome invariant, in the two directions the P34 rollup tests
# further down do not reach: a step that failed after terraform printed a
# complete summary line is still not "applied" (its counts render anyway,
# because counts are decoration), and the destroy half of the same rule
# (docs/Apply-and-destroy-reporting.md §14).
# ----------------------------------------------------------------------
setup
write_meta "e" success "2:0:0" "0:10" "$(ops_apply failure true 2 0 0 0:20)"
run_step
assert "§14: exit 1 + a complete summary line → failed, not applied" \
  grep -qxF '**1 environment · 0 applied · 1 failed**' "${GITHUB_STEP_SUMMARY}"
assert "§14: … terraform's counts still render (they are decoration)" row_has e '`💫 2/2`'
assert "§14: … with a ❌ worst outcome" row_has e '| <span title="a step failed or was cancelled">❌</span> |'
teardown

setup
write_meta "e" success "0:0:0" "0:30" "$(ops_apply success true 0 0 0 0:20),$(ops_destroy success false '?' 3 0:40)"
run_step
assert "§14: destroy exit 0 + no summary line → counted as destroyed, '?' cell" \
  bash -c "grep -qxF '**1 environment · 1 applied · 1 destroyed · 0 failed**' '${GITHUB_STEP_SUMMARY}' && grep -qF '| \`💥 ?/3\` |' '${GITHUB_STEP_SUMMARY}'"
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
# R — relevance-file (docs/Path-relevance.md §6.5)
# ----------------------------------------------------------------------
# write_relevance <mode> <reason> <changed-count> <environment:github-environment:verdict>...
write_relevance() {
  local mode="${1}" reason="${2}" changed="${3}"; shift 3
  local entries='[]' spec e ge v
  for spec in "$@"; do
    IFS=':' read -r e ge v <<<"${spec}"
    entries=$(jq -c --arg e "${e}" --arg ge "${ge}" --arg v "${v}" \
      '. + [{"environment": $e, "github-environment": $ge, "verdict": $v,
             "reasons": ["relevance: test"], "add-pr-comment": "true", "pr-comment-group": ""}]' <<<"${entries}")
  done
  jq -n --arg m "${mode}" --arg r "${reason}" --argjson c "${changed}" --argjson envs "${entries}" \
    '{schema_version: 1, relevance: {mode: $m, reason: $r, changed_count: $c},
      counts: {affected: ([$envs[] | select(.verdict == "run")] | length),
               unaffected: ([$envs[] | select(.verdict == "skip")] | length)},
      environments: $envs, comments: {}, notices: [], record: []}' >"${RUNNER_TEMP}/relevance.json"
}
RUN_URL='https://github.com/dsb-norge/test-repo/actions/runs/999'
NA='<span title="not affected">—</span>'
DASH_ROW_TAIL="| ${NA} | ${NA} | ${NA} | ${NA} | ${NA} | ${NA} |"
MISSING_ROW_TAIL="| <span title=\"affected, but its job left no metadata: cancelled, crashed or not uploaded\">❔</span> | — | — | — | — | [run](${RUN_URL}) |"
env_order() { grep -oE '^\| `[a-z0-9-]+`' "${GITHUB_STEP_SUMMARY}" | tr -d '|` ' | tr '\n' ' '; }

# R1 — mixed: one affected, two not; rows keep environments-yml order
setup
write_relevance diff diff 1 prod:prod:skip staging:staging:run sandbox:sandbox:skip
write_meta "staging" success "1:0:0" "0:04" "$(ops_apply success true 1 0 0 1:07)"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R1: exits 0" test "${LAST_EXIT}" -eq 0
assert "R1: headline counts environments, affected, not affected, applied, failed" \
  grep -qxF '**3 environments · 1 affected · 2 not affected · 1 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
assert "R1: relevance line names the mode and the changed-file count (singular)" \
  grep -qxF 'Relevance: `diff`, 1 changed file' "${GITHUB_STEP_SUMMARY}"
assert "R1: rows in environments-yml order, affected and not affected interleaved" \
  test "$(env_order)" = "prod staging sandbox "
assert "R1: an unaffected env is a row of dashes with a 'not affected' tooltip" \
  test "$(row prod)" = "| \`prod\` ${DASH_ROW_TAIL}"
assert "R1: the affected env's row is today's row, byte for byte" \
  test "$(row staging)" = "| \`staging\` | <span title=\"every step that ran succeeded\">✅</span> | \`💫 1\` \`🛠️ 0\` \`💥 0\` | \`💫 1/1\` \`🛠️ 0/0\` \`💥 0/0\` | — | \`1:11\` | [run](${RUN_URL}) |"
assert "R1: a footer line explains the dashed rows" \
  grep -qxF '_Rows of `—`: not affected by this change, so not planned._' "${GITHUB_STEP_SUMMARY}"
assert "R1: no nothing-to-verify line when something is affected" \
  bash -c "! grep -q 'Nothing needed verifying' '${GITHUB_STEP_SUMMARY}'"
assert "R1: environment-count counts every environment, failed-count the failures" \
  bash -c "[ \"\$(grep '^environment-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 3 ] && [ \"\$(grep '^failed-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 0 ]"
unset input_relevance_file
teardown

# R2 — zero affected (a docs-only change): says nothing needed verifying,
# never "No environments", and still lists every environment
setup
write_relevance diff diff 2 prod:prod:skip staging:staging:skip sandbox:sandbox:skip
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R2: exits 0" test "${LAST_EXIT}" -eq 0
assert "R2: headline" \
  grep -qxF '**3 environments · 0 affected · 3 not affected · 0 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
assert "R2: says nothing needed verifying" \
  grep -qxF '_Nothing needed verifying: no environment is affected by this change._' "${GITHUB_STEP_SUMMARY}"
assert "R2: not the no-environments block" bash -c "! grep -q '_No environments' '${GITHUB_STEP_SUMMARY}'"
assert "R2: relevance line (plural)" grep -qxF 'Relevance: `diff`, 2 changed files' "${GITHUB_STEP_SUMMARY}"
assert "R2: three dashed rows in environments-yml order" \
  bash -c "[ \"\$(grep -cF '${DASH_ROW_TAIL}' '${GITHUB_STEP_SUMMARY}')\" = 3 ]" 
assert "R2: … in environments-yml order" test "$(env_order)" = "prod staging sandbox "
assert "R2: environment-count is 3" test "$(get_output environment-count)" = "3"
unset input_relevance_file
teardown

# R3 — mode all: the reason is shown, not the changed-file count
setup
write_relevance all workflow-changed 2 prod:prod:run staging:staging:run
write_meta "prod" failure "0:0:0" "0:10"
write_meta "staging" success "0:0:0" "0:10"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R3: relevance line names the mode and the fail-open reason" \
  grep -qxF 'Relevance: `all` (workflow-changed)' "${GITHUB_STEP_SUMMARY}"
assert "R3: headline" \
  grep -qxF '**2 environments · 2 affected · 0 not affected · 0 applied · 1 failed**' "${GITHUB_STEP_SUMMARY}"
assert "R3: no dashed-row footer when every environment is affected" \
  bash -c "! grep -q 'Rows of' '${GITHUB_STEP_SUMMARY}'"
unset input_relevance_file
teardown

# R4 — a relevance-file that is not on disk (a failed artifact download) or
# is not a relevance document renders exactly as no file at all
render_g1_fixture() {
  write_meta "charlie" success "1:0:0" "0:04" "$(ops_apply success true 1 0 0 1:07)"
  write_meta "alpha"   failure "0:0:0" "9:49"
  write_meta "bravo"   success "2:1:0" "0:30"
}
R4_DIR=$(mktemp -d)
setup
render_g1_fixture
run_step
cp "${GITHUB_STEP_SUMMARY}" "${R4_DIR}/nofile.md"; cp "${GITHUB_OUTPUT}" "${R4_DIR}/nofile.out"
teardown
setup
render_g1_fixture
export input_relevance_file="${RUNNER_TEMP}/does-not-exist/relevance.json"
run_step
assert "R4: missing file → exits 0" test "${LAST_EXIT}" -eq 0
assert "R4: missing file → summary byte-identical to no file" cmp -s "${R4_DIR}/nofile.md" "${GITHUB_STEP_SUMMARY}"
assert "R4: missing file → outputs identical to no file" cmp -s "${R4_DIR}/nofile.out" "${GITHUB_OUTPUT}"
assert "R4: missing file → warned about" grep -q 'relevance file not found' "${OUT_FILE}"
unset input_relevance_file
teardown
setup
render_g1_fixture
echo '{not json' >"${RUNNER_TEMP}/relevance.json"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R4: malformed file → summary byte-identical to no file" cmp -s "${R4_DIR}/nofile.md" "${GITHUB_STEP_SUMMARY}"
assert "R4: malformed file → warned about" grep -q 'not a relevance document' "${OUT_FILE}"
unset input_relevance_file
teardown
setup
export input_relevance_file="${RUNNER_TEMP}/does-not-exist.json"
run_step
assert "R4: missing file and no metadata → today's no-environments block" grep -q '_No environments' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file
teardown
rm -rf "${R4_DIR}"

# R5 — an affected env whose job left no metadata (cancelled or crashed)
# still gets a row, and the headline says so
setup
write_relevance diff diff 3 prod:prod:run staging:staging:run sandbox:sandbox:skip
write_meta "staging" success "0:0:0" "0:10"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R5: the env without metadata still has a row" test "$(row prod)" = "| \`prod\` ${MISSING_ROW_TAIL}"
assert "R5: headline counts it as affected and as not reported, not as failed" \
  grep -qxF '**3 environments · 2 affected · 1 not affected · 0 applied · 0 failed · 1 not reported**' "${GITHUB_STEP_SUMMARY}"
assert "R5: failed-count does not count it" test "$(get_output failed-count)" = "0"
unset input_relevance_file
teardown

# R6 — metadata is keyed by github-environment; the destroyed counter keeps
# its place in the extended headline
setup
write_relevance diff diff 1 prod-app:production:run dev:dev:skip
write_meta "production" success "0:0:0" "0:30" "$(ops_apply success true 0 0 0 0:20),$(ops_destroy success true 3 3 0:40)"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R6: matched on github-environment and labelled by it, as today's rows" row_has production '| `💥 3/3` |'
assert "R6: no row for the environment name" test -z "$(row prod-app)"
assert "R6: headline with the destroyed counter" \
  grep -qxF '**2 environments · 1 affected · 1 not affected · 1 applied · 1 destroyed · 0 failed**' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file
teardown

# R7 — metadata for an env the file does not list is rendered after the
# listed ones and warned about, never dropped
setup
write_relevance diff diff 1 prod:prod:run
write_meta "prod" success "0:0:0" "0:10"
write_meta "stray" failure "0:0:0" "0:10"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R7: the stray env renders after the listed ones" test "$(env_order)" = "prod stray "
assert "R7: warned about" grep -q "stray.*not in the relevance file" "${OUT_FILE}"
assert "R7: headline N/A/U from the file; its failure still counts" \
  grep -qxF '**1 environment · 1 affected · 0 not affected · 0 applied · 1 failed**' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file
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
