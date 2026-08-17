#!/bin/env bash
#
# Tests for step_apply.sh
#
# Uses a stub 'terraform' binary (injected via TF_BIN) so tests don't
# require — and never call — the real terraform binary. The stub records
# its argv one element per line (preceded by the argument count) plus its
# working directory, which is what makes the array-built-invocation
# assertions possible: a string-built command that word-splits a path with
# a space shows up as a higher argument count.
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

OUT_FILE=/tmp/test_output_apply.txt

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

  PLAN_FILE="${GITHUB_WORKSPACE}/tf-plan-testenv.plan"
  echo 'fake plan' >"${PLAN_FILE}"

  export input_working_directory="${WORK_DIR}"
  export input_terraform_plan_file="${PLAN_FILE}"

  unset MOCK_TF_EXIT MOCK_TF_STDOUT MOCK_TF_ARGS_FILE MOCK_TF_PWD_FILE MOCK_ENV_FILE
  unset input_extra_envs_file
}

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
if [ -n "${MOCK_TF_ARGS_FILE:-}" ]; then
  printf '%s\n' "${#}" "${@}" >"${MOCK_TF_ARGS_FILE}"
fi
if [ -n "${MOCK_TF_PWD_FILE:-}" ]; then
  pwd >"${MOCK_TF_PWD_FILE}"
fi
if [ -n "${MOCK_TF_STDOUT:-}" ]; then
  printf '%s\n' "${MOCK_TF_STDOUT}"
fi
exit "${MOCK_TF_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/terraform"
  export TF_BIN="${stub_dir}/terraform"
}

# Enable argv + pwd recording for the next run_step.
record_invocation() {
  export MOCK_TF_ARGS_FILE="${RUNNER_TEMP}/tf-args.txt"
  export MOCK_TF_PWD_FILE="${RUNNER_TEMP}/tf-pwd.txt"
}

# Argument count as recorded by the stub.
argc() { head -n1 "${MOCK_TF_ARGS_FILE}"; }

# Nth recorded argument (1-based).
argn() { sed -n "$((${1} + 1))p" "${MOCK_TF_ARGS_FILE}"; }

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_apply.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
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
    cat "${OUT_FILE}" 2>/dev/null || true
    echo "--- /step output ---"
    echo "--- recorded argv ---"
    cat "${MOCK_TF_ARGS_FILE}" 2>/dev/null || true
    echo "--- /recorded argv ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}         TERRAFORM-APPLY STEP TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: Happy path (terraform exit 0)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_invocation
export MOCK_TF_EXIT=0
export MOCK_TF_STDOUT="Apply complete! Resources: 1 added, 0 changed, 0 destroyed."
run_step
assert "Happy path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Happy path: stub stdout reaches the log" \
  grep -q "Apply complete" "${OUT_FILE}"
assert "Happy path: terraform invoked from the working directory" \
  test "$(cat "${MOCK_TF_PWD_FILE}")" = "${WORK_DIR}"

# ----------------------------------------------------------------------
# Test: argv shape — apply -input=false -auto-approve <plan-file>
# ----------------------------------------------------------------------
assert "argv: exactly 4 arguments" test "$(argc)" -eq 4
assert "argv: 1st is 'apply'" test "$(argn 1)" = "apply"
assert "argv: 2nd is '-input=false'" test "$(argn 2)" = "-input=false"
assert "argv: 3rd is '-auto-approve'" test "$(argn 3)" = "-auto-approve"
assert "argv: 4th is the plan file, verbatim" test "$(argn 4)" = "${PLAN_FILE}"

# ----------------------------------------------------------------------
# Test: Failure (terraform exit 1)
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export MOCK_TF_EXIT=1
export MOCK_TF_STDOUT="Error: applying plan failed"
run_step
assert "Failure: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Failure: error log line present" \
  grep -q "apply exited with code '1'" "${OUT_FILE}"
assert "Failure: terraform stderr/stdout still reaches the log" \
  grep -q "applying plan failed" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: plan file path containing a space reaches terraform as ONE argv
# element. Regression guard for the string-built invocation this action
# used to have — see docs/Per-goal-environment-variables.md §6.5.
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_invocation
PLAN_FILE="${GITHUB_WORKSPACE}/tf plan with spaces.plan"
echo 'fake plan' >"${PLAN_FILE}"
export input_terraform_plan_file="${PLAN_FILE}"
export MOCK_TF_EXIT=0
run_step
assert "Space in path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Space in path: still exactly 4 arguments (no word-splitting)" \
  test "$(argc)" -eq 4
assert "Space in path: plan file arrives verbatim" \
  test "$(argn 4)" = "${PLAN_FILE}"
assert "Space in path: logged command string shows the real quoting" \
  grep -Fq "'${PLAN_FILE}'" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: plan file path containing a glob character is not expanded
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
record_invocation
# Files the glob would match if expansion happened.
touch "${WORK_DIR}/decoy-a" "${WORK_DIR}/decoy-b"
PLAN_FILE="${GITHUB_WORKSPACE}/tf-plan-*.plan"
touch "${GITHUB_WORKSPACE}/tf-plan-one.plan" "${GITHUB_WORKSPACE}/tf-plan-two.plan"
export input_terraform_plan_file="${PLAN_FILE}"
export MOCK_TF_EXIT=0
run_step
assert "Glob in path: still exactly 4 arguments (no glob expansion)" \
  test "$(argc)" -eq 4
assert "Glob in path: plan file arrives unexpanded" \
  test "$(argn 4)" = "${GITHUB_WORKSPACE}/tf-plan-*.plan"

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
  bash -c "! grep -q 'applying per-goal environment variables' '/tmp/test_output_apply.txt'"

setup_workdir
install_stub_terraform
record_env
export input_extra_envs_file=""
run_step
assert "T17: empty extra-envs-file, step exits 0" test "${LAST_EXIT}" -eq 0
assert "T17: empty path is reported as not configured" \
  grep -q 'no per-goal environment variables file configured' '/tmp/test_output_apply.txt'

# ----------------------------------------------------------------------
# T18 — a path that does not exist is a hard error
# ----------------------------------------------------------------------
setup_workdir
install_stub_terraform
export input_extra_envs_file="${RUNNER_TEMP}/nope/missing.json"
run_step
assert "T18: missing file, step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "T18: the error names the path" \
  grep -q "missing.json' does not exist" '/tmp/test_output_apply.txt'

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
assert "T20: keys are logged" grep -q "setting 'GOMEMLIMIT'" '/tmp/test_output_apply.txt'
assert "T20: values are NOT logged" \
  bash -c "! grep -q '12GiB' '/tmp/test_output_apply.txt'"

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
assert "T21: the unset is logged" grep -q "unsetting 'GOMEMLIMIT'" '/tmp/test_output_apply.txt'
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
# Summary
# ----------------------------------------------------------------------
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
  grep -q 'is not valid JSON' '/tmp/test_output_apply.txt'

setup_workdir
install_stub_terraform
record_env
use_extra_envs ''
run_step
assert "negative: an empty file fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error says an object was expected" \
  grep -q 'must hold a JSON object' '/tmp/test_output_apply.txt'

setup_workdir
install_stub_terraform
record_env
use_extra_envs '["not","an","object"]'
run_step
assert "negative: a JSON array fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the type found" \
  grep -q "got 'array'" '/tmp/test_output_apply.txt'

setup_workdir
install_stub_terraform
record_env
use_extra_envs '{"FOO BAR":"x"}'
run_step
assert "negative: a variable name with a space fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the offending key" \
  grep -q "'FOO BAR' is not a valid environment variable name" '/tmp/test_output_apply.txt'

# 'export FOO=BAR=x' would otherwise assign 'BAR=x' to FOO — a different
# variable than the caller asked for, silently.
setup_workdir
install_stub_terraform
record_env
use_extra_envs '{"FOO=BAR":"x"}'
run_step
assert "negative: a variable name containing '=' fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: it is rejected as a name, not silently reinterpreted" \
  grep -q "'FOO=BAR' is not a valid environment variable name" '/tmp/test_output_apply.txt'

# The tool must never have run for the case above: a step that cannot apply its
# configured environment must not proceed to invoke terraform/tflint.
assert "negative: the tool was not invoked at all" \
  bash -c "[ ! -s '${MOCK_ENV_FILE}' ]"

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
  grep -q 'could not be entered' '/tmp/test_output_apply.txt'
assert "negative: the tool was never invoked" \
  bash -c "[ ! -s '${MOCK_ENV_FILE}' ]"

# ======================================================================
# The inline 'check-prereqs' step.
#
# The implementation guide allows prerequisite checks to stay inline, and this
# one normally would not earn a test — except that this is the only action in
# the repo that mutates infrastructure, and the check is what stops it running
# 'apply' against a plan file that is not there.
# ======================================================================
run_prereqs() {
  local plan_file="${1}"
  local tmp
  tmp="$(mktemp -d)"
  printf '%s' "${plan_file}" >"${tmp}/plan-file.txt"

  python3 "${_this_script_dir}/extract_step_source.py" \
    "${_this_script_dir}/action.yml" check-prereqs "${tmp}/step.sh" \
    "inputs.terraform-plan-file=@${tmp}/plan-file.txt" \
    "github.action_path=${_this_script_dir}"

  # Same shell flags the runner uses, so 'exit 1' behaves as it does in CI.
  PATH="${RUNNER_TEMP}/stub-bin:${PATH}" \
    bash --noprofile --norc -eo pipefail "${tmp}/step.sh" >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

setup_workdir
install_stub_terraform
run_prereqs "${PLAN_FILE}"
assert "prereqs: an existing plan file and terraform on PATH passes" \
  test "${LAST_EXIT}" -eq 0
assert "prereqs: it says the plan file exists" \
  grep -q 'the configured plan file exists' "${OUT_FILE}"

setup_workdir
install_stub_terraform
run_prereqs "${GITHUB_WORKSPACE}/no-such-plan.plan"
assert "prereqs: a missing plan file fails before anything is applied" \
  test "${LAST_EXIT}" -ne 0
assert "prereqs: the error explains why" \
  grep -q 'the configured plan file does not exists' "${OUT_FILE}"

setup_workdir
install_stub_terraform
run_prereqs ""
assert "prereqs: an empty plan-file path fails" test "${LAST_EXIT}" -ne 0

# A directory is not a plan file.
setup_workdir
install_stub_terraform
run_prereqs "${WORK_DIR}"
assert "prereqs: a directory is not accepted as a plan file" \
  test "${LAST_EXIT}" -ne 0

# ----------------------------------------------------------------------
# jq older than 1.7 has no '--raw-output0'. The runner images this repo
# targets have 1.7.x, but 'runs-on' is caller-overridable to self-hosted
# groups — and a jq that rejects the flag made the read loop consume nothing
# while the step carried on having applied nothing at all.
#
# apply-extra-envs is byte-identical across the six goal actions
# (docs/Per-goal-environment-variables.md §9.6), and resolve-goal-envs' suite
# asserts that, so exercising this once here covers all six.
# ----------------------------------------------------------------------
install_stub_old_jq() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/jq" <<'STUB'
#!/bin/env bash
# Simulates jq 1.6: every other option works, --raw-output0 does not.
for _arg in "${@}"; do
  if [ "${_arg}" = "--raw-output0" ]; then
    echo "jq: Unknown option: --raw-output0" >&2
    exit 2
  fi
done
exec "${REAL_JQ}" "${@}"
STUB
  chmod +x "${stub_dir}/jq"
  export REAL_JQ="$(command -v jq)"
  OLD_JQ_PATH="${stub_dir}"
}

setup_workdir
install_stub_terraform
install_stub_old_jq
record_env
use_extra_envs '{"GOMEMLIMIT":"12GiB","GOGC":25}'
(
  PATH="${OLD_JQ_PATH}:${PATH}"
  set -o allexport
  source "${_this_script_dir}/step_apply.sh"
) >"${OUT_FILE}" 2>&1
LAST_EXIT=$?
assert "old jq: the step fails rather than applying nothing" test "${LAST_EXIT}" -ne 0
assert "old jq: the error reports how many of how many were applied" \
  grep -q 'applied 0 of 2 environment variable(s)' "${OUT_FILE}"
assert "old jq: the error points at the jq version" \
  grep -q 'jq is older than 1.7' "${OUT_FILE}"
assert "old jq: terraform was never invoked" \
  bash -c "[ ! -s '${MOCK_ENV_FILE}' ]"
unset REAL_JQ

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}           step_apply.sh SUMMARY            ${NC}"
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
