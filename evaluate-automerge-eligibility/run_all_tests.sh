#!/bin/env bash
#
# Tests for evaluate-automerge-eligibility: the action's own run block, end to end.
#
# The adapter (engine/dsb_tf_engine/automerge_evidence.py) and the rules (automerge_project.py)
# are unit tested in engine/ under the coverage and mutation gates. This suite runs what only a
# runner runs: the run block of action.yml, extracted with yq, with its expressions pasted into
# the script text as GitHub pastes them, the step's env: set, and nothing else of this suite's
# environment.
#
#  1. Every golden case (engine/tests/evaluator_port, docs/Auto-merge.md §14), captured from the
#     bash evaluator this action ran before the engine: the same exit code and is-eligible, and
#     every reason the case asserts.
#  2. The run block's shape, stage results holding shell syntax, caller values in the log, a value
#     starting with '-', a relevance file outside the workspace, a Dependabot major in the
#     relevance file's admission (D15), and the caller's checkout staying off Python's import path.
#
# To run the evaluator by hand, in a directory holding the metadata files:
#   GITHUB_ACTOR='dependabot[bot]' GITHUB_OUTPUT=<file> python3 -I -B <repo>/engine/run.py evaluate-automerge \
#     --metadata-files-pattern='matrix-job-meta-*.json' --relevance-file=relevance.json \
#     --test-metadata-files-pattern='terraform-test-meta-*.json' --stage-results-file=<file holding stage-results-json>
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
_cases_dir="$(cd -- "${_this_script_dir}/../engine/tests/evaluator_port" &>/dev/null && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# The step's log and the step itself, one file each per run of this suite: suites run side by side.
OUT_FILE="$(mktemp)"
STEP_JSON="$(mktemp)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${OUT_FILE}" "${STEP_JSON}" "${SCRATCH}"' EXIT
yq -o json '.runs.steps[0]' "${_this_script_dir}/action.yml" >"${STEP_JSON}"

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

pass() {
  echo -e "${GREEN}✓ PASSED${NC}${1:+: ${1}}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo -e "${RED}✗ FAILED${NC}: ${1}"
  echo "--- step output (tail) ---"
  tail -n 40 "${OUT_FILE}" 2>/dev/null || true
  echo "--- /step output ---"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

begin() {
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${1}${NC}"
}

# A sandbox for the case in $1: its files in a workspace (ws), the run block with the case's inputs
# pasted in (step.sh), and the step's env: with them substituted, one assignment a line (env).
make_sandbox() {
  SANDBOX="$(mktemp -d -p "${SCRATCH}")"
  python3 - "${_this_script_dir}" "${STEP_JSON}" "${1}" "${SANDBOX}" <<'PY'
import json, os, shlex, sys
action_dir, step_file, case_file, sandbox = sys.argv[1:5]
with open(step_file, encoding="utf-8") as handle:
    step = json.load(handle)
with open(case_file, encoding="utf-8") as handle:
    case = json.load(handle)
os.makedirs(f"{sandbox}/ws")
for name, content in case["files"].items():
    with open(f"{sandbox}/ws/{name}", "w", encoding="utf-8") as handle:
        handle.write(content["text"] if "text" in content else json.dumps(content["json"], indent=2))
inputs = {"metadata-files-pattern": case["metadata_files_pattern"], "relevance-file": case["relevance_file"],
          "test-metadata-files-pattern": case["test_metadata_files_pattern"],
          "stage-results-json": case["stage_results_json"]}
def paste(text):
    for name, value in inputs.items():
        text = text.replace("${{ inputs." + name + " }}", value)
    return text.replace("${{ github.action_path }}", action_dir)
with open(f"{sandbox}/step.sh", "w", encoding="utf-8") as handle:
    handle.write(paste(step["run"]))
with open(f"{sandbox}/env", "w", encoding="utf-8") as handle:
    for key, value in (step.get("env") or {}).items():
        handle.write(f"{key}={shlex.quote(paste(str(value)))}\n")
    handle.write(f"GITHUB_ACTOR={shlex.quote(case['actor'])}\n")
PY
}

# A copy of the case in $1 changed by the jq filter in $2; prints the copy's path.
case_with() {
  local copy
  copy="$(mktemp -p "${SCRATCH}" --suffix=.json)"
  jq "${2}" "${1}" >"${copy}"
  echo "${copy}"
}

# Run the sandbox's step in its workspace as the runner runs a composite step: what the runner sets,
# then the step's env:. Extra assignments may be given as arguments. Sets STEP_EXIT.
run_step() {
  : >"${SANDBOX}/output.txt"
  (
    cd "${SANDBOX}/ws" || exit 1
    env -i PATH="${PATH}" HOME="${HOME}" LANG="${LANG:-C.UTF-8}" GITHUB_OUTPUT="${SANDBOX}/output.txt" \
      GITHUB_ACTION_PATH="${_this_script_dir}" "$@" \
      bash --noprofile --norc -c 'set -a; source "${1}"; set +a; exec bash --noprofile --norc -eo pipefail "${2}"' \
      _ "${SANDBOX}/env" "${SANDBOX}/step.sh"
  ) >"${OUT_FILE}" 2>&1
  STEP_EXIT=$?
}

# A step output by name, in either form GitHub reads: name=value or name<<delimiter.
step_output() {
  python3 - "${SANDBOX}/output.txt" "${1}" <<'PY'
import sys
path, name = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
for index, line in enumerate(lines):
    if line.startswith(name + "="):
        print(line[len(name) + 1:])
        break
    if line.startswith(name + "<<"):
        print("\n".join(lines[index + 1:lines.index(line[len(name) + 2:], index + 1)]))
        break
PY
}

# Lines of the step's log that are outside every stop-commands block.
outside_verbatim() {
  awk '/^::stop-commands::/{t="::" substr($0, 18) "::"; next} t && $0==t {t=""; next} !t' "${OUT_FILE}"
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}   EVALUATE-AUTOMERGE-ELIGIBILITY TESTS     ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ======================================================================
# 1: every golden case, end to end
# ======================================================================

for case_file in "${_cases_dir}"/*.json; do
  begin "golden $(basename "${case_file}" .json)"
  make_sandbox "${case_file}"
  run_step
  expected_exit="$(jq -r '.expected.exit' "${case_file}")"
  expected_eligible="$(jq -r '.expected.is_eligible' "${case_file}")"
  actual_eligible="$(step_output is-eligible)"
  problems=()
  [[ "${STEP_EXIT}" == "${expected_exit}" ]] || problems+=("exit code ${STEP_EXIT}, expected ${expected_exit}")
  [[ "${actual_eligible}" == "${expected_eligible}" ]] ||
    problems+=("is-eligible '${actual_eligible}', expected '${expected_eligible}'")
  while IFS= read -r text; do
    if [[ "${text}" == '!'* ]]; then
      grep -qF -- "${text#!}" "${OUT_FILE}" && problems+=("output holds: ${text#!}")
    else
      grep -qF -- "${text}" "${OUT_FILE}" || problems+=("output lacks: ${text}")
    fi
  done < <(jq -r '.expected.texts[]' "${case_file}")
  if [[ ${#problems[@]} -eq 0 ]]; then
    pass "exit ${STEP_EXIT}, is-eligible '${actual_eligible}'"
  else
    fail "$(printf '%s; ' "${problems[@]}")"
  fi
done

# ======================================================================
# 2: what only the action's run block and a runner do
# ======================================================================

baseline="${_cases_dir}/001-single-file-basic-eligible-scenario.json"
# The first eligible case that reads a relevance file.
with_relevance="$(jq -r 'select(.relevance_file == "relevance-input.json" and .kind == "run"
  and .expected.is_eligible == "true") | input_filename' "${_cases_dir}"/*.json | head -n 1)"

begin "run block: a description comment first, the stage results to a file through a quoted, unique heredoc, python3 -I"
run_block="$(jq -r '.run' "${STEP_JSON}")"
if [[ "$(head -n 1 <<<"${run_block}")" == "# "* ]] \
  && grep -qx "cat >\"\${stage_results_file}\" <<'EVALUATE_AUTOMERGE_ELIGIBILITY_STAGE_RESULTS_JSON'" <<<"${run_block}" \
  && grep -qx 'EVALUATE_AUTOMERGE_ELIGIBILITY_STAGE_RESULTS_JSON' <<<"${run_block}" \
  && grep -q '^python3 -I -B "${{ github.action_path }}/../engine/run.py" evaluate-automerge \\$' <<<"${run_block}" \
  && [[ "$(grep -c '\${{' <<<"${run_block}")" == "2" ]] \
  && ! grep -qE '^(export|input_|set -o allexport|source)' <<<"${run_block}" \
  && [[ "$(jq -c '.env' "${STEP_JSON}")" == '{"METADATA_FILES_PATTERN":"${{ inputs.metadata-files-pattern }}","RELEVANCE_FILE":"${{ inputs.relevance-file }}","TEST_METADATA_FILES_PATTERN":"${{ inputs.test-metadata-files-pattern }}"}' ]]; then
  pass
else
  fail "the run block no longer has its hardened shape"
fi

begin "stage results: shell syntax in the value stays data"
make_sandbox "$(case_with "${with_relevance}" '.stage_results_json = "{\"1\": \"$(touch INJECTED) `touch INJECTED2`\", \"2\": \"skipped\"}"')"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && ! compgen -G "${SANDBOX}/ws/INJECTED*" >/dev/null \
  && [[ "$(step_output is-eligible)" == "true" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or the stage results ran as shell"
fi

begin "log: an environment name carrying a workflow command starts no command"
make_sandbox "$(case_with "${baseline}" '.files["matrix-job-meta-sandbox.json"].json.metadata.environment = "sandbox\n::warning::injected"')"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && grep -q '::warning::injected' "${OUT_FILE}" \
  && ! outside_verbatim | grep -q '^::warning::'; then
  pass
else
  fail "exit ${STEP_EXIT}, or a caller's value reached the log as a workflow command"
fi

begin "log: a configuration error naming a caller's value is one annotation, its newline escaped"
make_sandbox "$(case_with "${baseline}" '.files["matrix-job-meta-sandbox.json"].json.matrix_context.vars["pr-auto-merge-limits"]["plan-max-count-add"] = "1\n::warning::injected"')"
run_step
if [[ ${STEP_EXIT} -eq 1 ]] && ! outside_verbatim | grep -q '^::warning::' \
  && grep -qF "::error title=evaluate-automerge-eligibility::Configuration error: 'plan-max-count-add' value '1%0A::warning::injected' is not a valid integer" "${OUT_FILE}" \
  && [[ -z "$(step_output is-eligible)" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or the error annotation was split or unescaped"
fi

begin "arguments: a pattern starting with '-' is a pattern, not an option"
make_sandbox "$(case_with "${baseline}" '.files |= with_entries(.key |= sub("^matrix-job-meta-"; "-meta-")) | .metadata_files_pattern = "-meta-*.json"')"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(step_output is-eligible)" == "true" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, is-eligible '$(step_output is-eligible)'"
fi

begin "relevance: the file is read from outside the workspace, as the workflow downloads it to runner.temp"
make_sandbox "${with_relevance}"
mkdir -p "${SANDBOX}/temp/relevance" && mv "${SANDBOX}/ws/relevance-input.json" "${SANDBOX}/temp/relevance/relevance.json"
sed -i "s|^RELEVANCE_FILE=.*|RELEVANCE_FILE=${SANDBOX}/temp/relevance/relevance.json|" "${SANDBOX}/env"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(step_output is-eligible)" == "true" ]] \
  && grep -q "Environments in relevance file:" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, is-eligible '$(step_output is-eligible)', or the relevance file was not read"
fi

begin "dependabot: a major in the admission's facts, read from the relevance file, keeps the pull request open"
admission='{"applies": true, "admitted": true, "push_run": false, "dependencies": [{"kind": "provider",
  "address": "registry.terraform.io/hashicorp/azurerm", "from": "4.81.0", "to": "5.8.0"}]}'
make_sandbox "$(case_with "${with_relevance}" ".actor = \"dependabot[bot]\"
  | .files[\"relevance-input.json\"].json.admission = ${admission}
  | (.files[] | .json? | objects | .. | objects | select(has(\"pr-auto-merge-from-actors\"))
     | .[\"pr-auto-merge-from-actors\"]) |= [\"dependabot[bot]\"]")"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(step_output is-eligible)" == "false" ]] \
  && grep -qF "WARN: Dependabot's pull request moves provider hashicorp/azurerm from 4.81.0 to 5.8.0, past its major" "${OUT_FILE}" \
  && grep -qF "Pull request: ❌ Dependabot's majors" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, is-eligible '$(step_output is-eligible)', or the major was not named"
fi

begin "isolation: the caller's checkout and PYTHON* variables cannot replace the standard library"
make_sandbox "${baseline}"
echo 'raise SystemExit("caller json.py imported")' >"${SANDBOX}/ws/json.py"
mkdir -p "${SANDBOX}/pypath" && echo 'raise SystemExit("PYTHONPATH glob imported")' >"${SANDBOX}/pypath/glob.py"
run_step PYTHONPATH="${SANDBOX}/pypath" PYTHONSTARTUP="${SANDBOX}/ws/json.py"
if [[ ${STEP_EXIT} -eq 0 ]] && ! grep -q "imported" "${OUT_FILE}" && [[ "$(step_output is-eligible)" == "true" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or a module from the checkout or PYTHONPATH was imported"
fi

# ======================================================================
# Summary
# ======================================================================
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}                 SUMMARY                    ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -eq 0 ]]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
fi
