#!/bin/env bash
#
# Test runner for setup-tflint. Covers all five logic-bearing step scripts.
#
# Strategy:
#   - Each test runs the step in a subshell so state can't leak.
#   - A fake `curl` and `unzip` are placed on PATH ahead of real binaries so
#     get-meta and install can be exercised hermetically. Behaviour driven by
#     env-var-pointed response files.
#   - get-meta tests heavily cover both 'latest' and specific-version paths
#     plus error branches — this is the step the upcoming logic change
#     touches. Tests that pin "specific-version triggers an API call" are
#     marked with `# PIN-API-FOR-SPECIFIC-VERSION` so we can find and update
#     them when the short-circuit lands.
#

set -u
_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# ============================================================================
# Fixtures + fake binaries
# ============================================================================

# Minimal JSON shape for the GitHub Releases API. Only the fields we read.
LATEST_RELEASE_JSON='{
  "tag_name": "v0.62.1",
  "assets": [
    {"name": "tflint_darwin_amd64.zip", "browser_download_url": "https://example/tflint_darwin_amd64.zip"},
    {"name": "tflint_linux_amd64.zip",  "browser_download_url": "https://example/tflint_v0.62.1_linux_amd64.zip"},
    {"name": "tflint_windows_amd64.zip","browser_download_url": "https://example/tflint_windows_amd64.zip"}
  ]
}'

# Array of two releases — the 100-per-page list endpoint.
ALL_RELEASES_JSON='[
  {
    "tag_name": "v0.62.1",
    "assets": [
      {"name": "tflint_linux_amd64.zip", "browser_download_url": "https://example/tflint_v0.62.1_linux_amd64.zip"}
    ]
  },
  {
    "tag_name": "v0.61.0",
    "assets": [
      {"name": "tflint_darwin_amd64.zip", "browser_download_url": "https://example/tflint_darwin_amd64.zip"},
      {"name": "tflint_linux_amd64.zip",  "browser_download_url": "https://example/tflint_v0.61.0_linux_amd64.zip"}
    ]
  }
]'

setup() {
  TEST_DIR=$(mktemp -d)
  mkdir -p "${TEST_DIR}/bin"

  # Fake curl: serves whatever's at $CURL_FAKE_BODY_FILE, exit code $CURL_FAKE_EXIT.
  # Also records each invocation to $CURL_FAKE_CALL_LOG.
  cat > "${TEST_DIR}/bin/curl" <<'FAKE_CURL'
#!/bin/bash
LOG="${CURL_FAKE_CALL_LOG:-/dev/null}"
echo "curl $*" >> "${LOG}"
if [ "${CURL_FAKE_EXIT:-0}" != "0" ]; then
  exit "${CURL_FAKE_EXIT}"
fi
# When -o <file> is provided (install step), write body there. Otherwise
# write to stdout (get-meta step).
out_target=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "-o" ]; then
    j=$((i + 1))
    out_target="${!j}"
    break
  fi
done
if [ -n "${CURL_FAKE_BODY_FILE:-}" ] && [ -f "${CURL_FAKE_BODY_FILE}" ]; then
  if [ -n "${out_target}" ]; then
    cp "${CURL_FAKE_BODY_FILE}" "${out_target}"
  else
    cat "${CURL_FAKE_BODY_FILE}"
  fi
fi
exit 0
FAKE_CURL
  chmod +x "${TEST_DIR}/bin/curl"

  export CURL_FAKE_CALL_LOG="${TEST_DIR}/curl-calls.log"
  export CURL_FAKE_BODY_FILE="${TEST_DIR}/curl-body"
  unset CURL_FAKE_EXIT
  : > "${CURL_FAKE_CALL_LOG}"

  export PATH="${TEST_DIR}/bin:${PATH}"

  # GH Actions plumbing
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${TEST_DIR}"
  export GITHUB_PATH=$(mktemp)

  cd "${TEST_DIR}"
}

teardown() {
  rm -rf "${TEST_DIR}" 2>/dev/null || true
  rm -f "${GITHUB_OUTPUT:-}" "${GITHUB_PATH:-}" 2>/dev/null || true
  unset TEST_DIR
}

# Run a step in a subshell; captures stdout/stderr; STEP_EXIT_CODE set on return.
run_step() {
  local step="${1}"
  (
    set -o allexport
    source "${_this_script_dir}/${step}"
  ) > "${TEST_DIR}/step.log" 2>&1
  STEP_EXIT_CODE=$?
}

# Pull a single-line output value from $GITHUB_OUTPUT.
get_output() {
  local key="${1}"
  grep "^${key}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-
}

run_test() {
  local name="${1}" fn="${2}"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  setup
  local err
  err=$("${fn}" 2>&1)
  local code=$?
  if [[ ${code} -eq 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo -e "${err}"
    echo "--- step.log ---"
    cat "${TEST_DIR}/step.log" 2>/dev/null
    echo "--- curl calls ---"
    cat "${CURL_FAKE_CALL_LOG}" 2>/dev/null
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}" 2>/dev/null
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  teardown
}

# Standard get-meta env. Tests override what they need.
prep_get_meta_env() {
  export input_tflint_version="latest"
  export input_github_token="fake-token"
  export input_runner_tool_cache="/tmp/runner-tool-cache"
  export input_runner_os="Linux"
  export input_runner_arch="X64"
}

# ============================================================================
# Test cases — step_get_meta.sh ('latest' path)
# ============================================================================

test_get_meta_latest_sets_outputs() {
  prep_get_meta_env
  echo "${LATEST_RELEASE_JSON}" > "${CURL_FAKE_BODY_FILE}"
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(get_output tag-name)" = "v0.62.1" ]] || { echo "tag-name: $(get_output tag-name)"; return 1; }
  [[ "$(get_output download-url)" = "https://example/tflint_v0.62.1_linux_amd64.zip" ]] || { echo "download-url: $(get_output download-url)"; return 1; }
  [[ "$(get_output install-dir)" = "/tmp/runner-tool-cache/tflint_v0.62.1" ]] || { echo "install-dir: $(get_output install-dir)"; return 1; }
  [[ "$(get_output install-bin-path)" = "/tmp/runner-tool-cache/tflint_v0.62.1/tflint" ]] || { echo "install-bin-path: $(get_output install-bin-path)"; return 1; }
  [[ "$(get_output cache-key)" = "tflint-binary-v0.62.1-Linux-X64" ]] || { echo "cache-key: $(get_output cache-key)"; return 1; }
  return 0
}

test_get_meta_latest_hits_releases_latest_endpoint() {
  # PIN-API-FOR-LATEST: 'latest' must call /releases/latest, not /releases?per_page=...
  prep_get_meta_env
  echo "${LATEST_RELEASE_JSON}" > "${CURL_FAKE_BODY_FILE}"
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  if ! grep -q '/releases/latest' "${CURL_FAKE_CALL_LOG}"; then
    echo "expected curl to hit /releases/latest"
    cat "${CURL_FAKE_CALL_LOG}"
    return 1
  fi
  return 0
}

test_get_meta_latest_picks_linux_amd64_asset_only() {
  prep_get_meta_env
  echo "${LATEST_RELEASE_JSON}" > "${CURL_FAKE_BODY_FILE}"
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  # Must be linux_amd64, never darwin/windows
  local url="$(get_output download-url)"
  [[ "${url}" = *linux_amd64* ]] || { echo "url is not linux_amd64: ${url}"; return 1; }
  [[ "${url}" != *darwin* ]] || { echo "url leaked darwin: ${url}"; return 1; }
  [[ "${url}" != *windows* ]] || { echo "url leaked windows: ${url}"; return 1; }
  return 0
}

test_get_meta_latest_empty_response_fails() {
  prep_get_meta_env
  : > "${CURL_FAKE_BODY_FILE}"  # empty body
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for empty response"; return 1; }
  return 0
}

test_get_meta_latest_malformed_json_fails() {
  prep_get_meta_env
  echo "this is not json" > "${CURL_FAKE_BODY_FILE}"
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for malformed json"; return 1; }
  return 0
}

# ============================================================================
# Test cases — step_get_meta.sh (specific-version path)
# ============================================================================

test_get_meta_specific_version_sets_outputs() {
  prep_get_meta_env
  export input_tflint_version="v0.61.0"
  echo "${ALL_RELEASES_JSON}" > "${CURL_FAKE_BODY_FILE}"
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "step exit ${STEP_EXIT_CODE}"; return 1; }
  [[ "$(get_output tag-name)" = "v0.61.0" ]] || { echo "tag-name: $(get_output tag-name)"; return 1; }
  [[ "$(get_output download-url)" = "https://example/tflint_v0.61.0_linux_amd64.zip" ]] || { echo "download-url: $(get_output download-url)"; return 1; }
  [[ "$(get_output install-dir)" = "/tmp/runner-tool-cache/tflint_v0.61.0" ]] || { echo "install-dir: $(get_output install-dir)"; return 1; }
  [[ "$(get_output cache-key)" = "tflint-binary-v0.61.0-Linux-X64" ]] || { echo "cache-key: $(get_output cache-key)"; return 1; }
  return 0
}

test_get_meta_specific_version_currently_calls_api() {
  # PIN-API-FOR-SPECIFIC-VERSION: today, a specific version triggers an
  # /releases?per_page=100 call. The upcoming logic change makes this go
  # away — when it does, this test SHOULD break, and we'll replace it
  # with the new short-circuit assertion.
  prep_get_meta_env
  export input_tflint_version="v0.61.0"
  echo "${ALL_RELEASES_JSON}" > "${CURL_FAKE_BODY_FILE}"
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  if ! grep -q '/releases?per_page=' "${CURL_FAKE_CALL_LOG}"; then
    echo "expected curl to hit /releases?per_page=... (current behavior)"
    cat "${CURL_FAKE_CALL_LOG}"
    return 1
  fi
  return 0
}

test_get_meta_specific_version_not_in_response_fails() {
  # PIN-API-FOR-SPECIFIC-VERSION: today, requesting a version that doesn't
  # appear in the list endpoint fails. After short-circuit, this case would
  # pass (we'd trust the input) — that's a different trade-off the new
  # behavior accepts.
  prep_get_meta_env
  export input_tflint_version="v9.99.99"  # not in fixture
  echo "${ALL_RELEASES_JSON}" > "${CURL_FAKE_BODY_FILE}"
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit for missing version"; return 1; }
  return 0
}

# ============================================================================
# Test cases — step_get_meta.sh (curl failures)
# ============================================================================

test_get_meta_curl_failure_propagates() {
  prep_get_meta_env
  export CURL_FAKE_EXIT=92  # the real failure mode we saw in prod-wlzs
  : > "${CURL_FAKE_BODY_FILE}"
  run_step step_get_meta.sh
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected non-zero exit when curl fails"; return 1; }
  return 0
}

# ============================================================================
# Test cases — step_get_config.sh
# ============================================================================

prep_get_config_env() {
  export input_config_file_path=""
  export input_working_directory="${TEST_DIR}"
}

test_get_config_finds_config_in_workdir() {
  prep_get_config_env
  echo "plugin \"terraform\" {}" > "${TEST_DIR}/.tflint.hcl"
  run_step step_get_config.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  local out="$(get_output config-file)"
  [[ "${out}" = "${TEST_DIR}/.tflint.hcl" ]] || { echo "expected workdir path, got: ${out}"; return 1; }
  return 0
}

test_get_config_falls_back_to_workspace() {
  prep_get_config_env
  # Workdir has no .tflint.hcl; workspace does
  local sub_workdir="${TEST_DIR}/sub"
  mkdir -p "${sub_workdir}"
  echo "plugin \"terraform\" {}" > "${GITHUB_WORKSPACE}/.tflint.hcl"
  export input_working_directory="${sub_workdir}"
  run_step step_get_config.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  local out="$(get_output config-file)"
  [[ "${out}" = "${GITHUB_WORKSPACE}/.tflint.hcl" ]] || { echo "expected workspace path, got: ${out}"; return 1; }
  return 0
}

test_get_config_uses_explicit_path_when_exists() {
  prep_get_config_env
  local explicit="${TEST_DIR}/custom-tflint.hcl"
  echo "plugin \"terraform\" {}" > "${explicit}"
  export input_config_file_path="${explicit}"
  run_step step_get_config.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  [[ "$(get_output config-file)" = "${explicit}" ]] || { echo "expected explicit path, got: $(get_output config-file)"; return 1; }
  return 0
}

test_get_config_explicit_path_missing_warns_but_succeeds() {
  prep_get_config_env
  export input_config_file_path="/nonexistent/.tflint.hcl"
  run_step step_get_config.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  # Output is empty path when configured path doesn't exist anywhere.
  [[ -z "$(get_output config-file)" ]] || { echo "expected empty config-file output, got: $(get_output config-file)"; return 1; }
  if ! grep -q 'does not exist' "${TEST_DIR}/step.log"; then
    echo "expected warning about non-existent path"
    return 1
  fi
  return 0
}

# ============================================================================
# Test cases — step_exists_check.sh
# ============================================================================

test_exists_check_no_dir_no_binary_returns_false_and_creates_dir() {
  local install_dir="${TEST_DIR}/install"
  export input_install_dir="${install_dir}"
  export input_install_bin_path="${install_dir}/tflint"
  run_step step_exists_check.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  [[ "$(get_output already-installed)" = "false" ]] || { echo "expected false, got: $(get_output already-installed)"; return 1; }
  [[ -d "${install_dir}" ]] || { echo "install-dir should have been created"; return 1; }
  return 0
}

test_exists_check_dir_only_returns_false() {
  local install_dir="${TEST_DIR}/install"
  mkdir -p "${install_dir}"
  export input_install_dir="${install_dir}"
  export input_install_bin_path="${install_dir}/tflint"
  run_step step_exists_check.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  [[ "$(get_output already-installed)" = "false" ]] || { echo "dir without binary should be false, got: $(get_output already-installed)"; return 1; }
  return 0
}

test_exists_check_dir_and_binary_returns_true() {
  local install_dir="${TEST_DIR}/install"
  mkdir -p "${install_dir}"
  : > "${install_dir}/tflint"
  export input_install_dir="${install_dir}"
  export input_install_bin_path="${install_dir}/tflint"
  run_step step_exists_check.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  [[ "$(get_output already-installed)" = "true" ]] || { echo "expected true, got: $(get_output already-installed)"; return 1; }
  return 0
}

# ============================================================================
# Test cases — step_install.sh
# ============================================================================

test_install_happy_path() {
  local install_dir="${TEST_DIR}/install"
  mkdir -p "${install_dir}"
  # Build a real zip containing a fake tflint binary that the fake curl
  # will deliver as the "downloaded" file.
  local fixture_dir=$(mktemp -d)
  echo '#!/bin/sh' > "${fixture_dir}/tflint"
  chmod +x "${fixture_dir}/tflint"
  (cd "${fixture_dir}" && zip -q tflint.zip tflint)
  cp "${fixture_dir}/tflint.zip" "${CURL_FAKE_BODY_FILE}"
  export input_download_url="http://fake/tflint.zip"
  export input_install_dir="${install_dir}"
  export input_install_bin_path="${install_dir}/tflint"
  run_step step_install.sh
  rm -rf "${fixture_dir}"
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || { echo "install failed, exit ${STEP_EXIT_CODE}"; return 1; }
  [[ -f "${install_dir}/tflint" ]] || { echo "binary not extracted"; return 1; }
  return 0
}

test_install_missing_binary_after_extraction_fails() {
  local install_dir="${TEST_DIR}/install"
  mkdir -p "${install_dir}"
  # Build a zip that does NOT contain `tflint` — install must fail.
  local fixture_dir=$(mktemp -d)
  echo "bogus" > "${fixture_dir}/not-tflint"
  (cd "${fixture_dir}" && zip -q tflint.zip not-tflint)
  cp "${fixture_dir}/tflint.zip" "${CURL_FAKE_BODY_FILE}"
  export input_download_url="http://fake/tflint.zip"
  export input_install_dir="${install_dir}"
  export input_install_bin_path="${install_dir}/tflint"
  run_step step_install.sh
  rm -rf "${fixture_dir}"
  [[ ${STEP_EXIT_CODE} -ne 0 ]] || { echo "expected install to fail when binary missing"; return 1; }
  return 0
}

# ============================================================================
# Test cases — step_add_to_path.sh
# ============================================================================

test_add_to_path_appends_install_dir_to_github_path() {
  local install_dir="${TEST_DIR}/install"
  mkdir -p "${install_dir}"
  export input_install_dir="${install_dir}"
  run_step step_add_to_path.sh
  [[ ${STEP_EXIT_CODE} -eq 0 ]] || return 1
  if ! grep -qF "${install_dir}" "${GITHUB_PATH}"; then
    echo "GITHUB_PATH file does not contain ${install_dir}"
    cat "${GITHUB_PATH}"
    return 1
  fi
  return 0
}

# ============================================================================
# Run
# ============================================================================

# step_get_meta — 'latest' path
run_test "get-meta 'latest' sets all 5 outputs correctly"               test_get_meta_latest_sets_outputs
run_test "get-meta 'latest' hits /releases/latest endpoint"             test_get_meta_latest_hits_releases_latest_endpoint
run_test "get-meta 'latest' selects only linux_amd64 asset"             test_get_meta_latest_picks_linux_amd64_asset_only
run_test "get-meta 'latest' fails on empty response"                    test_get_meta_latest_empty_response_fails
run_test "get-meta 'latest' fails on malformed json"                    test_get_meta_latest_malformed_json_fails

# step_get_meta — specific-version path
run_test "get-meta specific version sets all 5 outputs correctly"       test_get_meta_specific_version_sets_outputs
run_test "get-meta specific version currently calls list-releases API"  test_get_meta_specific_version_currently_calls_api
run_test "get-meta specific version not in response → fails"            test_get_meta_specific_version_not_in_response_fails

# step_get_meta — curl failures
run_test "get-meta propagates curl failure (exit 92)"                   test_get_meta_curl_failure_propagates

# step_get_config
run_test "get-config finds .tflint.hcl in working-directory"            test_get_config_finds_config_in_workdir
run_test "get-config falls back to workspace .tflint.hcl"               test_get_config_falls_back_to_workspace
run_test "get-config uses explicit config-file-path when it exists"     test_get_config_uses_explicit_path_when_exists
run_test "get-config explicit path missing → warn + empty output"       test_get_config_explicit_path_missing_warns_but_succeeds

# step_exists_check
run_test "exists-check no dir, no binary → false + dir created"         test_exists_check_no_dir_no_binary_returns_false_and_creates_dir
run_test "exists-check dir without binary → false"                      test_exists_check_dir_only_returns_false
run_test "exists-check dir + binary → true"                             test_exists_check_dir_and_binary_returns_true

# step_install
run_test "install happy path: downloads + unzips + verifies binary"     test_install_happy_path
run_test "install fails when zip doesn't contain tflint binary"         test_install_missing_binary_after_extraction_fails

# step_add_to_path
run_test "add-to-path appends install-dir to \$GITHUB_PATH"             test_add_to_path_appends_install_dir_to_github_path

# ============================================================================
echo ""
echo "========================================"
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "========================================"

if [[ ${TESTS_FAILED} -gt 0 ]]; then exit 1; fi
exit 0
