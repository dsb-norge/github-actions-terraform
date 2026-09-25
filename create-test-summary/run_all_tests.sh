#!/bin/env bash
#
# Tests for step_summary.sh
#
# Each case builds its fixtures in a temp dir: the matrix (as the shim hands
# it over, a JSON string captured shell-local), terraform-test-meta-*.json
# files shaped like capture-matrix-job-meta's output, a Jobs API fixture and
# a relevance.json with the not-run list. The step is sourced in a subshell;
# the body is compared byte for byte with test-data/golden/<case>.md.
#
# UPDATE_GOLDENS=1 bash create-test-summary/run_all_tests.sh rewrites the
# goldens; review the diff.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GOLDEN_DIR="${_this_script_dir}/test-data/golden"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

OUT_FILE="$(mktemp)"
trap 'rm -f "${OUT_FILE}"' EXIT

setup() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/step-summary-of-job.md"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="dsb-norge/test-repo"
  export GITHUB_RUN_ID="4242"
  export GITHUB_ACTOR="some-dev"
  export GITHUB_WORKFLOW="CI build"
  export input_metadata_files_pattern="terraform-test-meta-*.json"
  export input_not_run_file=""
  export input_jobs_json_file="${RUNNER_TEMP}/jobs.json"
  export input_run_url=""
  export input_output_file_suffix=""
  unset GH_TOKEN
  : >"${GITHUB_STEP_SUMMARY}"
  : >"${RUNNER_TEMP}/matrix.ndjson"
  : >"${RUNNER_TEMP}/jobs.ndjson"
  MATRIX_OVERRIDE=""
  cd "${RUNNER_TEMP}"
}

teardown() {
  cd /
  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${RUNNER_TEMP}"
}

# ----------------------------------------------------------------------
# Fixture builders
# ----------------------------------------------------------------------

# mrow <slug> <file> <root> <lane> [allow-failing] [github-environment]
#      [provider-set] [provider-set-environments-json] [provider-set-lock] [root-kind]
mrow() {
  jq -nc --arg slug "${1}" --arg file "${2}" --arg root "${3}" --arg lane "${4}" \
    --argjson allow "${5:-false}" --arg genv "${6:-}" --arg set "${7:-a1b2c3}" \
    --argjson envs "${8:-[\"prod\"]}" --arg lock "${9:-envs/prod/.terraform.lock.hcl}" --arg kind "${10:-module}" '
    {slug: $slug, test: {file: $file, root: $root, rel: ($file | ltrimstr($root + "/")), lane: $lane,
      "runs-on": "ubuntu-latest", "terraform-version": "1.15.x", "timeout-minutes": 30,
      "allow-failing-terraform-tests": $allow, "github-environment": $genv, "root-kind": $kind,
      "provider-set": $set, "provider-set-lock": $lock, "provider-set-environments": $envs,
      "cache-terraform-modules": "true", "fork-safe": ($genv == ""), "extra-envs": {}, "extra-envs-from-secrets": {}}}' \
    >>"${RUNNER_TEMP}/matrix.ndjson"
}

# meta <slug> <status> <reason> <passed> <failed> <errored> <skipped> <elapsed-ms>
#      [failed-runs-json] [failed-runs-omitted] [providers-summary] [extra-jq]
# The matrix context is the row mrow wrote for <slug>, filtered the way
# capture-matrix-job-meta filters it (extra-envs-from-secrets dropped).
meta() {
  local slug="${1}"
  local row
  row=$(jq -c --arg s "${slug}" 'select(.slug == $s) | del(.test["extra-envs-from-secrets"])' "${RUNNER_TEMP}/matrix.ndjson")
  [ -z "${row}" ] && row="{\"slug\":\"${slug}\",\"test\":{}}"
  jq -n --argjson row "${row}" --arg status "${2}" --arg reason "${3}" \
    --arg passed "${4}" --arg failed "${5}" --arg errored "${6}" --arg skipped "${7}" --arg elapsed "${8}" \
    --arg runs "${9:-[]}" --arg omitted "${10:-0}" --arg providers "${11:-azuread 3.9.0 environments}" '
    ($passed | tonumber? // 0) as $p | ($failed | tonumber? // 0) as $f | ($errored | tonumber? // 0) as $e | ($skipped | tonumber? // 0) as $k |
    {
      metadata: {environment: $row.slug, captured_at: "2026-09-25T10:10:00Z", schema_version: "2.0.0"},
      workflow: {run_id: "4242", run_attempt: "1", workflow_name: "CI build"},
      matrix_context: $row,
      github_context: {event_name: "pull_request"},
      steps: {
        "verify-credentials": {outcome: (if $row.test["github-environment"] == "" then "skipped" else "success" end), conclusion: "success", outputs: {}},
        "provider-versions": {outcome: "success", conclusion: "success", outputs: {}},
        init: {outcome: "success", conclusion: "success", outputs: {}},
        test: {outcome: (if $status == "pass" then "success" else "failure" end), conclusion: "success", outputs: {
          status: $status, reason: $reason, passed: $passed, failed: $failed, errored: $errored, skipped: $skipped,
          total: (($p + $f + $e + $k) | tostring), "elapsed-ms": $elapsed,
          summary: "Success! \($p) passed, \($f) failed.",
          "failed-runs-json": $runs, "failed-runs-omitted": $omitted, "providers-summary": $providers,
          "runner-platform": "linux_amd64",
          "runs-json-file": "/home/runner/work/_temp/\($row.slug)/runs.json",
          "diagnostics-json-file": "/home/runner/work/_temp/\($row.slug)/diagnostics.json"}},
        "upload-test-output": {outcome: "success", conclusion: "success", outputs: {"artifact-id": "1", "artifact-url": "https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/\($row.slug)"}}
      }
    }' >"${RUNNER_TEMP}/terraform-test-meta-${slug}.json"
  if [ -n "${12:-}" ]; then
    jq "${12}" "${RUNNER_TEMP}/terraform-test-meta-${slug}.json" >"${RUNNER_TEMP}/m.tmp" && mv "${RUNNER_TEMP}/m.tmp" "${RUNNER_TEMP}/terraform-test-meta-${slug}.json"
  fi
}

# job <id> <name> <conclusion> <started> <completed> [test-step-number|none]
# Steps carry the numbers GitHub gives them, not their positions: a skipped
# step keeps its number and post steps jump ahead.
job() {
  local step="${6:-14}"
  jq -nc --argjson id "${1}" --arg name "${2}" --arg c "${3}" --arg s "${4}" --arg e "${5}" --arg step "${step}" '
    {id: $id, name: $name, status: (if $c == "" then "in_progress" else "completed" end),
     conclusion: (if $c == "" then null else $c end),
     html_url: "https://github.com/dsb-norge/test-repo/actions/runs/4242/job/\($id)",
     started_at: $s, completed_at: (if $e == "" then null else $e end),
     steps: ([{name: "Set up job", number: 1}, {name: "⚙️ Terraform init", number: 11}]
             + (if $step == "none" then [] else [{name: "🧪 Terraform test", number: ($step | tonumber)}] end)
             + [{name: "Post ⬇ Checkout", number: 31}])}' >>"${RUNNER_TEMP}/jobs.ndjson"
}

# Writes the jobs as the helper writes a paginated response: one array per
# page, <per-page> jobs each.
write_jobs() {
  local per_page="${1:-100}"
  jq -sc --argjson n "${per_page}" 'if length == 0 then [] else ([range(0; length; $n) as $i | .[$i:$i + $n]] | .[]) end' "${RUNNER_TEMP}/jobs.ndjson" >"${RUNNER_TEMP}/jobs.json"
}

# not_run <file> <lane> <reason>
not_run() {
  local f="${RUNNER_TEMP}/relevance.json"
  [ -f "${f}" ] || printf '{"schema_version":1,"tests":{"not_run":[]}}' >"${f}"
  jq --arg file "${1}" --arg lane "${2}" --arg reason "${3}" '.tests.not_run += [{file: $file, lane: $lane, reason: $reason}]' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
  export input_not_run_file="${f}"
}

run_step() {
  local matrix_json
  if [ -n "${MATRIX_OVERRIDE}" ]; then
    matrix_json="${MATRIX_OVERRIDE}"
  else
    matrix_json=$(jq -sc '{include: .}' "${RUNNER_TEMP}/matrix.ndjson")
  fi
  # Mirrors the shim: toJSON(inputs.tests-matrix-json) of the output string,
  # captured shell-local before allexport, never exported.
  local captured
  captured=$(printf '%s' "${matrix_json}" | jq -Rs '.')
  (
    input_tests_matrix_json="${captured}"
    set -o allexport
    source "${_this_script_dir}/step_summary.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
  BODY_FILE=$(get_output body-file)
  STEP_SUMMARY_FILE=$(get_output step-summary-file)
}

get_output() { grep "^${1}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-; }
body_has() { grep -qF -- "${1}" "${BODY_FILE}"; }
body_lacks() { ! grep -qF -- "${1}" "${BODY_FILE}"; }
out_has() { grep -qF -- "${1}" "${OUT_FILE}"; }

# golden <case>: the body equals test-data/golden/<case>.md byte for byte.
golden() {
  local name="${1}" file="${GOLDEN_DIR}/${1}.md"
  if [ "${UPDATE_GOLDENS:-}" = "1" ]; then
    mkdir -p "${GOLDEN_DIR}"
    cp "${BODY_FILE}" "${file}"
    echo "  (golden ${name} updated)"
    return 0
  fi
  if [ ! -f "${file}" ]; then
    echo "  golden ${file} is missing; run with UPDATE_GOLDENS=1"
    return 1
  fi
  diff -u "${file}" "${BODY_FILE}"
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
    echo "--- body ---"; cat "${BODY_FILE:-/dev/null}" 2>/dev/null || true
    echo "--- end ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

T0="2026-09-25T10:00:00Z"
URL="https://github.com/dsb-norge/test-repo/actions/runs/4242"

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}       CREATE-TEST-SUMMARY STEP TESTS       ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# all-green — three roots, one lane; caller-prefixed job names over two
# pages; the step anchor from the step's number, not its position
# ----------------------------------------------------------------------
setup
mrow "modules-group--unit-group" "modules/group/tests/unit-group.tftest.hcl" "modules/group" "unit"
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit"
mrow "root--unit-net" "tests/unit-net.tftest.hcl" "." "unit"
mrow "modules-rg--unit-rg" "modules/rg/tests/unit-rg.tftest.hcl" "modules/rg" "unit"
meta "modules-group--unit-group" pass "" 4 0 0 0 31000
meta "root--unit-app" pass "" 8 0 0 0 12000
meta "root--unit-net" pass "" 3 0 0 0 36500 "[]" 0 "azuread 3.9.0 environments · random 3.9.1 floating" '.steps.test.outputs["providers-floating-count"] = "1"'
meta "modules-group--unit-group" pass "" 4 0 0 0 31000 "[]" 0 "azuread 3.9.0 environments · random 3.9.1 floating · null 3.2.4 floating"
meta "modules-rg--unit-rg" pass "" 2 0 0 0 5000
job 101 "tf / Terraform test (modules/group/tests/unit-group.tftest.hcl)" success "2026-09-25T10:00:05Z" "2026-09-25T10:01:10Z" 14
job 102 "tf / Terraform test (tests/unit-app.tftest.hcl)" success "2026-09-25T10:00:03Z" "2026-09-25T10:00:40Z" 13
job 103 "tf / Terraform test (tests/unit-net.tftest.hcl)" success "2026-09-25T10:00:04Z" "2026-09-25T10:04:15Z" 12
job 104 "tf / Terraform test (modules/rg/tests/unit-rg.tftest.hcl)" success "2026-09-25T10:00:06Z" "2026-09-25T10:00:50Z" none
job 105 "tf / Terraform (prod)" success "2026-09-25T10:00:01Z" "2026-09-25T10:09:00Z"
write_jobs 2
run_step
assert "all-green: exits 0" test "${LAST_EXIT}" -eq 0
assert "all-green: golden" golden all-green
assert "all-green: headline counts, files, lanes and the tests' wall-clock time" \
  body_has "✅ 4 passed — 4 files · 1 lane · ⏱ 4:12"
assert "all-green: the '.' root section comes first" \
  bash -c "grep -n '<summary>✅' '${BODY_FILE}' | head -n1 | grep -qF '<code>.</code>'"
assert "all-green: job link anchors at the test step's number from the API (13), not its position" \
  body_has "[job log](${URL}/job/102#step:13:1)"
assert "all-green: no test step in the API → '#logs'" body_has "[job log](${URL}/job/104#logs)"
assert "all-green: the output link is the metadata's artifact-url" body_has "[output](${URL}/artifacts/root--unit-app)"
assert "all-green: providers-floating-count on the root line" body_has "lane unit · ⏱ 0:48 · 1 test-only provider floating</summary>"
assert "all-green: without the count, floating providers are counted from providers-summary" \
  body_has "lane unit · ⏱ 0:31 · 2 test-only providers floating</summary>"
assert "all-green: no Failed, Tolerated or Not run section" \
  bash -c "! grep -qE 'Failed \\(|Tolerated \\(|Not run \\(' '${BODY_FILE}'"
assert "all-green: counts" \
  test "$(get_output failed-count)/$(get_output tolerated-count)/$(get_output passed-count)/$(get_output not-run-count)" = "0/0/4/0"
assert "all-green: notice annotation" out_has "::notice title=Terraform tests::4 passed"
assert "all-green: head marker reduced to [A-Za-z0-9_-]" test "$(get_output head-marker)" = "<!-- tf:head:tests:CIbuild -->"
assert "all-green: footer links the run" bash -c "tail -n1 '${BODY_FILE}' | grep -qxF '[Workflow log](${URL})'"
assert "all-green: the step summary is the body without the footer" \
  bash -c "diff <(sed '\$d' '${BODY_FILE}' | sed '\$d') '${STEP_SUMMARY_FILE}'"
assert "all-green: the step summary is appended to GITHUB_STEP_SUMMARY" \
  bash -c "grep -qF '### Terraform tests summary' '${GITHUB_STEP_SUMMARY}' && ! grep -qF '[Workflow log]' '${GITHUB_STEP_SUMMARY}'"
assert "all-green: nothing large in GITHUB_OUTPUT" test "$(wc -c <"${GITHUB_OUTPUT}")" -lt 1024
teardown

# ----------------------------------------------------------------------
# one-failure — an assertion failure among passes
# ----------------------------------------------------------------------
setup
mrow "modules-group--integration-directory-group" "modules/group/tests/integration-directory-group.tftest.hcl" "modules/group" "directory" false "tftest-directory"
mrow "root--unit-group" "tests/unit-group.tftest.hcl" "." "unit"
meta "modules-group--integration-directory-group" fail assertion 5 1 0 0 160000 \
  '[{"run":"group_is_created","status":"fail","file":"modules/group/tests/integration-directory-group.tftest.hcl","line":42,"summary":"Test assertion failed","detail":"group display name must start with `tftest-`"}]'
meta "root--unit-group" pass "" 8 0 0 0 12000
job 201 "Terraform test (modules/group/tests/integration-directory-group.tftest.hcl)" success "${T0}" "2026-09-25T10:02:45Z"
job 202 "Terraform test (tests/unit-group.tftest.hcl)" success "${T0}" "2026-09-25T10:00:20Z"
write_jobs
run_step
assert "one-failure: golden" golden one-failure
assert "one-failure: headline" body_has "❌ 1 failed · ✅ 1 passed — 2 files · 2 lanes · ⏱ 2:45"
assert "one-failure: the failed row" \
  body_has '| `modules/group/tests/integration-directory-group.tftest.hcl` | directory | 5/6 | `2:40` | [job log]'
assert "one-failure: the run block and its diagnostic" \
  body_has '- `group_is_created` — Test assertion failed: group display name must start with `tftest-` (`modules/group/tests/integration-directory-group.tftest.hcl:42`)'
assert "one-failure: counts" test "$(get_output failed-count)/$(get_output passed-count)" = "1/1"
assert "one-failure: error annotation" out_has "::error title=Terraform tests::1 failed, 1 passed"
teardown

# ----------------------------------------------------------------------
# tolerated-error — a run error with a skipped follower, allowed to fail
# ----------------------------------------------------------------------
setup
mrow "modules-rg--integration-subscription-rg" "modules/rg/tests/integration-subscription-rg.tftest.hcl" "modules/rg" "subscription" true "tftest-subscription"
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit"
meta "modules-rg--integration-subscription-rg" error run 2 0 1 1 65000 \
  '[{"run":"assign_role","status":"error","file":"modules/rg/main.tf","line":31,"summary":"Error: authorization failed for the principal","detail":""},{"run":"verify_role","status":"skip","file":"","line":null,"summary":"","detail":""}]'
meta "root--unit-app" pass "" 8 0 0 0 12000
job 301 "Terraform test (modules/rg/tests/integration-subscription-rg.tftest.hcl)" success "${T0}" "2026-09-25T10:01:10Z"
job 302 "Terraform test (tests/unit-app.tftest.hcl)" success "${T0}" "2026-09-25T10:00:15Z"
write_jobs
run_step
assert "tolerated-error: golden" golden tolerated-error
assert "tolerated-error: the Result cell carries the tooltip" \
  body_has '<span title="error (run): allowed to fail">⚠️ error</span> | 2/4 | `1:05`'
assert "tolerated-error: the details summary counts errors and skips" body_has '— 1 error, 1 skipped</summary>'
assert "tolerated-error: the skipped follower" body_has '- `verify_role` — skipped: a previous run block errored'
assert "tolerated-error: counts" test "$(get_output failed-count)/$(get_output tolerated-count)/$(get_output passed-count)" = "0/1/1"
assert "tolerated-error: warning annotation" out_has "::warning title=Terraform tests::1 tolerated, 1 passed"
teardown

# ----------------------------------------------------------------------
# init-error — reported by the test action; and the same row from step
# outcomes when the test step left no status
# ----------------------------------------------------------------------
setup
mrow "modules-net--unit-net" "modules/net/tests/unit-net.tftest.hcl" "modules/net" "unit"
meta "modules-net--unit-net" error init 0 0 0 0 "" "[]" 0 "" '.steps.init.outcome = "failure"'
job 401 "Terraform test (modules/net/tests/unit-net.tftest.hcl)" failure "${T0}" "2026-09-25T10:00:30Z"
write_jobs
run_step
assert "init-error: golden" golden init-error
assert "init-error: Runs cell is the tooltip span, Time an em-dash" \
  body_has '| `modules/net/tests/unit-net.tftest.hcl` | unit | <span title="error (init)">error</span> | — |'
cp "${BODY_FILE}" "${RUNNER_TEMP}/init-from-action.md"
meta "modules-net--unit-net" "" "" "" "" "" "" "" "[]" 0 "" '.steps.init.outcome = "failure" | .steps.test = {outcome: "skipped", conclusion: "skipped", outputs: {}}'
run_step
assert "init-error: classified from the init step's outcome when the test step was skipped" \
  diff "${RUNNER_TEMP}/init-from-action.md" "${BODY_FILE}"
teardown

# ----------------------------------------------------------------------
# no-credentials — an environment lane without secrets: the bring-up
# commands with the environment, repository and run filled in
# ----------------------------------------------------------------------
setup
mrow "modules-group--integration-directory-group" "modules/group/tests/integration-directory-group.tftest.hcl" "modules/group" "directory" false "tftest-directory"
meta "modules-group--integration-directory-group" error no-credentials 0 0 0 0 "" "[]" 0 "" '.steps["verify-credentials"].outcome = "failure" | .steps.init.outcome = "skipped"'
job 501 "Terraform test (modules/group/tests/integration-directory-group.tftest.hcl)" failure "${T0}" "2026-09-25T10:00:09Z"
write_jobs
run_step
assert "no-credentials: golden" golden no-credentials
assert "no-credentials: the details summary names the environment" body_has '— no credentials in <code>tftest-directory</code></summary>'
assert "no-credentials: gh secret set with the environment filled in" \
  body_has "gh secret set ARM_TENANT_ID       --repo dsb-norge/test-repo --env tftest-directory --body '<tenant-id>'"
assert "no-credentials: the re-run command for this run" body_has "gh run rerun 4242 --repo dsb-norge/test-repo --failed"
meta "modules-group--integration-directory-group" "" "" "" "" "" "" "" "[]" 0 "" '.steps["verify-credentials"].outcome = "failure" | .steps.init.outcome = "skipped" | del(.steps.test)'
cp "${BODY_FILE}" "${RUNNER_TEMP}/cred-from-action.md"
run_step
assert "no-credentials: classified from the credential step when the test step left nothing" \
  diff "${RUNNER_TEMP}/cred-from-action.md" "${BODY_FILE}"
teardown

# ----------------------------------------------------------------------
# lock-platform — the environment lock lacks the runner's platform: the
# lock and the fix command, every environment of the set named
# ----------------------------------------------------------------------
setup
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit" false "" "a1b2c3" '["prod","staging"]' "envs/prod/.terraform.lock.hcl"
meta "root--unit-app" error lock-platform 0 0 0 0 "" "[]" 0 "" '.steps["provider-versions"].outcome = "failure" | .steps.init.outcome = "skipped"'
job 551 "Terraform test (tests/unit-app.tftest.hcl)" failure "${T0}" "2026-09-25T10:00:09Z"
write_jobs
run_step
assert "lock-platform: golden" golden lock-platform
assert "lock-platform: names the environment lock and the platform" \
  body_has 'The provider lock `envs/prod/.terraform.lock.hcl` records no `h1:` checksum for the runner'"'"'s platform `linux_amd64`'
assert "lock-platform: the fix command" body_has "terraform -chdir=envs/prod providers lock -platform=linux_amd64"
assert "lock-platform: every environment of the set" body_has 'every environment of this provider set needs it: `prod`, `staging`'
teardown

# An environment root uses its own lock; no runner platform recorded → placeholder
setup
mrow "envs-prod--smoke" "envs/prod/tests/smoke.tftest.hcl" "envs/prod" "unit" false "" "a1b2c3" '["prod"]' "" environment
meta "envs-prod--smoke" "" "" "" "" "" "" "" "[]" 0 "" '.steps["provider-versions"].outcome = "failure" | .steps.init.outcome = "skipped" | .steps.test.outputs = {}'
write_jobs
run_step
assert "lock-platform: an environment root's own lock, the platform placeholder when unknown" \
  body_has "terraform -chdir=envs/prod providers lock -platform=<os>_<arch>"
teardown

# ----------------------------------------------------------------------
# not-run — misplaced and secrets-unavailable files; Dependabot wording
# ----------------------------------------------------------------------
setup
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit"
meta "root--unit-app" pass "" 8 0 0 0 12000
job 601 "Terraform test (tests/unit-app.tftest.hcl)" success "${T0}" "2026-09-25T10:00:15Z"
write_jobs
not_run "tests/setup/helper.tftest.hcl" "" "misplaced"
not_run "modules/rg/tests/integration-subscription-rg-extra.tftest.hcl" "subscription" "secrets unavailable"
run_step
assert "not-run: golden" golden not-run
assert "not-run: headline counts the not-run files and their lanes" \
  body_has "✅ 1 passed · ⏭️ 2 not run — 3 files · 2 lanes · ⏱ 0:15"
assert "not-run: misplaced row, lane an em-dash" \
  body_has '| `tests/setup/helper.tftest.hcl` | — | misplaced: not in a test root (see docs) |'
assert "not-run: secrets unavailable on a fork" body_has 'secrets unavailable (fork pull request)'
assert "not-run: not-run-count" test "$(get_output not-run-count)" = "2"
assert "not-run: notice annotation mentions them" out_has "::notice title=Terraform tests::1 passed, 2 not run"
export GITHUB_ACTOR="dependabot[bot]"
run_step
assert "not-run: Dependabot wording" body_has 'secrets unavailable (Dependabot pull request)'
teardown

# A bare array is accepted too; a missing file is not an error
setup
printf '[{"file":"x/y/z.tftest.hcl","lane":"","reason":"misplaced"}]' >"${RUNNER_TEMP}/nr.json"
export input_not_run_file="${RUNNER_TEMP}/nr.json"
run_step
assert "not-run: a bare array of entries" body_has '| `x/y/z.tftest.hcl` | — | misplaced'
export input_not_run_file="${RUNNER_TEMP}/does-not-exist.json"
run_step
assert "not-run: a missing file warns and renders without it" \
  bash -c "grep -qF 'not found' '${OUT_FILE}' && grep -qF 'No test files found.' '${BODY_FILE}'"
teardown

# ----------------------------------------------------------------------
# no-metadata — matrix rows without metadata, rendered from the Jobs API
# conclusion (P33)
# ----------------------------------------------------------------------
setup
mrow "modules-rg--integration-subscription-rg" "modules/rg/tests/integration-subscription-rg.tftest.hcl" "modules/rg" "subscription" true "tftest-subscription"
mrow "modules-kv--integration-subscription-kv" "modules/kv/tests/integration-subscription-kv.tftest.hcl" "modules/kv" "subscription" false "tftest-subscription"
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit"
mrow "root--unit-waiting" "tests/unit-waiting.tftest.hcl" "." "unit"
meta "root--unit-app" pass "" 8 0 0 0 12000
job 701 "Terraform test (modules/rg/tests/integration-subscription-rg.tftest.hcl)" cancelled "${T0}" "2026-09-25T10:00:02Z"
job 702 "Terraform test (tests/unit-app.tftest.hcl)" success "${T0}" "2026-09-25T10:00:15Z"
job 703 "Terraform test (tests/unit-waiting.tftest.hcl)" "" "${T0}" ""
write_jobs
run_step
assert "no-metadata: golden" golden no-metadata
assert "no-metadata: a cancelled job is a failed row, not tolerated even on a tolerant lane" \
  body_has '| `modules/rg/tests/integration-subscription-rg.tftest.hcl` | subscription | <span title="error (job did not run)">error</span> | — | [job log]'
assert "no-metadata: the conclusion is named" body_has '— the job did not run (cancelled)</summary>'
assert "no-metadata: a job still waiting" body_has '— the job did not run (in_progress)</summary>'
assert "no-metadata: a row the Jobs API does not list" body_has '— the job did not run (not found)</summary>'
assert "no-metadata: counts every matrix row" test "$(get_output failed-count)/$(get_output passed-count)" = "3/1"
assert "no-metadata: logged" out_has "no metadata for 'root--unit-waiting'"
teardown

# A job that succeeded but left no metadata still counts as passed
setup
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit"
job 711 "Terraform test (tests/unit-app.tftest.hcl)" success "${T0}" "2026-09-25T10:00:15Z"
write_jobs
run_step
assert "no-metadata: a succeeded job without metadata is passed, Runs a tooltip dash" \
  body_has '| `tests/unit-app.tftest.hcl` | unit | <span title="the job succeeded but left no metadata">—</span> | — |'
teardown

# ----------------------------------------------------------------------
# missing-links — no jobs file and no token: no job links, one line says so
# ----------------------------------------------------------------------
setup
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit"
mrow "root--unit-net" "tests/unit-net.tftest.hcl" "." "unit"
meta "root--unit-app" pass "" 8 0 0 0 12000
meta "root--unit-net" fail assertion 1 1 0 0 3000 '[{"run":"cidr","status":"fail","file":"tests/unit-net.tftest.hcl","line":7,"summary":"Test assertion failed","detail":"wrong CIDR"}]'
meta "root--unit-net" fail assertion 1 1 0 0 3000 '[{"run":"cidr","status":"fail","file":"tests/unit-net.tftest.hcl","line":7,"summary":"Test assertion failed","detail":"wrong CIDR"}]' 0 "" 'del(.steps["upload-test-output"])'
export input_jobs_json_file=""
run_step
assert "missing-links: golden" golden missing-links
assert "missing-links: exits 0" test "${LAST_EXIT}" -eq 0
assert "missing-links: no job link anywhere" body_lacks "[job log]"
assert "missing-links: the body says so in one line" \
  body_has "_Job links are unavailable: the run's jobs could not be read from the Jobs API._"
assert "missing-links: a missing output link leaves the cell empty" \
  body_has '| `tests/unit-net.tftest.hcl` | unit | 1/2 | `0:03` |  |'
assert "missing-links: the headline time is an em-dash" body_has "⏱ —"
export input_jobs_json_file="${RUNNER_TEMP}/broken.json"
echo '{not json' >"${input_jobs_json_file}"
run_step
assert "missing-links: a malformed jobs file degrades the same way" \
  bash -c "grep -qF 'Job links are unavailable' '${BODY_FILE}' && grep -qF 'holds no jobs' '${OUT_FILE}'"
teardown

# The Jobs API helper: failure and success through a stubbed gh
setup
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit"
meta "root--unit-app" pass "" 8 0 0 0 12000
export input_jobs_json_file=""
export GH_TOKEN="dummy"
mkdir -p "${RUNNER_TEMP}/bin"
cat >"${RUNNER_TEMP}/bin/gh" <<'STUB'
#!/bin/env bash
echo "$*" >>"${RUNNER_TEMP}/gh-calls.log"
[ -n "${GH_STUB_FAIL:-}" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
printf '[{"id":1,"name":"tf / Terraform test (tests/unit-app.tftest.hcl)","conclusion":"success","html_url":"https://github.com/dsb-norge/test-repo/actions/runs/4242/job/1","started_at":"2026-09-25T10:00:00Z","completed_at":"2026-09-25T10:00:15Z","steps":[{"name":"🧪 Terraform test","number":9}]}]\n'
printf '[{"id":2,"name":"other","conclusion":"success","html_url":"x","steps":[]}]\n'
STUB
chmod +x "${RUNNER_TEMP}/bin/gh"
PATH="${RUNNER_TEMP}/bin:${PATH}" run_step
assert "jobs-api: paginated call on the run's jobs" \
  grep -qxF "api --paginate repos/dsb-norge/test-repo/actions/runs/4242/jobs --jq .jobs" "${RUNNER_TEMP}/gh-calls.log"
assert "jobs-api: two pages joined, the link resolved" body_has "[job log](${URL}/job/1#step:9:1)"
GH_STUB_FAIL=1 PATH="${RUNNER_TEMP}/bin:${PATH}" run_step
assert "jobs-api: an API failure warns, exits 0 and drops the job links" \
  bash -c "[ ${LAST_EXIT} -eq 0 ] && grep -qF 'HTTP 403' '${OUT_FILE}' && grep -qF 'Job links are unavailable' '${BODY_FILE}'"
teardown

# ----------------------------------------------------------------------
# provider-sets — a file per set: bracketed job names, sets named on rows
# and per-root lines
# ----------------------------------------------------------------------
setup
mrow "root--unit-app--a1b2c3" "tests/unit-app.tftest.hcl" "." "unit" false "" "a1b2c3" '["prod"]' "envs/prod/.terraform.lock.hcl"
mrow "root--unit-app--d4e5f6" "tests/unit-app.tftest.hcl" "." "unit" false "" "d4e5f6" '["dev","staging"]' "envs/dev/.terraform.lock.hcl"
meta "root--unit-app--a1b2c3" pass "" 8 0 0 0 12000
meta "root--unit-app--d4e5f6" fail assertion 7 1 0 0 13000 '[{"run":"sku","status":"fail","file":"tests/unit-app.tftest.hcl","line":3,"summary":"Test assertion failed","detail":"sku"}]'
job 801 "Terraform test (tests/unit-app.tftest.hcl) [providers: prod]" success "${T0}" "2026-09-25T10:00:15Z" 14
job 802 "Terraform test (tests/unit-app.tftest.hcl) [providers: dev, staging]" success "${T0}" "2026-09-25T10:00:16Z" 15
write_jobs
run_step
assert "provider-sets: golden" golden provider-sets
assert "provider-sets: the headline counts files once and names the sets" \
  body_has "❌ 1 failed · ✅ 1 passed — 1 file · 1 lane · 2 provider sets · ⏱ 0:16"
assert "provider-sets: the failed row names its set and links its own job" \
  body_has '| `tests/unit-app.tftest.hcl` · providers from dev, staging | unit | 7/8 | `0:13` | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/802#step:15:1)'
assert "provider-sets: the per-root line names its set" body_has '— 1 file · 1 passed · lane unit · ⏱ 0:12 · providers from prod</summary>'
teardown

# ----------------------------------------------------------------------
# zero-rows — nothing discovered: the "no test files" body
# ----------------------------------------------------------------------
setup
MATRIX_OVERRIDE='{"include":[]}'
run_step
assert "zero-rows: golden" golden zero-rows
assert "zero-rows: counts all zero" \
  test "$(get_output failed-count)/$(get_output tolerated-count)/$(get_output passed-count)/$(get_output not-run-count)" = "0/0/0/0"
assert "zero-rows: notice annotation" out_has "::notice title=Terraform tests::no test files"
MATRIX_OVERRIDE=' '
run_step
assert "zero-rows: an empty tests-matrix-json is not an error" \
  bash -c "[ ${LAST_EXIT} -eq 0 ] && grep -qF 'No test files found.' '${BODY_FILE}'"
teardown

# ----------------------------------------------------------------------
# Metadata robustness: unknown schema, malformed, and metadata for a slug
# the matrix does not list
# ----------------------------------------------------------------------
setup
mrow "root--unit-app" "tests/unit-app.tftest.hcl" "." "unit"
meta "root--unit-app" pass "" 8 0 0 0 12000
meta "root--unit-old" pass "" 1 0 0 0 1000 "[]" 0 "" '.metadata.schema_version = "1.0.0"'
echo '{not json' >"${RUNNER_TEMP}/terraform-test-meta-broken.json"
meta "root--unit-orphan" pass "" 2 0 0 0 2000 "[]" 0 "" '.matrix_context = {slug: "root--unit-orphan", test: {file: "tests/unit-orphan.tftest.hcl", root: ".", lane: "unit"}}'
write_jobs
run_step
assert "metadata: an unknown schema version is skipped with a warning" \
  bash -c "grep -qF \"unknown metadata schema version '1.0.0'\" '${OUT_FILE}' && ! grep -qF 'unit-old' '${BODY_FILE}'"
assert "metadata: a malformed file is skipped with a warning" out_has "skipping malformed metadata file"
assert "metadata: metadata the matrix does not list is rendered, with a warning" \
  bash -c "grep -qF 'tests/unit-orphan.tftest.hcl' '${BODY_FILE}' && grep -qF \"'root--unit-orphan', which is not in the matrix\" '${OUT_FILE}'"
assert "metadata: counts" test "$(get_output passed-count)" = "2"
teardown

# ----------------------------------------------------------------------
# Sort order: failed rows by path; roots with '.' first, then by path
# ----------------------------------------------------------------------
setup
for f in "modules/b" "modules/a" "."; do
  s="${f//\//-}"; [ "${f}" = "." ] && s="root"
  mrow "${s}--z" "${f#./}/tests/z.tftest.hcl" "${f}" "unit"; meta "${s}--z" fail assertion 0 1 0 0 1000 '[]'
  mrow "${s}--a" "${f#./}/tests/a.tftest.hcl" "${f}" "unit"; meta "${s}--a" pass "" 1 0 0 0 1000
done
write_jobs
run_step
assert "sort: failed rows sorted by path" \
  bash -c "grep -oE '^\\| \`[^\`]+/z.tftest.hcl\`' '${BODY_FILE}' | tr -d '|\` ' | tr '\n' ' ' | grep -qxF './tests/z.tftest.hcl modules/a/tests/z.tftest.hcl modules/b/tests/z.tftest.hcl '"
assert "sort: roots '.', then modules/a, then modules/b" \
  bash -c "grep -oE '<summary>✅ <code>[^<]+' '${BODY_FILE}' | sed 's/.*<code>//' | tr '\n' ' ' | grep -qxF '. modules/a modules/b '"
teardown

# ----------------------------------------------------------------------
# Budget — one case per trim step of §6.4, plus the last-resort guard
# ----------------------------------------------------------------------

# long_runs <n> <detail-chars>: a failed-runs-json with <n> diagnostics
long_runs() {
  jq -nc --argjson n "${1}" --argjson len "${2}" \
    '[range(0; $n) | {run: "run_\(.)", status: "error", file: "modules/x/main.tf", line: (. + 1), summary: "Error: provider error", detail: ("d" * $len)}]'
}

# budget-trim-1: failed details over budget uncapped, under once capped
setup
runs=$(long_runs 12 250)
for i in $(seq -w 1 25); do
  mrow "modules-x--f${i}" "modules/x/tests/unit-f${i}.tftest.hcl" "modules/x" "unit"
  meta "modules-x--f${i}" error run 0 0 12 0 1000 "${runs}"
done
write_jobs
run_step
assert "budget-trim-1: golden" golden budget-trim-1
assert "budget-trim-1: logged at trim level 1" out_has "at trim level 1"
assert "budget-trim-1: every details capped with the marker" \
  test "$(grep -c '… (truncated, see job log)' "${BODY_FILE}")" -eq 25
assert "budget-trim-1: within budget" test "$(jq -Rs 'length' "${BODY_FILE}")" -le 65000
teardown

# budget-trim-2: capped details plus large per-root tables; tables collapse
setup
runs=$(long_runs 12 250)
for i in $(seq -w 1 18); do
  mrow "modules-x--f${i}" "modules/x/tests/unit-f${i}.tftest.hcl" "modules/x" "unit"
  meta "modules-x--f${i}" error run 0 0 12 0 1000 "${runs}"
done
for i in $(seq -w 1 200); do
  mrow "modules-long-path-for-many-passing-files--p${i}" "modules/long-path-for-many-passing-files/tests/unit-passing-file-number-${i}.tftest.hcl" "modules/long-path-for-many-passing-files" "unit"
  meta "modules-long-path-for-many-passing-files--p${i}" pass "" 3 0 0 0 2000
done
write_jobs
run_step
assert "budget-trim-2: golden" golden budget-trim-2
assert "budget-trim-2: logged at trim level 2" out_has "at trim level 2"
assert "budget-trim-2: the root collapses to its summary line" \
  bash -c "grep -qxF '✅ <code>modules/long-path-for-many-passing-files</code> — 200 files · 200 passed · lane unit · ⏱ 6:40' '${BODY_FILE}' && ! grep -qF 'unit-passing-file-number-001' '${BODY_FILE}'"
assert "budget-trim-2: within budget" test "$(jq -Rs 'length' "${BODY_FILE}")" -le 65000
teardown

# budget-trim-3: a large not-run list collapses to its summary line
setup
runs=$(long_runs 12 250)
for i in $(seq -w 1 18); do
  mrow "modules-x--f${i}" "modules/x/tests/unit-f${i}.tftest.hcl" "modules/x" "unit"
  meta "modules-x--f${i}" error run 0 0 12 0 1000 "${runs}"
done
jq -n '{tests: {not_run: [range(0; 400) | {file: "modules/some/deep/scenario-directory/tests/nested/misplaced-file-\(.).tftest.hcl", lane: "", reason: "misplaced"}]}}' >"${RUNNER_TEMP}/relevance.json"
export input_not_run_file="${RUNNER_TEMP}/relevance.json"
write_jobs
run_step
assert "budget-trim-3: golden" golden budget-trim-3
assert "budget-trim-3: logged at trim level 3" out_has "at trim level 3"
assert "budget-trim-3: the not-run list is its summary line" \
  bash -c "grep -qxF '⏭️ Not run (400)' '${BODY_FILE}' && ! grep -qF 'misplaced-file-1.tftest' '${BODY_FILE}'"
assert "budget-trim-3: within budget" test "$(jq -Rs 'length' "${BODY_FILE}")" -le 65000
teardown

# budget-guard: a failed table alone over budget; cut, closed and footed
setup
for i in $(seq -w 1 256); do
  mrow "f${i}" "modules/a-very-long-module-directory-name-to-make-rows-wide/submodule/tests/integration-directory-some-long-test-name-${i}.tftest.hcl" "modules/a-very-long-module-directory-name-to-make-rows-wide/submodule" "directory"
  meta "f${i}" fail assertion 0 1 0 0 1000 '[]'
done
write_jobs
run_step
assert "budget-guard: the matrix passed in exceeds one envp string (128 KiB), yet every fork ran" \
  bash -c "[ \$(jq -sc '{include: .}' '${RUNNER_TEMP}/matrix.ndjson' | wc -c) -gt 131072 ] && ! grep -qF 'Argument list too long' '${OUT_FILE}'"
assert "budget-guard: logged at trim level 4" out_has "at trim level 4"
assert "budget-guard: within budget" test "$(jq -Rs 'length' "${BODY_FILE}")" -le 65000
assert "budget-guard: says it was cut, keeps the footer" \
  bash -c "grep -qF '… (truncated to fit a comment, see the workflow log)' '${BODY_FILE}' && tail -n1 '${BODY_FILE}' | grep -qF '[Workflow log]'"
assert "budget-guard: headline and counts intact" \
  bash -c "grep -qF '❌ 256 failed — 256 files' '${BODY_FILE}' && [ \"\$(grep '^failed-count=' '${GITHUB_OUTPUT}' | cut -d= -f2)\" = 256 ]"
teardown

# ----------------------------------------------------------------------
# Output files: suffix, and GITHUB_STEP_SUMMARY unset
# ----------------------------------------------------------------------
setup
export input_output_file_suffix="a/b c"
unset GITHUB_STEP_SUMMARY
run_step
assert "outputs: suffix reduced and used in the directory" \
  bash -c "[[ '${BODY_FILE}' == */create-test-summary-abc/body.md ]] && [ -s '${BODY_FILE}' ]"
assert "outputs: GITHUB_STEP_SUMMARY unset → exit 0, rendered to the log" \
  bash -c "[ ${LAST_EXIT} -eq 0 ] && grep -qF 'GITHUB_STEP_SUMMARY is not set' '${OUT_FILE}'"
export input_run_url="https://example.test/run"
export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/s.md"
run_step
assert "outputs: run-url overrides the footer link" bash -c "tail -n1 '${BODY_FILE}' | grep -qxF '[Workflow log](https://example.test/run)'"
teardown

# ----------------------------------------------------------------------
# The shim: toJSON capture, unique delimiter, a description comment first
# ----------------------------------------------------------------------
assert "shim: the run block opens with a description comment" \
  python3 -c "
import yaml,sys
d=yaml.safe_load(open('${_this_script_dir}/action.yml'))
sys.exit(0 if all(s['run'].lstrip().startswith('# ') for s in d['runs']['steps'] if 'run' in s) else 1)"
assert "shim: the matrix is captured as toJSON before allexport" \
  python3 -c "
import yaml,sys
r=yaml.safe_load(open('${_this_script_dir}/action.yml'))['runs']['steps'][0]['run']
sys.exit(0 if '\${{ toJSON(inputs.tests-matrix-json) }}' in r and r.index('toJSON') < r.index('set -o allexport') else 1)"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
