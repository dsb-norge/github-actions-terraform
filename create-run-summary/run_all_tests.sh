#!/bin/env bash
#
# Tests for step_summary.sh
#
# Fixture metadata files are written into a temp dir; the step is sourced
# in a subshell with GITHUB_STEP_SUMMARY bound to a temp file; assertions
# read that file. (docs/Apply-and-destroy-reporting.md §7.9, §10.5)
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
    # As production runs it: GitHub sources the shim under 'bash -eo pipefail', so a failing
    # command the harness would tolerate kills the step there.
    set -eo pipefail
    # As the shim does: stage-results-json is a shell-local captured before allexport, never
    # exported, and empty when the caller passes nothing.
    input_stage_results_json="${STAGE_RESULTS:-}"
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

# R8 — the contract: the relevance.json the engine publishes, not a hand-written one. A key the
# engine renames fails here, where the hand-written files above would stay green.
engine_relevance() {
  python3 -I -B "${_this_script_dir}/../engine/tests/relevance_fixture.py" "${1}" "${RUNNER_TEMP}/relevance.json"
}
setup
engine_relevance docs-only
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R8: exits 0 on the engine's docs-only file" test "${LAST_EXIT}" -eq 0
assert "R8: headline counts the engine's verdicts" \
  grep -qxF '**3 environments · 0 affected · 3 not affected · 0 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
assert "R8: rows labelled by github-environment, in environments-yml order" \
  test "$(env_order)" = "prod-gh staging sandbox "
assert "R8: relevance line from the engine's block" grep -qxF 'Relevance: `diff`, 2 changed files' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file
teardown

setup
engine_relevance one-environment
write_meta "staging" success "0:0:0" "0:10"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R8: one affected environment with its metadata" \
  grep -qxF '**3 environments · 1 affected · 2 not affected · 0 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
staging_row="$(row staging)"
assert "R8: the affected row is rendered from its metadata, not dashed" \
  test -n "${staging_row}" -a "${staging_row%"${DASH_ROW_TAIL}"}" = "${staging_row}"
unset input_relevance_file
teardown

setup
engine_relevance workflow-changed
write_meta "prod-gh" success "0:0:0" "0:10"
write_meta "staging" success "0:0:0" "0:10"
write_meta "sandbox" success "0:0:0" "0:10"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R8: mode all names the engine's reason" grep -qxF 'Relevance: `all` (workflow-changed)' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file
teardown

# R9 — the trigger block: who dispatched what, and a schedule nothing took part in, from the engine's
# own file. Neither run carries a change, so neither says "affected by this change".
setup
engine_relevance dispatch-staging
write_meta "staging" success "0:0:0" "0:10"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R9: the dispatch line is quoted under the relevance line" \
  grep -qxF '> dispatched by octocat: environment staging, goal plan, reason "reconcile after incident 42"' \
  "${GITHUB_STEP_SUMMARY}"
assert "R9: a dispatch does not speak of a change" bash -c "! grep -q 'this change' '${GITHUB_STEP_SUMMARY}'"
assert "R9: the dashed rows are not part of the run" \
  grep -qxF '_Rows of `—`: not part of this run, so not planned._' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file
teardown

setup
engine_relevance schedule-nothing
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R9: exits 0 on a schedule nothing took part in" test "${LAST_EXIT}" -eq 0
assert "R9: the schedule line names the key" \
  grep -qxF "> schedule: no environment takes part in scheduled runs; add 'schedule' to the trigger-events of the environment the schedule is for" \
  "${GITHUB_STEP_SUMMARY}"
assert "R9: no 'nothing needed verifying' on a schedule" bash -c "! grep -q 'Nothing needed verifying' '${GITHUB_STEP_SUMMARY}'"
unset input_relevance_file
teardown

setup
engine_relevance schedule-capped
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R9: exits 0 on a schedule with capped environments" test "${LAST_EXIT}" -eq 0
assert "R9: the schedule line says what each running environment was capped to" \
  grep -qxF "> schedule: goal default for staging; goal plan for prod (schedule-goal, plan where an environment sets none)" \
  "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file
teardown

setup
engine_relevance docs-only
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "R9: a pull request has no trigger line" bash -c "! grep -q '^> ' '${GITHUB_STEP_SUMMARY}'"
assert "R9: and still says nothing needed verifying" grep -q 'Nothing needed verifying' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file
teardown

# ----------------------------------------------------------------------
# O — environment ordering (docs/Environment-ordering.md §7.2): held-back rows, the headline term,
# the ordering footer. The stage results arrive as STAGE_RESULTS, the stage-results-json input.
# ----------------------------------------------------------------------
# staged_entry <environment> <run|skip> [--genv=<github-environment>] [--stage=<n>]
#              [--depends-on=<a,b>] [--goals=<a,b>] [--reason=<text>]...
# One environments[] entry as the engine writes it with ordering: the declared depends-on on every
# entry; on a run entry its stage, the granted goals, and --reason texts between the relevance
# reason and the goals reason.
staged_entry() {
  local env="${1}" verdict="${2}"; shift 2
  local genv="${env}" stage="1" deps="" goals="init,format,validate,lint,plan" extra='[]'
  while [ $# -gt 0 ]; do
    case "${1}" in
      --genv=*) genv="${1#*=}" ;;
      --stage=*) stage="${1#*=}" ;;
      --depends-on=*) deps="${1#*=}" ;;
      --goals=*) goals="${1#*=}" ;;
      --reason=*) extra=$(jq -c --arg r "${1#*=}" '. + [$r]' <<<"${extra}") ;;
    esac
    shift
  done
  jq -nc --arg e "${env}" --arg ge "${genv}" --arg v "${verdict}" --argjson s "${stage}" \
    --arg d "${deps}" --arg g "${goals}" --argjson extra "${extra}" '
    ($d | split(",") | map(select(. != ""))) as $deps
    | ($g | split(",") | map(select(. != ""))) as $goals
    | {"environment": $e, "github-environment": $ge, "verdict": $v, "depends-on": $deps,
       "add-pr-comment": "true", "pr-comment-group": ""}
      + if $v == "run" then
          {"stage": $s, "goals": $goals,
           "reasons": (["relevance: envs/\($e)/**"] + $extra + ["goals: \($goals | join(", "))"])}
        else {"reasons": ["relevance: no changed file matches"]} end'
}
# write_staged_relevance <stages-used> <entry-json>...
# The engine's counts.by_stage from the entries, and `ordering: stage <n>` second on every run
# entry when more than one stage is in use, as the engine writes it.
write_staged_relevance() {
  local used="${1}"; shift
  printf '%s\n' "$@" | jq -s --argjson used "${used}" '
    (if $used > 1 then map(if .verdict == "run" then .stage as $s | .reasons |= (.[:1] + ["ordering: stage \($s)"] + .[1:]) else . end)
     else . end) as $envs
    | def in_stage($n): [$envs[] | select(.verdict == "run" and .stage == $n)] | length;
    {schema_version: 1, relevance: {mode: "diff", reason: "diff", changed_count: 3},
     ordering: {declared: true, stages_used: $used, cap: 3, bypass: null},
     counts: {affected: ([$envs[] | select(.verdict == "run")] | length),
              unaffected: ([$envs[] | select(.verdict == "skip")] | length),
              by_stage: {"1": in_stage(1), "2": in_stage(2), "3": in_stage(3)}},
     environments: $envs, comments: {}, notices: [], record: []}' >"${RUNNER_TEMP}/relevance.json"
  export input_relevance_file="${RUNNER_TEMP}/relevance.json"
}
# A metadata file's row under allow-failing-terraform-operations, a JSON boolean as the engine writes it.
allow_failing() {
  local f="${RUNNER_TEMP}/matrix-job-meta-${1}.json"
  jq '.matrix_context.vars["allow-failing-terraform-operations"] = true' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
}
HELD_BY_FAILURE='<span title="held back: stage 2; stage 1 failed">⏭️</span>'
ordering_lines() { grep -c '^_Ordering:' "${GITHUB_STEP_SUMMARY}"; }
# The ordering line, whole; empty when there is none.
ordering_line() { grep '^_Ordering:' "${GITHUB_STEP_SUMMARY}" || true; }

# The §7.2 run: shared failed in stage 1, so stage 2 (prod, which depends on it, and sandbox, a
# free-standing environment in the last stage) never ran
held_back_fixture() {
  write_staged_relevance 2 \
    "$(staged_entry shared run --stage=1 --goals=init,format,validate,lint,plan,apply)" \
    "$(staged_entry prod run --stage=2 --depends-on=shared --goals=init,format,validate,lint,plan,apply)" \
    "$(staged_entry sandbox run --stage=2 --goals=init,format,validate,lint,plan,apply)"
  write_meta "shared" success "2:0:0" "0:54" "$(ops_apply failure false '?' '?' '?' 0:20)"
}

# O1 — a held-back row, the headline term and the footer, byte for byte
setup
held_back_fixture
STAGE_RESULTS='{"1": "failure", "2": "skipped", "3": "skipped"}'
run_step
assert "O1: exits 0" test "${LAST_EXIT}" -eq 0
assert "O1: headline counts the held-back environments, not as failed or not reported" \
  grep -qxF '**3 environments · 3 affected · 0 not affected · 0 applied · 2 held back · 1 failed**' "${GITHUB_STEP_SUMMARY}"
assert "O1: a held-back row is the held-back outcome and dashes, byte for byte" \
  test "$(row prod)" = "| \`prod\` | ${HELD_BY_FAILURE} | — | — | — | — | — |"
assert "O1: … for every environment of the stage" \
  test "$(row sandbox)" = "| \`sandbox\` | ${HELD_BY_FAILURE} | — | — | — | — | — |"
assert "O1: the environment that failed renders from its metadata" \
  row_has shared '| <span title="a step failed or was cancelled">❌</span> | `💫 2` `🛠️ 0` `💥 0` | `💫 ?/2`'
assert "O1: the footer lists the stages, then names the failed stage and the held-back environments, in environments-yml order" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`, `sandbox`. Stage 1 failed, so stage 2 did not run. Held back: `prod`, `sandbox`._'
assert "O1: one ordering line, directly below the table" \
  bash -c "[ \"\$(grep -c '^_Ordering:' '${GITHUB_STEP_SUMMARY}')\" = 1 ] && grep -A2 -F '| \`sandbox\` |' '${GITHUB_STEP_SUMMARY}' | tail -n1 | grep -q '^_Ordering:'"
assert "O1: environment-count counts every environment, failed-count only the failure" \
  bash -c "[ \"\$(grep '^environment-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 3 ] && [ \"\$(grep '^failed-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 1 ]"
unset input_relevance_file STAGE_RESULTS
teardown

# O2 — held back told apart from crashed: an affected environment without metadata in a stage that
# ran is today's ❔ row, not reported, never held back
setup
held_back_fixture
write_meta "shared" success "0:0:0" "0:10" "$(ops_apply success true 0 0 0 0:20)"
write_meta "sandbox" success "0:0:0" "0:10"
STAGE_RESULTS='{"1": "success", "2": "failure", "3": "skipped"}'
run_step
assert "O2: the environment that left no metadata in a stage that ran is the ❔ row" \
  test "$(row prod)" = "| \`prod\` ${MISSING_ROW_TAIL}"
assert "O2: headline counts it as not reported, and nothing as held back" \
  grep -qxF '**3 environments · 3 affected · 0 not affected · 1 applied · 0 failed · 1 not reported**' "${GITHUB_STEP_SUMMARY}"
assert "O2: nothing held back or failed in ordering's terms: the listing stands alone" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`, `sandbox`._'
unset input_relevance_file STAGE_RESULTS
teardown

# O3 — held back told apart from an empty stage: stage 3 skipped with no environment in it holds
# nothing back, and a cancelled stage is named as cancelled
setup
write_staged_relevance 2 \
  "$(staged_entry shared run --stage=1)" \
  "$(staged_entry prod run --stage=2 --depends-on=shared)"
STAGE_RESULTS='{"1": "cancelled", "2": "skipped", "3": "skipped"}'
run_step
assert "O3: a cancelled stage is named in the tooltip" \
  test "$(row prod)" = '| `prod` | <span title="held back: stage 2; stage 1 was cancelled">⏭️</span> | — | — | — | — | — |'
assert "O3: … and in the footer; the empty stage 3 is not mentioned" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`. Stage 1 was cancelled, so stage 2 did not run. Held back: `prod`._'
assert "O3: the cancelled environment without metadata is still the ❔ row" \
  test "$(row shared)" = "| \`shared\` ${MISSING_ROW_TAIL}"
assert "O3: headline" \
  grep -qxF '**2 environments · 2 affected · 0 not affected · 0 applied · 1 held back · 0 failed · 1 not reported**' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file STAGE_RESULTS
teardown

# O4 — three stages: a failure in stage 1 holds back both later stages, and one held back by stage
# 2's failure names stage 2
setup
write_staged_relevance 3 \
  "$(staged_entry hub run --stage=1)" \
  "$(staged_entry spoke run --stage=2 --depends-on=hub)" \
  "$(staged_entry app run --stage=3 --depends-on=spoke)"
write_meta "hub" failure "0:0:0" "0:10"
STAGE_RESULTS='{"1": "failure", "2": "skipped", "3": "skipped"}'
run_step
assert "O4: stage 3 names stage 1, the lowest failed stage, not the skipped stage 2" \
  test "$(row app)" = '| `app` | <span title="held back: stage 3; stage 1 failed">⏭️</span> | — | — | — | — | — |'
assert "O4: three stages listed in order, then one sentence for both held-back stages" \
  test "$(ordering_line)" = '_Ordering: 3 stages. Stage 1: `hub`. Stage 2: `spoke`. Stage 3: `app`. Stage 1 failed, so stages 2 and 3 did not run. Held back: `spoke`, `app`._'
rm -f "${RUNNER_TEMP}"/matrix-job-meta-*.json
write_meta "hub" success "0:0:0" "0:10"
write_meta "spoke" failure "0:0:0" "0:10"
: >"${GITHUB_STEP_SUMMARY}"
STAGE_RESULTS='{"1": "success", "2": "failure", "3": "skipped"}'
run_step
assert "O4: held back by stage 2" \
  test "$(row app)" = '| `app` | <span title="held back: stage 3; stage 2 failed">⏭️</span> | — | — | — | — | — |'
assert "O4: … and the footer says so" \
  test "$(ordering_line)" = '_Ordering: 3 stages. Stage 1: `hub`. Stage 2: `spoke`. Stage 3: `app`. Stage 2 failed, so stage 3 did not run. Held back: `app`._'
: >"${GITHUB_STEP_SUMMARY}"
STAGE_RESULTS='{"1": "failure", "2": "cancelled", "3": "skipped"}'
run_step
assert "O4: what held a stage back is the lowest earlier stage that failed or was cancelled" \
  test "$(row app)" = '| `app` | <span title="held back: stage 3; stage 1 failed">⏭️</span> | — | — | — | — | — |'
unset input_relevance_file STAGE_RESULTS
teardown

# O4b — a skipped stage the builder counts no environment in holds nothing back, whatever an
# entry says: its matrix was empty, so the entry's job never existed and it is not reported
setup
write_staged_relevance 2 \
  "$(staged_entry shared run --stage=1)" \
  "$(staged_entry prod run --stage=2 --depends-on=shared)"
jq '.counts.by_stage["2"] = 0' "${RUNNER_TEMP}/relevance.json" >"${RUNNER_TEMP}/x.json" && mv "${RUNNER_TEMP}/x.json" "${RUNNER_TEMP}/relevance.json"
write_meta "shared" failure "0:0:0" "0:10"
STAGE_RESULTS='{"1": "failure", "2": "skipped", "3": "skipped"}'
run_step
assert "O4b: a stage with a row count of 0 holds nothing back" test "$(row prod)" = "| \`prod\` ${MISSING_ROW_TAIL}"
unset input_relevance_file STAGE_RESULTS
teardown

# O5 — a skipped stage with nothing before it that failed (a run cancelled between stages): held
# back all the same, without a cause the results cannot give
setup
write_staged_relevance 2 \
  "$(staged_entry shared run --stage=1)" \
  "$(staged_entry prod run --stage=2 --depends-on=shared)"
write_meta "shared" success "0:0:0" "0:10"
STAGE_RESULTS='{"1": "success", "2": "skipped", "3": "skipped"}'
run_step
assert "O5: the tooltip names the stage only" \
  test "$(row prod)" = '| `prod` | <span title="held back: stage 2">⏭️</span> | — | — | — | — | — |'
assert "O5: the footer says the stage did not run" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`. Stage 2 did not run. Held back: `prod`._'
unset input_relevance_file STAGE_RESULTS
teardown

# O6 — a declared dependency that was not in the run (§7.2, §8): named for an environment granted
# apply, with the engine's reason for leaving the dependency out and the environment's label
setup
write_staged_relevance 2 \
  "$(staged_entry shared skip --genv=shared-gh)" \
  "$(staged_entry net run --stage=1)" \
  "$(staged_entry prod run --genv=prod-gh --stage=1 --depends-on=shared --goals=init,format,validate,lint,plan,apply \
      --reason="ordering: depends-on 'shared' not in this run (relevance: no changed file matches)")" \
  "$(staged_entry app run --stage=2 --depends-on=net)"
write_meta "net" success "0:0:0" "0:10"
write_meta "prod-gh" success "1:0:0" "0:10" "$(ops_apply success true 1 0 0 0:20)"
write_meta "app" success "0:0:0" "0:10"
STAGE_RESULTS='{"1": "success", "2": "success", "3": "skipped"}'
run_step
assert "O6: the dependency line, labelled by github-environment" \
  test "$(ordering_line)" = "_Ordering: 2 stages. Stage 1: \`net\`, \`prod-gh\`. Stage 2: \`app\`. \`prod-gh\` applied; its dependency \`shared-gh\` was not in this run (relevance: no changed file matches)._"
assert "O6: no held-back term in the headline when nothing was held back" \
  grep -qxF '**4 environments · 3 affected · 1 not affected · 1 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file STAGE_RESULTS
teardown

# O7 — §8's own case: one stage, because relevance left the dependency out. The line is the only
# warning an operator gets, so it is not dropped with the stages; a plan-only environment, which
# changed nothing, is not named
setup
write_staged_relevance 1 \
  "$(staged_entry shared skip)" \
  "$(staged_entry prod run --stage=1 --depends-on=shared --goals=init,format,validate,lint,plan,apply \
      --reason="ordering: depends-on 'shared' not in this run (relevance: no changed file matches)")" \
  "$(staged_entry audit run --stage=1 --depends-on=shared \
      --reason="ordering: depends-on 'shared' not in this run (relevance: no changed file matches)")" \
  "$(staged_entry gone run --stage=1 --depends-on=shared --goals=init,plan,destroy-plan,destroy \
      --reason="ordering: depends-on 'shared' not in this run (relevance: no changed file matches)")"
write_meta "prod" success "0:0:0" "0:10" "$(ops_apply failure false '?' '?' '?' 0:20)"
write_meta "audit" success "0:0:0" "0:10"
write_meta "gone" success "0:0:0" "0:10" "$(ops_destroy success true 1 1 0:10)"
STAGE_RESULTS='{"1": "success", "2": "skipped", "3": "skipped"}'
run_step
assert "O7: one stage in the prefix; an apply that did not succeed 'ran', a destroy 'destroyed'" \
  grep -qxF "_Ordering: 1 stage. \`prod\` ran; its dependency \`shared\` was not in this run (relevance: no changed file matches). \`gone\` destroyed; its dependency \`shared\` was not in this run (relevance: no changed file matches)._" "${GITHUB_STEP_SUMMARY}"
assert "O7: the plan-only environment is not named" bash -c "! grep '^_Ordering:' '${GITHUB_STEP_SUMMARY}' | grep -q audit"
assert "O7: one stage lists no stages" bash -c "! grep '^_Ordering:' '${GITHUB_STEP_SUMMARY}' | grep -q 'Stage 1:'"
unset input_relevance_file STAGE_RESULTS
teardown

# O8 — a tolerated failure that released the next stage (D5, P10)
setup
write_staged_relevance 2 \
  "$(staged_entry shared run --stage=1 --goals=init,format,validate,lint,plan,apply)" \
  "$(staged_entry net run --stage=1)" \
  "$(staged_entry prod run --stage=2 --depends-on=shared --goals=init,format,validate,lint,plan,apply)"
write_meta "shared" success "1:0:0" "0:10" "$(ops_apply failure false '?' '?' '?' 0:20)"
allow_failing shared
write_meta "net" success "0:0:0" "0:10"
write_meta "prod" success "1:0:0" "0:10" "$(ops_apply success true 1 0 0 0:20)"
STAGE_RESULTS='{"1": "success", "2": "success", "3": "skipped"}'
run_step
assert "O8: the release is named, with the environment that failed under the flag" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`, `net`. Stage 2: `prod`. Stage 1 released stage 2; `shared` failed but allows failing operations._'
assert "O8: the tolerated failure still counts as failed" \
  grep -qxF '**3 environments · 3 affected · 0 not affected · 1 applied · 1 failed**' "${GITHUB_STEP_SUMMARY}"
allow_failing net
jq '.steps.plan.outcome = "failure"' "${RUNNER_TEMP}/matrix-job-meta-net.json" >"${RUNNER_TEMP}/x.json" && mv "${RUNNER_TEMP}/x.json" "${RUNNER_TEMP}/matrix-job-meta-net.json"
: >"${GITHUB_STEP_SUMMARY}"
run_step
assert "O8: several are listed, with the plural verb" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`, `net`. Stage 2: `prod`. Stage 1 released stage 2; `shared`, `net` failed but allow failing operations._'
unset input_relevance_file STAGE_RESULTS
teardown

# O9 — a failure the flag does not tolerate, or one in the last stage, releases nothing
setup
write_staged_relevance 2 \
  "$(staged_entry shared run --stage=1)" \
  "$(staged_entry prod run --stage=2 --depends-on=shared)"
write_meta "shared" success "0:0:0" "0:10"
write_meta "prod" failure "0:0:0" "0:10"
allow_failing prod
STAGE_RESULTS='{"1": "success", "2": "success", "3": "skipped"}'
run_step
assert "O9: a tolerated failure in the last stage released nothing: the listing alone" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`._'
rm -f "${RUNNER_TEMP}"/matrix-job-meta-*.json
write_meta "shared" failure "0:0:0" "0:10"
write_meta "prod" success "0:0:0" "0:10"
: >"${GITHUB_STEP_SUMMARY}"
run_step
assert "O9: a failure without allow-failing-terraform-operations is not named as tolerated" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`._'
allow_failing shared
: >"${GITHUB_STEP_SUMMARY}"
rm -f "${RUNNER_TEMP}/matrix-job-meta-prod.json"
STAGE_RESULTS='{"1": "success", "2": "skipped", "3": "skipped"}'
run_step
assert "O9: a stage that did not run was released by nothing" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`. Stage 2 did not run. Held back: `prod`._'
unset input_relevance_file STAGE_RESULTS
teardown

# O9b — a held-back environment did nothing, so its missing dependency is not named; the held-back
# sentence says all there is
setup
write_staged_relevance 2 \
  "$(staged_entry legacy skip)" \
  "$(staged_entry shared run --stage=1)" \
  "$(staged_entry prod run --stage=2 --depends-on=shared,legacy --goals=init,format,validate,lint,plan,apply \
      --reason="ordering: depends-on 'legacy' not in this run (relevance: no changed file matches)")"
write_meta "shared" failure "0:0:0" "0:10"
STAGE_RESULTS='{"1": "failure", "2": "skipped", "3": "skipped"}'
run_step
assert "O9b: only the held-back sentence" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`. Stage 1 failed, so stage 2 did not run. Held back: `prod`._'
unset input_relevance_file STAGE_RESULTS
teardown

# O10 — an ordered run where nothing went wrong says nothing about ordering, and an environment
# with metadata renders from it whatever its stage's result says
setup
held_back_fixture
write_meta "shared" success "0:0:0" "0:10" "$(ops_apply success true 0 0 0 0:20)"
write_meta "prod" success "0:0:0" "0:10" "$(ops_apply success true 0 0 0 0:20)"
write_meta "sandbox" success "0:0:0" "0:10" "$(ops_apply success true 0 0 0 0:20)"
STAGE_RESULTS='{"1": "success", "2": "success", "3": "skipped"}'
run_step
assert "O10: a clean ordered run has the listing alone, below the table" \
  test "$(ordering_line)" = '_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`, `sandbox`._'
assert "O10: … and today's headline" \
  grep -qxF '**3 environments · 3 affected · 0 not affected · 3 applied · 0 failed**' "${GITHUB_STEP_SUMMARY}"
: >"${GITHUB_STEP_SUMMARY}"
STAGE_RESULTS='{"1": "failure", "2": "skipped", "3": "skipped"}'
run_step
assert "O10: metadata wins over a skipped stage: not held back" \
  bash -c "! grep -q 'held back' '${GITHUB_STEP_SUMMARY}'"
unset input_relevance_file STAGE_RESULTS
teardown

# O11 — without the stage results (absent, empty, or not an object of results), and with every
# environment in stage 1, the summary is byte for byte today's
O11_DIR=$(mktemp -d)
setup
held_back_fixture
run_step
cp "${GITHUB_STEP_SUMMARY}" "${O11_DIR}/absent.md"; cp "${GITHUB_OUTPUT}" "${O11_DIR}/absent.out"
unset input_relevance_file
teardown
assert "O11: absent → a held-back-shaped run renders today's ❔ rows" \
  grep -qF "| \`prod\` ${MISSING_ROW_TAIL}" "${O11_DIR}/absent.md"
assert "O11: absent → nothing about ordering" bash -c "! grep -qE 'Ordering|held back' '${O11_DIR}/absent.md'"
for o11_value in '' ' ' '{not json' '["failure"]' '"failure"'; do
  setup
  held_back_fixture
  STAGE_RESULTS="${o11_value}"
  run_step
  assert "O11: stage results '${o11_value}' → summary byte-identical to absent" cmp -s "${O11_DIR}/absent.md" "${GITHUB_STEP_SUMMARY}"
  assert "O11: stage results '${o11_value}' → outputs identical to absent" cmp -s "${O11_DIR}/absent.out" "${GITHUB_OUTPUT}"
  unset input_relevance_file STAGE_RESULTS
  teardown
done
for o11_value in '{not json' '["failure"]' '"failure"'; do
  setup
  held_back_fixture
  STAGE_RESULTS="${o11_value}"
  run_step
  assert "O11: the unusable value '${o11_value}' is warned about" grep -q 'stage-results-json is not a JSON object' "${OUT_FILE}"
  unset input_relevance_file STAGE_RESULTS
  teardown
done
# The unordered caller: every environment in stage 1, stages 2 and 3 skipped for being empty, and a
# stage-1 failure holds nothing back
setup
write_staged_relevance 1 \
  "$(staged_entry prod skip)" \
  "$(staged_entry staging run --stage=1)" \
  "$(staged_entry sandbox run --stage=1)"
write_meta "staging" failure "0:0:0" "0:10"
run_step
cp "${GITHUB_STEP_SUMMARY}" "${O11_DIR}/stage1.md"
for o11_value in '{"1": "success", "2": "skipped", "3": "skipped"}' '{"1": "failure", "2": "skipped", "3": "skipped"}' \
  '{"1": "skipped", "2": "skipped", "3": "skipped"}'; do
  : >"${GITHUB_STEP_SUMMARY}"
  STAGE_RESULTS="${o11_value}"
  run_step
  assert "O11: everything in stage 1, results ${o11_value} → byte-identical to absent" cmp -s "${O11_DIR}/stage1.md" "${GITHUB_STEP_SUMMARY}"
done
unset input_relevance_file STAGE_RESULTS
teardown
# The unordered caller with today's relevance file, which has no stages at all
setup
write_relevance diff diff 1 prod:prod:skip staging:staging:run sandbox:sandbox:run
write_meta "staging" success "1:0:0" "0:04" "$(ops_apply success true 1 0 0 1:07)"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
cp "${GITHUB_STEP_SUMMARY}" "${O11_DIR}/unordered.md"
: >"${GITHUB_STEP_SUMMARY}"
STAGE_RESULTS='{"1": "success", "2": "skipped", "3": "skipped"}'
run_step
assert "O11: an unordered caller's summary is byte-identical with the stage results" cmp -s "${O11_DIR}/unordered.md" "${GITHUB_STEP_SUMMARY}"
unset input_relevance_file STAGE_RESULTS
teardown
# Without a relevance file there is nothing to join the results with
setup
render_g1_fixture
run_step
cp "${GITHUB_STEP_SUMMARY}" "${O11_DIR}/nofile.md"
: >"${GITHUB_STEP_SUMMARY}"
STAGE_RESULTS='{"1": "failure", "2": "skipped", "3": "skipped"}'
run_step
assert "O11: no relevance file → byte-identical with the stage results" cmp -s "${O11_DIR}/nofile.md" "${GITHUB_STEP_SUMMARY}"
unset STAGE_RESULTS
teardown
rm -rf "${O11_DIR}"

# ----------------------------------------------------------------------
# A — Dependabot admission (docs/Dependabot-admission.md §7): a refused pull request's admission
# section and nothing-ran line; every other run as before
# ----------------------------------------------------------------------
# with_admission <block-json> [<reason>]: set relevance.json's admission block and, with a reason,
# make it the only reason of every skipped environment, as rule 3a writes it.
with_admission() {
  jq --argjson a "${1}" --arg r "${2:-}" \
    '.admission = $a | if $r == "" then . else .environments |= map(if .verdict == "skip" then .reasons = [$r] else . end) end' \
    "${RUNNER_TEMP}/relevance.json" >"${RUNNER_TEMP}/x.json" && mv "${RUNNER_TEMP}/x.json" "${RUNNER_TEMP}/relevance.json"
}
# A refused grouped pull request: a provider that passes, one failing two checks, a module failing
# one, and a change that is not a dependency version.
A_REFUSED='{"applies": true, "admitted": false, "push_run": false, "refused_count": 2, "total": 3,
  "dependencies": [
    {"kind": "provider", "address": "registry.terraform.io/hashicorp/azurerm", "from": "4.41.0", "to": "4.42.0",
     "files": ["envs/dev/.terraform.lock.hcl", "envs/prod/.terraform.lock.hcl"], "admitted": true,
     "checks": [{"check": "host", "ok": true, "detail": "registry.terraform.io"},
                {"check": "allow", "ok": true, "detail": "`hashicorp` is on the allow list"},
                {"check": "age", "ok": true, "detail": "published 9 days ago"},
                {"check": "key", "ok": true, "detail": "signed with `34365D9472D7468F`, as the base version"},
                {"check": "hashes", "ok": true, "detail": "every `zh:` hash is in the publisher'"'"'s checksums"}]},
    {"kind": "provider", "address": "registry.terraform.io/cyrilgdn/postgresql", "from": "1.25.0", "to": "1.26.0",
     "files": ["envs/prod/.terraform.lock.hcl"], "admitted": false,
     "checks": [{"check": "host", "ok": true, "detail": "registry.terraform.io"},
                {"check": "allow", "ok": false, "detail": "`cyrilgdn` is not on the allow list"},
                {"check": "age", "ok": false, "detail": "published 1 day ago; the minimum is 3 days, reached at 2026-10-04 12:00 UTC"},
                {"check": "key", "ok": true, "detail": "signed with `5F4D2B9A1C3E7D60`, as the base version"},
                {"check": "hashes", "ok": true, "detail": "every `zh:` hash is in the publisher'"'"'s checksums"}]},
    {"kind": "module", "address": "Azure/naming/azurerm", "from": "0.4.3", "to": "0.4.4",
     "files": ["main/naming.tf"], "admitted": false,
     "checks": [{"check": "source", "ok": true, "detail": "registry module"},
                {"check": "allow", "ok": true, "detail": "`Azure` is on the allow list"},
                {"check": "age", "ok": false, "detail": "published 1 day ago; the minimum is 3 days, reached at 2026-10-04 12:00 UTC"}]}],
  "problems": [{"check": "shape", "detail": "`main/versions.tf`: a change outside a version: `count = 1` → `count = 2`"}]}'
A_ADMITTED='{"applies": true, "admitted": true, "push_run": false, "refused_count": 0, "total": 1, "problems": [],
  "dependencies": [{"kind": "provider", "address": "registry.terraform.io/hashicorp/azurerm", "from": "4.41.0", "to": "4.42.0",
    "files": ["envs/dev/.terraform.lock.hcl"], "admitted": true,
    "checks": [{"check": "allow", "ok": true, "detail": "`hashicorp` is on the allow list"}]}]}'
A_PUSH_RUN='{"applies": true, "admitted": true, "push_run": true, "dependencies": [], "problems": [], "refused_count": 0, "total": 0}'
A_NOT_APPLYING='{"applies": false}'
# The row of an environment the admission refused: every cell the aggregator's not-admitted cell.
NADM='<span title="not admitted: the Dependabot admission refused this pull request">🚫</span>'
NADM_ROW_TAIL="| ${NADM} | ${NADM} | ${NADM} | ${NADM} | ${NADM} | ${NADM} |"

# A1 — refused: the nothing-ran line in place of nothing-needed-verifying, then the admission
# section, then the environments, each refused one a row of 🚫 counted as not admitted, never as
# not affected, and explained by its own footer line. The whole summary, byte for byte.
setup
write_relevance diff diff 2 prod:prod:skip staging:staging:skip sandbox:sandbox:skip
with_admission "${A_REFUSED}" "admission: not admitted"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
cat >"${RUNNER_TEMP}/expected.md" <<EXPECTED
## Terraform run summary

**3 environments · 0 affected · 0 not affected · 3 not admitted · 0 applied · 0 failed**

_Nothing ran: the Dependabot admission refused this pull request._

### 🚫 Dependabot pull request not admitted

No Terraform ran: the Dependabot admission refused this pull request. The pull request's admission comment says what to do.

| Dependency | Change | Result |
|---|---|---|
| provider \`hashicorp/azurerm\` | 4.41.0 → 4.42.0 | ✅ admitted |
| provider \`cyrilgdn/postgresql\` | 1.25.0 → 1.26.0 | ❌ \`cyrilgdn\` is not on the allow list; published 1 day ago; the minimum is 3 days, reached at 2026-10-04 12:00 UTC |
| module \`Azure/naming/azurerm\` | 0.4.3 → 0.4.4 | ❌ published 1 day ago; the minimum is 3 days, reached at 2026-10-04 12:00 UTC |
| the change | — | ❌ \`main/versions.tf\`: a change outside a version: \`count = 1\` → \`count = 2\` |

Relevance: \`diff\`, 2 changed files

| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |
|---|:---:|---|---|---|---|---|
| \`prod\` ${NADM_ROW_TAIL}
| \`staging\` ${NADM_ROW_TAIL}
| \`sandbox\` ${NADM_ROW_TAIL}

_Plan / Apply / Destroy: \`💫\` added \`🛠️\` changed \`💥\` destroyed; apply and destroy cells are applied/planned, \`?\` when the operation did not complete. Time is the sum of the env's terraform invocations._

_Rows of 🚫: the Dependabot admission refused this pull request, so nothing ran._

EXPECTED
assert "A1: exits 0" test "${LAST_EXIT}" -eq 0
assert "A1: the refused run's summary, byte for byte" diff "${RUNNER_TEMP}/expected.md" "${GITHUB_STEP_SUMMARY}"
assert "A1: environment-count / failed-count as for any run" \
  bash -c "[ \"\$(grep '^environment-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 3 ] && [ \"\$(grep '^failed-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 0 ]"
unset input_relevance_file
teardown

# A2 — a relevance file without the block (one from before the admission), and with it not
# applying, admitted, or a Dependabot push run: no section, byte-identical to the file without it.
# The push run keeps "nothing needed verifying", as for any run with no affected environment.
A2_DIR=$(mktemp -d)
for a2_case in nothing-affected one-affected; do
  setup
  if [ "${a2_case}" = 'nothing-affected' ]; then
    write_relevance diff diff 2 prod:prod:skip staging:staging:skip sandbox:sandbox:skip
  else
    write_relevance diff diff 1 prod:prod:skip staging:staging:run sandbox:sandbox:skip
    write_meta "staging" success "1:0:0" "0:04" "$(ops_apply success true 1 0 0 1:07)"
  fi
  export input_relevance_file="${RUNNER_TEMP}/relevance.json"
  run_step
  cp "${GITHUB_STEP_SUMMARY}" "${A2_DIR}/without.md"; cp "${GITHUB_OUTPUT}" "${A2_DIR}/without.out"
  for a2_block in A_NOT_APPLYING A_ADMITTED A_PUSH_RUN; do
    : >"${GITHUB_STEP_SUMMARY}"; : >"${GITHUB_OUTPUT}"
    if [ "${a2_block}" = 'A_PUSH_RUN' ]; then
      with_admission "${!a2_block}" "admission: Dependabot push run"
    else
      with_admission "${!a2_block}"
    fi
    run_step
    assert "A2: ${a2_case}, ${a2_block} → summary byte-identical to no admission block" \
      cmp -s "${A2_DIR}/without.md" "${GITHUB_STEP_SUMMARY}"
    assert "A2: ${a2_case}, ${a2_block} → outputs identical" cmp -s "${A2_DIR}/without.out" "${GITHUB_OUTPUT}"
  done
  # The last block rendered is the push run's.
  assert "A2: ${a2_case}, no admission section" bash -c "! grep -q 'not admitted' '${GITHUB_STEP_SUMMARY}'"
  if [ "${a2_case}" = 'nothing-affected' ]; then
    assert "A2: the push run still says nothing needed verifying" \
      grep -qxF '_Nothing needed verifying: no environment is affected by this change._' "${GITHUB_STEP_SUMMARY}"
  fi
  unset input_relevance_file
  teardown
done
rm -rf "${A2_DIR}"

# A3 — a refused block jq cannot read leaves the section out with a warning, never half a table
# and never the step failed; the nothing-ran line stays, since the engine did refuse.
setup
write_relevance diff diff 2 prod:prod:skip staging:staging:skip
with_admission '{"applies": true, "admitted": false, "push_run": false, "dependencies": "not a list", "problems": []}' "admission: not admitted"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
assert "A3: exits 0" test "${LAST_EXIT}" -eq 0
assert "A3: warned about" grep -q 'admission block .* could not be read' "${OUT_FILE}"
assert "A3: no section, no table" bash -c "! grep -qE 'Dependabot pull request not admitted|\\| Dependency \\|' '${GITHUB_STEP_SUMMARY}'"
assert "A3: the nothing-ran line" \
  grep -qxF '_Nothing ran: the Dependabot admission refused this pull request._' "${GITHUB_STEP_SUMMARY}"
assert "A3: the environments still render" test "$(row staging)" = "| \`staging\` ${NADM_ROW_TAIL}"
unset input_relevance_file
teardown

# A4 — a refused run whose environments are not all refused: one trigger-events dropped before the
# admission ruled keeps today's not-affected row and footer line; each kind is counted and explained
# on its own. The whole summary, byte for byte.
setup
write_relevance diff diff 1 prod:prod:skip staging:staging:skip
with_admission '{"applies": true, "admitted": false, "push_run": false, "refused_count": 1, "total": 1, "problems": [],
  "dependencies": [{"kind": "provider", "address": "registry.terraform.io/cyrilgdn/postgresql", "from": "1.25.0", "to": "1.26.0",
    "files": ["envs/prod/.terraform.lock.hcl"], "admitted": false,
    "checks": [{"check": "allow", "ok": false, "detail": "`cyrilgdn` is not on the allow list"}]}]}' "admission: not admitted"
jq '.environments |= map(if .environment == "staging" then .reasons = ["trigger-events: pull_request not enabled"] else . end)' \
  "${RUNNER_TEMP}/relevance.json" >"${RUNNER_TEMP}/x.json" && mv "${RUNNER_TEMP}/x.json" "${RUNNER_TEMP}/relevance.json"
export input_relevance_file="${RUNNER_TEMP}/relevance.json"
run_step
cat >"${RUNNER_TEMP}/expected.md" <<EXPECTED
## Terraform run summary

**2 environments · 0 affected · 1 not affected · 1 not admitted · 0 applied · 0 failed**

_Nothing ran: the Dependabot admission refused this pull request._

### 🚫 Dependabot pull request not admitted

No Terraform ran: the Dependabot admission refused this pull request. The pull request's admission comment says what to do.

| Dependency | Change | Result |
|---|---|---|
| provider \`cyrilgdn/postgresql\` | 1.25.0 → 1.26.0 | ❌ \`cyrilgdn\` is not on the allow list |

Relevance: \`diff\`, 1 changed file

| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |
|---|:---:|---|---|---|---|---|
| \`prod\` ${NADM_ROW_TAIL}
| \`staging\` ${DASH_ROW_TAIL}

_Plan / Apply / Destroy: \`💫\` added \`🛠️\` changed \`💥\` destroyed; apply and destroy cells are applied/planned, \`?\` when the operation did not complete. Time is the sum of the env's terraform invocations._

_Rows of 🚫: the Dependabot admission refused this pull request, so nothing ran._

_Rows of \`—\`: not affected by this change, so not planned._

EXPECTED
assert "A4: exits 0" test "${LAST_EXIT}" -eq 0
assert "A4: not admitted beside trigger-events dropped, byte for byte" diff "${RUNNER_TEMP}/expected.md" "${GITHUB_STEP_SUMMARY}"
assert "A4: environment-count counts both" test "$(get_output environment-count)" = "2"
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
