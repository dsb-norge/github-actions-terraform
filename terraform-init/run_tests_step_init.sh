#!/bin/env bash
#
# Tests for step_init.sh
#
# Uses a stub 'terraform' binary (injected via TF_BIN) so tests don't
# require — and never call — the real terraform binary. The stub records
# its argv when MOCK_TF_ARGV_FILE is set and obeys MOCK_TF_EXIT,
# MOCK_TF_STDOUT env vars.
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

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}"

  WORK_DIR="${RUNNER_TEMP}/work"
  mkdir -p "${WORK_DIR}"

  export input_working_directory="${WORK_DIR}"
  export input_environment_name="testenv"
  export input_additional_dirs_json="[]"
  export input_plugin_cache_directory=""

  unset MOCK_TF_EXIT MOCK_TF_STDOUT MOCK_TF_ARGV_FILE MOCK_ENV_FILE
  unset input_extra_envs_file
}

# Installs a stub terraform that records argv and obeys MOCK_TF_EXIT.
# When MOCK_TF_EXIT_DIR_<base64-of-cwd> is set, the stub uses that value
# instead — lets a single test exercise different exit codes per dir.
install_stub_terraform() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/terraform" <<'STUB'
#!/bin/env bash
# Dump the environment the invocation was handed, NUL-delimited so multiline
# values survive. Used by the per-goal environment-variable tests.
if [ -n "${MOCK_ENV_FILE:-}" ]; then
  env -0 >"${MOCK_ENV_FILE}"
fi
if [ -n "${MOCK_TF_ARGV_FILE:-}" ]; then
  # Record argv plus PWD so tests can verify which dir each call ran from.
  printf 'pwd=%s argv=%s\n' "$(pwd)" "$*" >>"${MOCK_TF_ARGV_FILE}"
fi
if [ -n "${MOCK_TF_STDOUT:-}" ]; then
  printf '%s\n' "${MOCK_TF_STDOUT}"
fi
# Per-call exit override based on argv. Lets one test exercise mixed
# success/failure across project-dir + additional-dirs init.
for tok in "$@"; do
  case "${tok}" in
    -chdir=*)
      _chdir="${tok#-chdir=}"
      _env_var="MOCK_TF_EXIT_$(echo -n "${_chdir}" | md5sum | cut -c1-8)"
      if [ -n "${!_env_var:-}" ]; then exit "${!_env_var}"; fi
      ;;
  esac
done
exit "${MOCK_TF_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_init.sh"
  ) >/tmp/test_output_init.txt 2>&1
  LAST_EXIT=$?
}

get_output() {
  local key="${1}"
  grep "^${key}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-
}

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
    cat /tmp/test_output_init.txt 2>/dev/null || true
    echo "--- /step output ---"
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}" 2>/dev/null || true
    echo "--- /GITHUB_OUTPUT ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}         TERRAFORM-INIT STEP TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: Happy path, no additional dirs
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="Terraform has been successfully initialized!"
run_step
assert "Happy path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Happy path: console-output-file output is published" \
  test -n "$(get_output tf-init-console-output-file)"
assert "Happy path: console-output-file exists" \
  test -s "$(get_output tf-init-console-output-file)"
assert "Happy path: console-output-file contains stub stdout" \
  grep -q "successfully initialized" "$(get_output tf-init-console-output-file)"

# ----------------------------------------------------------------------
# Test: Additional dirs — both init invocations land in the same console file
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
EXTRA_DIR="modules/foo"
mkdir -p "${GITHUB_WORKSPACE}/${EXTRA_DIR}"
export input_additional_dirs_json="[\"${EXTRA_DIR}\"]"
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="initialized OK"
export MOCK_TF_ARGV_FILE="${RUNNER_TEMP}/argv.log"
run_step
assert "Additional dirs: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Additional dirs: terraform invoked twice" \
  bash -c "[[ \$(wc -l <\"${MOCK_TF_ARGV_FILE}\") -eq 2 ]]"
assert "Additional dirs: second invocation uses -chdir=" \
  grep -q -- "-chdir=${GITHUB_WORKSPACE}/${EXTRA_DIR}" "${MOCK_TF_ARGV_FILE}"
_cf="$(get_output tf-init-console-output-file)"
assert "Additional dirs: console file contains both invocations' output" \
  bash -c "[[ \$(grep -c 'initialized OK' '${_cf}') -eq 2 ]]"

# ----------------------------------------------------------------------
# Test: Failure path — terraform exit 1 → step exits non-zero
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=1
export MOCK_TF_STDOUT="Error: failed to init"
run_step
assert "Failure: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Failure: error log line present" \
  grep -q "init exited with code '1'" /tmp/test_output_init.txt
assert "Failure: console-output-file still captured" \
  test -s "$(get_output tf-init-console-output-file)"

# ----------------------------------------------------------------------
# Test: Mixed success/failure across project dir + additional dir
# Project init exits 0; additional dir's init exits 1; total non-zero.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
EXTRA_DIR="modules/bar"
mkdir -p "${GITHUB_WORKSPACE}/${EXTRA_DIR}"
export input_additional_dirs_json="[\"${EXTRA_DIR}\"]"
export MOCK_TF_EXIT=0
# Set exit-override for the extra dir's abs path
_chdir_hash="$(echo -n "${GITHUB_WORKSPACE}/${EXTRA_DIR}" | md5sum | cut -c1-8)"
declare -x "MOCK_TF_EXIT_${_chdir_hash}=1"
run_step
assert "Mixed: step exits non-zero overall" test "${LAST_EXIT}" -ne 0
assert "Mixed: failure log mentions exit code 1" \
  grep -q "init exited with code '1'" /tmp/test_output_init.txt
unset "MOCK_TF_EXIT_${_chdir_hash}"

# ----------------------------------------------------------------------
# Test: Missing additional dir → step exits non-zero with descriptive log
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_additional_dirs_json="[\"modules/does-not-exist\"]"
export MOCK_TF_EXIT=0
run_step
assert "Missing dir: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Missing dir: log mentions does-not-exist" \
  grep -q "does not exist" /tmp/test_output_init.txt

# ----------------------------------------------------------------------
# Test: Empty additional-dirs JSON falls back to project-only init
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_additional_dirs_json=""
export MOCK_TF_EXIT=0
export MOCK_TF_ARGV_FILE="${RUNNER_TEMP}/argv.log"
run_step
assert "Empty JSON: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Empty JSON: terraform invoked exactly once" \
  bash -c "[[ \$(wc -l <\"${MOCK_TF_ARGV_FILE}\") -eq 1 ]]"
assert "Empty JSON: no-additional-dirs log line present" \
  grep -q "no additional directories" /tmp/test_output_init.txt

# ----------------------------------------------------------------------
# Test: Environment name appears in console-output-file path
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_environment_name="my-special-env"
export MOCK_TF_EXIT=0
run_step
cf="$(get_output tf-init-console-output-file)"
assert "Env name: file name embeds environment name" \
  bash -c "[[ '${cf}' == *'tf-init-console-output-my-special-env.txt' ]]"

# ======================================================================
# Per-goal environment variables (the 'extra-envs-file' input)
# Scenario numbering follows docs/Per-goal-environment-variables.md §10.
# ======================================================================

# Write a JSON environment map to a file and point the step at it.
use_extra_envs() {
  export input_extra_envs_file="${RUNNER_TEMP}/extra-envs.json"
  printf '%s' "${1}" >"${input_extra_envs_file}"
}

# Have the stub dump the environment it was handed.
record_env() {
  export MOCK_ENV_FILE="${RUNNER_TEMP}/invocation-env.txt"
  : >"${MOCK_ENV_FILE}"
}

# Exact value of one variable as the invocation saw it. Non-zero if it was
# unset. NUL-delimited, so a multiline value comes back byte-identical.
env_value() {
  local name="${1}" entry
  while IFS= read -r -d '' entry; do
    if [[ "${entry}" == "${name}="* ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done <"${MOCK_ENV_FILE}"
  return 1
}

# Trailing newlines survive the comparison: command substitution strips them,
# so both sides get a sentinel appended. A PEM value ends in one.
env_eq() {
  local var="${1}" expected="${2}" actual
  env_value "${var}" >/dev/null || return 1
  actual="$(env_value "${var}"; printf 'x')"
  [[ "${actual}" == "${expected}x" ]]
}

env_is_unset() { ! env_value "${1}" >/dev/null; }

# ----------------------------------------------------------------------
# T17 — no file configured is a no-op (regression guard for every existing
# caller: they pass nothing at all)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
unset input_extra_envs_file
run_step
assert "T17: unset extra-envs-file, step exits 0" test "${LAST_EXIT}" -eq 0
assert "T17: nothing is injected" env_is_unset DSB_TEST_VALUE
assert "T17: no per-goal group is opened in the log" \
  bash -c "! grep -q 'applying per-goal environment variables' '/tmp/test_output_init.txt'"

setup_workdir
install_stub_terraform
record_env
export input_extra_envs_file=""
run_step
assert "T17: empty extra-envs-file, step exits 0" test "${LAST_EXIT}" -eq 0
assert "T17: empty path is reported as not configured" \
  grep -q 'no per-goal environment variables file configured' '/tmp/test_output_init.txt'

# ----------------------------------------------------------------------
# T18 — a path that does not exist is a hard error
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_extra_envs_file="${RUNNER_TEMP}/nope/missing.json"
run_step
assert "T18: missing file, step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "T18: the error names the path" \
  grep -q "missing.json' does not exist" '/tmp/test_output_init.txt'

# ----------------------------------------------------------------------
# T19 — an empty map is a no-op
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
use_extra_envs '{}'
run_step
assert "T19: empty map, step exits 0" test "${LAST_EXIT}" -eq 0
assert "T19: nothing is injected" env_is_unset DSB_TEST_VALUE

# ----------------------------------------------------------------------
# T20 — plain values reach the environment the invocation sees
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
use_extra_envs '{"GOMEMLIMIT":"12GiB","GOGC":25,"DSB_TEST_BOOL":true}'
run_step
assert "T20: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T20: a string value arrives verbatim" env_eq GOMEMLIMIT '12GiB'
assert "T20: a JSON number arrives as its decimal text" env_eq GOGC '25'
assert "T20: a JSON boolean arrives as 'true'" env_eq DSB_TEST_BOOL 'true'
assert "T20: keys are logged" grep -q "setting 'GOMEMLIMIT'" '/tmp/test_output_init.txt'
assert "T20: values are NOT logged" \
  bash -c "! grep -q '12GiB' '/tmp/test_output_init.txt'"

# ----------------------------------------------------------------------
# T21 — a JSON null genuinely unsets, even a variable exported job-wide
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
export GOMEMLIMIT="6GiB" # stands in for a value that came via $GITHUB_ENV
use_extra_envs '{"GOMEMLIMIT":null}'
run_step
assert "T21: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T21: the variable is gone from the invocation's environment" \
  env_is_unset GOMEMLIMIT
assert "T21: the unset is logged" grep -q "unsetting 'GOMEMLIMIT'" '/tmp/test_output_init.txt'
unset GOMEMLIMIT

# Sanity check the other half of T21: without the null it would have been seen.
setup_workdir
install_stub_terraform
record_env
export GOMEMLIMIT="6GiB"
unset input_extra_envs_file
run_step
assert "T21: control — the job-wide value is visible without an override" \
  env_eq GOMEMLIMIT '6GiB'
unset GOMEMLIMIT

# ----------------------------------------------------------------------
# T22 — an empty string is set-and-empty, which is NOT the same as unset
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
export GOMEMLIMIT="6GiB"
use_extra_envs '{"GOMEMLIMIT":""}'
run_step
assert "T22: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T22: the variable is still present" \
  bash -c "grep -qz '^GOMEMLIMIT=$' '${MOCK_ENV_FILE}'"
assert "T22: and its value is the empty string" env_eq GOMEMLIMIT ''
unset GOMEMLIMIT

# ----------------------------------------------------------------------
# T23 — a multiline value survives intact
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
use_extra_envs '{"DSB_TEST_PEM":"-----BEGIN RSA PRIVATE KEY-----\nline-two\n-----END RSA PRIVATE KEY-----\n"}'
run_step
assert "T23: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T23: the multiline value arrives byte-identical" \
  env_eq DSB_TEST_PEM '-----BEGIN RSA PRIVATE KEY-----
line-two
-----END RSA PRIVATE KEY-----
'

# ----------------------------------------------------------------------
# T24 — shell metacharacters are not interpreted anywhere on the way
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
use_extra_envs '{"DSB_TEST_VALUE":"a $HOME `id` \"q\" '"'"'s'"'"' * ; | & value"}'
run_step
assert "T24: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T24: the value arrives verbatim, nothing expanded or executed" \
  env_eq DSB_TEST_VALUE 'a $HOME `id` "q" '"'"'s'"'"' * ; | & value'

# ----------------------------------------------------------------------
# §6.3 — who wins for an action-managed variable.
#
# TF_PLUGIN_CACHE_DIR is exported by this step script at runtime, i.e. AFTER
# apply-extra-envs has run, so the action wins and a caller cannot accidentally
# disable provider plugin caching. Asymmetric on purpose: a variable set in the
# step's env: block (TF_IN_AUTOMATION) is applied before the script runs, so
# there the caller wins. Documented, not enforced.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
mkdir -p "${GITHUB_WORKSPACE}/extra-dir"
export input_additional_dirs_json='["extra-dir"]'
export input_plugin_cache_directory="${RUNNER_TEMP}/action-owned-cache"
use_extra_envs '{"TF_PLUGIN_CACHE_DIR":"/tmp/caller-owned-cache","TF_IN_AUTOMATION":"false"}'
run_step
assert "§6.3: step exits 0" test "${LAST_EXIT}" -eq 0
assert "§6.3: the action wins for TF_PLUGIN_CACHE_DIR (exported at runtime)" \
  env_eq TF_PLUGIN_CACHE_DIR "${RUNNER_TEMP}/action-owned-cache"
assert "§6.3: the caller's TF_IN_AUTOMATION is applied (env: block equivalent)" \
  env_eq TF_IN_AUTOMATION 'false'

# ----------------------------------------------------------------------
# T25 — the values are scoped to the step's own shell and do not leak
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
use_extra_envs '{"DSB_TEST_VALUE":"only-inside-the-step"}'
run_step
assert "T25: the invocation did see the value" \
  env_eq DSB_TEST_VALUE 'only-inside-the-step'
assert "T25: it did not leak into the surrounding shell" \
  test -z "${DSB_TEST_VALUE:-}"
assert "T25: and nothing was written to \$GITHUB_ENV" \
  bash -c "[ -z \"\${GITHUB_ENV:-}\" ] || ! grep -q 'DSB_TEST_VALUE' \"\${GITHUB_ENV}\""

# ----------------------------------------------------------------------
# An unusable file must fail the step, not be silently skipped. A file that
# applies nothing while the step carries on as if it had is the failure mode
# this whole feature exists to avoid: the consequence surfaces as an OOM or a
# wrong-credentials error far from its cause.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
use_extra_envs '{ this is not json'
run_step
assert "negative: unparseable JSON fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error says it is not valid JSON" \
  grep -q 'is not valid JSON' '/tmp/test_output_init.txt'

setup_workdir
install_stub_terraform
record_env
use_extra_envs ''
run_step
assert "negative: an empty file fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error says an object was expected" \
  grep -q 'must hold a JSON object' '/tmp/test_output_init.txt'

setup_workdir
install_stub_terraform
record_env
use_extra_envs '["not","an","object"]'
run_step
assert "negative: a JSON array fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the type found" \
  grep -q "got 'array'" '/tmp/test_output_init.txt'

setup_workdir
install_stub_terraform
record_env
use_extra_envs '{"FOO BAR":"x"}'
run_step
assert "negative: a variable name with a space fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the offending key" \
  grep -q "'FOO BAR' is not a valid environment variable name" '/tmp/test_output_init.txt'

# 'export FOO=BAR=x' would otherwise assign 'BAR=x' to FOO — a different
# variable than the caller asked for, silently.
setup_workdir
install_stub_terraform
record_env
use_extra_envs '{"FOO=BAR":"x"}'
run_step
assert "negative: a variable name containing '=' fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: it is rejected as a name, not silently reinterpreted" \
  grep -q "'FOO=BAR' is not a valid environment variable name" '/tmp/test_output_init.txt'

# The tool must never have run for the case above: a step that cannot apply its
# configured environment must not proceed to invoke terraform/tflint.
assert "negative: the tool was not invoked at all" \
  bash -c "[ ! -s '${MOCK_ENV_FILE}' ]"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
# A working directory that cannot be entered must fail the step. Unguarded,
# 'cd' failing left the step running in whatever directory it was invoked
# from — i.e. operating on the wrong tree.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_env
export input_working_directory="${RUNNER_TEMP}/no-such-project-dir"
run_step
assert "negative: a missing working directory fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the directory" \
  grep -q 'could not be entered' '/tmp/test_output_init.txt'
assert "negative: the tool was never invoked" \
  bash -c "[ ! -s '${MOCK_ENV_FILE}' ]"

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}            step_init.sh SUMMARY            ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
