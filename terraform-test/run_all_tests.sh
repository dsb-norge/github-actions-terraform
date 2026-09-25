#!/bin/env bash
#
# Test runner for terraform-test.
#
# The step runs against a fake terraform binary (test-data/fake_terraform.sh)
# that replays JSON logs captured from a real Terraform 1.16.2
# (test-data/terraform-1.16.2/, captured by test-data/capture/capture.sh with
# credential-free providers and mock_provider). Nothing here needs a real
# Terraform or the network.
#
# Expected values are literals, never read back from the action's own
# constants. Golden files (test-data/golden/) hold the report and step
# summary blocks; regenerate with UPDATE_GOLDENS=1 and review the diff.
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

DATA_DIR="${_this_script_dir}/test-data"
FIXTURES="${DATA_DIR}/terraform-1.16.2"
GOLDEN_DIR="${DATA_DIR}/golden"
UPDATE_GOLDENS="${UPDATE_GOLDENS:-}"
MODULE_CI="${_this_script_dir}/../.github/workflows/terraform-module-ci.yaml"

# --------------------------------------------------------------------------
# Harness
# --------------------------------------------------------------------------

setup() {
  TEST_TMP="$(mktemp -d)"
  export RUNNER_TEMP="${TEST_TMP}/runner-temp"
  export GITHUB_WORKSPACE="${TEST_TMP}/workspace"
  mkdir -p "${RUNNER_TEMP}" "${GITHUB_WORKSPACE}" "${TEST_TMP}/bin"
  export GITHUB_OUTPUT="${TEST_TMP}/github-output"
  export GITHUB_STEP_SUMMARY="${TEST_TMP}/step-summary"
  : >"${GITHUB_OUTPUT}"
  : >"${GITHUB_STEP_SUMMARY}"
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_RUN_ID="424242"
  export RUNNER_OS="Linux"
  export RUNNER_ARCH="X64"

  cp "${DATA_DIR}/fake_terraform.sh" "${TEST_TMP}/bin/terraform"
  chmod +x "${TEST_TMP}/bin/terraform"
  export FAKE_TF_LOG="${TEST_TMP}/terraform-calls.log"
  : >"${FAKE_TF_LOG}"
  unset FAKE_TF_OUTPUT FAKE_TF_EXIT FAKE_TF_JUNIT FAKE_TF_STDERR FAKE_TF_VERSION_JSON

  STEP_LOG="${TEST_TMP}/step-output.txt"
  TEST_PATH="${TEST_TMP}/bin:${PATH}"

  # Inputs, as the action.yml shim hands them over (the new call shape).
  export input_test_file="tests/unit-pass.tftest.hcl"
  export input_working_directory="modules/net"
  export input_junit="true"
  export input_slug="modules-net--unit-pass"
  export input_status_credentials=""
  export input_status_lock=""
  export input_status_init="success"
  export input_environments_lock_file=""
  mkdir -p "${GITHUB_WORKSPACE}/modules/net"
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# fixture <name> [exit code]: what the fake terraform prints for 'test'.
fixture() {
  export FAKE_TF_OUTPUT="${FIXTURES}/${1}"
  export FAKE_TF_EXIT="${2:-0}"
}

# fake_version <version>: what 'terraform version -json' reports.
fake_version() {
  export FAKE_TF_VERSION_JSON="${TEST_TMP}/version.json"
  printf '{"terraform_version": "%s", "platform": "linux_amd64", "provider_selections": {}, "terraform_outdated": false}\n' "${1}" >"${FAKE_TF_VERSION_JSON}"
}

# Run the step as GitHub would: from the workspace (a composite step's
# default), sourced under allexport in a subshell so 'exit' ends only it.
run_step() {
  (
    cd "${GITHUB_WORKSPACE}" || exit 99
    export PATH="${TEST_PATH}"
    export TF_IN_AUTOMATION=true
    set -eo pipefail
    set -o allexport
    source "${_this_script_dir}/step_run_tests.sh"
  ) >"${STEP_LOG}" 2>&1
  LAST_EXIT=$?
}

# Value of one output (name=value or name<<delim form).
output_value() {
  python3 - "${GITHUB_OUTPUT}" "${1}" <<'PY'
import re
import sys

src, wanted = sys.argv[1:3]
lines = open(src, encoding="utf-8").read().split("\n")
i = 0
found = None
while i < len(lines):
    line = lines[i]
    heredoc = re.match(r'^([^=<]+)<<(.+)$', line)
    if heredoc:
        name, delim = heredoc.groups()
        value = []
        i += 1
        while i < len(lines) and lines[i] != delim:
            value.append(lines[i])
            i += 1
        if name == wanted:
            found = "\n".join(value)
    elif "=" in line:
        name, _, value = line.partition("=")
        if name == wanted:
            found = value
    i += 1
sys.stdout.write(found if found is not None else "")
PY
}

assert() {
  local name="${1}"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "$@"; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo "--- step output ---"
    cat "${STEP_LOG}" 2>/dev/null || true
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}" 2>/dev/null || true
    echo "--- end ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

output_is() {
  local actual
  actual="$(output_value "${1}")"
  [ "${actual}" == "${2}" ] && return 0
  echo "  output '${1}': expected '${2}', got '${actual}'"
  return 1
}

# outputs_are name=value ...: several outputs at once.
outputs_are() {
  local pair ok=0
  for pair in "$@"; do
    output_is "${pair%%=*}" "${pair#*=}" || ok=1
  done
  return ${ok}
}

exit_is() {
  [ "${LAST_EXIT}" == "${1}" ] && return 0
  echo "  exit code: expected ${1}, got ${LAST_EXIT}"
  return 1
}

# The 'terraform test' invocations, paths normalised.
test_calls() {
  grep -- ' args=test ' "${FAKE_TF_LOG}" | sed -e "s|${GITHUB_WORKSPACE}|<WORKSPACE>|g" -e "s|${RUNNER_TEMP}|<RUNNER_TEMP>|g"
}

test_call_is() {
  local actual
  actual="$(test_calls)"
  [ "${actual}" == "${1}" ] && return 0
  echo "  terraform test call: expected '${1}', got '${actual}'"
  return 1
}

terraform_test_not_run() {
  [ -z "$(test_calls)" ] && return 0
  echo "  terraform test ran: $(test_calls)"
  return 1
}

# file_json_is <output name> <expected compact JSON>
file_json_is() {
  local path actual
  path="$(output_value "${1}")"
  [ -f "${path}" ] || { echo "  '${1}' file '${path}' missing"; return 1; }
  actual="$(jq -c . "${path}")"
  [ "${actual}" == "${2}" ] && return 0
  echo "  ${1}: expected ${2}"
  echo "  ${1}:      got ${actual}"
  return 1
}

log_contains() {
  grep -qF -- "${1}" "${STEP_LOG}" && return 0
  echo "  log lacks '${1}'"
  return 1
}

log_lacks() {
  grep -qF -- "${1}" "${STEP_LOG}" || return 0
  echo "  log contains '${1}'"
  return 1
}

annotation_count_is() {
  local kind="${1}" expected="${2}" actual
  actual="$(grep -c "^::${kind} " "${STEP_LOG}")"
  [ "${actual}" == "${expected}" ] && return 0
  echo "  ::${kind} lines: expected ${expected}, got ${actual}"
  return 1
}

# Compare a file with a golden; UPDATE_GOLDENS=1 rewrites the golden.
matches_golden() {
  local golden="${GOLDEN_DIR}/${1}"
  local actual_file="${2}"
  if [ -n "${UPDATE_GOLDENS}" ]; then
    mkdir -p "$(dirname "${golden}")"
    cp "${actual_file}" "${golden}"
    return 0
  fi
  cmp -s "${golden}" "${actual_file}" && return 0
  echo "  differs from golden/${1}:"
  diff "${golden}" "${actual_file}" | sed 's/^/    /'
  return 1
}

report_matches() {
  local path
  path="$(output_value report-file)"
  [ -f "${path}" ] || { echo "  report '${path}' missing"; return 1; }
  matches_golden "${1}" "${path}"
}

step_summary_matches() {
  matches_golden "${1}" "${GITHUB_STEP_SUMMARY}"
}

# Every output line stays small: paths, counts and short strings only.
outputs_are_small() {
  local longest total
  longest="$(awk '{ if (length($0) > max) max = length($0) } END { print max + 0 }' "${GITHUB_OUTPUT}")"
  total="$(wc -c <"${GITHUB_OUTPUT}")"
  if [ "${longest}" -le 4096 ] && [ "${total}" -le 8192 ]; then
    return 0
  fi
  echo "  GITHUB_OUTPUT: longest line ${longest}, total ${total} bytes"
  return 1
}

# Structural assertions on action.yml (and the module CI workflow).
yaml_check() {
  python3 - "${_this_script_dir}/action.yml" "${MODULE_CI}" "${1}" <<'PY'
import re
import sys
import yaml

action = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
module_ci = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))
check = sys.argv[3]
inputs = action.get("inputs", {})
outputs = action.get("outputs", {})
steps = action["runs"]["steps"]
by_id = {step.get("id"): step for step in steps}
test = by_id["run-tests"]

module_test_step = next(
    step
    for step in module_ci["jobs"]["module-tests"]["steps"]
    if "terraform-test@" in str(step.get("uses", ""))
)
module_ci_text = open(sys.argv[2], encoding="utf-8").read()
read_outputs = set(re.findall(r"steps\.test\.outputs\.([a-z-]+)", module_ci_text))

expected_outputs = {
    "status", "reason", "passed", "failed", "errored", "skipped", "total", "elapsed-ms",
    "summary", "exit-code", "terraform-version", "terraform-version-floor", "runner-platform", "test-file-path",
    "json-file", "report-file", "junit-file", "runs-json-file", "diagnostics-json-file",
    "providers-json-file", "providers-summary", "providers-floating-count",
    "failed-runs-json", "failed-runs-omitted", "json", "report",
}
legacy_if = "inputs.working-directory == ''"

checks = {
    # Module CI passes only these keys; every one must be an input.
    "module-ci-inputs": set(module_test_step.get("with", {})) <= set(inputs),
    # Module CI reads these outputs; every one must exist.
    "module-ci-outputs": bool(read_outputs) and read_outputs <= set(outputs),
    "inputs": set(inputs) == {
        "test-file", "working-directory", "junit", "slug", "status-credentials",
        "status-lock", "status-init", "environments-lock-file", "azure-login", "upload-artifact",
    } and inputs["test-file"].get("required") is True
    and all(inputs[name].get("default") == "" for name in (
        "working-directory", "slug", "status-credentials", "status-lock", "status-init",
        "environments-lock-file"))
    and inputs["junit"].get("default") == "true"
    and inputs["azure-login"].get("default") == "auto"
    and inputs["upload-artifact"].get("default") == "auto",
    "outputs": set(outputs) == expected_outputs and all(
        outputs[name]["value"] == "${{ steps.run-tests.outputs.%s }}" % name for name in outputs),
    "login-gated": by_id["azure-login"]["uses"] == "azure/login@v3"
    and by_id["azure-login"]["if"]
    == "inputs.azure-login == 'true' || (inputs.azure-login == 'auto' && " + legacy_if + ")"
    and by_id["azure-login"]["with"] == {
        "tenant-id": "${{ env.ARM_TENANT_ID }}",
        "subscription-id": "${{ env.ARM_SUBSCRIPTION_ID }}",
        "client-id": "${{ env.ARM_CLIENT_ID }}",
    }
    and steps.index(by_id["azure-login"]) < steps.index(test),
    "upload-gated": by_id["upload-test-results"]["uses"] == "actions/upload-artifact@v7"
    and "(inputs.upload-artifact == 'true' || (inputs.upload-artifact == 'auto' && " + legacy_if + "))"
    in by_id["upload-test-results"]["if"]
    and "steps.run-tests.outputs.json-file != ''" in by_id["upload-test-results"]["if"]
    and by_id["upload-test-results"]["with"] == {
        "name": "test-results-output-${{ inputs.test-file }}",
        "path": "${{ steps.run-tests.outputs.json-file }}",
    },
    "test-step": test.get("continue-on-error") is True
    and "!cancelled()" in str(test.get("if"))
    and "steps.azure-login.outcome != 'failure'" in str(test.get("if"))
    and str(test["env"].get("TF_IN_AUTOMATION")).lower() == "true"
    and "working-directory" not in test,
    "gate-last": steps[-1]["id"] == "test-status"
    and "steps.run-tests.outputs.status != 'pass'" in steps[-1]["if"]
    and "steps.run-tests.outcome == 'failure'" in steps[-1]["if"]
    and steps[-1]["if"].startswith("always()")
    and "exit 1" in steps[-1]["run"],
    # Only small scalars reach envp: every env value is a plain input.
    "env-scalars": all(
        re.fullmatch(r"\$\{\{ inputs\.[a-z-]+ \}\}", str(value)) or key == "TF_IN_AUTOMATION"
        for key, value in test["env"].items()),
    "run-block-labels": all(
        str(step["run"]).lstrip().startswith("#") for step in steps if "run" in step),
}
ok = checks[check]
if not ok:
    print(f"  structural check '{check}' failed")
    if check == "module-ci-outputs":
        print(f"  module CI reads {sorted(read_outputs)}")
sys.exit(0 if ok else 1)
PY
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}          TERRAFORM-TEST TEST SUITE         ${NC}"
echo -e "${YELLOW}============================================${NC}"

# --------------------------------------------------------------------------
# C — classification (§5.5 rows 3-9), one fixture per row
# --------------------------------------------------------------------------
# fixture | exit | test-file | status | reason | passed failed errored skipped | summary
classification_cases=(
  "pass.json|0|tests/unit-pass.tftest.hcl|pass||2 0 0 0|Success! 2 passed, 0 failed."
  "fail.json|1|tests/unit-fail.tftest.hcl|fail|assertion|1 1 0 0|Failure! 1 passed, 1 failed."
  "runerror.json|1|tests/unit-runerror.tftest.hcl|error|run|1 0 1 1|Failure! 1 passed, 1 failed, 1 skipped."
  "fileerror.json|1|tests/unit-fileerror.tftest.hcl|error|file|0 0 0 1|Failure! 0 passed, 0 failed, 1 skipped."
  "unknownprov.json|1|tests/unit-unknownprov.tftest.hcl|error|file|0 0 0 0|Failure! 0 passed, 0 failed."
  "invalid.json|1|tests/unit-pass.tftest.hcl|error|invalid|0 0 0 0|"
  "filtermiss.json|0|tests/nosuch.tftest.hcl|error|not-discovered|0 0 0 0|Success! 0 passed, 0 failed."
  "noinit.json|1|tests/unit-pass.tftest.hcl|error|not-initialised|0 0 1 1|Failure! 0 passed, 1 failed, 1 skipped."
  "modnotinstalled.json|1|tests/unit-mod.tftest.hcl|error|not-initialised|0 0 0 0|"
  "nopackage.json|1|tests/unit-pass.tftest.hcl|error|not-initialised|0 0 0 0|"
  "corruptedplugins.json|1|tests/unit-pass.tftest.hcl|error|not-initialised|0 0 0 0|"
  "checksummismatch.json|1|tests/unit-pass.tftest.hcl|error|not-initialised|0 0 0 0|"
  "emptyroot-mock.json|0|tests/unit-mod.tftest.hcl|pass||1 0 0 0|Success! 1 passed, 0 failed."
  "lockroot.json|0|tests/unit-pass.tftest.hcl|pass||2 0 0 0|Success! 2 passed, 0 failed."
  "../not-json.txt|1|tests/unit-pass.tftest.hcl|error|invalid|0 0 0 0|"
  "pass.json|1|tests/unit-pass.tftest.hcl|error|invalid|2 0 0 0|Success! 2 passed, 0 failed."
)

for entry in "${classification_cases[@]}"; do
  IFS='|' read -r fixture_name tf_exit test_file status reason counts summary <<<"${entry}"
  read -r passed failed errored skipped <<<"${counts}"
  setup
  fixture "${fixture_name}" "${tf_exit}"
  export input_test_file="${test_file}"
  run_step
  label="C ${fixture_name} (exit ${tf_exit})"
  assert "${label}: status '${status}' reason '${reason}'" outputs_are "status=${status}" "reason=${reason}"
  assert "${label}: counts ${counts}" outputs_are "passed=${passed}" "failed=${failed}" "errored=${errored}" \
    "skipped=${skipped}" "total=$((passed + failed + errored + skipped))" "exit-code=${tf_exit}"
  assert "${label}: summary" output_is summary "${summary}"
  if [ "${status}" == "pass" ]; then
    assert "${label}: step exits 0" exit_is 0
  else
    assert "${label}: step exits 1" exit_is 1
  fi
  teardown
done

# --------------------------------------------------------------------------
# E — earlier steps (§5.5 rows 0, 0b, 1): no terraform, status from inputs
# --------------------------------------------------------------------------
# credentials | lock | init | status | reason
earlier_cases=(
  "failure||skipped|error|no-credentials"
  "cancelled|||error|no-credentials"
  "failure|failure|failure|error|no-credentials"
  "|failure|skipped|error|lock-platform"
  "skipped|failure|skipped|error|lock-platform"
  "||failure|error|init"
  "||skipped|error|init"
  "||cancelled|error|init"
)
for entry in "${earlier_cases[@]}"; do
  IFS='|' read -r credentials lock init status reason <<<"${entry}"
  setup
  fixture pass.json
  export input_status_credentials="${credentials}" input_status_lock="${lock}" input_status_init="${init}"
  run_step
  label="E credentials '${credentials}' lock '${lock}' init '${init}'"
  assert "${label}: ${status} (${reason})" outputs_are "status=${status}" "reason=${reason}"
  assert "${label}: terraform test not run" terraform_test_not_run
  assert "${label}: no JSON log, empty exit code, zero counts" outputs_are "json-file=" "exit-code=" "total=0" \
    "runs-json-file=${RUNNER_TEMP}/modules-net--unit-pass/runs.json" "failed-runs-json=[]"
  assert "${label}: step exits 1" exit_is 1
  teardown
done

setup
fixture pass.json
export input_status_credentials="skipped" input_status_lock="success" input_status_init="success"
run_step
assert "E credentials 'skipped' (no environment lane), lock and init success: the test runs" outputs_are "status=pass" "reason="
teardown

setup
fixture pass.json
export input_status_init=""
run_step
assert "E no outcomes supplied (legacy callers): the test runs" outputs_are "status=pass" "reason="
teardown

setup
export input_status_lock="failure"
run_step
assert "E lock-platform: runner-platform is published for the fix" output_is runner-platform "linux_amd64"
assert "E lock-platform: the annotation names the platform" log_contains "terraform providers lock -platform=linux_amd64"
teardown

# --------------------------------------------------------------------------
# V — the version gate (§3.5) and -junit-xml from 1.11 (§5.4)
# --------------------------------------------------------------------------
setup
fixture pass.json
fake_version "1.11.4"
run_step
assert "V 1.11.4 with a working directory: error (terraform-version)" outputs_are "status=error" "reason=terraform-version" "terraform-version=1.11.4"
assert "V 1.11.4: terraform test not run" terraform_test_not_run
assert "V 1.11.4: the message names the floor" log_contains "below the floor 1.13.0"
assert "V 1.11.4: the floor is published" output_is terraform-version-floor "1.13.0"
teardown

# A failed init defers to the floor: an old version is the likelier cause.
setup
fixture pass.json
fake_version "1.11.4"
export input_status_init="failure"
run_step
assert "V 1.11.4 after a failed init: error (terraform-version), not init" outputs_are "status=error" "reason=terraform-version" "terraform-version=1.11.4"
assert "V 1.11.4 after a failed init: terraform test not run" terraform_test_not_run
teardown

setup
fixture pass.json
fake_version "1.13.0"
export input_status_init="failure"
run_step
assert "V 1.13.0 after a failed init: error (init)" outputs_are "status=error" "reason=init" "terraform-version=1.13.0"
teardown

# 1.12 initialises an empty root but refuses a test file's variable blocks: below the floor.
setup
fixture pass.json
fake_version "1.12.2"
run_step
assert "V 1.12.2: error (terraform-version)" outputs_are "status=error" "reason=terraform-version" "terraform-version=1.12.2"
assert "V 1.12.2: terraform test not run" terraform_test_not_run
teardown

setup
fixture pass.json
fake_version "1.11.4"
export input_status_lock="failure" input_status_init="skipped"
run_step
assert "V 1.11.4 after a failed lock check: error (lock-platform), the version not read" outputs_are "status=error" "reason=lock-platform" "terraform-version="
teardown

setup
fixture pass.json
fake_version "1.13.0"
run_step
assert "V 1.13.0: runs" outputs_are "status=pass" "terraform-version=1.13.0"
teardown

setup
fixture pass.json
fake_version "1.13.0-rc1"
run_step
assert "V 1.13.0-rc1: counts as 1.13.0" output_is status pass
teardown

setup
fixture pass.json
fake_version "2.0.0"
run_step
assert "V 2.0.0: runs" output_is status pass
teardown

setup
fixture pass.json
fake_version "1.9.8"
export input_working_directory="" input_test_file="unit-pass.tftest.hcl" input_slug=""
run_step
assert "V legacy call shape on 1.9.8: no floor, runs" output_is status pass
assert "V 1.9.8: no -junit-xml below 1.11" test_call_is "cwd=<WORKSPACE> TF_IN_AUTOMATION=true args=test -json -no-color -filter=tests/unit-pass.tftest.hcl"
teardown

setup
fixture pass.json
fake_version "1.11.0"
export input_working_directory="" input_test_file="unit-pass.tftest.hcl" input_slug=""
run_step
assert "V 1.11.0: -junit-xml passed" test_call_is "cwd=<WORKSPACE> TF_IN_AUTOMATION=true args=test -json -no-color -filter=tests/unit-pass.tftest.hcl -junit-xml=<RUNNER_TEMP>/root--unit-pass/junit.xml"
teardown

setup
fixture pass.json
export input_junit="false"
run_step
assert "V junit 'false': no -junit-xml" test_call_is "cwd=<WORKSPACE>/modules/net TF_IN_AUTOMATION=true args=test -json -no-color -filter=tests/unit-pass.tftest.hcl"
assert "V junit 'false': junit-file empty" output_is junit-file ""
teardown

setup
run_step_without_terraform() {
  local dir="${TEST_TMP}/bin-no-tf"
  mkdir -p "${dir}"
  local tool
  for tool in basename dirname md5sum head realpath cat jq sed awk tr wc mkdir rm mv grep; do
    ln -sf "$(command -v "${tool}")" "${dir}/${tool}"
  done
  TEST_PATH="${dir}"
  run_step
}
run_step_without_terraform
assert "V terraform missing: error (terraform-version)" outputs_are "status=error" "reason=terraform-version"
assert "V terraform missing: the message says so" log_contains "terraform is not available on PATH"
teardown

# --------------------------------------------------------------------------
# I — invocation (§5.4) and file layout
# --------------------------------------------------------------------------
setup
fixture pass.json
export FAKE_TF_JUNIT="${FIXTURES}/pass.junit.xml"
export FAKE_TF_STDERR="a stray stderr line"
run_step
assert "I from the working directory, -filter verbatim, -junit-xml under RUNNER_TEMP/<slug>/" \
  test_call_is "cwd=<WORKSPACE>/modules/net TF_IN_AUTOMATION=true args=test -json -no-color -filter=tests/unit-pass.tftest.hcl -junit-xml=<RUNNER_TEMP>/modules-net--unit-pass/junit.xml"
assert "I file paths under RUNNER_TEMP/<slug>/" outputs_are \
  "json-file=${RUNNER_TEMP}/modules-net--unit-pass/test.json" \
  "report-file=${RUNNER_TEMP}/modules-net--unit-pass/report.txt" \
  "junit-file=${RUNNER_TEMP}/modules-net--unit-pass/junit.xml" \
  "runs-json-file=${RUNNER_TEMP}/modules-net--unit-pass/runs.json" \
  "diagnostics-json-file=${RUNNER_TEMP}/modules-net--unit-pass/diagnostics.json" \
  "providers-json-file=${RUNNER_TEMP}/modules-net--unit-pass/providers.json" \
  "test-file-path=modules/net/tests/unit-pass.tftest.hcl"
assert "I the JSON log holds stdout and stderr" \
  test "$(cat "${FIXTURES}/pass.json"; echo "a stray stderr line")" == "$(cat "${RUNNER_TEMP}/modules-net--unit-pass/test.json")"
assert "I a stray stderr line does not break classification" output_is status pass
assert "I nothing is written into the workspace" test -z "$(find "${GITHUB_WORKSPACE}" -type f)"
assert "I no leftover internal files" test -z "$(find "${RUNNER_TEMP}" -name '.*' -type f)"
teardown

setup
fixture pass.json
export input_slug=""
run_step
assert "I slug derived from root and file when not given" output_is json-file "${RUNNER_TEMP}/modules-net--unit-pass/test.json"
teardown

setup
fixture pass.json
export input_slug="" input_working_directory="." input_test_file="./tests/unit-pass.tftest.hcl"
run_step
assert "I root '.': slug 'root--…', leading './' dropped from the filter" test_call_is \
  "cwd=<WORKSPACE> TF_IN_AUTOMATION=true args=test -json -no-color -filter=tests/unit-pass.tftest.hcl -junit-xml=<RUNNER_TEMP>/root--unit-pass/junit.xml"
assert "I root '.': test-file-path without a prefix" output_is test-file-path "tests/unit-pass.tftest.hcl"
teardown

setup
fixture pass.json
export input_working_directory="${GITHUB_WORKSPACE}/modules/net"
run_step
assert "I absolute working directory" test_call_is \
  "cwd=<WORKSPACE>/modules/net TF_IN_AUTOMATION=true args=test -json -no-color -filter=tests/unit-pass.tftest.hcl -junit-xml=<RUNNER_TEMP>/modules-net--unit-pass/junit.xml"
assert "I absolute working directory: repository-relative file path" output_is test-file-path "modules/net/tests/unit-pass.tftest.hcl"
teardown

setup
fixture pass.json
export input_working_directory="modules/missing"
run_step
assert "I missing working directory: error (not-discovered), no terraform" outputs_are "status=error" "reason=not-discovered"
assert "I missing working directory: terraform test not run" terraform_test_not_run
teardown

setup
fixture pass.json
run_step
assert "I no JUnit written: junit-file empty" output_is junit-file ""
teardown

setup
fixture pass.json
mkdir -p "${RUNNER_TEMP}/modules-net--unit-pass"
echo 'stale' >"${RUNNER_TEMP}/modules-net--unit-pass/junit.xml"
run_step
assert "I a JUnit file from an earlier run of the step is not reported" output_is junit-file ""
teardown

# --------------------------------------------------------------------------
# O — outputs and files (§5.6)
# --------------------------------------------------------------------------
setup
fixture runerror.json 1
export input_test_file="tests/unit-runerror.tftest.hcl"
run_step
assert "O elapsed-ms from the test_file timestamps" output_is elapsed-ms "271"
assert "O runs-json-file: one object per run block" file_json_is runs-json-file \
  '[{"run":"first_passes","status":"pass","elapsed-ms":165},{"run":"postcondition_errors","status":"error","elapsed-ms":104},{"run":"after_error","status":"skip","elapsed-ms":null}]'
assert "O diagnostics-json-file: file prefixed with the root" file_json_is diagnostics-json-file \
  '[{"run":"postcondition_errors","file":"modules/net/main.tf","line":20,"summary":"Resource postcondition failed","detail":"prefix must not be boom"}]'
assert "O failed-runs-json: errored run with its diagnostic, then the skipped one" output_is failed-runs-json \
  '[{"run":"postcondition_errors","status":"error","file":"modules/net/main.tf","line":20,"summary":"Resource postcondition failed","detail":"prefix must not be boom"},{"run":"after_error","status":"skip","file":"","line":null,"summary":"","detail":""}]'
assert "O failed-runs-omitted 0" output_is failed-runs-omitted "0"
assert "O legacy names alias the new ones" outputs_are \
  "json=${RUNNER_TEMP}/modules-net--unit-pass/test.json" "report=${RUNNER_TEMP}/modules-net--unit-pass/report.txt"
assert "O report golden (run error)" report_matches report_runerror.txt
teardown

setup
fixture pass.json
run_step
assert "O pass: elapsed-ms" output_is elapsed-ms "1163"
assert "O pass: diagnostics empty" file_json_is diagnostics-json-file '[]'
assert "O pass: failed-runs-json empty" output_is failed-runs-json '[]'
assert "O report golden (pass)" report_matches report_pass.txt
teardown

setup
fixture fileerror.json 1
export input_test_file="tests/unit-fileerror.tftest.hcl" input_working_directory="."
mkdir -p "${GITHUB_WORKSPACE}"
run_step
assert "O root '.': diagnostic file not prefixed; file-level diagnostic has no run" file_json_is diagnostics-json-file \
  '[{"run":"","file":"tests/unit-fileerror.tftest.hcl","line":1,"summary":"Required variable not set","detail":"The variable \"needed\" is required, but is not set."}]'
assert "O file-level diagnostic first in failed-runs-json" output_is failed-runs-json \
  '[{"run":"","status":"error","file":"tests/unit-fileerror.tftest.hcl","line":1,"summary":"Required variable not set","detail":"The variable \"needed\" is required, but is not set."},{"run":"uses_required_var","status":"skip","file":"","line":null,"summary":"","detail":""}]'
teardown

setup
fixture unknownprov.json 1
export input_test_file="tests/unit-unknownprov.tftest.hcl"
run_step
assert "O diagnostic without a range: empty file, null line" file_json_is diagnostics-json-file \
  '[{"run":"","file":"","line":null,"summary":"unknown provider registry.terraform.io/hashicorp/time","detail":""}]'
teardown

setup
fixture filtermiss.json
export input_test_file="tests/nosuch.tftest.hcl"
run_step
assert "O warnings are not diagnostics (the unknown-file warning)" file_json_is diagnostics-json-file '[]'
teardown

# A log with many long diagnostics: everything bounded.
setup
big="${TEST_TMP}/big.json"
jq -c 'select(.type != "diagnostic")' "${FIXTURES}/runerror.json" >"${big}"
for i in $(seq 1 40); do
  jq -c --arg i "${i}" --arg long "$(printf 'x%.0s' $(seq 1 400))" \
    'select(.type == "diagnostic") | .diagnostic.summary = "Problem \($i)" | .diagnostic.detail = $long | .["@message"] = "Error: Problem \($i)"' \
    "${FIXTURES}/runerror.json" >>"${big}"
done
export FAKE_TF_OUTPUT="${big}" FAKE_TF_EXIT=1
export input_test_file="tests/unit-runerror.tftest.hcl"
run_step
assert "O big log: failed-runs-json at most 3000 bytes" test "$(output_value failed-runs-json | wc -c)" -le 3000
assert "O big log: kept plus omitted is every element (40 diagnostics + 1 skip)" \
  test "$(( $(output_value failed-runs-json | jq length) + $(output_value failed-runs-omitted) ))" -eq 41
assert "O big log: detail cut to 200 characters" \
  test "$(output_value failed-runs-json | jq -r '.[0].detail | length')" -eq 200
assert "O big log: nothing large in GITHUB_OUTPUT" outputs_are_small
assert "O big log: diagnostics file keeps every diagnostic in full" \
  test "$(jq 'length' "$(output_value diagnostics-json-file)")" -eq 40
teardown

# The report is capped at 65 000 bytes on a line boundary.
setup
huge="${TEST_TMP}/huge.json"
jq -c 'select(.type != "diagnostic")' "${FIXTURES}/runerror.json" >"${huge}"
long_detail="$(printf 'ø%.0s' $(seq 1 1000))"
for i in $(seq 1 60); do
  jq -c --arg i "${i}" --arg long "${long_detail}" \
    'select(.type == "diagnostic") | .diagnostic.summary = "Problem \($i)" | .diagnostic.detail = $long' \
    "${FIXTURES}/runerror.json" >>"${huge}"
done
export FAKE_TF_OUTPUT="${huge}" FAKE_TF_EXIT=1
export input_test_file="tests/unit-runerror.tftest.hcl"
run_step
report_file="$(output_value report-file)"
assert "O huge report: at most 65 000 bytes plus the truncation line" \
  test "$(wc -c <"${report_file}")" -le 65040
assert "O huge report: ends with the truncation note" test "$(tail -n 1 "${report_file}")" == "… (truncated, see test.json)"
assert "O huge report: valid UTF-8 (no split sequence)" iconv -f UTF-8 -t UTF-8 "${report_file}" -o /dev/null
assert "O huge report: 10 annotations and one warning for the rest" annotation_count_is error 10
assert "O huge report: the warning counts the rest" log_contains "::warning title=Terraform test::50 more error diagnostics in the report (modules/net/tests/unit-runerror.tftest.hcl)"
teardown

# --------------------------------------------------------------------------
# A — annotations (§5.7)
# --------------------------------------------------------------------------
setup
fixture runerror.json 1
export input_test_file="tests/unit-runerror.tftest.hcl"
run_step
assert "A one ::error per diagnostic, file and line inline" log_contains \
  "::error file=modules/net/main.tf,line=20,title=Terraform test error::postcondition_errors: Resource postcondition failed — prefix must not be boom"
assert "A exactly one ::error" annotation_count_is error 1
teardown

setup
fixture pass.json
run_step
assert "A pass: no ::error" annotation_count_is error 0
teardown

setup
fixture filtermiss.json
export input_test_file="tests/nosuch.tftest.hcl"
run_step
assert "A reason without diagnostics: one ::error naming it" log_contains \
  "::error title=Terraform test error (not-discovered)::modules/net/tests/nosuch.tftest.hcl: Terraform did not discover 'tests/nosuch.tftest.hcl' from 'modules/net': -filter matched no test file."
teardown

setup
escaped="${TEST_TMP}/escaped.json"
jq -c 'if .type == "diagnostic" then .diagnostic.range.filename = "a,b:c%.tf" | .diagnostic.detail = "line one\nline two 100%" else . end' \
  "${FIXTURES}/runerror.json" >"${escaped}"
export FAKE_TF_OUTPUT="${escaped}" FAKE_TF_EXIT=1
export input_test_file="tests/unit-runerror.tftest.hcl"
run_step
assert "A workflow-command escaping of properties and data" log_contains \
  "::error file=modules/net/a%2Cb%3Ac%25.tf,line=20,title=Terraform test error::postcondition_errors: Resource postcondition failed — line one%0Aline two 100%25"
teardown

setup
fixture fileerror.json 1
export input_test_file="tests/unit-fileerror.tftest.hcl"
run_step
assert "A file-level diagnostic: no run prefix" log_contains \
  "::error file=modules/net/tests/unit-fileerror.tftest.hcl,line=1,title=Terraform test error::Required variable not set — The variable \"needed\" is required, but is not set."
teardown

setup
fixture fail.json 1
export input_test_file="tests/unit-fail.tftest.hcl"
run_step
assert "A assertion: title says fail" log_contains \
  "::error file=modules/net/tests/unit-fail.tftest.hcl,line=4,title=Terraform test fail::prefix_is_wrong: Test assertion failed — group display name must start with tftest-"
teardown

# --------------------------------------------------------------------------
# S — per-job step summary (§5.8)
# --------------------------------------------------------------------------
setup
fixture pass.json
run_step
assert "S pass golden" step_summary_matches summary_pass.md
teardown

setup
fixture runerror.json 1
export input_test_file="tests/unit-runerror.tftest.hcl"
run_step
assert "S run error golden" step_summary_matches summary_runerror.md
teardown

setup
fixture fail.json 1
export input_test_file="tests/unit-fail.tftest.hcl"
run_step
assert "S assertion golden" step_summary_matches summary_fail.md
teardown

setup
export input_status_credentials="failure"
run_step
assert "S no-credentials golden" step_summary_matches summary_no_credentials.md
teardown

setup
unset GITHUB_STEP_SUMMARY
fixture pass.json
run_step
assert "S no GITHUB_STEP_SUMMARY: the step still passes" exit_is 0
teardown

# --------------------------------------------------------------------------
# P — resolved provider versions against the copied lock (§5.3)
# --------------------------------------------------------------------------
setup
fixture lockroot.json
cp "${FIXTURES}/written.lock.hcl" "${GITHUB_WORKSPACE}/modules/net/.terraform.lock.hcl"
mkdir -p "${GITHUB_WORKSPACE}/envs/prod"
cp "${FIXTURES}/copied.lock.hcl" "${GITHUB_WORKSPACE}/envs/prod/.terraform.lock.hcl"
export input_environments_lock_file="envs/prod/.terraform.lock.hcl"
run_step
assert "P copied lock: kept version is environments, test-only is floating" file_json_is providers-json-file \
  '[{"name":"registry.terraform.io/hashicorp/null","version":"3.2.3","origin":"environments","environments-version":"3.2.3"},{"name":"registry.terraform.io/hashicorp/random","version":"3.9.1","origin":"floating","environments-version":null}]'
assert "P providers-summary and floating count" outputs_are \
  "providers-summary=null 3.2.3 environments · random 3.9.1 floating" "providers-floating-count=1"
assert "P step summary golden with providers" step_summary_matches summary_providers.md
teardown

setup
fixture lockroot.json
cp "${FIXTURES}/written.lock.hcl" "${GITHUB_WORKSPACE}/modules/net/.terraform.lock.hcl"
export input_environments_lock_file="${GITHUB_WORKSPACE}/modules/net/.terraform.lock.hcl"
run_step
assert "P environment root (its own lock, absolute path): every provider environments" outputs_are \
  "providers-summary=null 3.2.3 environments · random 3.9.1 environments" "providers-floating-count=0"
teardown

setup
fixture lockroot.json
cp "${FIXTURES}/written.lock.hcl" "${GITHUB_WORKSPACE}/modules/net/.terraform.lock.hcl"
run_step
assert "P no environments lock: origin root" file_json_is providers-json-file \
  '[{"name":"registry.terraform.io/hashicorp/null","version":"3.2.3","origin":"root","environments-version":null},{"name":"registry.terraform.io/hashicorp/random","version":"3.9.1","origin":"root","environments-version":null}]'
teardown

setup
fixture lockroot.json
cp "${FIXTURES}/written.lock.hcl" "${GITHUB_WORKSPACE}/modules/net/.terraform.lock.hcl"
export input_environments_lock_file="envs/missing/.terraform.lock.hcl"
run_step
assert "P environments lock missing: origin root and a warning" outputs_are \
  "providers-summary=null 3.2.3 root · random 3.9.1 root" "status=pass"
assert "P environments lock missing: warned" log_contains "environments lock 'envs/missing/.terraform.lock.hcl' not found"
teardown

setup
fixture pass.json
run_step
assert "P no lock in the root: empty list and summary" outputs_are "providers-summary=" "providers-floating-count=0"
assert "P no lock in the root: providers file is []" file_json_is providers-json-file '[]'
teardown

setup
cp "${FIXTURES}/written.lock.hcl" "${GITHUB_WORKSPACE}/modules/net/.terraform.lock.hcl"
export input_status_init="failure"
run_step
assert "P init failed: providers not read" outputs_are "providers-summary=" "providers-floating-count=0"
teardown

# --------------------------------------------------------------------------
# M — module CI compatibility (§9.7): the legacy call shape
# --------------------------------------------------------------------------
setup
fixture pass.json
export input_working_directory="" input_test_file="unit-pass.tftest.hcl" input_slug="" input_status_init=""
run_step
assert "M legacy shape: from the workspace, -filter=tests/<test-file>" test_call_is \
  "cwd=<WORKSPACE> TF_IN_AUTOMATION=true args=test -json -no-color -filter=tests/unit-pass.tftest.hcl -junit-xml=<RUNNER_TEMP>/root--unit-pass/junit.xml"
assert "M legacy shape: json, report, summary, exit-code as module CI reads them" outputs_are \
  "json=${RUNNER_TEMP}/root--unit-pass/test.json" "report=${RUNNER_TEMP}/root--unit-pass/report.txt" \
  "summary=Success! 2 passed, 0 failed." "exit-code=0" "status=pass"
assert "M legacy shape: step exits 0" exit_is 0
teardown

setup
fixture fail.json 1
export input_working_directory="" input_test_file="unit-fail.tftest.hcl" input_slug="" input_status_init=""
run_step
assert "M legacy shape, failing test: step exits 1 (the action fails)" exit_is 1
assert "M legacy shape, failing test: report file exists" test -f "$(output_value report)"
teardown

setup
assert "M module CI's with: keys are all inputs" yaml_check module-ci-inputs
assert "M module CI's outputs (steps.test.outputs.*) all exist" yaml_check module-ci-outputs
assert "M azure/login runs for the legacy shape by default, gated by azure-login" yaml_check login-gated
assert "M upload runs for the legacy shape by default, gated by upload-artifact" yaml_check upload-gated
teardown

# --------------------------------------------------------------------------
# Y — action.yml structure
# --------------------------------------------------------------------------
setup
assert "Y inputs and their defaults" yaml_check inputs
assert "Y every output maps to the step output of the same name" yaml_check outputs
assert "Y test step: continue-on-error, runs unless cancelled or login failed, TF_IN_AUTOMATION" yaml_check test-step
assert "Y the gate fails the action unless the status is pass, last" yaml_check gate-last
assert "Y only plain inputs reach the step's env" yaml_check env-scalars
assert "Y every run block opens with a label comment" yaml_check run-block-labels
teardown

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
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
