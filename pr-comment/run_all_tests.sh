#!/bin/env bash
#
# Test runner for step_pr_comment.sh
#
# Strategy:
#   - Each test creates a temp dir
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

# Setup a fresh sandbox
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

  # Default inputs; tests override individual ones as needed
  export input_repo="dsb-norge/test-repo"
  export input_issue_number="123"
  export input_mode="upsert"
  export input_marker="<!-- tf:head:env:dev -->"
  export input_body="### dev

⏳ Running…
"

  cd "${TEST_DIR}"
}

teardown() {
  unset input_repo input_issue_number input_mode input_marker input_body
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
    source "${_this_script_dir}/step_pr_comment.sh"
  ) > "${TEST_DIR}/step.log" 2>&1
  STEP_EXIT_CODE=$?
}

# Read a single-line output value from GITHUB_OUTPUT
get_output() {
  local name="${1}"
  grep "^${name}=" "${GITHUB_OUTPUT}" | head -n1 | sed -E "s|^${name}=||"
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

# Count POST/PATCH/DELETE invocations in the gh call log
count_calls() {
  local verb="${1}"
  local n
  n=$(grep -c -- "-X ${verb}" "${GH_FAKE_CALL_LOG}" 2>/dev/null || true)
  echo "${n:-0}"
}

# ============================================================================
# Test cases
# ============================================================================

test_upsert_no_match_posts_fresh() {
  echo "[]" > "${GH_FAKE_LIST_RESPONSE_FILE}"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls POST)" -eq 1 ]] || { echo "expected 1 POST, got $(count_calls POST)"; return 1; }
  [[ "$(count_calls PATCH)" -eq 0 ]] || { echo "expected 0 PATCH"; return 1; }
  [[ "$(count_calls DELETE)" -eq 0 ]] || { echo "expected 0 DELETE"; return 1; }
  [[ "$(get_output action)" == "created" ]] || { echo "action='$(get_output action)', expected 'created'"; return 1; }
  return 0
}

test_upsert_match_different_hash_patches() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 1001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\n<!-- comment-hash:0000ffffdeadbeef -->\n\nold body"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls PATCH)" -eq 1 ]] || { echo "expected 1 PATCH, got $(count_calls PATCH)"; return 1; }
  [[ "$(count_calls POST)" -eq 0 ]] || { echo "expected 0 POST"; return 1; }
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/1001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH on id 1001"; return 1
  fi
  [[ "$(get_output action)" == "updated" ]] || { echo "action='$(get_output action)', expected 'updated'"; return 1; }
  [[ "$(get_output comment-id)" == "1001" ]] || { echo "comment-id='$(get_output comment-id)', expected '1001'"; return 1; }
  return 0
}

test_upsert_match_arbitrary_body_patches() {
  # Existing comment carries the marker — content underneath doesn't matter.
  # Every match triggers a PATCH (no hash short-circuit anymore).
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 2002, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\nany existing body content"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls PATCH)" -eq 1 ]] || { echo "expected 1 PATCH, got $(count_calls PATCH)"; return 1; }
  [[ "$(get_output action)" == "updated" ]] || { echo "action='$(get_output action)'"; return 1; }
  return 0
}

test_upsert_duplicates_keep_oldest() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 3001, "created_at": "2026-02-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\nnewer dup"},
  {"id": 3002, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\noldest"},
  {"id": 3003, "created_at": "2026-03-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\nnewest dup"}
]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Keep oldest (3002) → PATCH it; delete the other two
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/3002' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH on id 3002 (oldest)"; return 1
  fi
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/3001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE on id 3001"; return 1
  fi
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/3003' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE on id 3003"; return 1
  fi
  [[ "$(count_calls DELETE)" -eq 2 ]] || { echo "expected 2 DELETE, got $(count_calls DELETE)"; return 1; }
  [[ "$(count_calls PATCH)" -eq 1 ]] || { echo "expected 1 PATCH"; return 1; }
  [[ "$(get_output comment-id)" == "3002" ]] || { echo "expected comment-id=3002, got '$(get_output comment-id)'"; return 1; }
  return 0
}

test_upsert_patch_fail_falls_back_to_post() {
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 4001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\nold"}]
JSON
  export GH_FAKE_PATCH_EXIT=1
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls PATCH)" -eq 1 ]] || { echo "expected 1 PATCH attempt"; return 1; }
  [[ "$(count_calls POST)" -eq 1 ]] || { echo "expected 1 POST fallback"; return 1; }
  [[ "$(get_output action)" == "created" ]] || { echo "action='$(get_output action)', expected 'created'"; return 1; }
  return 0
}

test_delete_no_match() {
  export input_mode="delete"
  echo "[]" > "${GH_FAKE_LIST_RESPONSE_FILE}"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls DELETE)" -eq 0 ]] || { echo "expected 0 DELETE"; return 1; }
  [[ "$(get_output action)" == "not-found" ]] || { echo "action='$(get_output action)', expected 'not-found'"; return 1; }
  return 0
}

test_delete_single_match() {
  export input_mode="delete"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 5001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\nfoo"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls DELETE)" -eq 1 ]] || { echo "expected 1 DELETE"; return 1; }
  if ! grep -q 'DELETE repos/dsb-norge/test-repo/issues/comments/5001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected DELETE on id 5001"; return 1
  fi
  [[ "$(get_output action)" == "deleted" ]] || { echo "action='$(get_output action)'"; return 1; }
  return 0
}

test_delete_multiple_matches() {
  export input_mode="delete"
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[
  {"id": 6001, "created_at": "2026-01-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\na"},
  {"id": 6002, "created_at": "2026-02-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\nb"},
  {"id": 6003, "created_at": "2026-03-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\nc"}
]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls DELETE)" -eq 3 ]] || { echo "expected 3 DELETE, got $(count_calls DELETE)"; return 1; }
  [[ "$(get_output action)" == "deleted" ]] || { echo "action='$(get_output action)'"; return 1; }
  return 0
}

test_degraded_upsert_posts_fresh() {
  export GH_FAKE_LIST_EXIT=1
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls POST)" -eq 1 ]] || { echo "expected 1 POST in degraded upsert"; return 1; }
  [[ "$(count_calls PATCH)" -eq 0 ]] || { echo "expected 0 PATCH in degraded mode"; return 1; }
  [[ "$(get_output action)" == "created" ]] || { echo "action='$(get_output action)'"; return 1; }
  return 0
}

test_degraded_delete_is_noop() {
  export input_mode="delete"
  export GH_FAKE_LIST_EXIT=1
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(count_calls DELETE)" -eq 0 ]] || { echo "expected 0 DELETE in degraded delete"; return 1; }
  [[ "$(get_output action)" == "not-found" ]] || { echo "action='$(get_output action)'"; return 1; }
  return 0
}

test_input_validation_missing_mode() {
  unset input_mode
  run_step
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for missing mode"; return 1; }
  if ! grep -q "input_mode" "${TEST_DIR}/step.log"; then
    echo "expected error mentioning input_mode"; return 1
  fi
  return 0
}

test_input_validation_missing_marker() {
  unset input_marker
  run_step
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for missing marker"; return 1; }
  return 0
}

test_input_validation_invalid_mode() {
  export input_mode="frobnicate"
  run_step
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for invalid mode"; return 1; }
  if ! grep -q "Invalid mode" "${TEST_DIR}/step.log"; then
    echo "expected error mentioning Invalid mode"; return 1
  fi
  return 0
}

test_input_validation_upsert_missing_body() {
  export input_mode="upsert"
  unset input_body
  run_step
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for upsert with no body"; return 1; }
  if ! grep -q "input_body is required" "${TEST_DIR}/step.log"; then
    echo "expected error mentioning input_body required"; return 1
  fi
  return 0
}

test_delete_does_not_require_body() {
  export input_mode="delete"
  unset input_body
  echo "[]" > "${GH_FAKE_LIST_RESPONSE_FILE}"
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "expected zero exit; delete should not need body"; return 1; }
  return 0
}

test_pagination_flattens_multiple_pages() {
  # Simulate 3 pages: --paginate output is multiple JSON arrays concatenated.
  # Marker matches a comment on the 3rd page.
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 7001, "created_at": "2026-01-01T00:00:00Z", "body": "page1 unrelated"}]
[{"id": 7002, "created_at": "2026-02-01T00:00:00Z", "body": "page2 unrelated"}]
[{"id": 7003, "created_at": "2026-03-01T00:00:00Z", "body": "<!-- tf:head:env:dev -->\npage3 match"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  # Should PATCH the match on page 3
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/7003' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH on id 7003 (page 3 match)"; return 1
  fi
  [[ "$(get_output action)" == "updated" ]] || { echo "action='$(get_output action)'"; return 1; }
  return 0
}

test_marker_substring_match_not_anchored() {
  # The action uses 'contains' so the marker can appear anywhere in the body.
  cat > "${GH_FAKE_LIST_RESPONSE_FILE}" <<'JSON'
[{"id": 8001, "created_at": "2026-01-01T00:00:00Z", "body": "Some preamble\n<!-- tf:head:env:dev -->\nbody continues"}]
JSON
  run_step
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  if ! grep -q 'PATCH repos/dsb-norge/test-repo/issues/comments/8001' "${GH_FAKE_CALL_LOG}"; then
    echo "expected PATCH on id 8001"; return 1
  fi
  return 0
}

# ============================================================================
# Run all
# ============================================================================

run_test "upsert: no match → POST fresh"                                test_upsert_no_match_posts_fresh
run_test "upsert: match, different hash → PATCH"                        test_upsert_match_different_hash_patches
run_test "upsert: match (any body shape) → PATCH"                       test_upsert_match_arbitrary_body_patches
run_test "upsert: duplicates → keep oldest, PATCH it, DELETE others"    test_upsert_duplicates_keep_oldest
run_test "upsert: PATCH fail → fallback POST fresh"                     test_upsert_patch_fail_falls_back_to_post
run_test "delete: no match → not-found, 0 DELETEs"                      test_delete_no_match
run_test "delete: 1 match → 1 DELETE"                                   test_delete_single_match
run_test "delete: 3 matches → 3 DELETEs"                                test_delete_multiple_matches
run_test "degraded (list fails): upsert → POST fresh"                   test_degraded_upsert_posts_fresh
run_test "degraded (list fails): delete → no-op, action=not-found"      test_degraded_delete_is_noop
run_test "validation: missing input_mode → fail-fast"                   test_input_validation_missing_mode
run_test "validation: missing input_marker → fail-fast"                 test_input_validation_missing_marker
run_test "validation: invalid mode value → fail-fast"                   test_input_validation_invalid_mode
run_test "validation: upsert + missing input_body → fail-fast"          test_input_validation_upsert_missing_body
run_test "delete does NOT require input_body"                           test_delete_does_not_require_body
run_test "pagination: multi-page list flattened before scan"            test_pagination_flattens_multiple_pages
run_test "marker match uses contains() — not anchored to line 1"        test_marker_substring_match_not_anchored

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
