#!/bin/env bash
#
# Tests for create-tf-vars-matrix: the action's own run block, end to end.
#
# The adapter and the engine are unit tested in engine/ under the coverage and mutation gates.
# This suite runs what only a runner runs: the run block of action.yml, extracted with yq, with
# its two expressions substituted as GitHub substitutes them (pasted into the script text), real
# yq underneath and a stub gh where the API is needed.
#
#  1. Every port case (engine/tests/port/cases): matrix-json, or the exit code and the ::error
#     annotations, equal the case's golden (engine_expected when the case records a deviation).
#  2. The input document the adapter logs for every case equals the case's committed input.json,
#     which is what the engine suite decides from. UPDATE_ENGINE_INPUTS=1 rewrites them.
#  3. The run block's shape, the default-branch fallback and its failure, a broken yq, a
#     non-JSON input, caller values in the log, secrets and inputs staying out of the adapter's
#     environment, and the caller's checkout staying off Python's import path.
#
# To run the adapter by hand against a file holding toJSON(inputs), in the project's checkout:
#   GITHUB_REPOSITORY=o/r GITHUB_EVENT_NAME=push GITHUB_REF_NAME=main GITHUB_OUTPUT=/tmp/out \
#     python3 -I -B engine/run.py create-matrix --inputs-file <file holding toJSON(inputs)>
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
_cases_dir="$(cd -- "${_this_script_dir}/../engine/tests/port/cases" &>/dev/null && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

OUT_FILE="$(mktemp)"

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

pass() {
  echo -e "${GREEN}✓ PASSED${NC}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo -e "${RED}✗ FAILED${NC}: ${1}"
  echo "--- step output (tail) ---"
  tail -n 30 "${OUT_FILE}" 2>/dev/null || true
  echo "--- /step output ---"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

begin() {
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${1}${NC}"
}

# A sandbox for the case in $1: a workspace holding the case's directories, the inputs as
# toJSON would render them, and an event payload carrying the case's default branch.
make_sandbox() {
  local case_file="${1}" directory
  SANDBOX="$(mktemp -d)"
  mkdir -p "${SANDBOX}/ws" "${SANDBOX}/bin"
  while IFS= read -r directory; do
    mkdir -p "${SANDBOX}/ws/${directory}"
  done < <(jq -r '.directories[]?' "${case_file}")
  jq '.inputs_json' "${case_file}" >"${SANDBOX}/inputs.json"
  jq -n --arg branch "$(jq -r '.default_branch' "${case_file}")" '{repository: {default_branch: $branch}}' \
    >"${SANDBOX}/event.json"
  CASE_REF_NAME="$(jq -r '.ref_name' "${case_file}")"
}

# The run block of action.yml with its expressions substituted, as the runner pastes them.
render_run_block() {
  python3 - "${_this_script_dir}" "${SANDBOX}/inputs.json" <<'PY'
import subprocess, sys
action_dir, inputs_file = sys.argv[1], sys.argv[2]
block = subprocess.run(["yq", ".runs.steps[0].run", f"{action_dir}/action.yml"],
                       capture_output=True, text=True, check=True).stdout
with open(inputs_file, encoding="utf-8") as handle:
    inputs = handle.read().rstrip("\n")
print(block.replace("${{ inputs.inputs-json }}", inputs).replace("${{ github.action_path }}", action_dir), end="")
PY
}

# Run the action's run block in the sandbox. Extra environment assignments may be given as
# arguments. Sets STEP_EXIT; the step's output file is ${SANDBOX}/output.txt.
run_step() {
  : >"${SANDBOX}/output.txt"
  render_run_block >"${SANDBOX}/step.sh"
  (
    cd "${SANDBOX}/ws" || exit 1
    # A dispatch fetches no changed files: the port cases decide rows, and relevance, which a
    # push or a pull request adds, has its own tests below.
    export GITHUB_REPOSITORY="example-org/example-repo" GITHUB_EVENT_NAME="workflow_dispatch"
    export GITHUB_REF_NAME="${CASE_REF_NAME:-main}" GITHUB_EVENT_PATH="${SANDBOX}/event.json"
    export GITHUB_OUTPUT="${SANDBOX}/output.txt" GH_TOKEN="fake-token" GITHUB_RUN_ID="4711" GITHUB_RUN_ATTEMPT="1"
    mkdir -p "${SANDBOX}/temp" && export RUNNER_TEMP="${SANDBOX}/temp"
    export PATH="${SANDBOX}/bin:${PATH}"
    for assignment in "$@"; do export "${assignment?}"; done
    # The runner's shell for a composite step.
    bash --noprofile --norc -eo pipefail "${SANDBOX}/step.sh"
  ) >"${OUT_FILE}" 2>&1
  STEP_EXIT=$?
}

# The matrix-json value from the sandbox's output file.
matrix_output() {
  awk '/^matrix-json<<EOF_/{d=substr($0, index($0,"<<")+2); f=1; next} f && $0==d {f=0} f' "${SANDBOX}/output.txt"
}

# A single-line step output by name.
step_output() {
  awk -v name="${1}" 'index($0, name "<<EOF_") == 1 {getline; print; exit}' "${SANDBOX}/output.txt"
}

# The input document the adapter logged, from its verbatim log group.
logged_document() {
  awk '/^::group::create-tf-vars-matrix: decision engine input document$/{g=1; next}
       g && /^::stop-commands::/{t="::" substr($0, 18) "::"; next}
       g && t && $0==t {exit}
       g && t' "${OUT_FILE}"
}

# Error annotation messages, unescaped as the runner shows them.
error_messages() {
  sed -n 's/^::error title=create-tf-vars-matrix:://p' "${OUT_FILE}" \
    | python3 -c 'import sys, json; print(json.dumps([l.rstrip("\n").replace("%0A","\n").replace("%0D","\r").replace("%25","%") for l in sys.stdin], separators=(",", ":")))'
}

# Lines of the step's log that are outside every stop-commands block.
outside_verbatim() {
  awk '/^::stop-commands::/{t="::" substr($0, 18) "::"; next} t && $0==t {t=""; next} !t' "${OUT_FILE}"
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}       CREATE-TF-VARS-MATRIX TESTS          ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ======================================================================
# 1 + 2: every port case, end to end and as an input document
# ======================================================================

for case_dir in "${_cases_dir}"/*/; do
  case_dir="${case_dir%/}"
  name="$(basename "${case_dir}")"
  case_file="${case_dir}/case.json"
  make_sandbox "${case_file}"
  run_step

  begin "end to end: ${name}"
  expected="$(jq -c '.engine_expected // empty' "${case_file}")"
  [[ -z "${expected}" ]] && expected="$(jq -c '.' "${case_dir}/expected.json")"
  if [[ "$(jq -r '.exit_code' <<<"${expected}")" == "0" ]]; then
    if [[ ${STEP_EXIT} -ne 0 ]]; then
      fail "exit code ${STEP_EXIT}, expected 0"
    elif [[ "$(matrix_output | jq -S -c .)" == "$(jq -S -c '.matrix' <<<"${expected}")" ]]; then
      pass
    else
      fail "matrix-json differs from the golden"
    fi
  elif [[ ${STEP_EXIT} -ne 2 ]]; then
    fail "exit code ${STEP_EXIT}, expected 2"
  elif [[ "$(error_messages)" == "$(jq -c '.errors' <<<"${expected}")" ]]; then
    pass
  else
    fail "errors $(error_messages), expected $(jq -c '.errors' <<<"${expected}")"
  fi

  begin "input document: ${name}"
  if [[ "${UPDATE_ENGINE_INPUTS:-}" == "1" ]]; then
    logged_document | jq -S . >"${case_dir}/input.json"
  fi
  if diff <(jq -S . "${case_dir}/input.json") <(logged_document | jq -S .) >/dev/null 2>&1; then
    pass
  else
    fail "the adapter builds a different document than ${case_dir}/input.json"
  fi
done

# ======================================================================
# 3: what only the action's run block and a runner do
# ======================================================================

baseline="${_cases_dir}/defaults/case.json"

begin "run block: a description comment first, inputs to a file through a quoted, unique heredoc, python3 -I"
run_block="$(yq '.runs.steps[0].run' "${_this_script_dir}/action.yml")"
if [[ "$(head -n 1 <<<"${run_block}")" == "# "* ]] \
  && grep -qx "cat >\"\${inputs_file}\" <<'CREATE_TF_VARS_MATRIX_INPUTS_JSON'" <<<"${run_block}" \
  && grep -qx 'CREATE_TF_VARS_MATRIX_INPUTS_JSON' <<<"${run_block}" \
  && grep -q '^python3 -I -B "${{ github.action_path }}/../engine/run.py" create-matrix --inputs-file "${inputs_file}"$' <<<"${run_block}" \
  && [[ "$(grep -c '\${{' <<<"${run_block}")" == "2" ]] \
  && ! grep -qE '^(export|input_)' <<<"${run_block}"; then
  pass
else
  fail "the run block no longer has its hardened shape"
fi

begin "default branch: a payload without it falls back to the API"
make_sandbox "${baseline}"
echo '{}' >"${SANDBOX}/event.json"
printf '#!/bin/env bash\n[[ "$1 $2" == "api repos/example-org/example-repo" ]] && echo %s\n' \
  "'{\"default_branch\":\"trunk\"}'" >"${SANDBOX}/bin/gh"
chmod +x "${SANDBOX}/bin/gh"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(matrix_output | jq -r '.include[0].vars["caller-repo-default-branch"]')" == "trunk" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or the default branch did not come from the API"
fi

begin "default branch: a failing API call fails the step and shows the answer verbatim"
make_sandbox "${baseline}"
echo '{}' >"${SANDBOX}/event.json"
printf '#!/bin/env bash\necho "HTTP 404: Not Found" >&2\nexit 1\n' >"${SANDBOX}/bin/gh"
chmod +x "${SANDBOX}/bin/gh"
run_step
if [[ ${STEP_EXIT} -eq 1 ]] && grep -q "could not resolve the default branch" "${OUT_FILE}" \
  && grep -qx "HTTP 404: Not Found" "${OUT_FILE}" && [[ -z "$(matrix_output)" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or the failure was not reported"
fi

for broken_yq in 'echo "yq: command not found" >&2; exit 127' 'echo "Error: unknown command \"e\""; exit 1' 'echo "not json"'; do
  begin "yq: a broken yq fails the step naming yq, never blaming the caller's YAML ($(cut -c1-30 <<<"${broken_yq}"))"
  make_sandbox "${baseline}"
  printf '#!/bin/env bash\n%s\n' "${broken_yq}" >"${SANDBOX}/bin/yq"
  chmod +x "${SANDBOX}/bin/yq"
  # run_step renders the run block with the real yq before the stub goes on the PATH.
  run_step
  if [[ ${STEP_EXIT} -eq 1 ]] && grep -q "yq on the runner cannot parse YAML to JSON" "${OUT_FILE}" \
    && ! grep -q "not valid yaml" "${OUT_FILE}" && [[ -z "$(matrix_output)" ]]; then
    pass
  else
    fail "exit ${STEP_EXIT}, or the failure was not attributed to yq"
  fi
done

begin "inputs: a value that is not a JSON object is refused before anything is decided"
make_sandbox "${baseline}"
printf 'environments-yml: not json\n' >"${SANDBOX}/inputs.json"
run_step
if [[ ${STEP_EXIT} -eq 1 ]] && grep -q "'inputs-json' cannot be read as JSON" "${OUT_FILE}" && [[ -z "$(matrix_output)" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or a non-JSON input was not refused"
fi

begin "inputs: a JSON value that is not an object is refused"
make_sandbox "${baseline}"
echo '["a"]' >"${SANDBOX}/inputs.json"
run_step
if [[ ${STEP_EXIT} -eq 1 ]] && grep -q "is not a JSON object; it expects toJSON(inputs)" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or a JSON array was not refused"
fi

begin "inputs: a value holding the delimiter line and shell syntax stays data"
make_sandbox "${baseline}"
jq '.["pr-comment-group"] = "x\nCREATE_TF_VARS_MATRIX_INPUTS_JSON\ntouch INJECTED $(touch INJECTED2) `touch INJECTED3`"' \
  "${SANDBOX}/inputs.json" >"${SANDBOX}/inputs.new" && mv "${SANDBOX}/inputs.new" "${SANDBOX}/inputs.json"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && ! compgen -G "${SANDBOX}/ws/INJECTED*" >/dev/null \
  && [[ "$(matrix_output | jq -r '.include[0].vars["pr-comment-group"]')" == *'touch INJECTED $(touch INJECTED2)'* ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or a JSON value escaped the heredoc"
fi

begin "log: a name carrying a workflow command is refused, and the refusal starts no command"
make_sandbox "${baseline}"
jq '.["environments-yml"] = "- environment: \"env-a\\n::warning::injected\"\n  project-dir: .\n"' \
  "${SANDBOX}/inputs.json" >"${SANDBOX}/inputs.new" && mv "${SANDBOX}/inputs.new" "${SANDBOX}/inputs.json"
run_step
if [[ ${STEP_EXIT} -eq 2 ]] && ! grep -q '^::warning::' "${OUT_FILE}" && ! grep -q 'decision record' "${OUT_FILE}" \
  && [[ -z "$(matrix_output)" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or a caller's value reached the log as a workflow command"
fi

begin "log: an error naming a caller's value is one annotation, its percent escaped and its newline shown as \\n"
make_sandbox "${baseline}"
jq '.["environments-yml"] = "- environment: \"x%\\n::warning::injected\"\n"' \
  "${SANDBOX}/inputs.json" >"${SANDBOX}/inputs.new" && mv "${SANDBOX}/inputs.new" "${SANDBOX}/inputs.json"
run_step
if [[ ${STEP_EXIT} -eq 2 ]] && ! grep -q '^::warning::' "${OUT_FILE}" \
  && [[ "$(grep -c '^::error title=create-tf-vars-matrix::' "${OUT_FILE}")" == "1" ]] \
  && grep -qF "::error title=create-tf-vars-matrix::The environment name 'x%25\\n::warning::injected' must be" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or the error annotation was split or unescaped"
fi

begin "no leak: neither the inputs nor secret-shaped variables reach the adapter's environment or documents"
make_sandbox "${baseline}"
jq '.["environments-yml"] = "- environment: \"env-a\"\n  url: \"https://example.com/SENTINEL-INPUTS-7f3a\"\n"' \
  "${SANDBOX}/inputs.json" >"${SANDBOX}/inputs.new" && mv "${SANDBOX}/inputs.new" "${SANDBOX}/inputs.json"
real_python="$(command -v python3)"
cat >"${SANDBOX}/bin/python3" <<EOF
#!/bin/env bash
env >>"${SANDBOX}/python-env.txt"
exec "${real_python}" "\$@"
EOF
chmod +x "${SANDBOX}/bin/python3"
run_step ARM_CLIENT_SECRET=SENTINEL-SECRET-91c2 TF_VAR_password=SENTINEL-SECRET-91c2
if [[ ${STEP_EXIT} -eq 0 ]] && [[ -s "${SANDBOX}/python-env.txt" ]] \
  && ! grep -q "SENTINEL-INPUTS-7f3a" "${SANDBOX}/python-env.txt" \
  && matrix_output | grep -q "SENTINEL-INPUTS-7f3a" \
  && ! logged_document | grep -q "SENTINEL-SECRET-91c2" && ! matrix_output | grep -q "SENTINEL-SECRET-91c2"; then
  pass
else
  fail "exit ${STEP_EXIT}, or the inputs or a secret leaked"
fi

begin "isolation: the caller's checkout and PYTHON* variables cannot replace the standard library"
make_sandbox "${baseline}"
echo 'raise SystemExit("caller json.py imported")' >"${SANDBOX}/ws/json.py"
mkdir -p "${SANDBOX}/pypath" && echo 'raise SystemExit("PYTHONPATH argparse imported")' >"${SANDBOX}/pypath/argparse.py"
run_step PYTHONPATH="${SANDBOX}/pypath" PYTHONSTARTUP="${SANDBOX}/ws/json.py"
if [[ ${STEP_EXIT} -eq 0 ]] && ! grep -q "imported" "${OUT_FILE}" && [[ -n "$(matrix_output)" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or a module from the checkout or PYTHONPATH was imported"
fi

# ======================================================================
# 4: relevance, with the changed files fetched through gh
# ======================================================================

# A gh answering the changed-file endpoints of the example repository from files in ${SANDBOX}/api,
# named after the endpoint with '/' as '_'; any other request fails as the API would.
make_gh() {
  mkdir -p "${SANDBOX}/api"
  cat >"${SANDBOX}/bin/gh" <<'GH'
#!/usr/bin/env bash
answer="$(dirname "$0")/../api/${2//\//_}"
[[ "$1" == "api" && -f "${answer}" ]] && cat "${answer}" && exit 0
echo "gh: Not Found (HTTP 404) for $2" >&2
exit 1
GH
  chmod +x "${SANDBOX}/bin/gh"
}

# The decision record the adapter logged.
logged_record() {
  awk '/^::group::create-tf-vars-matrix: decision record$/{g=1; next}
       g && /^::stop-commands::/{t="::" substr($0, 18) "::"; next}
       g && t && $0==t {exit}
       g && t' "${OUT_FILE}"
}

before="$(printf 'b%.0s' {1..40})"
after="$(printf 'a%.0s' {1..40})"

begin "relevance: a push touching only documentation leaves an empty matrix and succeeds"
make_sandbox "${baseline}"
make_gh
jq -n --arg b "${before}" --arg a "${after}" '{repository: {default_branch: "main"}, before: $b, after: $a}' \
  >"${SANDBOX}/event.json"
echo '{"files": [{"filename": "README.md"}, {"filename": "envs/env-a/notes.md"}]}' \
  >"${SANDBOX}/api/repos_example-org_example-repo_compare_${before}...${after}"
run_step GITHUB_EVENT_NAME=push
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(matrix_output | jq -c .)" == '{"environment":[],"include":[]}' ]] \
  && [[ "$(logged_record)" == "env-a: skip — relevance: no changed file matches" ]] \
  && [[ "$(step_output affected-count) $(step_output unaffected-count) $(step_output changed-count)" == "0 1 2" ]] \
  && [[ "$(step_output relevance-mode)/$(step_output relevance-reason)" == "diff/diff" ]] \
  && [[ "$(jq -r '.environments[0].verdict' "$(step_output relevance-file)")" == "skip" ]] \
  && grep -qx '::notice title=Terraform CI::relevance diff (diff): 0 of 1 environment affected; nothing to verify for this change' "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or the documentation-only push still ran env-a"
fi

begin "relevance: a pull request is read through its files, paged, and runs what it touches"
make_sandbox "${baseline}"
make_gh
echo '{"repository": {"default_branch": "main"}, "pull_request": {"number": 87, "head": {"sha": "abc"}}}' \
  >"${SANDBOX}/event.json"
echo '{"changed_files": 1, "head": {"sha": "abc"}}' >"${SANDBOX}/api/repos_example-org_example-repo_pulls_87"
echo '[{"filename": "envs/env-a/main.tf", "status": "modified"}]' \
  >"${SANDBOX}/api/repos_example-org_example-repo_pulls_87_files?per_page=100&page=1"
run_step GITHUB_EVENT_NAME=pull_request
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(matrix_output | jq -c .environment)" == '["env-a"]' ]] \
  && [[ "$(logged_record)" == "env-a: run — relevance: envs/env-a/**" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or the pull request's own change did not run env-a"
fi

begin "relevance: an API that cannot answer runs every environment and the step succeeds"
make_sandbox "${baseline}"
make_gh
jq -n --arg b "${before}" --arg a "${after}" '{repository: {default_branch: "main"}, before: $b, after: $a}' \
  >"${SANDBOX}/event.json"
run_step GITHUB_EVENT_NAME=push
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(matrix_output | jq -c .environment)" == '["env-a"]' ]] \
  && [[ "$(logged_record)" == "env-a: run — relevance: all:api-error" ]] && ! grep -q '^::error' "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or a failed fetch did not fail open"
fi

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}      CREATE-TF-VARS-MATRIX SUMMARY         ${NC}"
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
