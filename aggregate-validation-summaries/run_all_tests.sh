#!/bin/env bash
#
# Test runner for step_aggregate.sh
#
# Strategy:
#   - Each test creates a temp dir with fixture matrix-job-meta-*.json files
#   - A fake `gh` script is placed on PATH ahead of the real one; it records
#     every call to ${GH_FAKE_CALL_LOG} and returns canned responses driven
#     by ${GH_FAKE_LIST_RESPONSE_FILE} (for `--paginate ... /comments`)
#   - The step is sourced in a subshell so its side-effects don't leak
#   - Assertions inspect stdout, GITHUB_OUTPUT, and the recorded gh calls
#

set -u
_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# Setup a fresh sandbox for one test
setup() {
  TEST_DIR=$(mktemp -d)

  # Fake gh. Behaviour driven by env vars + response files in TEST_DIR.
  mkdir -p "${TEST_DIR}/bin"
  cat > "${TEST_DIR}/bin/gh" <<'FAKE_GH'
#!/bin/bash
LOG="${GH_FAKE_CALL_LOG:-/dev/null}"
echo "gh $*" >> "${LOG}"
# Order matters: more specific patterns first.
case "$*" in
  *"--paginate"*"/actions/runs/"*"/jobs"*)
    # Jobs-API call. Returns a flat JSON array (because production code uses
    # --jq '.jobs', which strips the envelope and concatenates pages).
    if [ -n "${GH_FAKE_JOBS_RESPONSE_FILE:-}" ] && [ -f "${GH_FAKE_JOBS_RESPONSE_FILE}" ]; then
      cat "${GH_FAKE_JOBS_RESPONSE_FILE}"
    else
      echo "[]"
    fi
    if [ "${GH_FAKE_JOBS_EXIT:-0}" != "0" ]; then
      exit "${GH_FAKE_JOBS_EXIT}"
    fi
    ;;
  *"--paginate"*"/comments"*)
    if [ -n "${GH_FAKE_LIST_RESPONSE_FILE:-}" ] && [ -f "${GH_FAKE_LIST_RESPONSE_FILE}" ]; then
      cat "${GH_FAKE_LIST_RESPONSE_FILE}"
    else
      echo "[]"
    fi
    if [ "${GH_FAKE_LIST_EXIT:-0}" != "0" ]; then
      exit "${GH_FAKE_LIST_EXIT}"
    fi
    ;;
  *"-X DELETE"*)
    if [ "${GH_FAKE_DELETE_EXIT:-0}" != "0" ]; then
      exit "${GH_FAKE_DELETE_EXIT}"
    fi
    echo '{"deleted": true}'
    ;;
  *"-X PATCH"*"/issues/comments/"*)
    if [ "${GH_FAKE_PATCH_EXIT:-0}" != "0" ]; then
      exit "${GH_FAKE_PATCH_EXIT}"
    fi
    # Extract the comment id from the URL and echo it — matches production
    # _gh_patch_comment which uses --jq '.id' on the response.
    # URL form: repos/<repo>/issues/comments/<id>
    for arg in "$@"; do
      if [[ "${arg}" == repos/*"/issues/comments/"* ]]; then
        echo "${arg##*/}"
        break
      fi
    done
    ;;
  *"-X POST"*)
    if [ "${GH_FAKE_POST_EXIT:-0}" != "0" ]; then
      exit "${GH_FAKE_POST_EXIT}"
    fi
    # Each post returns a different fake id from a counter so tests can
    # distinguish per-group posts.
    POST_COUNTER_FILE="${TEST_DIR:-/tmp}/.post-counter"
    COUNTER=$(cat "${POST_COUNTER_FILE}" 2>/dev/null || echo 9000)
    COUNTER=$((COUNTER + 1))
    echo "${COUNTER}" > "${POST_COUNTER_FILE}"
    echo "${COUNTER}"
    ;;
esac
FAKE_GH
  chmod +x "${TEST_DIR}/bin/gh"

  export GH_FAKE_CALL_LOG="${TEST_DIR}/gh-calls.log"
  export GH_FAKE_LIST_RESPONSE_FILE="${TEST_DIR}/list-response.json"
  export GH_FAKE_JOBS_RESPONSE_FILE="${TEST_DIR}/jobs-response.json"
  unset GH_FAKE_LIST_EXIT GH_FAKE_DELETE_EXIT GH_FAKE_POST_EXIT GH_FAKE_PATCH_EXIT GH_FAKE_JOBS_EXIT
  echo "[]" > "${GH_FAKE_LIST_RESPONSE_FILE}"
  echo "[]" > "${GH_FAKE_JOBS_RESPONSE_FILE}"
  : > "${GH_FAKE_CALL_LOG}"

  export PATH="${TEST_DIR}/bin:${PATH}"

  # GH Actions plumbing
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${TEST_DIR}"
  export GITHUB_REPOSITORY="dsb-norge/test-repo"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_RUN_ID="999"
  export GITHUB_WORKFLOW="Terraform CI"
  export GITHUB_ACTOR="test-user"
  export GITHUB_EVENT_NAME="pull_request"
  export GH_TOKEN="fake"

  export input_metadata_files_pattern="matrix-job-meta-*.json"
  export input_pr_number="123"

  cd "${TEST_DIR}"
}

teardown() {
  rm -rf "${TEST_DIR}" 2>/dev/null || true
  unset TEST_DIR
}

# Create a metadata file in TEST_DIR.
# Usage: write_meta <env> [group] [fmt_outcome] [extra-counts-json] [plan_time]
# When plan_time is non-empty, the plan step's outputs include a
# "plan-time" entry — mimicking what terraform-plan@v0 now publishes.
# Empty / unset preserves the pre-plan-time fixture shape so older tests
# stay backwards-compatible.
write_meta() {
  local env="${1}" group="${2:-}" fmt_outcome="${3:-success}" counts="${4:-}" plan_time="${5:-}"
  local counts_default='{"count-add":"0","count-change":"0","count-destroy":"0","count-import":"0","count-move":"0","count-remove":"0"}'
  local counts_use="${counts:-${counts_default}}"
  local plan_outputs='{}'
  if [ -n "${plan_time}" ]; then
    plan_outputs="{\"plan-time\": \"${plan_time}\"}"
  fi
  cat > "${TEST_DIR}/matrix-job-meta-${env}.json" <<JSON
{
  "metadata": {"environment": "${env}", "captured_at": "2026-01-30T12:00:00Z", "schema_version": "2.0.0"},
  "workflow": {"run_id": "999", "run_number": "1", "run_attempt": "1",
               "workflow_name": "Terraform CI", "job_name": "terraform-ci-cd",
               "actor": "test-user", "event_name": "pull_request",
               "ref": "refs/pull/123/merge", "sha": "abc"},
  "matrix_context": {"environment": "${env}", "vars": {"environment": "${env}", "pr-comment-group": "${group}"}},
  "github_context": {"actor": "test-user"},
  "steps": {
    "init":        {"outcome": "success", "conclusion": "success", "outputs": {}},
    "verify-lock": {"outcome": "success", "conclusion": "success", "outputs": {}},
    "fmt":         {"outcome": "${fmt_outcome}", "conclusion": "${fmt_outcome}", "outputs": {}},
    "validate":    {"outcome": "success", "conclusion": "success", "outputs": {}},
    "lint":        {"outcome": "success", "conclusion": "success", "outputs": {}},
    "plan":        {"outcome": "success", "conclusion": "success", "outputs": ${plan_outputs}},
    "parse-plan":  {"outcome": "success", "conclusion": "success", "outputs": ${counts_use}}
  }
}
JSON
}

# Set up the fake Jobs API response so per-env job URL resolution succeeds.
# Each env arg gets a synthetic html_url. The job name format mirrors what
# GitHub actually renders when this reusable workflow is called from another
# workflow: "<caller-job-name> / Terraform (<env>)". The default caller name
# is "tf" (matches the real-world calling repo) — override via the first
# argument prefixed with "caller=" if a test needs a different one. Use
# "caller=" (empty) to test the bare "Terraform (<env>)" format.
# Usage:
#   with_jobs_for env1 env2 ...
#   with_jobs_for caller=ci-cd env1 env2 ...
#   with_jobs_for caller= env1 env2 ...
with_jobs_for() {
  local caller="tf / "
  if [[ "${1:-}" == caller=* ]]; then
    local val="${1#caller=}"
    if [ -z "${val}" ]; then
      caller=""
    else
      caller="${val} / "
    fi
    shift
  fi
  local out='['
  local first=true
  local env
  for env in "${@}"; do
    if [ "${first}" = "true" ]; then first=false; else out+=','; fi
    out+="{\"id\": $((RANDOM + 1000)), \"name\": \"${caller}Terraform (${env})\", \"html_url\": \"https://github.com/dsb-norge/test-repo/actions/runs/999/job/${env}\"}"
  done
  out+=']'
  echo "${out}" > "${GH_FAKE_JOBS_RESPONSE_FILE}"
}

# Run the step. Captures stdout to ${TEST_DIR}/step.log; reads GITHUB_OUTPUT
# for assertions.
#
# Match production: action.yml shim sources step under 'bash -eo pipefail'.
# Without -eo pipefail the harness silently tolerates bugs (failed
# subcommand, broken pipeline) that would crash the step in CI.
run_step() {
  (
    set -eo pipefail
    set -o allexport
    source "${_this_script_dir}/step_aggregate.sh"
  ) > "${TEST_DIR}/step.log" 2>&1
  STEP_EXIT_CODE=$?
}

# Read groups-processed-json output (multi-line)
get_processed_json() {
  local content="" delim="" in_block=false
  while IFS= read -r line; do
    if [[ "${in_block}" == true ]]; then
      if [[ "${line}" == "${delim}" ]]; then break; fi
      if [[ -n "${content}" ]]; then content="${content}"$'\n'"${line}"; else content="${line}"; fi
    elif [[ "${line}" =~ ^groups-processed-json\<\<(.*)$ ]]; then
      delim="${BASH_REMATCH[1]}"
      in_block=true
    fi
  done < "${GITHUB_OUTPUT}"
  echo "${content}"
}

# Generic test runner
run_test() {
  local name="${1}"
  local fn="${2}"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  setup
  local err
  err=$("${fn}" 2>&1)
  local exit_code=$?
  if [[ ${exit_code} -eq 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo -e "${err}"
    echo "--- step output ---"
    cat "${TEST_DIR}/step.log" 2>/dev/null
    echo "--- gh calls ---"
    cat "${GH_FAKE_CALL_LOG}" 2>/dev/null
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}" 2>/dev/null
    echo "--- end ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  teardown
}

# ============================================================================
# Test cases
# ============================================================================

test_empty_desired_empty_existing_is_noop() {
  # No metadata files; empty PR comment list.
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Must have called list (once) but no DELETE and no POST
  if ! grep -q 'gh api --paginate' "${GH_FAKE_CALL_LOG}"; then
    echo "expected gh list call"; return 1
  fi
  if grep -q 'DELETE' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect DELETE in empty/empty scenario"; return 1
  fi
  if grep -q 'POST' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect POST in empty/empty scenario"; return 1
  fi
  return 0
}

test_sweep_only_orphans() {
  # No desired groups, but PR has an existing marker comment from a prior run
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 5001, "created_at": "2026-01-30T10:00:00Z", "body": "<!-- tf:head:group:stale-group -->\n### Terraform validation summary for group: `stale-group`\nold body"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/5001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE of orphan comment 5001"; return 1
  fi
  if grep -q 'POST' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect POST when desired set is empty"; return 1
  fi
  if grep -q 'PATCH' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect PATCH on orphan"; return 1
  fi
  return 0
}

test_post_when_no_existing() {
  # Two envs in one group, no existing comments
  write_meta "alpha-dev" "dev"
  write_meta "beta-dev" "dev"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if grep -q 'DELETE' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect DELETE when no existing"; return 1
  fi
  if [[ $(grep -c 'POST' "${GH_FAKE_CALL_LOG}") -ne 1 ]]; then
    echo "expected exactly 1 POST"; return 1
  fi
  # Verify body content was generated (peek at the body file path used)
  local body_file
  body_file=$(grep -o 'body=@/tmp/[^ ]*' "${GH_FAKE_CALL_LOG}" | head -n1 | cut -d@ -f2)
  if [ -z "${body_file}" ] || [ ! -f "${body_file}" ]; then
    # File was cleaned up - that's fine. Check the step log instead.
    if ! grep -q 'Terraform validation summary for group: `dev`' "${TEST_DIR}/step.log"; then
      echo "expected rendered body to contain group prefix"; return 1
    fi
  fi
  return 0
}

test_mixed_orphan_delete_and_patch() {
  # One desired group ('dev'), one orphan ('obsolete-group').
  # Existing 'dev' marker is PATCHed in place (stable identity), orphan
  # is deleted, no POST is needed.
  write_meta "alpha-dev" "dev"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 7001, "created_at": "2026-01-30T10:00:00Z", "body": "<!-- tf:head:group:dev -->\n### Terraform validation summary for group: `dev`\nold body"},
  {"id": 7002, "created_at": "2026-01-30T10:00:00Z", "body": "<!-- tf:head:group:obsolete-group -->\n### Terraform validation summary for group: `obsolete-group`\norphan body"}
]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # 'dev' marker is patched in place — NOT deleted
  if grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/7001' "${GH_FAKE_CALL_LOG}"; then
    echo "did NOT expect DELETE of existing 'dev' marker 7001 — it should be PATCHed"; return 1
  fi
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/7001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH of existing 'dev' marker 7001"; return 1
  fi
  # Orphan marker is deleted
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/7002' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE of orphan 7002"; return 1
  fi
  # No POST: 'dev' was upserted via PATCH, not a fresh post.
  if grep -q 'POST' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect POST when existing marker is patched in place"; return 1
  fi
  return 0
}

test_alphabetical_column_order() {
  # Three envs added in non-alpha order; expect alpha column order in output
  write_meta "charlie" "dev"
  write_meta "alpha" "dev"
  write_meta "bravo" "dev"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Header line should list envs alphabetically
  if ! grep -q '|  | Step | alpha | bravo | charlie |' "${TEST_DIR}/step.log"; then
    echo "expected alphabetical header '|  | Step | alpha | bravo | charlie |'"
    grep '|  | Step |' "${TEST_DIR}/step.log" || true
    return 1
  fi
  return 0
}

test_per_env_anchor_resolved() {
  write_meta "myenv" "g"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 4242, "body": "<!-- tf:tag:plan:myenv:run-id-999 -->\nplan extract body"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q '\[log extract\](#issuecomment-4242)' "${TEST_DIR}/step.log"; then
    echo "expected resolved log-extract anchor #issuecomment-4242"
    return 1
  fi
  return 0
}

test_per_env_anchor_missing_but_job_url_resolved_shows_only_job_log() {
  write_meta "lonely" "g"
  with_jobs_for "lonely"
  # No per-env comment in the PR
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local links_row
  links_row=$(grep -E '^\| <span title="Links"' "${TEST_DIR}/step.log" | head -n1)
  if [ -z "${links_row}" ]; then
    echo "no Links row found"; return 1
  fi
  if echo "${links_row}" | grep -q 'log extract'; then
    echo "Links row must NOT contain 'log extract' when no per-env comment exists"
    echo "row: ${links_row}"
    return 1
  fi
  if ! echo "${links_row}" | grep -q '\[job log\](https://github.com/dsb-norge/test-repo/actions/runs/999/job/lonely#logs)'; then
    echo "expected resolved per-env job URL in Links row"
    echo "row: ${links_row}"
    return 1
  fi
  return 0
}

test_neither_anchor_nor_job_url_yields_empty_cell() {
  write_meta "ghost" "g"
  # No PR comment match AND no jobs API match (jobs response is empty array)
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local links_row
  links_row=$(grep -E '^\| <span title="Links"' "${TEST_DIR}/step.log" | head -n1)
  if [ -z "${links_row}" ]; then echo "no Links row found"; return 1; fi
  # Cell for 'ghost' (the only env in the group) must be empty: `... | Links |  |`
  if ! echo "${links_row}" | grep -qE '\| Links \|  \|'; then
    echo "expected empty Links cell when neither anchor nor job URL resolved"
    echo "row: ${links_row}"
    return 1
  fi
  return 0
}

test_both_anchor_and_job_url_resolved_shows_both_with_br() {
  write_meta "envX" "g"
  with_jobs_for "envX"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 7777, "body": "<!-- tf:tag:plan:envX:run-id-999 -->\nplan extract body"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local links_row
  links_row=$(grep -E '^\| <span title="Links"' "${TEST_DIR}/step.log" | head -n1)
  if [ -z "${links_row}" ]; then echo "no Links row found"; return 1; fi
  if ! echo "${links_row}" | grep -q '\[log extract\](#issuecomment-7777)<br>\[job log\](https://github.com/dsb-norge/test-repo/actions/runs/999/job/envX#logs)'; then
    echo "expected both links separated by <br>"
    echo "row: ${links_row}"
    return 1
  fi
  return 0
}

test_jobs_api_failure_omits_job_log_for_all_envs() {
  write_meta "envA" "g"
  export GH_FAKE_JOBS_EXIT=1
  echo "boom" > "${GH_FAKE_JOBS_RESPONSE_FILE}"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Specifically: no markdown `[job log](...)` link in any rendered Links row.
  # (Use literal-bracket match to avoid catching the WARN log line's prose.)
  local links_row
  links_row=$(grep -E '^\| <span title="Links"' "${TEST_DIR}/step.log" | head -n1)
  if echo "${links_row}" | grep -q '\[job log\]'; then
    echo "Links row must not contain a [job log] link when Jobs API fails"
    echo "row: ${links_row}"
    return 1
  fi
  # And we should have logged a warn about it
  if ! grep -q 'Failed to list run jobs' "${TEST_DIR}/step.log"; then
    echo "expected warning 'Failed to list run jobs'"
    return 1
  fi
  return 0
}

test_job_url_resolution_handles_caller_prefixed_name() {
  # Real-world: when this reusable workflow is called from another workflow,
  # GitHub renders matrix job names with the caller's job name prepended,
  # e.g. "tf / Terraform (dsb-norge)". This is the default form of
  # with_jobs_for. Verify the regex picks it up.
  write_meta "myenv" "g"
  with_jobs_for "myenv"  # produces name "tf / Terraform (myenv)"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q "Resolved 1 per-env job URL" "${TEST_DIR}/step.log"; then
    echo "expected exactly 1 resolved job URL"
    grep "Resolved" "${TEST_DIR}/step.log" || true
    return 1
  fi
  local links_row
  links_row=$(grep -E '^\| <span title="Links"' "${TEST_DIR}/step.log" | head -n1)
  if ! echo "${links_row}" | grep -q '\[job log\](https://github.com/dsb-norge/test-repo/actions/runs/999/job/myenv#logs)'; then
    echo "expected resolved per-env job URL despite 'tf / ' prefix"
    echo "row: ${links_row}"
    return 1
  fi
  return 0
}

test_job_url_resolution_handles_bare_name() {
  # Backwards: if a caller invokes the reusable workflow at the top level
  # (no parent job), names lack the "caller / " prefix.
  write_meta "myenv" "g"
  with_jobs_for caller= "myenv"  # produces bare "Terraform (myenv)"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q "Resolved 1 per-env job URL" "${TEST_DIR}/step.log"; then
    echo "expected 1 resolved URL even with bare name"
    return 1
  fi
  return 0
}

test_job_url_resolution_skips_non_matrix_jobs() {
  # Real workflow includes 'tf / PR comment aggregator' and 'tf / Create job
  # matrix' jobs alongside the matrix. They must not match the regex.
  write_meta "myenv" "g"
  cat > "${GH_FAKE_JOBS_RESPONSE_FILE}" <<'JSON'
[
  {"id": 1, "name": "tf / Create job matrix", "html_url": "https://example/1"},
  {"id": 2, "name": "tf / Terraform (myenv)", "html_url": "https://example/2"},
  {"id": 3, "name": "tf / Terraform conclusion", "html_url": "https://example/3"},
  {"id": 4, "name": "tf / PR comment aggregator", "html_url": "https://example/4"},
  {"id": 5, "name": "tf / PR auto merger", "html_url": "https://example/5"}
]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q "Resolved 1 per-env job URL" "${TEST_DIR}/step.log"; then
    echo "expected exactly 1 match (Terraform conclusion, PR comment aggregator, etc. must be filtered out)"
    grep "Resolved\|Resolving" "${TEST_DIR}/step.log" || true
    return 1
  fi
  return 0
}

test_grouped_footer_is_workflow_log() {
  # Per-group head footer is a single [Workflow log](url) line pointing at
  # the workflow run page. (Per-env head's [Job log] footer targets a job-
  # specific URL — different shape, different file.)
  write_meta "envA" "g"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Body content was emitted to the step log (see post_pass).
  # Must contain the new footer and NOT contain any of the legacy fields.
  if ! grep -q '\[Workflow log\](https://github.com/dsb-norge/test-repo/actions/runs/999)' "${TEST_DIR}/step.log"; then
    echo "expected '[Workflow log](url)' footer with run URL"
    grep '\[Workflow log\]' "${TEST_DIR}/step.log" || true
    return 1
  fi
  # Guard: the per-group head must not regress to '[Job log]' (that label is
  # reserved for per-env heads where the URL is the job page, not the run).
  if grep -q '\[Job log\]' "${TEST_DIR}/step.log"; then
    echo "per-group head footer must not say '[Job log]'"
    return 1
  fi
  for stale in 'Pusher: @' 'Action: `pull_request`' 'Workflow: `'; do
    if grep -qF "${stale}" "${TEST_DIR}/step.log"; then
      echo "legacy footer field still present in rendered body: ${stale}"
      return 1
    fi
  done
  return 0
}

test_upsert_pass_does_not_nest_log_groups() {
  # GitHub Actions does not support nested log groups. Verify that no
  # ::group:: line appears before a matching ::endgroup:: while another
  # ::group:: is already open.
  write_meta "envA" "dev"
  write_meta "envB" "prod"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Walk the log; track nesting depth. If depth ever exceeds 1, fail.
  local depth=0
  local max_depth=0
  while IFS= read -r line; do
    if [[ "${line}" == "::group::"* ]]; then
      depth=$((depth + 1))
      if [[ ${depth} -gt ${max_depth} ]]; then max_depth=${depth}; fi
    elif [[ "${line}" == "::endgroup::"* ]]; then
      depth=$((depth - 1))
    fi
  done < "${TEST_DIR}/step.log"
  if [[ ${max_depth} -gt 1 ]]; then
    echo "log groups nested: max depth=${max_depth}, expected 1"
    grep -E '^::(group|endgroup)' "${TEST_DIR}/step.log" | head -40
    return 1
  fi
  return 0
}

test_per_env_anchor_picks_newest_when_multiple_attempts() {
  # Two attempts of the same run leave two plan tags for the same env
  # (different attempt tokens). Aggregator's env-prefix lookup matches
  # both — newest comment id wins.
  write_meta "dup" "g"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 100, "body": "<!-- tf:tag:plan:dup:run-id-999:attempt-1 -->\nattempt-1 plan"},
  {"id": 999, "body": "<!-- tf:tag:plan:dup:run-id-999:attempt-2 -->\nattempt-2 plan"},
  {"id": 500, "body": "<!-- tf:tag:plan:dup:run-id-998:attempt-1 -->\nfrom an earlier run, not GC'd"}
]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q '#issuecomment-999' "${TEST_DIR}/step.log"; then
    echo "expected anchor to point at newest id 999"
    return 1
  fi
  if ! grep -q 'plan tags match for env-prefix' "${TEST_DIR}/step.log"; then
    echo "expected warning about multiple plan tags matching env-prefix"
    return 1
  fi
  return 0
}

test_status_emoji_map() {
  # Build envs with different fmt outcomes to exercise the status map
  write_meta "envS" "g" "success"
  write_meta "envF" "g" "failure"
  write_meta "envC" "g" "cancelled"
  write_meta "envK" "g" "skipped"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local log="${TEST_DIR}/step.log"
  # All four emoji+title pairs must appear at least once in the Format row
  local fmt_row
  fmt_row=$(grep -E '^\| <span title="Format and Style"' "${log}")
  for pair in \
    '<span title="success">✅</span>' \
    '<span title="failure">❌</span>' \
    '<span title="cancelled">🚫</span>' \
    '<span title="skipped">⏭️</span>'; do
    if ! echo "${fmt_row}" | grep -qF "${pair}"; then
      echo "expected '${pair}' in Format row: ${fmt_row}"
      return 1
    fi
  done
  return 0
}

test_plan_details_optional_categories() {
  # Set non-zero move and remove for one env
  local counts='{"count-add":"3","count-change":"2","count-destroy":"1","count-import":"0","count-move":"4","count-remove":"5"}'
  write_meta "myenv" "g" "success" "${counts}"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local log="${TEST_DIR}/step.log"
  # add/change/destroy always present
  grep -q '`💫 3` add' "${log}" || { echo "missing add badge"; return 1; }
  grep -q '`🛠️ 2` change' "${log}" || { echo "missing change badge"; return 1; }
  grep -q '`💥 1` destroy' "${log}" || { echo "missing destroy badge"; return 1; }
  # move and remove non-zero -> present
  grep -q '`🔀 4` move' "${log}" || { echo "missing move badge"; return 1; }
  grep -q '`⛓️‍💥 5` remove' "${log}" || { echo "missing remove badge"; return 1; }
  # import was zero -> must NOT appear
  if grep -q '`📥 0` import' "${log}"; then
    echo "import (count=0) must not appear"
    return 1
  fi
  return 0
}

test_plan_details_left_align_div() {
  write_meta "envA" "g"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q '<div align="left">' "${TEST_DIR}/step.log"; then
    echo "expected Plan Details cell to wrap in <div align=\"left\">"
    return 1
  fi
  return 0
}

test_group_marker_then_prefix_byte_exact() {
  write_meta "envA" "dev"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Body line 1 must be the HTML marker (load-bearing for upsert identity).
  # Body line 2 must be the byte-exact group H3 (still visible to readers).
  if ! grep -q '^<!-- tf:head:group:dev -->$' "${TEST_DIR}/step.log"; then
    echo "expected byte-exact marker line '<!-- tf:head:group:dev -->'"
    return 1
  fi
  if ! grep -q '^### Terraform validation summary for group: `dev`$' "${TEST_DIR}/step.log"; then
    echo "expected byte-exact H3 group heading"
    return 1
  fi
  return 0
}

test_degraded_mode_when_list_fails() {
  write_meta "envA" "g"
  # Make gh list call fail
  export GH_FAKE_LIST_EXIT=1
  echo "boom" > "${GH_FAKE_LIST_RESPONSE_FILE}"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE} (degraded mode should still succeed overall)"; return 1; }
  if ! grep -q 'degraded mode' "${TEST_DIR}/step.log"; then
    echo "expected 'degraded mode' log line"
    return 1
  fi
  # Delete pass must be skipped
  if grep -q 'DELETE' "${GH_FAKE_CALL_LOG}"; then
    echo "DELETE must NOT be called in degraded mode"
    return 1
  fi
  # POST must still happen so the table renders
  if [[ $(grep -c 'POST' "${GH_FAKE_CALL_LOG}") -ne 1 ]]; then
    echo "expected 1 POST even in degraded mode"
    return 1
  fi
  return 0
}

test_malformed_metadata_is_skipped() {
  write_meta "good" "g"
  echo "not valid json" > "${TEST_DIR}/matrix-job-meta-broken.json"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q 'Skipping malformed metadata file' "${TEST_DIR}/step.log"; then
    echo "expected 'Skipping malformed' warning"
    return 1
  fi
  # Good file should still be processed
  if ! grep -q "Env 'good' belongs to group 'g'" "${TEST_DIR}/step.log"; then
    echo "valid file should still be processed"
    return 1
  fi
  return 0
}

test_envs_without_group_are_ignored() {
  write_meta "in-group" "dev"
  write_meta "no-group" ""
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Header should only have the in-group env
  if ! grep -q '|  | Step | in-group |$' "${TEST_DIR}/step.log"; then
    echo "header should contain only 'in-group' env"
    grep '|  | Step |' "${TEST_DIR}/step.log"
    return 1
  fi
  return 0
}

test_multiple_groups_sorted_alphabetically() {
  write_meta "zenv" "zebra"
  write_meta "aenv" "alpha"
  write_meta "menv" "mike"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Three POSTs in alphabetical group order
  if [[ $(grep -c 'POST' "${GH_FAKE_CALL_LOG}") -ne 3 ]]; then
    echo "expected 3 POSTs (one per group)"
    return 1
  fi
  # Per-group log group names appear in alpha order
  local order
  order=$(grep -oE "Step 5: Upsert group '[^']+'" "${TEST_DIR}/step.log" | head -3 | tr '\n' ' ')
  local expected="Step 5: Upsert group 'alpha' Step 5: Upsert group 'mike' Step 5: Upsert group 'zebra' "
  if [[ "${order}" != "${expected}" ]]; then
    echo "groups not in alphabetical order"
    echo "got:      ${order}"
    echo "expected: ${expected}"
    return 1
  fi
  return 0
}

test_groups_processed_json_output() {
  # 'dev' is desired but has no existing marker → posted fresh.
  # 'obsolete' has an existing marker but is not desired → orphan-deleted.
  write_meta "envA" "dev"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 8001, "created_at": "2026-01-30T10:00:00Z", "body": "<!-- tf:head:group:obsolete -->\n### Terraform validation summary for group: `obsolete`\n"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local processed
  processed=$(get_processed_json)
  if ! echo "${processed}" | jq -e '.[] | select(.action == "orphan-deleted" and .group == "obsolete")' >/dev/null; then
    echo "expected orphan-deleted entry for 'obsolete'"
    echo "got: ${processed}"
    return 1
  fi
  if ! echo "${processed}" | jq -e '.[] | select(.action == "posted" and .group == "dev")' >/dev/null; then
    echo "expected posted entry for 'dev'"
    echo "got: ${processed}"
    return 1
  fi
  return 0
}

test_step_row_order_byte_exact() {
  write_meta "envA" "g"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local log="${TEST_DIR}/step.log"
  # Extract just the table body rows in order
  local lines
  lines=$(grep -oE '^\| <span title="[^"]+">' "${log}" | head -9)
  local expected='| <span title="Initialization">
| <span title="Lock file">
| <span title="Format and Style">
| <span title="Validate">
| <span title="TFLint">
| <span title="Plan">
| <span title="Plan details">
| <span title="Plan time">
| <span title="Links">'
  if [[ "${lines}" != "${expected}" ]]; then
    echo "step row order mismatch"
    echo "got:"
    echo "${lines}"
    echo "expected:"
    echo "${expected}"
    return 1
  fi
  return 0
}

test_missing_pr_number_fails_fast() {
  write_meta "envA" "g"
  unset input_pr_number
  run_step
  if [[ ${STEP_EXIT_CODE} -eq 0 ]]; then
    echo "expected non-zero exit when input_pr_number missing"
    return 1
  fi
  if ! grep -q 'input_pr_number is required' "${TEST_DIR}/step.log"; then
    echo "expected 'input_pr_number is required' error"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# Plan time row
# --------------------------------------------------------------------------

# Plan time present in metadata → backtick-wrapped value wrapped in a
# <span title="mm:ss (minutes:seconds)"> so desktop hover surfaces the unit.
test_plan_time_row_renders_value() {
  write_meta "envA" "g" "success" "" "1:23"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local log="${TEST_DIR}/step.log"
  local expected='| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">`1:23`</span> |'
  if ! grep -qF "${expected}" "${log}"; then
    echo "expected Plan time row with value-cell tooltip"
    echo "expected line: ${expected}"
    grep -F 'Plan time' "${log}" | sed 's/^/  /'
    return 1
  fi
  return 0
}

# Plan time absent from metadata → cell renders the 'not applicable' dash,
# still wrapped in the same tooltip so the column meaning stays discoverable.
test_plan_time_row_renders_em_dash_when_missing() {
  write_meta "envA" "g"  # no plan_time → plan.outputs is '{}'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local log="${TEST_DIR}/step.log"
  local expected='| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">—</span> |'
  if ! grep -qF "${expected}" "${log}"; then
    echo "expected em-dash cell with tooltip for missing plan-time"
    echo "expected line: ${expected}"
    grep -F 'Plan time' "${log}" | sed 's/^/  /'
    return 1
  fi
  return 0
}

# Multi-env group: each env's Plan time cell reflects its own metadata,
# rows are emitted in alphabetical column order. Each cell carries the
# same tooltip — present-value and em-dash branches alike.
test_plan_time_row_per_env() {
  # Alphabetical column order makes the env-to-cell mapping predictable.
  write_meta "alpha" "g" "success" "" "0:42"
  write_meta "bravo" "g" "success" "" ""        # missing → "—"
  write_meta "charlie" "g" "success" "" "2:05"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local log="${TEST_DIR}/step.log"
  # Build expected row: icon | label | alpha-cell | bravo-cell | charlie-cell
  local expected='| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">`0:42`</span> | <span title="mm:ss (minutes:seconds)">—</span> | <span title="mm:ss (minutes:seconds)">`2:05`</span> |'
  if ! grep -qF "${expected}" "${log}"; then
    echo "expected per-env Plan time row not found"
    echo "expected line: ${expected}"
    grep -F 'Plan time' "${log}" | sed 's/^/  /'
    return 1
  fi
  return 0
}

# Plan time row sits between Plan Details and Links.
test_plan_time_row_position() {
  write_meta "envA" "g" "success" "" "0:05"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local log="${TEST_DIR}/step.log"
  local pd_line pt_line links_line
  pd_line=$(grep -n '| <span title="Plan details">' "${log}" | head -n1 | cut -d: -f1)
  pt_line=$(grep -n '| <span title="Plan time">'    "${log}" | head -n1 | cut -d: -f1)
  links_line=$(grep -n '| <span title="Links">'     "${log}" | head -n1 | cut -d: -f1)
  if [ -z "${pd_line}" ] || [ -z "${pt_line}" ] || [ -z "${links_line}" ]; then
    echo "expected Plan details, Plan time and Links rows all present (pd=${pd_line} pt=${pt_line} links=${links_line})"
    return 1
  fi
  if ! { [ "${pt_line}" -gt "${pd_line}" ] && [ "${pt_line}" -lt "${links_line}" ]; }; then
    echo "expected Plan time row between Plan details (${pd_line}) and Links (${links_line}); got pt=${pt_line}"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# Marker-based upsert behaviour
# --------------------------------------------------------------------------

# Existing single marker comment for desired group → PATCHed in place
# (stable comment id; no fresh POST, no DELETE).
test_existing_marker_is_patched() {
  write_meta "envA" "dev"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 6001, "created_at": "2026-01-30T10:00:00Z", "body": "<!-- tf:head:group:dev -->\n### Terraform validation summary for group: `dev`\nold body"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/6001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH of existing marker comment 6001"
    grep -E 'PATCH|POST|DELETE' "${GH_FAKE_CALL_LOG}" || true
    return 1
  fi
  if grep -q 'POST' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect POST when existing marker can be patched"; return 1
  fi
  if grep -q 'DELETE' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect DELETE when only a single matching marker exists"; return 1
  fi
  # Processed JSON should record action=patched
  local processed
  processed=$(get_processed_json)
  if ! echo "${processed}" | jq -e '.[] | select(.action == "patched" and .group == "dev" and ."comment-id" == "6001")' >/dev/null; then
    echo "expected processed-json entry {group: 'dev', action: 'patched', id: 6001}"
    echo "got: ${processed}"
    return 1
  fi
  return 0
}

# Multiple marker comments for the SAME group (pre-existing duplicates) →
# oldest is PATCHed, the rest are deleted. Self-healing.
test_duplicate_markers_delete_extras_patch_oldest() {
  write_meta "envA" "dev"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 6100, "created_at": "2026-02-01T10:00:00Z", "body": "<!-- tf:head:group:dev -->\n### Terraform validation summary for group: `dev`\nmid-age dup"},
  {"id": 6200, "created_at": "2026-03-01T10:00:00Z", "body": "<!-- tf:head:group:dev -->\n### Terraform validation summary for group: `dev`\nnewest dup"},
  {"id": 6050, "created_at": "2026-01-15T10:00:00Z", "body": "<!-- tf:head:group:dev -->\n### Terraform validation summary for group: `dev`\noldest — should be kept"}
]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Oldest (6050) is patched, the two newer are deleted
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/6050' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH of oldest duplicate 6050"
    grep -E 'PATCH|POST|DELETE' "${GH_FAKE_CALL_LOG}" || true
    return 1
  fi
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/6100' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE of duplicate 6100"; return 1
  fi
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/6200' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE of duplicate 6200"; return 1
  fi
  # Patched and duplicate-deleted should both appear in processed-json
  local processed
  processed=$(get_processed_json)
  if ! echo "${processed}" | jq -e '.[] | select(.action == "patched" and ."comment-id" == "6050")' >/dev/null; then
    echo "expected processed.action=patched id=6050"; echo "got: ${processed}"; return 1
  fi
  if ! echo "${processed}" | jq -e '[.[] | select(.action == "duplicate-deleted")] | length == 2' >/dev/null; then
    echo "expected 2 duplicate-deleted entries"; echo "got: ${processed}"; return 1
  fi
  return 0
}

# Legacy comment from the pre-marker era (body starts with the H3, no
# marker) → ignored: no DELETE, no PATCH. The system posts a fresh
# marked comment alongside it (the no-migration trade-off — operators
# clean up legacy comments by hand).
test_legacy_prefix_only_comment_is_ignored() {
  write_meta "envA" "dev"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 6300, "created_at": "2025-12-01T10:00:00Z", "body": "### Terraform validation summary for group: `dev`\nlegacy body without marker"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/6300' "${GH_FAKE_CALL_LOG}"; then
    echo "legacy comment 6300 MUST NOT be deleted (no migration policy)"; return 1
  fi
  if grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/6300' "${GH_FAKE_CALL_LOG}"; then
    echo "legacy comment 6300 MUST NOT be patched"; return 1
  fi
  if [[ $(grep -c 'POST' "${GH_FAKE_CALL_LOG}") -ne 1 ]]; then
    echo "expected exactly 1 POST (fresh marked comment alongside legacy)"; return 1
  fi
  return 0
}

# Marker comment body line 1 must be the per-group marker; line 2 blank;
# line 3 the visible H3. Pinning byte-level shape so accidental drift in
# render_group_body or _render_full_body breaks this test (and only this
# test).
test_body_starts_with_marker_then_h3() {
  write_meta "envA" "dev"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # The assembled body is echoed into the step log right after a
  # 'aggregate-validation-summaries: Body:' line; capture the first three
  # lines after that — marker, blank, H3.
  local seen_marker seen_h3
  seen_marker=$(awk '/Body:$/ {flag=1; next} flag {print; exit}' "${TEST_DIR}/step.log")
  # H3 is the next non-blank line.
  seen_h3=$(awk '/Body:$/ {flag=1; n=0; next} flag {n++; if (n>=2 && NF) {print; exit}}' "${TEST_DIR}/step.log")

  local marker_line='<!-- tf:head:group:dev -->'
  local h3_line='### Terraform validation summary for group: `dev`'

  if [[ "${seen_marker}" != "${marker_line}" ]]; then
    echo "expected line 1 = '${marker_line}', got '${seen_marker}'"; return 1
  fi
  if [[ "${seen_h3}" != "${h3_line}" ]]; then
    echo "expected first non-blank line after marker = '${h3_line}', got '${seen_h3}'"; return 1
  fi
  return 0
}

# Two distinct groups (dev + prod) both have existing markers → both get
# PATCHed in their own pass, neither is deleted, no POST occurs. Verifies
# per-group markers route correctly when multiple group comments coexist.
test_multiple_groups_each_patched() {
  write_meta "envA" "dev"
  write_meta "envB" "prod"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 6400, "created_at": "2026-01-15T10:00:00Z", "body": "<!-- tf:head:group:dev -->\n### Terraform validation summary for group: `dev`\nold dev"},
  {"id": 6500, "created_at": "2026-01-15T10:00:00Z", "body": "<!-- tf:head:group:prod -->\n### Terraform validation summary for group: `prod`\nold prod"}
]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/6400' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH of dev marker 6400"; return 1
  fi
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/6500' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH of prod marker 6500"; return 1
  fi
  if grep -q 'POST' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect POST when both groups have existing markers"; return 1
  fi
  if grep -q 'DELETE' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect DELETE when no orphans and no duplicates"; return 1
  fi
  return 0
}

# PATCH failure → fall back to POST so the comment is still visible.
test_patch_failure_falls_back_to_post() {
  write_meta "envA" "dev"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 6600, "created_at": "2026-01-30T10:00:00Z", "body": "<!-- tf:head:group:dev -->\n### Terraform validation summary for group: `dev`\nold body"}]
JSON
  export GH_FAKE_PATCH_EXIT=22
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE} — PATCH failure should not abort"; return 1; }
  # PATCH was attempted on 6600, failed, then POST as fallback
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/6600' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH attempt before fallback"; return 1
  fi
  if [[ $(grep -c 'POST' "${GH_FAKE_CALL_LOG}") -ne 1 ]]; then
    echo "expected exactly 1 POST as fallback after PATCH failure"; return 1
  fi
  return 0
}

test_post_failure_recorded_without_aborting() {
  write_meta "envA" "g"
  export GH_FAKE_POST_EXIT=22
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE} — should not abort on post failure"; return 1; }
  local processed
  processed=$(get_processed_json)
  if ! echo "${processed}" | jq -e '.[] | select(.action == "post-failed")' >/dev/null; then
    echo "expected post-failed entry in groups-processed-json"
    echo "got: ${processed}"
    return 1
  fi
  return 0
}

# ============================================================================
# Run tests
# ============================================================================

run_test "empty desired + empty existing is a no-op"                       test_empty_desired_empty_existing_is_noop
run_test "sweep mode: empty desired + orphan existing → delete only"       test_sweep_only_orphans
run_test "post mode: desired + no existing → post only"                    test_post_when_no_existing
run_test "mixed upsert: orphan deleted + matching marker patched in place" test_mixed_orphan_delete_and_patch
run_test "envs render in alphabetical column order"                        test_alphabetical_column_order
run_test "per-env anchor resolved → log-extract link rendered"             test_per_env_anchor_resolved
run_test "anchor missing + job URL resolved → Links shows only job log"    test_per_env_anchor_missing_but_job_url_resolved_shows_only_job_log
run_test "neither anchor nor job URL → Links cell is empty"                test_neither_anchor_nor_job_url_yields_empty_cell
run_test "both anchor + job URL resolved → both lines, <br>-joined"        test_both_anchor_and_job_url_resolved_shows_both_with_br
run_test "Jobs API failure → 'job log' line omitted for all envs"          test_jobs_api_failure_omits_job_log_for_all_envs
run_test "job URL resolution handles 'caller / Terraform (env)' prefix"   test_job_url_resolution_handles_caller_prefixed_name
run_test "job URL resolution handles bare 'Terraform (env)' too"          test_job_url_resolution_handles_bare_name
run_test "job URL resolution skips non-matrix jobs"                       test_job_url_resolution_skips_non_matrix_jobs
run_test "upsert pass does NOT nest log groups"                            test_upsert_pass_does_not_nest_log_groups
run_test "grouped head footer is [Workflow log] (workflow run URL)"       test_grouped_footer_is_workflow_log
run_test "per-env anchor picks newest comment id across multiple attempts" test_per_env_anchor_picks_newest_when_multiple_attempts
run_test "status emoji map covers success/failure/cancelled/skipped"       test_status_emoji_map
run_test "Plan Details: optional categories appear only when non-zero"     test_plan_details_optional_categories
run_test "Plan Details cell wraps in <div align='left'>"                   test_plan_details_left_align_div
run_test "group marker + H3 prefix lines are byte-exact"                   test_group_marker_then_prefix_byte_exact
run_test "degraded mode: gh list fails → skip orphan delete, fresh POST"   test_degraded_mode_when_list_fails
run_test "malformed metadata file is skipped with warning"                 test_malformed_metadata_is_skipped
run_test "envs without pr-comment-group are ignored"                       test_envs_without_group_are_ignored
run_test "multiple groups are posted in alphabetical order"                test_multiple_groups_sorted_alphabetically
run_test "groups-processed-json output records every action"               test_groups_processed_json_output
run_test "table step rows appear in spec order"                            test_step_row_order_byte_exact
run_test "Plan time row renders backtick-wrapped value when present"        test_plan_time_row_renders_value
run_test "Plan time row renders em-dash '—' when plan-time missing"         test_plan_time_row_renders_em_dash_when_missing
run_test "Plan time row reflects per-env values across multi-env group"    test_plan_time_row_per_env
run_test "Plan time row sits between Plan details and Links rows"           test_plan_time_row_position
run_test "missing input_pr_number fails the step"                          test_missing_pr_number_fails_fast
run_test "post failure does not abort, recorded in output"                 test_post_failure_recorded_without_aborting
run_test "existing marker comment → PATCHed in place (stable id)"          test_existing_marker_is_patched
run_test "duplicate markers → delete extras, PATCH oldest"                 test_duplicate_markers_delete_extras_patch_oldest
run_test "legacy prefix-only comment → ignored (no-migration policy)"      test_legacy_prefix_only_comment_is_ignored
run_test "body starts with marker on line 1, H3 next non-blank"            test_body_starts_with_marker_then_h3
run_test "multiple groups: each marker patched independently"              test_multiple_groups_each_patched
run_test "PATCH failure → fall back to POST"                               test_patch_failure_falls_back_to_post

# ============================================================================
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
