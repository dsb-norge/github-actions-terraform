#!/bin/env bash
#
# Tests for create-tf-vars-matrix.
#
# Two layers:
#
#  1. Unit tests of the merge/normalize helpers in helpers_additional.sh.
#  2. Fixture-driven runs of the action's real inline bash. The 'create-vars'
#     and 'validate' steps are extracted from action.yml by
#     extract_step_source.py (literal expression substitution, no shell
#     escaping) and executed against the JSON fixtures in test_data/, with a
#     stub 'curl' standing in for the GitHub API call that resolves the calling
#     repo's default branch.
#
# This is deterministic and needs no tty, unlike the older
# test_action_source.sh harness, which remains for manual debugging.
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

OUT_FILE=/tmp/test_output_create_tf_vars_matrix.txt

export GITHUB_ACTION_PATH="${_this_script_dir}"

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

# Call a function from helpers_additional.sh in a subshell, so the helpers'
# load-time logging never mixes into the value under test.
call_helper() {
  (
    source "${_this_script_dir}/helpers.sh" >/dev/null 2>&1
    "$@"
  )
}

# Run the action's 'create-vars' step against an inputs-json fixture.
# Populates LAST_EXIT and MATRIX_JSON.
run_create_vars() {
  local fixture="${_this_script_dir}/test_data/${1}_inputs-json.json"
  local branch="${2:-main}"

  WORK_DIR="$(mktemp -d)"
  export GITHUB_OUTPUT="${WORK_DIR}/output.txt"
  : >"${GITHUB_OUTPUT}"
  export GITHUB_WORKSPACE="${WORK_DIR}/ws"
  # Directories the fixtures point 'project-dir' at.
  mkdir -p "${GITHUB_WORKSPACE}/envs/my-tf-env"

  mkdir -p "${WORK_DIR}/stub-bin"
  cat >"${WORK_DIR}/stub-bin/curl" <<'STUB'
#!/bin/env bash
echo '{"default_branch":"main"}'
STUB
  chmod +x "${WORK_DIR}/stub-bin/curl"

  python3 "${_this_script_dir}/extract_step_source.py" \
    "${_this_script_dir}/action.yml" create-vars "${WORK_DIR}/step_create_vars.sh" \
    "inputs.inputs-json=@${fixture}" \
    "github.repository=dsb-norge/test-repo" \
    "github.token=fake-token" \
    "github.ref_name=${branch}" \
    "github.action_path=${_this_script_dir}"

  (
    cd "${GITHUB_WORKSPACE}" || exit 1
    PATH="${WORK_DIR}/stub-bin:${PATH}" bash "${WORK_DIR}/step_create_vars.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?

  MATRIX_JSON="$(read_multiline_output json)"
}

# Run the action's 'validate' step against the JSON produced by the most
# recent run_create_vars. Populates LAST_EXIT.
run_validate() {
  printf '%s\n' "${MATRIX_JSON}" >"${WORK_DIR}/create-vars.json"

  python3 "${_this_script_dir}/extract_step_source.py" \
    "${_this_script_dir}/action.yml" validate "${WORK_DIR}/step_validate.sh" \
    "steps.create-vars.outputs.json=@${WORK_DIR}/create-vars.json" \
    "github.action_path=${_this_script_dir}"

  (
    cd "${GITHUB_WORKSPACE}" || exit 1
    bash "${WORK_DIR}/step_validate.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

# Read a multiline output (name<<"DELIM" ... "DELIM") from $GITHUB_OUTPUT.
read_multiline_output() {
  python3 - "${GITHUB_OUTPUT}" "${1}" <<'PY'
import re
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
match = re.search(
    r'^%s<<"([^"]+)"\n(.*?)\n"\1"\s*$' % re.escape(name), text, re.S | re.M
)
print(match.group(2) if match else "", end="")
PY
}

# jq query against MATRIX_JSON for a single environment.
env_query() {
  local environment="${1}" filter="${2}"
  printf '%s' "${MATRIX_JSON}" \
    | jq -c --arg env "${environment}" '.[] | select(.environment == $env) | '"${filter}"
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
    echo "--- step output (tail) ---"
    tail -n 40 "${OUT_FILE}" 2>/dev/null || true
    echo "--- /step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# assert_eq <name> <expected> <actual>
assert_eq() {
  local name="${1}" expected="${2}" actual="${3}"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if [[ "${expected}" == "${actual}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: expected '${expected}', got '${actual}'"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}       CREATE-TF-VARS-MATRIX TESTS          ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ======================================================================
# merge-yml-field-json — the type dispatch
# See docs/Per-goal-environment-variables.md §9.5.
# ======================================================================

assert_eq "merge: arrays concatenate (the case '*' cannot do)" \
  '["a","b"]' \
  "$(call_helper merge-yml-field-json '["a"]' '["b"]' | jq -c .)"

assert_eq "merge: null global yields the environment value" \
  '["b"]' \
  "$(call_helper merge-yml-field-json 'null' '["b"]' | jq -c .)"

assert_eq "merge: null environment yields the global value" \
  '{"A":1}' \
  "$(call_helper merge-yml-field-json '{"A":1}' 'null' | jq -c .)"

assert_eq "merge: flat objects override per key (unchanged from 'add')" \
  '{"A":1,"B":3}' \
  "$(call_helper merge-yml-field-json '{"A":1,"B":2}' '{"B":3}' | jq -Sc .)"

assert_eq "merge: nested objects deep merge, sibling keys survive" \
  '{"plan":{"GOGC":25,"GOMEMLIMIT":"24GiB"}}' \
  "$(call_helper merge-yml-field-json '{"plan":{"GOGC":25,"GOMEMLIMIT":"12GiB"}}' '{"plan":{"GOMEMLIMIT":"24GiB"}}' | jq -Sc .)"

assert_eq "merge: nested objects keep untouched sibling goals" \
  '{"lint":{"GOGC":400},"plan":{"GOGC":25}}' \
  "$(call_helper merge-yml-field-json '{"plan":{"GOGC":25},"lint":{"GOGC":400}}' '{"plan":{"GOGC":25}}' | jq -Sc .)"

assert_eq "merge: a null leaf survives the merge (unset semantics)" \
  '{"plan":{"GOMEMLIMIT":null}}' \
  "$(call_helper merge-yml-field-json '{"plan":{"GOMEMLIMIT":"6GiB"}}' '{"plan":{"GOMEMLIMIT":null}}' | jq -Sc .)"

assert_eq "merge: environment scalar replaces global scalar" \
  '{"A":"env"}' \
  "$(call_helper merge-yml-field-json '{"A":"global"}' '{"A":"env"}' | jq -Sc .)"

# ======================================================================
# normalize-goal-keys-json
# ======================================================================

ALL_GOAL_KEYS='["apply","destroy","destroy-plan","format","init","lint","plan","validate"]'

assert_eq "normalize: empty object gains all eight goal keys" \
  "${ALL_GOAL_KEYS}" \
  "$(call_helper normalize-goal-keys-json '{}' | jq -c '[keys[]] | sort')"

assert_eq "normalize: every added key defaults to an empty object" \
  'true' \
  "$(call_helper normalize-goal-keys-json '{}' | jq -c '[.[] | . == {}] | all')"

assert_eq "normalize: JSON null input becomes the full key set" \
  "${ALL_GOAL_KEYS}" \
  "$(call_helper normalize-goal-keys-json 'null' | jq -c '[keys[]] | sort')"

assert_eq "normalize: empty string input becomes the full key set" \
  "${ALL_GOAL_KEYS}" \
  "$(call_helper normalize-goal-keys-json '' | jq -c '[keys[]] | sort')"

assert_eq "normalize: existing goal values are preserved" \
  '{"GOGC":25}' \
  "$(call_helper normalize-goal-keys-json '{"plan":{"GOGC":25}}' | jq -c '.plan')"

assert_eq "normalize: goals not mentioned still become empty objects" \
  '{}' \
  "$(call_helper normalize-goal-keys-json '{"plan":{"GOGC":25}}' | jq -c '.apply')"

assert_eq "normalize: a null leaf inside a goal is preserved" \
  'null' \
  "$(call_helper normalize-goal-keys-json '{"apply":{"GOMEMLIMIT":null}}' | jq -c '.apply.GOMEMLIMIT')"

# Unknown keys pass through untouched — rejecting them is resolve-goal-envs'
# job, so a caller writing 'all:' gets one error from one place.
assert_eq "normalize: an unknown goal key passes through untouched" \
  '{"NOPE":1}' \
  "$(call_helper normalize-goal-keys-json '{"all":{"NOPE":1}}' | jq -c '.all')"

assert_eq "normalize: unknown keys do not stop the eight from being added" \
  '9' \
  "$(call_helper normalize-goal-keys-json '{"all":{}}' | jq -c '[keys[]] | length')"

# ======================================================================
# Fixture: minimal — everything defaulted
# ======================================================================

run_create_vars 'test_input_minimal'

assert "minimal: create-vars step exits 0" test "${LAST_EXIT}" -eq 0
assert "minimal: output is a non-empty JSON array" \
  bash -c "[[ \$(printf '%s' '${MATRIX_JSON}' | jq -r 'type') == 'array' ]] && [[ \$(printf '%s' '${MATRIX_JSON}' | jq -r 'length') -ge 1 ]]"

assert_eq "minimal: 'extra-envs-per-goal' has all eight goal keys" \
  "${ALL_GOAL_KEYS}" \
  "$(env_query my-tf-env '[.["extra-envs-per-goal"] | keys[]] | sort')"

assert_eq "minimal: 'extra-envs-from-secrets-per-goal' has all eight goal keys" \
  "${ALL_GOAL_KEYS}" \
  "$(env_query my-tf-env '[.["extra-envs-from-secrets-per-goal"] | keys[]] | sort')"

assert_eq "minimal: every per-goal entry defaults to an empty object" \
  'true' \
  "$(env_query my-tf-env '[.["extra-envs-per-goal"][] | . == {}] | all')"

assert_eq "minimal: no '*-yml' fields survive into the matrix output" \
  '[]' \
  "$(env_query my-tf-env '[keys[] | select(endswith("-yml"))]')"

run_validate
assert "minimal: validate step exits 0" test "${LAST_EXIT}" -eq 0

# ======================================================================
# Fixture: happy day — global + per-environment values of everything
# ======================================================================

run_create_vars 'test_input_happy_day'

assert "happy day: create-vars step exits 0" test "${LAST_EXIT}" -eq 0
assert_eq "happy day: three environments produced" \
  '3' \
  "$(printf '%s' "${MATRIX_JSON}" | jq -c 'length')"

# --- deep merge: the load-bearing case -------------------------------------
# 'my-second-env' overrides only plan.GOMEMLIMIT. A shallow merge would
# replace the whole 'plan' object and drop GOGC back to the global default.
assert_eq "deep merge: per-env override keeps the goal's other keys" \
  '{"GOGC":25,"GOMEMLIMIT":"24GiB"}' \
  "$(env_query my-second-env '.["extra-envs-per-goal"].plan | to_entries | sort_by(.key) | from_entries')"

assert_eq "deep merge: other environments keep the global value" \
  '{"GOGC":25,"GOMEMLIMIT":"12GiB"}' \
  "$(env_query my-first-env '.["extra-envs-per-goal"].plan | to_entries | sort_by(.key) | from_entries')"

assert_eq "deep merge: goals the environment did not mention are untouched" \
  '{"GOGC":400}' \
  "$(env_query my-second-env '.["extra-envs-per-goal"].lint')"

# --- null leaves ----------------------------------------------------------
assert_eq "null leaf: survives into the matrix as JSON null, not a dropped key" \
  'true' \
  "$(env_query my-second-env '.["extra-envs-per-goal"].apply | has("GOMEMLIMIT")')"

assert_eq "null leaf: value is JSON null" \
  'null' \
  "$(env_query my-second-env '.["extra-envs-per-goal"].apply.GOMEMLIMIT')"

# --- per-goal secrets ----------------------------------------------------
assert_eq "per-goal secrets: global and per-env entries are merged" \
  '{"ARM_CLIENT_ID":"ARM_CLIENT_ID_secret","TF_VAR_my_custom":"more"}' \
  "$(env_query my-second-env '.["extra-envs-from-secrets-per-goal"].apply | to_entries | sort_by(.key) | from_entries')"

assert_eq "per-goal secrets: environments without an override get the global" \
  '{"ARM_CLIENT_ID":"ARM_CLIENT_ID_secret"}' \
  "$(env_query my-first-env '.["extra-envs-from-secrets-per-goal"].apply')"

assert_eq "per-goal: all eight keys normalized for every environment" \
  'true' \
  "$(printf '%s' "${MATRIX_JSON}" | jq -c '[.[] | ([.["extra-envs-per-goal"] | keys[]] | length) == 8] | all')"

# --- the array field the type dispatch exists for -------------------------
# 'pr-auto-merge-from-actors-yml' is a YAML array. A blanket switch to jq's
# '*' would make this a hard error instead of a concatenation.
assert_eq "array field: global and per-env arrays concatenate" \
  '["global-actor","env-actor"]' \
  "$(env_query my-second-env '.["pr-auto-merge-from-actors"]')"

assert_eq "array field: environments without an override get the global" \
  '["global-actor"]' \
  "$(env_query my-first-env '.["pr-auto-merge-from-actors"]')"

# --- flat objects: unchanged behaviour -----------------------------------
assert_eq "flat object: per-env limit overrides one key only" \
  '5' \
  "$(env_query my-second-env '.["pr-auto-merge-limits"]["plan-max-count-add"]')"

assert_eq "flat object: other limit keys keep the global value" \
  '-1' \
  "$(env_query my-second-env '.["pr-auto-merge-limits"]["plan-max-count-import"]')"

assert_eq "flat object: 'extra-envs' is unaffected by the merge change" \
  '{"ANOTHER_ENV":"1 2 3","ARM_USE_AZUREAD":true,"ARM_USE_OIDC":true}' \
  "$(env_query my-first-env '.["extra-envs"] | to_entries | sort_by(.key) | from_entries')"

assert_eq "flat object: 'extra-envs-from-secrets' is unaffected too" \
  '4' \
  "$(env_query my-first-env '.["extra-envs-from-secrets"] | length')"

assert_eq "happy day: no '*-yml' fields survive into the matrix output" \
  'true' \
  "$(printf '%s' "${MATRIX_JSON}" | jq -c '[.[] | [keys[] | select(endswith("-yml"))] | length == 0] | all')"

run_validate
assert "happy day: validate step exits 0" test "${LAST_EXIT}" -eq 0

# ======================================================================
# Fixture: invalid yaml — must fail loudly
# ======================================================================

run_create_vars 'test_input_fail_yml_spec'
assert "invalid yaml: create-vars step exits non-zero" test "${LAST_EXIT}" -ne 0
assert "invalid yaml: error names the offending input" \
  grep -q "input 'extra-envs-from-secrets-yml' is not valid yaml" "${OUT_FILE}"

# ======================================================================
# Summary
# ======================================================================
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
