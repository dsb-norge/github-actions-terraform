#!/bin/env bash
#
# Test runner for step_verify_lock.sh
#
# Tests use a stub 'terraform' binary (controlled via TF_BIN) so they
# exercise the script's logic without requiring terraform on PATH.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

# Reset GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, and create a clean working dir
# with a sample lock file and an empty .terraform directory.
# Sets globals: WORK_DIR, ORIG_LOCK_CONTENT
setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_STEP_SUMMARY=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}"

  WORK_DIR="${RUNNER_TEMP}/work"
  mkdir -p "${WORK_DIR}/.terraform"
  ORIG_LOCK_CONTENT='# original lock file contents
provider "x" {}
'
  printf '%s' "${ORIG_LOCK_CONTENT}" >"${WORK_DIR}/.terraform.lock.hcl"

  export input_working_directory="${WORK_DIR}"
  export input_platforms="linux_amd64
linux_arm64
darwin_arm64"
}

# Install a stub terraform binary that does NOT modify the lock file.
install_stub_noop() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'EOF'
#!/bin/env bash
exit 0
EOF
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

# Install a stub terraform binary that REWRITES the lock file in CWD,
# simulating a missing-platform fix-up.
install_stub_modifies() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'EOF'
#!/bin/env bash
echo "# added by stub" >> .terraform.lock.hcl
exit 0
EOF
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

# Install a stub terraform binary that exits with failure.
install_stub_fails() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'EOF'
#!/bin/env bash
echo "stub failure" >&2
exit 7
EOF
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

# Run the step in a subshell. Captures exit code into $LAST_EXIT.
# Captures combined stdout/stderr into /tmp/test_output.txt.
run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_verify_lock.sh"
  ) >/tmp/test_output.txt 2>&1
  LAST_EXIT=$?
}

# Get a single-line output value from $GITHUB_OUTPUT
get_output() {
  local key="${1}"
  grep "^${key}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-
}

# Common assertion + reporting wrapper.
# Args: test_name, condition_command...
assert() {
  local name="${1}"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "$@"; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo "--- step output ---"
    cat /tmp/test_output.txt 2>/dev/null || true
    echo "--- /step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}     VERIFY TERRAFORM LOCK FILE TESTS      ${NC}"
echo -e "${YELLOW}============================================${NC}"

# Test 1: Happy path — lock file already complete
setup_workdir
install_stub_noop
run_step
assert "Happy path passes with exit 0" \
  test "${LAST_EXIT}" -eq 0
assert "Happy path sets is-complete=true" \
  test "$(get_output is-complete)" = "true"
assert "Happy path leaves committed lock file unchanged" \
  cmp -s <(printf '%s' "${ORIG_LOCK_CONTENT}") "${WORK_DIR}/.terraform.lock.hcl"
assert "Happy path writes success summary" \
  grep -q "verification passed" "${GITHUB_STEP_SUMMARY}"

# Test 2: Lock file modified by terraform → missing platforms
setup_workdir
install_stub_modifies
run_step
assert "Modified lock fails with exit 1" \
  test "${LAST_EXIT}" -eq 1
assert "Modified lock sets is-complete=false" \
  test "$(get_output is-complete)" = "false"
assert "Modified lock writes failure summary" \
  grep -q "missing platform hashes" "${GITHUB_STEP_SUMMARY}"
assert "Modified lock summary includes fix command" \
  grep -q "terraform providers lock" "${GITHUB_STEP_SUMMARY}"

# Test 3: Missing .terraform.lock.hcl
setup_workdir
install_stub_noop
rm "${WORK_DIR}/.terraform.lock.hcl"
run_step
assert "Missing lock file fails" \
  test "${LAST_EXIT}" -ne 0
assert "Missing lock file emits error annotation" \
  grep -q "::error title=No lock file" /tmp/test_output.txt

# Test 4: Missing .terraform directory (init was not run)
setup_workdir
install_stub_noop
rm -rf "${WORK_DIR}/.terraform"
run_step
assert "Missing .terraform fails" \
  test "${LAST_EXIT}" -ne 0
assert "Missing .terraform emits error annotation" \
  grep -q "::error title=No .terraform directory" /tmp/test_output.txt

# Test 5: Missing working directory
setup_workdir
install_stub_noop
input_working_directory="${RUNNER_TEMP}/does-not-exist"
run_step
assert "Missing working dir fails" \
  test "${LAST_EXIT}" -ne 0

# Test 6: Empty platforms input
setup_workdir
install_stub_noop
input_platforms=""
run_step
assert "Empty platforms input fails" \
  test "${LAST_EXIT}" -ne 0
assert "Empty platforms emits error annotation" \
  grep -q "::error title=No platforms specified" /tmp/test_output.txt

# Test 7: Whitespace-only / blank line platforms are tolerated
setup_workdir
install_stub_noop
# Leading/trailing whitespace plus blank lines around two real platforms.
input_platforms="
  linux_amd64

  darwin_arm64
"
run_step
assert "Whitespace-only lines tolerated, exit 0" \
  test "${LAST_EXIT}" -eq 0
assert "Whitespace-tolerant run still passes verification" \
  test "$(get_output is-complete)" = "true"

# Test 8: terraform binary fails (e.g. provider download error)
setup_workdir
install_stub_fails
run_step
assert "terraform failure propagates exit code" \
  test "${LAST_EXIT}" -eq 7

# Test 9: Happy path leaves committed file untouched
# (terraform stub does nothing, so the file should be byte-identical)
setup_workdir
install_stub_noop
run_step
assert "Happy path preserves committed file content" \
  cmp -s <(printf '%s' "${ORIG_LOCK_CONTENT}") "${WORK_DIR}/.terraform.lock.hcl"

# --------------------------------------------------------------------------
# Lock-only mode
# --------------------------------------------------------------------------

# A working dir with a two-provider lock and no .terraform directory, in
# lock-only mode. Sets globals as setup_workdir does.
setup_lock_only() {
  setup_workdir
  rm -rf "${WORK_DIR}/.terraform"
  ORIG_LOCK_CONTENT='provider "registry.terraform.io/hashicorp/random" {
  version     = "3.9.1"
  constraints = "~> 3.6"
  hashes = [
    "h1:aaa=",
  ]
}

provider "registry.terraform.io/other/random" {
  version = "1.2.3"
  hashes = [
    "h1:bbb=",
  ]
}
'
  printf '%s' "${ORIG_LOCK_CONTENT}" >"${WORK_DIR}/.terraform.lock.hcl"
  export input_lock_only="true"
  export input_plugin_cache_directory=""
  export input_platforms="linux_amd64"
}

# Install a stub that records its working directory, its arguments and the
# configuration it was given, then runs the optional snippet $1 in its cwd.
install_stub_records() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  STUB_LOG="${RUNNER_TEMP}/stub.log"
  cat >"${stub_dir}/terraform" <<EOF
#!/bin/env bash
{ echo "cwd=\$(pwd)"; echo "args=\$*"; cat versions.tf 2>/dev/null; } >"${STUB_LOG}"
${1:-}
exit 0
EOF
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

# Test 10: lock-only runs without .terraform, outside the working directory
setup_lock_only
install_stub_records
run_step
assert "Lock-only passes without a .terraform directory" \
  test "${LAST_EXIT}" -eq 0
assert "Lock-only sets is-complete=true" \
  test "$(get_output is-complete)" = "true"
assert "Lock-only runs terraform outside the working directory" \
  bash -c '! grep -q "^cwd=${1}$" "${2}"' _ "${WORK_DIR}" "${STUB_LOG}"
assert "Lock-only requires each locked provider at its locked version" \
  grep -q 'p1 = { source = "registry.terraform.io/hashicorp/random", version = "3.9.1" }' "${STUB_LOG}"
assert "Lock-only gives same-type providers of two namespaces distinct local names" \
  grep -q 'p2 = { source = "registry.terraform.io/other/random", version = "1.2.3" }' "${STUB_LOG}"
assert "Lock-only without a plugin cache downloads (no -fs-mirror)" \
  bash -c '! grep -q -- "-fs-mirror" "${1}"' _ "${STUB_LOG}"
assert "Lock-only passes the platform" \
  grep -q -- "-platform=linux_amd64" "${STUB_LOG}"

# Test 11: a missing platform hash fails, the committed lock is untouched
setup_lock_only
install_stub_records 'sed -i "s/\"h1:aaa=\",/\"h1:aaa=\",\n    \"h1:new=\",/" .terraform.lock.hcl'
run_step
assert "Lock-only with a missing hash fails with exit 1" \
  test "${LAST_EXIT}" -eq 1
assert "Lock-only with a missing hash sets is-complete=false" \
  test "$(get_output is-complete)" = "false"
assert "Lock-only never modifies the committed lock" \
  cmp -s <(printf '%s' "${ORIG_LOCK_CONTENT}") "${WORK_DIR}/.terraform.lock.hcl"
assert "Lock-only failure summary shows the missing hash" \
  grep -q '+    "h1:new=",' "${GITHUB_STEP_SUMMARY}"
assert "Lock-only failure summary names the working directory" \
  grep -q "cd ${WORK_DIR}" "${GITHUB_STEP_SUMMARY}"

# Test 12: the rewritten constraints line alone is not a difference
setup_lock_only
install_stub_records 'sed -i "s/constraints = \"~> 3.6\"/constraints = \"3.9.1\"/; /version = \"1.2.3\"/a\  constraints = \"1.2.3\"" .terraform.lock.hcl'
run_step
assert "Lock-only ignores rewritten and added constraints lines" \
  test "${LAST_EXIT}" -eq 0

# Test 13: a plugin cache holding every package is used as the mirror
setup_lock_only
install_stub_records
cache="${RUNNER_TEMP}/cache"
mkdir -p "${cache}/registry.terraform.io/hashicorp/random/3.9.1/linux_amd64" \
  "${cache}/registry.terraform.io/other/random/1.2.3/linux_amd64"
input_plugin_cache_directory="${cache}"
run_step
assert "Lock-only hashes from a plugin cache that covers every provider" \
  grep -q -- "-fs-mirror=${cache}" "${STUB_LOG}"

# Test 14: a relative plugin cache path is resolved from the starting directory
setup_lock_only
install_stub_records
mkdir -p "${RUNNER_TEMP}/cache/registry.terraform.io/hashicorp/random/3.9.1/linux_amd64" \
  "${RUNNER_TEMP}/cache/registry.terraform.io/other/random/1.2.3/linux_amd64"
input_plugin_cache_directory="cache"
(cd "${RUNNER_TEMP}" && run_step && echo "${LAST_EXIT}" >"${RUNNER_TEMP}/exit")
assert "Lock-only resolves a relative plugin cache before changing directory" \
  grep -q -- "-fs-mirror=${RUNNER_TEMP}/cache" "${STUB_LOG}"

# Test 15: a plugin cache missing one provider is not used
setup_lock_only
install_stub_records
cache="${RUNNER_TEMP}/cache"
mkdir -p "${cache}/registry.terraform.io/hashicorp/random/3.9.1/linux_amd64"
input_plugin_cache_directory="${cache}"
run_step
assert "Lock-only downloads when the cache lacks a provider" \
  bash -c '! grep -q -- "-fs-mirror" "${1}"' _ "${STUB_LOG}"

# Test 16: a plugin cache missing one required platform is not used
setup_lock_only
install_stub_records
cache="${RUNNER_TEMP}/cache"
mkdir -p "${cache}/registry.terraform.io/hashicorp/random/3.9.1/linux_amd64" \
  "${cache}/registry.terraform.io/other/random/1.2.3/linux_amd64"
input_plugin_cache_directory="${cache}"
input_platforms="linux_amd64
linux_arm64"
run_step
assert "Lock-only downloads when the cache lacks a required platform" \
  bash -c '! grep -q -- "-fs-mirror" "${1}"' _ "${STUB_LOG}"

# Test 17: a lock that records no providers passes without running terraform
setup_lock_only
install_stub_fails
printf '# no providers\n' >"${WORK_DIR}/.terraform.lock.hcl"
run_step
assert "Lock-only with no locked providers passes" \
  test "${LAST_EXIT}" -eq 0
assert "Lock-only with no locked providers sets is-complete=true" \
  test "$(get_output is-complete)" = "true"

# Test 18: a terraform failure propagates in lock-only mode too
setup_lock_only
install_stub_fails
run_step
assert "Lock-only terraform failure propagates exit code" \
  test "${LAST_EXIT}" -eq 7

# Test 19: lock-only 'false' keeps requiring .terraform
setup_lock_only
input_lock_only="false"
install_stub_noop
run_step
assert "lock-only false still requires .terraform" \
  grep -q "::error title=No .terraform directory" /tmp/test_output.txt

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}               TEST SUMMARY                ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  echo -e "${RED}SOME TESTS FAILED!${NC}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED!${NC}"
  exit 0
fi
