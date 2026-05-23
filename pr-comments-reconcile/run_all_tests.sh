#!/bin/env bash
#
# Test runner for step_reconcile.sh
#
# Strategy mirrors aggregate-validation-summaries/run_all_tests.sh:
# fake `gh` on PATH, response files in TEST_DIR, subshell sourcing,
# assertions on stdout + GITHUB_OUTPUT + recorded gh calls.
#

set -u
_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

setup() {
  TEST_DIR=$(mktemp -d)

  mkdir -p "${TEST_DIR}/bin"
  cat > "${TEST_DIR}/bin/gh" <<'FAKE_GH'
#!/bin/bash
LOG="${GH_FAKE_CALL_LOG:-/dev/null}"
echo "gh $*" >> "${LOG}"
case "$*" in
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
  unset GH_FAKE_LIST_EXIT GH_FAKE_DELETE_EXIT GH_FAKE_POST_EXIT GH_FAKE_PATCH_EXIT
  echo "[]" > "${GH_FAKE_LIST_RESPONSE_FILE}"
  : > "${GH_FAKE_CALL_LOG}"

  export PATH="${TEST_DIR}/bin:${PATH}"

  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${TEST_DIR}"
  export GH_TOKEN="fake"

  export input_repo="dsb-norge/test-repo"
  export input_issue_number="123"
  export input_heads_yml="[]"
  export input_gc_yml="[]"

  cd "${TEST_DIR}"
}

teardown() {
  unset input_repo input_issue_number input_heads_yml input_gc_yml
  rm -rf "${TEST_DIR}" 2>/dev/null || true
  unset TEST_DIR
}

run_step() {
  # Match production: action.yml shim sources step under 'bash -eo pipefail'.
  # Without -eo pipefail the harness silently tolerates bugs (failed
  # subcommand, broken pipeline) that would crash the step in CI.
  (
    set -eo pipefail
    set -o allexport
    source "${_this_script_dir}/step_reconcile.sh"
  ) > "${TEST_DIR}/step.log" 2>&1
  STEP_EXIT_CODE=$?
}

# Read reconcile-json (multi-line) from GITHUB_OUTPUT
get_reconcile_json() {
  local content="" delim="" in_block=false
  while IFS= read -r line; do
    if [[ "${in_block}" == true ]]; then
      if [[ "${line}" == "${delim}" ]]; then break; fi
      if [[ -n "${content}" ]]; then content="${content}"$'\n'"${line}"; else content="${line}"; fi
    elif [[ "${line}" =~ ^reconcile-json\<\<(.*)$ ]]; then
      delim="${BASH_REMATCH[1]}"
      in_block=true
    fi
  done < "${GITHUB_OUTPUT}"
  echo "${content}"
}

count_calls() {
  local verb="${1}"
  local n
  n=$(grep -c -- "-X ${verb}" "${GH_FAKE_CALL_LOG}" 2>/dev/null || true)
  echo "${n:-0}"
}

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

test_empty_inputs_noop() {
  # heads=[], gc=[], no existing comments → just one list call, nothing else.
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls POST)" -eq 0 ]] || { echo "expected 0 POST"; return 1; }
  [[ "$(count_calls PATCH)" -eq 0 ]] || { echo "expected 0 PATCH"; return 1; }
  [[ "$(count_calls DELETE)" -eq 0 ]] || { echo "expected 0 DELETE"; return 1; }
  local json
  json=$(get_reconcile_json)
  [[ "$(echo "${json}" | jq 'length')" -eq 0 ]] || { echo "expected empty reconcile-json"; return 1; }
  return 0
}

test_empty_pr_three_heads_posts_in_order() {
  export input_heads_yml='- marker: "<!-- h:a -->"
  body: "body a"
- marker: "<!-- h:b -->"
  body: "body b"
- marker: "<!-- h:c -->"
  body: "body c"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls POST)" -eq 3 ]] || { echo "expected 3 POST, got $(count_calls POST)"; return 1; }
  [[ "$(count_calls PATCH)" -eq 0 ]] || { echo "expected 0 PATCH"; return 1; }
  # Verify declared order via the gh call log: POSTs appear in a:b:c sequence.
  # The fake gh logs each call; POSTs don't carry the body inline (it's
  # passed via -F body=@file), so we assert order via the reconcile-json
  # output which records markers in processing order.
  local json
  json=$(get_reconcile_json)
  local m1 m2 m3
  m1=$(echo "${json}" | jq -r '.[0].marker')
  m2=$(echo "${json}" | jq -r '.[1].marker')
  m3=$(echo "${json}" | jq -r '.[2].marker')
  [[ "${m1}" == "<!-- h:a -->" ]] || { echo "expected first marker h:a, got ${m1}"; return 1; }
  [[ "${m2}" == "<!-- h:b -->" ]] || { echo "expected second marker h:b, got ${m2}"; return 1; }
  [[ "${m3}" == "<!-- h:c -->" ]] || { echo "expected third marker h:c, got ${m3}"; return 1; }
  # All three should be created
  [[ "$(echo "${json}" | jq '[.[] | select(.action == "created")] | length')" -eq 3 ]] || { echo "expected 3 created"; return 1; }
  return 0
}

test_one_head_exists_different_hash_others_new() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 4001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- h:b -->\n<!-- comment-hash:beefdead -->\nold"}]
JSON
  export input_heads_yml='- marker: "<!-- h:a -->"
  body: "body a"
- marker: "<!-- h:b -->"
  body: "body b"
- marker: "<!-- h:c -->"
  body: "body c"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls PATCH)" -eq 1 ]] || { echo "expected 1 PATCH, got $(count_calls PATCH)"; return 1; }
  [[ "$(count_calls POST)" -eq 2 ]] || { echo "expected 2 POST, got $(count_calls POST)"; return 1; }
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/4001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH on id 4001"; return 1
  fi
  return 0
}

test_all_heads_exist_all_patched() {
  # Every matching head triggers a PATCH — no hash short-circuit.
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 5001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- h:a -->\nbody a"},
  {"id": 5002, "created_at": "2026-01-02T00:00:00Z", "body": "<!-- h:b -->\nbody b"}
]
JSON
  export input_heads_yml='- marker: "<!-- h:a -->"
  body: "body a"
- marker: "<!-- h:b -->"
  body: "body b"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls POST)" -eq 0 ]] || { echo "expected 0 POST"; return 1; }
  [[ "$(count_calls PATCH)" -eq 2 ]] || { echo "expected 2 PATCH, got $(count_calls PATCH)"; return 1; }
  local json
  json=$(get_reconcile_json)
  [[ "$(echo "${json}" | jq '[.[] | select(.action == "updated")] | length')" -eq 2 ]] || {
    echo "expected 2 updated, got: ${json}"; return 1
  }
  return 0
}

test_gc_deletes_non_matching() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 6001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- tf:tag:plan:dev:run-id-100 -->\nplan content (stale)"},
  {"id": 6002, "created_at": "2026-01-02T00:00:00Z", "body": "<!-- tf:tag:plan:dev:run-id-200 -->\nplan content (current)"},
  {"id": 6003, "created_at": "2026-01-03T00:00:00Z", "body": "<!-- tf:tag:plan:test:run-id-100 -->\nanother stale"},
  {"id": 6004, "created_at": "2026-01-04T00:00:00Z", "body": "Unrelated comment from reviewer"}
]
JSON
  export input_gc_yml='- marker-prefix: "<!-- tf:tag:plan:"
  keep-marker-substring: "run-id-200"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Should delete 6001 and 6003, keep 6002 (matches keep) and 6004 (doesn't match prefix)
  [[ "$(count_calls DELETE)" -eq 2 ]] || { echo "expected 2 DELETE, got $(count_calls DELETE)"; return 1; }
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/6001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE on 6001"; return 1
  fi
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/6003' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE on 6003"; return 1
  fi
  if grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/6002' "${GH_FAKE_CALL_LOG}"; then
    echo "did not expect DELETE on 6002 (current run-id)"; return 1
  fi
  return 0
}

test_gc_no_matches_is_noop() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 7001, "created_at": "2026-01-01T00:00:00Z", "body": "Unrelated comment"}]
JSON
  export input_gc_yml='- marker-prefix: "<!-- tf:tag:plan:"
  keep-marker-substring: "run-id-999"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls DELETE)" -eq 0 ]] || { echo "expected 0 DELETE"; return 1; }
  return 0
}

test_empty_gc_yml_skips_gc_even_with_matching_comments() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 8001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- tf:tag:plan:dev:run-id-100 -->\nstale plan"}]
JSON
  # Default input_gc_yml="[]" — no GC rules
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls DELETE)" -eq 0 ]] || { echo "expected 0 DELETE without GC rules"; return 1; }
  return 0
}

test_empty_heads_yml_skips_heads_pass() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 9001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- h:would-match -->\nexisting"}]
JSON
  # Default input_heads_yml="[]"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls POST)" -eq 0 ]] || { echo "expected 0 POST without heads"; return 1; }
  [[ "$(count_calls PATCH)" -eq 0 ]] || { echo "expected 0 PATCH without heads"; return 1; }
  return 0
}

test_heads_and_gc_together() {
  # One head matches (PATCH); one head new (POST); one stale tag GC'd.
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 10001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- h:existing -->\nold body"},
  {"id": 10002, "created_at": "2026-01-02T00:00:00Z", "body": "<!-- tf:tag:plan:dev:run-id-100 -->\nstale"}
]
JSON
  export input_heads_yml='- marker: "<!-- h:existing -->"
  body: "fresh body"
- marker: "<!-- h:new -->"
  body: "brand new"'
  export input_gc_yml='- marker-prefix: "<!-- tf:tag:plan:"
  keep-marker-substring: "run-id-200"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls PATCH)" -eq 1 ]] || { echo "expected 1 PATCH"; return 1; }
  [[ "$(count_calls POST)" -eq 1 ]] || { echo "expected 1 POST"; return 1; }
  [[ "$(count_calls DELETE)" -eq 1 ]] || { echo "expected 1 DELETE (GC)"; return 1; }
  return 0
}

test_gc_runs_before_heads() {
  # GC must DELETE stale tags BEFORE any heads PATCH/POST so outdated plan
  # output disappears as early as possible during a re-run. Verify by
  # checking the order of API calls in the gh log: every DELETE that
  # comes from the GC pass must appear before any PATCH or POST.
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 10001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- h:existing -->\nold body"},
  {"id": 10002, "created_at": "2026-01-02T00:00:00Z", "body": "<!-- tf:tag:plan:dev:run-id-100 -->\nstale"}
]
JSON
  export input_heads_yml='- marker: "<!-- h:existing -->"
  body: "fresh"'
  export input_gc_yml='- marker-prefix: "<!-- tf:tag:plan:"
  keep-marker-substring: "run-id-200"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }

  # Capture line numbers in the gh call log.
  local first_delete first_write
  first_delete=$(grep -n -- "-X DELETE" "${GH_FAKE_CALL_LOG}" | head -n1 | cut -d: -f1)
  first_write=$(grep -nE -- "-X (PATCH|POST)" "${GH_FAKE_CALL_LOG}" | head -n1 | cut -d: -f1)

  if [ -z "${first_delete}" ] || [ -z "${first_write}" ]; then
    echo "expected at least one DELETE and one PATCH/POST in the call log"
    cat "${GH_FAKE_CALL_LOG}"
    return 1
  fi
  if [ "${first_delete}" -ge "${first_write}" ]; then
    echo "expected DELETE (line ${first_delete}) BEFORE first PATCH/POST (line ${first_write})"
    cat "${GH_FAKE_CALL_LOG}"
    return 1
  fi
  return 0
}

test_degraded_mode_heads_posted_gc_skipped() {
  export GH_FAKE_LIST_EXIT=1
  export input_heads_yml='- marker: "<!-- h:a -->"
  body: "body a"
- marker: "<!-- h:b -->"
  body: "body b"'
  export input_gc_yml='- marker-prefix: "<!-- tf:tag:plan:"
  keep-marker-substring: "run-id-999"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls POST)" -eq 2 ]] || { echo "expected 2 POST (best-effort heads)"; return 1; }
  [[ "$(count_calls DELETE)" -eq 0 ]] || { echo "expected 0 DELETE in degraded mode"; return 1; }
  return 0
}

test_malformed_heads_yml_fails_fast() {
  # Truly malformed YAML: an unterminated quoted string. yq will reject this.
  export input_heads_yml='- marker: "unterminated
  body: foo'
  run_step
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for malformed yml"; return 1; }
  return 0
}

test_reconcile_json_contains_all_actions() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 11001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- h:patched -->\nold"}]
JSON
  export input_heads_yml='- marker: "<!-- h:patched -->"
  body: "new body for patched"
- marker: "<!-- h:created -->"
  body: "brand new"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  local json
  json=$(get_reconcile_json)
  # First entry should be h:patched with action=updated
  [[ "$(echo "${json}" | jq -r '.[0].marker')" == "<!-- h:patched -->" ]] || { echo "first marker mismatch"; return 1; }
  [[ "$(echo "${json}" | jq -r '.[0].action')" == "updated" ]] || { echo "first action should be updated"; return 1; }
  [[ "$(echo "${json}" | jq -r '.[0]."comment-id"')" == "11001" ]] || { echo "first comment-id should be 11001"; return 1; }
  # Second entry h:created with action=created
  [[ "$(echo "${json}" | jq -r '.[1].action')" == "created" ]] || { echo "second action should be created"; return 1; }
  return 0
}

test_duplicate_heads_keep_oldest() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 12001, "created_at": "2026-02-01T00:00:00Z", "body": "<!-- h:dup -->\nnewer"},
  {"id": 12002, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- h:dup -->\noldest (keep)"},
  {"id": 12003, "created_at": "2026-03-01T00:00:00Z", "body": "<!-- h:dup -->\nnewest"}
]
JSON
  export input_heads_yml='- marker: "<!-- h:dup -->"
  body: "fresh"'
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/12002' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH on oldest id 12002"; return 1
  fi
  [[ "$(count_calls DELETE)" -eq 2 ]] || { echo "expected 2 DELETE (duplicates)"; return 1; }
  return 0
}

test_missing_required_input_fails_fast() {
  unset input_repo
  run_step
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for missing input_repo"; return 1; }
  return 0
}

# ============================================================================
# Run all
# ============================================================================

run_test "empty inputs → no-op (list only)"                              test_empty_inputs_noop
run_test "empty PR + 3 heads → 3 POST in declared order"                 test_empty_pr_three_heads_posts_in_order
run_test "1 of 3 heads exists, different hash → 1 PATCH, 2 POST"         test_one_head_exists_different_hash_others_new
run_test "all heads exist → all PATCHed"                                 test_all_heads_exist_all_patched
run_test "GC: deletes non-matching, keeps current and unrelated"         test_gc_deletes_non_matching
run_test "GC: no prefix matches → no DELETEs"                            test_gc_no_matches_is_noop
run_test "empty gc-yml → skip GC even when matching comments exist"      test_empty_gc_yml_skips_gc_even_with_matching_comments
run_test "empty heads-yml → skip heads pass even when matches exist"     test_empty_heads_yml_skips_heads_pass
run_test "heads + GC together → both passes work"                        test_heads_and_gc_together
run_test "GC runs BEFORE heads (stale tags vanish first)"                test_gc_runs_before_heads
run_test "degraded (list fails) → heads POSTed best-effort, GC skipped"  test_degraded_mode_heads_posted_gc_skipped
run_test "malformed heads-yml → fail-fast"                               test_malformed_heads_yml_fails_fast
run_test "reconcile-json output records every head action"               test_reconcile_json_contains_all_actions
run_test "duplicate heads → keep oldest, PATCH it, DELETE rest"          test_duplicate_heads_keep_oldest
run_test "missing required input → fail-fast"                            test_missing_required_input_fails_fast

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
