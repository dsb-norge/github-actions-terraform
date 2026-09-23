#!/bin/env bash
#
# Tests for create-tf-vars-matrix, the shim around the decision engine.
#
# The engine's own decisions are tested in engine/; this suite tests what only the shim does:
#
#  1. Every port case (engine/tests/port/cases) end to end through the real step script, yq
#     and engine included: the matrix-json output, or the exit code and the ::error lines,
#     equal the case's golden (engine_expected when the case records a deliberate deviation).
#  2. The input document the shim builds for every case equals the case's committed
#     input.json, which is what the engine suite decides from. UPDATE_ENGINE_INPUTS=1
#     rewrites them.
#  3. The default-branch fallback, the Python floor, an engine crash, and that neither the
#     inputs nor secret-shaped variables reach the engine's environment or its documents.
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

# Prepare a sandbox for the case in $1: a workspace holding the case's directories, and the
# case's inputs JSON in ${SANDBOX}/inputs.json.
make_sandbox() {
  local case_file="${1}" directory
  SANDBOX="$(mktemp -d)"
  mkdir -p "${SANDBOX}/ws" "${SANDBOX}/bin"
  while IFS= read -r directory; do
    mkdir -p "${SANDBOX}/ws/${directory}"
  done < <(jq -r '.directories[]?' "${case_file}")
  jq '.inputs_json' "${case_file}" >"${SANDBOX}/inputs.json"
}

# Run the step script against the sandbox, as the action.yml shim does. Extra environment
# assignments may be given as arguments. Sets STEP_EXIT; the output is in ${SANDBOX}/output.txt.
run_step() {
  : >"${SANDBOX}/output.txt"
  (
    cd "${SANDBOX}/ws" || exit 1
    export GITHUB_ACTION_PATH="${_this_script_dir}"
    export GITHUB_OUTPUT="${SANDBOX}/output.txt"
    export input_repository="example-org/example-repo"
    export input_event_name="push"
    export input_ref_name="${CASE_REF_NAME:-main}"
    export input_default_branch="${CASE_DEFAULT_BRANCH-main}"
    export PATH="${SANDBOX}/bin:${PATH}"
    for assignment in "$@"; do export "${assignment?}"; done
    # The runner's shell flags, then the shim's own shape: the inputs captured before
    # allexport, so never exported.
    set -eo pipefail
    input_inputs_json="$(cat "${SANDBOX}/inputs.json")"
    set -o allexport
    # shellcheck disable=SC1091
    source "${_this_script_dir}/step_create_matrix.sh"
  ) >"${OUT_FILE}" 2>&1
  STEP_EXIT=$?
}

# The matrix-json value from the sandbox's output file.
matrix_output() {
  awk '/^matrix-json<<EOF_/{d=substr($0, index($0,"<<")+2); f=1; next} f && $0==d {f=0} f' "${SANDBOX}/output.txt"
}

# Build the engine's input document for the sandbox, as the step does, into $1.
build_document() {
  local out_file="${1}"
  (
    cd "${SANDBOX}/ws" || exit 1
    export GITHUB_ACTION_PATH="${_this_script_dir}"
    export input_repository="example-org/example-repo" input_event_name="push"
    export input_ref_name="${CASE_REF_NAME:-main}"
    source "${_this_script_dir}/helpers.sh" >/dev/null
    printf '%s' "${CASE_DEFAULT_BRANCH-main}" >"${SANDBOX}/default-branch"
    build-input-document "${SANDBOX}/inputs.json" "${out_file}" "${SANDBOX}/default-branch"
  ) >"${OUT_FILE}" 2>&1
}

# A python3 in front of the real one: records its environment, then runs the real one.
stub_python_recording_env() {
  local real_python
  real_python="$(command -v python3)"
  cat >"${SANDBOX}/bin/python3" <<EOF
#!/bin/env bash
env >>"${SANDBOX}/python-env.txt"
exec "${real_python}" "\$@"
EOF
  chmod +x "${SANDBOX}/bin/python3"
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
  CASE_REF_NAME="$(jq -r '.ref_name' "${case_file}")"
  CASE_DEFAULT_BRANCH="$(jq -r '.default_branch' "${case_file}")"
  make_sandbox "${case_file}"

  begin "input document: ${name}"
  build_document "${SANDBOX}/document.json"
  if [[ "${UPDATE_ENGINE_INPUTS:-}" == "1" ]]; then
    jq -S . "${SANDBOX}/document.json" >"${case_dir}/input.json"
  fi
  if diff <(jq -S . "${case_dir}/input.json") <(jq -S . "${SANDBOX}/document.json") >/dev/null 2>&1; then
    pass
  else
    fail "the shim builds a different document than ${case_dir}/input.json"
  fi

  begin "end to end: ${name}"
  expected="$(jq -c '.engine_expected // empty' "${case_file}")"
  [[ -z "${expected}" ]] && expected="$(jq -c '.' "${case_dir}/expected.json")"
  run_step
  expected_exit="$(jq -r '.exit_code' <<<"${expected}")"
  if [[ "${expected_exit}" == "0" ]]; then
    if [[ ${STEP_EXIT} -ne 0 ]]; then
      fail "exit code ${STEP_EXIT}, expected 0"
    elif [[ "$(matrix_output | jq -S -c .)" == "$(jq -S -c '.matrix' <<<"${expected}")" ]]; then
      pass
    else
      fail "matrix-json differs from the golden"
    fi
  else
    actual_errors="$(sed -n 's/^::error title=create-tf-vars-matrix:://p' "${OUT_FILE}" | jq -R . | jq -s -c .)"
    if [[ ${STEP_EXIT} -ne 2 ]]; then
      fail "exit code ${STEP_EXIT}, expected 2"
    elif [[ "${actual_errors}" == "$(jq -c '.errors' <<<"${expected}")" ]]; then
      pass
    else
      fail "errors ${actual_errors}, expected $(jq -c '.errors' <<<"${expected}")"
    fi
  fi
done
unset CASE_REF_NAME CASE_DEFAULT_BRANCH

# ======================================================================
# 3: what only the shim does
# ======================================================================

baseline="${_cases_dir}/defaults/case.json"

begin "default branch: an empty event value falls back to the API"
make_sandbox "${baseline}"
cat >"${SANDBOX}/bin/gh" <<'EOF'
#!/bin/env bash
[[ "$1 $2" == "api repos/example-org/example-repo" ]] && echo '{"default_branch":"trunk"}'
EOF
chmod +x "${SANDBOX}/bin/gh"
CASE_DEFAULT_BRANCH="" run_step
if [[ ${STEP_EXIT} -eq 0 ]] \
  && [[ "$(matrix_output | jq -r '.include[0].vars["caller-repo-default-branch"]')" == "trunk" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or the default branch did not come from the API"
fi

begin "default branch: a failing API call fails the step and says why"
make_sandbox "${baseline}"
printf '#!/bin/env bash\necho "HTTP 404: Not Found" >&2\nexit 1\n' >"${SANDBOX}/bin/gh"
chmod +x "${SANDBOX}/bin/gh"
CASE_DEFAULT_BRANCH="" run_step
if [[ ${STEP_EXIT} -ne 0 ]] && grep -q "could not resolve the default branch" "${OUT_FILE}" \
  && grep -q "HTTP 404: Not Found" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or no error naming the failure"
fi

begin "python floor: a runner below 3.10 fails with a message naming the floor"
make_sandbox "${baseline}"
printf '#!/bin/env bash\n[[ "$1" == "--version" ]] && echo "Python 3.8.10"\nexit 1\n' >"${SANDBOX}/bin/python3"
chmod +x "${SANDBOX}/bin/python3"
run_step
if [[ ${STEP_EXIT} -eq 1 ]] && grep -q "needs Python 3.10 or later on the runner, found: Python 3.8.10" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or no message naming the floor"
fi

for broken_yq in 'echo "yq: command not found" >&2; exit 127' 'echo "Error: unknown command \"e\""; exit 1' 'echo "not json"'; do
  begin "yq: a broken yq fails the step naming yq, never blaming the caller's YAML ($(cut -c1-30 <<<"${broken_yq}"))"
  make_sandbox "${baseline}"
  printf '#!/bin/env bash\n%s\n' "${broken_yq}" >"${SANDBOX}/bin/yq"
  chmod +x "${SANDBOX}/bin/yq"
  run_step
  if [[ ${STEP_EXIT} -eq 1 ]] && grep -q "yq on the runner cannot parse YAML to JSON" "${OUT_FILE}" \
    && ! grep -q "not valid yaml" "${OUT_FILE}" && [[ -z "$(matrix_output)" ]]; then
    pass
  else
    fail "exit ${STEP_EXIT}, or the failure was not attributed to yq"
  fi
done

begin "injection: a newline in an environment name cannot start a workflow command in the record"
make_sandbox "${baseline}"
jq '.["environments-yml"] = "- environment: \"env-a\\n::warning::injected\"\n  project-dir: .\n"' \
  "${SANDBOX}/inputs.json" >"${SANDBOX}/inputs.new" && mv "${SANDBOX}/inputs.new" "${SANDBOX}/inputs.json"
run_step
# The line may appear only inside a stop-commands block, where the runner shows it verbatim.
outside="$(awk '/^::stop-commands::/{t="::" substr($0, 18) "::"; next} t && $0==t {t=""; next} !t' "${OUT_FILE}")"
if [[ ${STEP_EXIT} -eq 0 ]] && grep -q '^::warning::injected' "${OUT_FILE}" \
  && ! grep -q '^::warning::' <<<"${outside}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or a caller's value reached the log as a workflow command"
fi

begin "injection: an error naming a caller's value is one annotation with its newline escaped"
make_sandbox "${baseline}"
jq '.["environments-yml"] = "- environment: \"x\\n::warning::injected\"\n- environment: \"x\\n::warning::injected\"\n"' \
  "${SANDBOX}/inputs.json" >"${SANDBOX}/inputs.new" && mv "${SANDBOX}/inputs.new" "${SANDBOX}/inputs.json"
run_step
if [[ ${STEP_EXIT} -eq 2 ]] && ! grep -q '^::warning::' "${OUT_FILE}" \
  && [[ "$(grep -c '^::error title=create-tf-vars-matrix::' "${OUT_FILE}")" == "1" ]] \
  && grep -q "^::error title=create-tf-vars-matrix::Duplicate environment 'x%0A::warning::injected'" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or the error annotation was split or unescaped"
fi

begin "annotations: a percent sign in a message is escaped"
make_sandbox "${baseline}"
jq '.["environments-yml"] = "- environment: \"100%\"\n- environment: \"100%\"\n"' \
  "${SANDBOX}/inputs.json" >"${SANDBOX}/inputs.new" && mv "${SANDBOX}/inputs.new" "${SANDBOX}/inputs.json"
run_step
if [[ ${STEP_EXIT} -eq 2 ]] && grep -q "Duplicate environment '100%25'" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, or the percent sign was not escaped"
fi

begin "engine crash: exit 1 with the engine's stderr in the log, no matrix"
make_sandbox "${baseline}"
real_python="$(command -v python3)"
cat >"${SANDBOX}/bin/python3" <<EOF
#!/bin/env bash
if [[ "\$*" == *dsb_tf_engine* ]]; then echo "Traceback: boom" >&2; exit 1; fi
exec "${real_python}" "\$@"
EOF
chmod +x "${SANDBOX}/bin/python3"
run_step
if [[ ${STEP_EXIT} -eq 1 ]] && grep -q "decision engine failed (exit code 1)" "${OUT_FILE}" \
  && grep -q "Traceback: boom" "${OUT_FILE}" && [[ -z "$(matrix_output)" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or the crash was not reported"
fi

begin "no leak: the inputs never reach the engine's environment"
make_sandbox "${baseline}"
jq '.["environments-yml"] = "- environment: \"env-a\"\n  url: \"https://example.com/SENTINEL-INPUTS-7f3a\"\n"' \
  "${SANDBOX}/inputs.json" >"${SANDBOX}/inputs.new" && mv "${SANDBOX}/inputs.new" "${SANDBOX}/inputs.json"
stub_python_recording_env
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ -s "${SANDBOX}/python-env.txt" ]] \
  && ! grep -q "SENTINEL-INPUTS-7f3a" "${SANDBOX}/python-env.txt" \
  && matrix_output | grep -q "SENTINEL-INPUTS-7f3a"; then
  pass
else
  fail "exit ${STEP_EXIT}, or the inputs appeared in the engine's environment"
fi

begin "no leak: secret-shaped variables stay out of the input document and the matrix"
make_sandbox "${baseline}"
build_document_with_secrets() {
  ARM_CLIENT_SECRET="SENTINEL-SECRET-91c2" GH_TOKEN="SENTINEL-SECRET-91c2" \
    TF_VAR_password="SENTINEL-SECRET-91c2" build_document "${SANDBOX}/document.json"
}
build_document_with_secrets
run_step ARM_CLIENT_SECRET=SENTINEL-SECRET-91c2 GH_TOKEN=SENTINEL-SECRET-91c2 TF_VAR_password=SENTINEL-SECRET-91c2
if [[ ${STEP_EXIT} -eq 0 ]] && ! grep -q "SENTINEL-SECRET-91c2" "${SANDBOX}/document.json" \
  && ! matrix_output | grep -q "SENTINEL-SECRET-91c2"; then
  pass
else
  fail "exit ${STEP_EXIT}, or a secret-shaped variable leaked"
fi

begin "action.yml: the run block opens with a description comment and captures before allexport"
run_block="$(yq '.runs.steps[0].run' "${_this_script_dir}/action.yml")"
if [[ "$(head -n 1 <<<"${run_block}")" == "# "* ]] \
  && [[ "$(grep -n 'input_inputs_json=\$(cat' <<<"${run_block}" | cut -d: -f1)" -lt \
    "$(grep -n 'set -o allexport' <<<"${run_block}" | cut -d: -f1)" ]] \
  && ! grep -q 'export input_inputs_json' <<<"${run_block}"; then
  pass
else
  fail "the run block's first line is not a comment, or the heredoc is captured after allexport or exported"
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
