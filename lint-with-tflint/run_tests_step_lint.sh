#!/bin/env bash
#
# Tests for step_lint.sh
#
# Uses a stub 'tflint' binary (injected via TFLINT_BIN) so tests don't require
# — and never call — the real tflint binary. The stub appends one
# 'INVOCATION <argc>' line per call followed by one line per argument, which is
# what makes the "a directory path with a space is ONE argument" assertions
# possible: the old string-built form produced two bogus directories instead.
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

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}/workspace"

  WORK_DIR="${GITHUB_WORKSPACE}/envs/sandbox"
  mkdir -p "${WORK_DIR}"

  CONFIG_FILE="${GITHUB_WORKSPACE}/.tflint.hcl"
  printf 'plugin "terraform" { enabled = true }\n' >"${CONFIG_FILE}"

  export input_working_directory="${WORK_DIR}"
  export input_config_file="${CONFIG_FILE}"

  ARGS_FILE="${RUNNER_TEMP}/tflint-args.txt"
  : >"${ARGS_FILE}"
  export MOCK_TFLINT_ARGS_FILE="${ARGS_FILE}"

  MANIFEST_DIR="${RUNNER_TEMP}/manifests"
  mkdir -p "${MANIFEST_DIR}"
  export MOCK_MANIFEST_DIR="${MANIFEST_DIR}"

  unset MOCK_TFLINT_EXIT MOCK_TFLINT_FAIL_DIR MOCK_TFLINT_INIT_FAIL_DIR MOCK_ENV_FILE MOCK_TFLINT_FAIL_VARFILE
  unset input_extra_envs_file input_examples
}

# Write a fake modules.json. Each argument is a module 'Dir' value. The
# directories are created too: terraform has them on disk by the time this
# runs, and ws-path (realpath) needs them to exist to render log lines.
write_modules_file() {
  local dirs_json dir
  dirs_json="$(printf '%s\n' "${@}" | jq -Rsc 'split("\n") | map(select(length > 0))
    | to_entries | map({Key: (if .value == "." then "" else "m\(.key)" end), Dir: .value})')"
  for dir in "${@}"; do
    mkdir -p "${WORK_DIR}/${dir}"
  done
  mkdir -p "${WORK_DIR}/.terraform/modules"
  jq -n --argjson mods "${dirs_json}" '{Modules: $mods}' \
    >"${WORK_DIR}/.terraform/modules/modules.json"
}

install_stub_tflint() {
  local stub_dir="${RUNNER_TEMP}/stub-bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/tflint" <<'STUB'
#!/bin/env bash
# Dump the environment the invocation was handed, NUL-delimited so multiline
# values survive. Used by the per-goal environment-variable tests.
if [ -n "${MOCK_ENV_FILE:-}" ]; then
  env -0 >"${MOCK_ENV_FILE}"
fi
_is_init=0
_chdir=""
_var_file=""
for arg in "${@}"; do
  [ "${arg}" = "--init" ] && _is_init=1
  case "${arg}" in --chdir=*) _chdir="${arg#--chdir=}" ;; esac
  case "${arg}" in --var-file=*) _var_file="${arg#--var-file=}" ;; esac
done

if [ -n "${MOCK_TFLINT_ARGS_FILE:-}" ]; then
  printf 'INVOCATION %s\n' "${#}" >>"${MOCK_TFLINT_ARGS_FILE}"
  printf '%s\n' "${@}" >>"${MOCK_TFLINT_ARGS_FILE}"
  printf 'DATADIR %s\n' "${TF_DATA_DIR:--}" >>"${MOCK_TFLINT_ARGS_FILE}"
fi

# Keep the manifest a lint run was handed: the step removes its temporary data
# directories before the assertions run.
if [ "${_is_init}" -eq 0 ] && [ -n "${TF_DATA_DIR:-}" ] && [ -n "${MOCK_MANIFEST_DIR:-}" ]; then
  cp "${TF_DATA_DIR}/modules/modules.json" "${MOCK_MANIFEST_DIR}/$(basename "${_chdir}").json"
fi

if [ -n "${MOCK_TFLINT_FAIL_VARFILE:-}" ] && [ "${_var_file}" = "${MOCK_TFLINT_FAIL_VARFILE}" ]; then
  echo "main.tf:1:1: Error - invalid value (rule)"
  exit 2
fi

if [ "${_is_init}" -eq 1 ]; then
  if [ -n "${MOCK_TFLINT_INIT_FAIL_DIR:-}" ] && [ "${_chdir}" = "${MOCK_TFLINT_INIT_FAIL_DIR}" ]; then
    echo "Failed to install plugin"
    exit 7
  fi
  exit 0
fi

if [ -n "${MOCK_TFLINT_FAIL_DIR:-}" ] && [ "${_chdir}" = "${MOCK_TFLINT_FAIL_DIR}" ]; then
  echo "main.tf:1:1: Warning - something (rule)"
  exit 2
fi
exit "${MOCK_TFLINT_EXIT:-0}"
STUB
  chmod +x "${stub_dir}/tflint"
  export TFLINT_BIN="${stub_dir}/tflint"
}

# 'set -e -o pipefail' is not decoration: GitHub sources a composite step's
# script in 'bash --noprofile --norc -e -o pipefail', so a bare test that
# comes out false ends the step there. Without errexit here the suite passes
# on code that fails on every real run.
run_step() {
  (
    set -e -o pipefail
    set -o allexport
    source "${_this_script_dir}/step_lint.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

invocations() { grep -c '^INVOCATION ' "${ARGS_FILE}"; }
init_invocations() { grep -c '^--init$' "${ARGS_FILE}"; }
lint_invocations() { grep -c '^--format=compact$' "${ARGS_FILE}"; }

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
    echo "--- recorded invocations ---"
    cat "${ARGS_FILE}" 2>/dev/null || true
    echo "--- /recorded invocations ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}        LINT-WITH-TFLINT LINT TESTS         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Test: no modules.json → lint the project directory only
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
run_step
assert "No modules file: step exits 0" test "${LAST_EXIT}" -eq 0
assert "No modules file: one init + one lint invocation" \
  test "$(invocations)" -eq 2
assert "No modules file: lints the project directory" \
  bash -c "grep -Fxq -- '--chdir=${WORK_DIR}' '${ARGS_FILE}'"
assert "No modules file: problem matcher registered" \
  grep -q '::add-matcher::.*tflint_matcher.json' "${OUT_FILE}"
assert "No modules file: config file passed to tflint" \
  bash -c "grep -Fxq -- '--config=${CONFIG_FILE}' '${ARGS_FILE}'"
assert "No modules file: summary line present" \
  grep -q "success ->" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: modules.json → init + lint per module dir, '.terraform/*' filtered
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_modules_file "." "modules/network" "modules/network" ".terraform/modules/vendored"
run_step
assert "Modules file: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Modules file: two init invocations" test "$(init_invocations)" -eq 2
assert "Modules file: two lint invocations" test "$(lint_invocations)" -eq 2
assert "Modules file: vendored '.terraform' dir excluded" \
  bash -c "! grep -q -- '--chdir=.*\.terraform/modules/vendored' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: a module directory path containing a space is linted as ONE
# directory, not two. This is the latent bug the array conversion fixes —
# see docs/Per-goal-environment-variables.md §6.5.
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_modules_file "modules/storage account"
run_step
assert "Space in dir: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Space in dir: exactly one init + one lint (not two dirs)" \
  test "$(invocations)" -eq 2
assert "Space in dir: both invocations have 3 arguments (path not word-split)" \
  test "$(grep -c '^INVOCATION 3$' "${ARGS_FILE}")" -eq 2
assert "Space in dir: path arrives verbatim as one argument" \
  bash -c "grep -Fxq -- '--chdir=${WORK_DIR}/modules/storage account' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: a module directory path containing a glob character is not expanded
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
mkdir -p "${WORK_DIR}/modules/a" "${WORK_DIR}/modules/b"
write_modules_file 'modules/*'
run_step
assert "Glob in dir: exactly one init + one lint (not one per match)" \
  test "$(invocations)" -eq 2
assert "Glob in dir: path arrives unexpanded" \
  bash -c "grep -Fxq -- '--chdir=${WORK_DIR}/modules/*' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: lint findings in one directory fail the step, other directories
# still get linted (exit codes are summed)
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_modules_file "." "modules/network" "modules/storage"
export MOCK_TFLINT_FAIL_DIR="${WORK_DIR}/modules/network"
run_step
assert "Findings: three dirs linted" test "$(lint_invocations)" -eq 3
assert "Findings: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Findings: exit code is the sum (0+2+0)" test "${LAST_EXIT}" -eq 2
assert "Findings: summary marks the failing directory" \
  grep -q "failure -> ./envs/sandbox/modules/network" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Test: a failing 'tflint --init' records that directory as failed and the
# remaining directories are still linted
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_modules_file "." "modules/network" "modules/storage"
export MOCK_TFLINT_INIT_FAIL_DIR="${WORK_DIR}/modules/network"
run_step
assert "Init failure: step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "Init failure: exit code is init's code (0+7+0)" test "${LAST_EXIT}" -eq 7
assert "Init failure: error logged" \
  grep -q "TFLint init exited with code '7'" "${OUT_FILE}"
assert "Init failure: failing dir is not linted" \
  test "$(lint_invocations)" -eq 2
assert "Init failure: remaining dirs still linted" \
  bash -c "grep -Fxq -- '--chdir=${WORK_DIR}/modules/storage' '${ARGS_FILE}'"

# ----------------------------------------------------------------------
# Test: config file path containing a space reaches tflint as one argument
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
CONFIG_FILE="${GITHUB_WORKSPACE}/my configs/.tflint.hcl"
mkdir -p "$(dirname "${CONFIG_FILE}")"
printf 'plugin "terraform" { enabled = true }\n' >"${CONFIG_FILE}"
export input_config_file="${CONFIG_FILE}"
run_step
assert "Space in config path: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Space in config path: arrives verbatim as one argument" \
  bash -c "grep -Fxq -- '--config=${CONFIG_FILE}' '${ARGS_FILE}'"

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
install_stub_tflint
record_env
unset input_extra_envs_file
run_step
assert "T17: unset extra-envs-file, step exits 0" test "${LAST_EXIT}" -eq 0
assert "T17: nothing is injected" env_is_unset DSB_TEST_VALUE
assert "T17: no per-goal group is opened in the log" \
  bash -c "! grep -q 'applying per-goal environment variables' '${_test_output}'"

setup_workdir
install_stub_tflint
record_env
export input_extra_envs_file=""
run_step
assert "T17: empty extra-envs-file, step exits 0" test "${LAST_EXIT}" -eq 0
assert "T17: empty path is reported as not configured" \
  grep -q 'no per-goal environment variables file configured' "${_test_output}"

# ----------------------------------------------------------------------
# T18 — a path that does not exist is a hard error
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
export input_extra_envs_file="${RUNNER_TEMP}/nope/missing.json"
run_step
assert "T18: missing file, step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "T18: the error names the path" \
  grep -q "missing.json' does not exist" "${_test_output}"

# ----------------------------------------------------------------------
# T19 — an empty map is a no-op
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
record_env
use_extra_envs '{}'
run_step
assert "T19: empty map, step exits 0" test "${LAST_EXIT}" -eq 0
assert "T19: nothing is injected" env_is_unset DSB_TEST_VALUE

# ----------------------------------------------------------------------
# T20 — plain values reach the environment the invocation sees
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
record_env
use_extra_envs '{"GOMEMLIMIT":"12GiB","GOGC":25,"DSB_TEST_BOOL":true}'
run_step
assert "T20: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T20: a string value arrives verbatim" env_eq GOMEMLIMIT '12GiB'
assert "T20: a JSON number arrives as its decimal text" env_eq GOGC '25'
assert "T20: a JSON boolean arrives as 'true'" env_eq DSB_TEST_BOOL 'true'
assert "T20: keys are logged" grep -q "setting 'GOMEMLIMIT'" "${_test_output}"
assert "T20: values are NOT logged" \
  bash -c "! grep -q '12GiB' '${_test_output}'"

# ----------------------------------------------------------------------
# T21 — a JSON null genuinely unsets, even a variable exported job-wide
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
record_env
export GOMEMLIMIT="6GiB" # stands in for a value that came via $GITHUB_ENV
use_extra_envs '{"GOMEMLIMIT":null}'
run_step
assert "T21: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T21: the variable is gone from the invocation's environment" \
  env_is_unset GOMEMLIMIT
assert "T21: the unset is logged" grep -q "unsetting 'GOMEMLIMIT'" "${_test_output}"
unset GOMEMLIMIT

# Sanity check the other half of T21: without the null it would have been seen.
setup_workdir
install_stub_tflint
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
install_stub_tflint
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
install_stub_tflint
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
install_stub_tflint
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
install_stub_tflint
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
install_stub_tflint
record_env
use_extra_envs '{ this is not json'
run_step
assert "negative: unparseable JSON fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error says it is not valid JSON" \
  grep -q 'is not valid JSON' "${_test_output}"

setup_workdir
install_stub_tflint
record_env
use_extra_envs ''
run_step
assert "negative: an empty file fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error says an object was expected" \
  grep -q 'must hold a JSON object' "${_test_output}"

setup_workdir
install_stub_tflint
record_env
use_extra_envs '["not","an","object"]'
run_step
assert "negative: a JSON array fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the type found" \
  grep -q "got 'array'" "${_test_output}"

setup_workdir
install_stub_tflint
record_env
use_extra_envs '{"FOO BAR":"x"}'
run_step
assert "negative: a variable name with a space fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the offending key" \
  grep -q "'FOO BAR' is not a valid environment variable name" "${_test_output}"

# 'export FOO=BAR=x' would otherwise assign 'BAR=x' to FOO — a different
# variable than the caller asked for, silently.
setup_workdir
install_stub_tflint
record_env
use_extra_envs '{"FOO=BAR":"x"}'
run_step
assert "negative: a variable name containing '=' fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: it is rejected as a name, not silently reinterpreted" \
  grep -q "'FOO=BAR' is not a valid environment variable name" "${_test_output}"

# The tool must never have run for the case above: a step that cannot apply its
# configured environment must not proceed to invoke terraform/tflint.
assert "negative: the tool was not invoked at all" \
  bash -c "[ ! -s '${MOCK_ENV_FILE}' ]"

# ----------------------------------------------------------------------
# Linting nothing must not report success. Before this was guarded, an
# unparseable modules.json made jq fail, the directory list came out empty,
# the loop never ran and the step exited 0 — "lint passed" with nothing
# linted.
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
mkdir -p "${WORK_DIR}/.terraform/modules"
printf '{ this is not json' >"${WORK_DIR}/.terraform/modules/modules.json"
run_step
assert "negative: unparseable modules.json fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the modules file" \
  grep -q 'failed to read directories from the terraform modules file' "${OUT_FILE}"
assert "negative: tflint was never invoked" test "$(invocations)" -eq 0

setup_workdir
install_stub_tflint
mkdir -p "${WORK_DIR}/.terraform/modules"
printf '{"NotModules": []}' >"${WORK_DIR}/.terraform/modules/modules.json"
run_step
assert "negative: modules.json without a Modules array fails the step" \
  test "${LAST_EXIT}" -ne 0
assert "negative: tflint was never invoked" test "$(invocations)" -eq 0

setup_workdir
install_stub_tflint
write_modules_file ".terraform/modules/only-vendored"
run_step
assert "negative: an empty directory list fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error says nothing was found to lint" \
  grep -q 'no directories to lint were found' "${OUT_FILE}"
assert "negative: tflint was never invoked" test "$(invocations)" -eq 0

# ----------------------------------------------------------------------
# A working directory that cannot be entered must fail the step. Unguarded,
# 'cd' failing left the step running in whatever directory it was invoked
# from — i.e. operating on the wrong tree.
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
record_env
export input_working_directory="${RUNNER_TEMP}/no-such-project-dir"
run_step
assert "negative: a missing working directory fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the directory" \
  grep -q 'could not be entered' "${_test_output}"
assert "negative: the tool was never invoked" \
  bash -c "[ ! -s '${MOCK_ENV_FILE}' ]"


# ======================================================================
# The lint contract (docs/Linting.md): module directories are linted against
# a manifest derived from the root's, var files go to the root only, and
# module examples are roots of their own.
# ======================================================================

# Write a manifest from a JSON array of {Key, Dir} into the given root
# (default: the working directory), creating the local directories.
write_manifest() {
  local root="${2:-${WORK_DIR}}" dir
  while IFS= read -r dir; do
    mkdir -p "${root}/${dir}"
  done < <(jq -r '.[].Dir' <<<"${1}")
  mkdir -p "${root}/.terraform/modules"
  jq -n --argjson mods "${1}" '{Modules: $mods}' >"${root}/.terraform/modules/modules.json"
}

# The recorded lint invocation (not init) for one --chdir, as a block of lines.
lint_block() {
  awk -v chdir="--chdir=${1}" '
    /^INVOCATION / { if (block != "" && lint && match_) printf "%s", block; block = ""; lint = 0; match_ = 0 }
    { block = block $0 "\n" }
    $0 == "--format=compact" { lint = 1 }
    $0 == chdir { match_ = 1 }
    END { if (block != "" && lint && match_) printf "%s", block }
  ' "${ARGS_FILE}"
}
lint_count_for() { lint_block "${1}" | grep -c '^INVOCATION '; }
# The keys of the manifest a module directory was linted with, sorted, comma-joined.
manifest_keys() { jq -r '[.Modules[].Key] | sort | join(",")' "${MANIFEST_DIR}/${1}.json"; }
manifest_dir() { jq -r --arg k "${2}" '.Modules[] | select(.Key == $k) | .Dir' "${MANIFEST_DIR}/${1}.json"; }

# ----------------------------------------------------------------------
# A module directory gets a manifest derived from the root's, through
# TF_DATA_DIR; the root is linted with its own.
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_manifest '[{"Key":"","Dir":"."},{"Key":"main","Dir":"../../main"},
  {"Key":"main.net","Dir":"../../modules/net"},{"Key":"main.naming","Dir":".terraform/modules/main.naming"}]'
run_step
assert "Derived: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Derived: root, main and modules/net are linted" test "$(lint_invocations)" -eq 3
assert "Derived: the root's lint has no TF_DATA_DIR" \
  test "$(lint_block "${WORK_DIR}" | grep '^DATADIR ')" = "DATADIR -"
assert "Derived: main's lint has a TF_DATA_DIR" \
  test "$(lint_block "${WORK_DIR}/../../main" | grep '^DATADIR ')" != "DATADIR -"
assert "Derived: main's manifest holds main and what it calls, prefix stripped" \
  test "$(manifest_keys main)" = ",naming,net"
assert "Derived: main's own entry points at main, absolute" \
  test "$(manifest_dir main '')" = "${WORK_DIR}/../../main"
assert "Derived: a remote module of main points into the root's .terraform" \
  test "$(manifest_dir main naming)" = "${WORK_DIR}/.terraform/modules/main.naming"
assert "Derived: modules/net's manifest holds only itself" \
  test "$(manifest_keys net)" = ""
assert "Derived: the temporary data directories are removed" \
  bash -c "for d in \$(grep '^DATADIR /' '${ARGS_FILE}' | cut -d' ' -f2-); do [ ! -e \"\${d}\" ] || exit 1; done"

# ----------------------------------------------------------------------
# A directory reached through several keys is linted once, with the
# manifest of its shortest key.
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_manifest '[{"Key":"","Dir":"."},{"Key":"main","Dir":"../../main"},
  {"Key":"main.a","Dir":"../../modules/a"},{"Key":"main.a.x","Dir":".terraform/modules/main.a.x"},
  {"Key":"main.b","Dir":"../../modules/b"},{"Key":"main.b.a","Dir":"../../modules/a"},
  {"Key":"main.b.a.x","Dir":".terraform/modules/main.b.a.x"}]'
run_step
assert "Two keys: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Two keys: modules/a is linted once" test "$(lint_count_for "${WORK_DIR}/../../modules/a")" -eq 1
assert "Two keys: its manifest is the shortest key's" \
  test "$(manifest_dir a x)" = "${WORK_DIR}/.terraform/modules/main.a.x"

# ----------------------------------------------------------------------
# Var files: the root once per explicit var file, never a module directory;
# terraform.tfvars and *.auto.tfvars are tflint's own to load.
# ----------------------------------------------------------------------
setup_workdir
install_stub_tflint
write_manifest '[{"Key":"","Dir":"."},{"Key":"main","Dir":"../../main"}]'
touch "${WORK_DIR}/env.dev.tfvars" "${WORK_DIR}/env.prod.tfvars" \
  "${WORK_DIR}/terraform.tfvars" "${WORK_DIR}/extra.auto.tfvars"
run_step
assert "Var files: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Var files: the root is linted once per explicit var file" \
  test "$(lint_count_for "${WORK_DIR}")" -eq 2
assert "Var files: env.dev.tfvars is passed" \
  bash -c "grep -Fxq -- '--var-file=${WORK_DIR}/env.dev.tfvars' '${ARGS_FILE}'"
assert "Var files: env.prod.tfvars is passed" \
  bash -c "grep -Fxq -- '--var-file=${WORK_DIR}/env.prod.tfvars' '${ARGS_FILE}'"
assert "Var files: terraform.tfvars is not passed" \
  bash -c "! grep -q -- '--var-file=.*terraform.tfvars' '${ARGS_FILE}'"
assert "Var files: *.auto.tfvars is not passed" \
  bash -c "! grep -q -- '--var-file=.*auto.tfvars' '${ARGS_FILE}'"
assert "Var files: the module directory is linted once" \
  test "$(lint_count_for "${WORK_DIR}/../../main")" -eq 1
assert "Var files: the module directory never gets a var file" \
  test -z "$(lint_block "${WORK_DIR}/../../main" | grep -- '^--var-file=')"
assert "Var files: the summary names each var file run" \
  grep -q "success -> ./envs/sandbox (env.prod.tfvars)" "${OUT_FILE}"

setup_workdir
install_stub_tflint
touch "${WORK_DIR}/env.dev.tfvars" "${WORK_DIR}/env.prod.tfvars"
export MOCK_TFLINT_FAIL_VARFILE="${WORK_DIR}/env.prod.tfvars"
run_step
assert "Var files: a failing var-file run fails the step" test "${LAST_EXIT}" -eq 2
assert "Var files: the summary marks the failing run" \
  grep -q "failure -> ./envs/sandbox (env.prod.tfvars)" "${OUT_FILE}"
assert "Var files: the other run still passes" \
  grep -q "success -> ./envs/sandbox (env.dev.tfvars)" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Module examples: with 'examples', each examples/*/ holding .tf files is a
# root of its own, linted with the same config, covering only directories
# inside it; the module itself is linted once, by the root.
# ----------------------------------------------------------------------
setup_examples() {
  setup_workdir
  install_stub_tflint
  WORK_DIR="${GITHUB_WORKSPACE}"
  export input_working_directory="${WORK_DIR}"
  write_manifest '[{"Key":"","Dir":"."},{"Key":"sub","Dir":"modules/sub"}]'
  EX1="${WORK_DIR}/examples/01-basic"
  mkdir -p "${EX1}" "${WORK_DIR}/examples/02-no-tf" "${WORK_DIR}/examples/03-not-initialised"
  touch "${EX1}/main.tf" "${WORK_DIR}/examples/03-not-initialised/main.tf" "${WORK_DIR}/examples/02-no-tf/README.md"
  write_manifest '[{"Key":"","Dir":"."},{"Key":"this","Dir":"../.."},
    {"Key":"this.sub","Dir":"../../modules/sub"},{"Key":"local","Dir":"local"}]' "${EX1}"
}

setup_examples
export input_examples="true"
run_step
assert "Examples: step exits 0" test "${LAST_EXIT}" -eq 0
assert "Examples: root, submodule, two example roots and one example module are linted" \
  test "$(lint_invocations)" -eq 5
assert "Examples: an initialised example is linted" test "$(lint_count_for "${EX1}")" -eq 1
assert "Examples: a module directory inside the example is linted" \
  test "$(lint_count_for "${EX1}/local")" -eq 1
assert "Examples: the module is not linted again through the example" \
  test "$(lint_count_for "${EX1}/../..")" -eq 0
assert "Examples: nor its submodule" \
  test "$(lint_count_for "${EX1}/../../modules/sub")" -eq 0
assert "Examples: an example without a manifest is linted as its root alone" \
  test "$(lint_count_for "${WORK_DIR}/examples/03-not-initialised")" -eq 1
assert "Examples: a directory without .tf files is not an example" \
  test "$(lint_count_for "${WORK_DIR}/examples/02-no-tf")" -eq 0
assert "Examples: every run uses the module's config" \
  test "$(grep -c -- '^--config=' "${ARGS_FILE}")" -eq "$(grep -Fxc -- "--config=${CONFIG_FILE}" "${ARGS_FILE}")"
assert "Examples: the example's module gets the example's derived manifest" \
  test "$(manifest_dir local '')" = "${EX1}/local"

setup_examples
run_step
assert "Examples off: only the module and its submodule are linted" \
  test "$(lint_invocations)" -eq 2

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}            step_lint.sh SUMMARY            ${NC}"
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
