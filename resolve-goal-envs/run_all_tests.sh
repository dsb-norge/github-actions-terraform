#!/bin/env bash
#
# Tests for step_resolve.sh
#
# Covers the resolution algorithm, the precedence rules, the validation
# rejections, the file/directory permissions, and the log-hygiene claim that no
# secret value ever reaches stdout or stderr.
#
# Scenario numbering follows docs/Per-goal-environment-variables.md §10
# (T1-T16).
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

OUT_FILE=/tmp/test_output_resolve.txt

GOALS=(init format validate lint plan apply destroy-plan destroy)

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

# Fresh environment. All four maps default to '{}' and the secrets bag to a
# small fixture; individual tests override what they exercise.
setup() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}/workspace"
  mkdir -p "${GITHUB_WORKSPACE}"

  export input_extra_envs='{}'
  export input_extra_envs_from_secrets='{}'
  export input_extra_envs_per_goal='{}'
  export input_extra_envs_from_secrets_per_goal='{}'

  set_secrets '{
    "AZURE_TENANT_ID": "tenant-value",
    "AZURE_PLAN_READER_CLIENT_ID": "reader-value",
    "AZURE_APPLY_CONTRIBUTOR_CLIENT_ID": "contributor-value",
    "MULTILINE_SECRET": "-----BEGIN RSA PRIVATE KEY-----\nline-two-of-the-key\n-----END RSA PRIVATE KEY-----\n",
    "EMPTY_SECRET": ""
  }'
}

# Write the secrets bag the way the action.yml shim does: to a file, exporting
# only the path.
set_secrets() {
  export input_secrets_file="$(mktemp "${RUNNER_TEMP}/secrets-bag-XXXXXXXX.json")"
  chmod 0600 "${input_secrets_file}"
  printf '%s' "${1}" >"${input_secrets_file}"
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_resolve.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
  ENVS_DIR="$(grep '^envs-dir=' "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-)"
}

# jq query against one goal's resolved file.
goal_query() {
  local goal="${1}" filter="${2}"
  jq -c "${filter}" "${ENVS_DIR}/${goal}.json"
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
    echo "--- step output ---"
    cat "${OUT_FILE}" 2>/dev/null || true
    echo "--- /step output ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}        RESOLVE-GOAL-ENVS STEP TESTS        ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# T1 — all inputs '{}' → eight files, each '{}'
# ----------------------------------------------------------------------
setup
run_step
assert "T1: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T1: envs-dir output is published" test -n "${ENVS_DIR}"
assert "T1: envs-dir exists" test -d "${ENVS_DIR}"
assert_eq "T1: exactly eight files produced" \
  '8' "$(find "${ENVS_DIR}" -maxdepth 1 -name '*.json' | wc -l)"
all_empty=true
for goal in "${GOALS[@]}"; do
  [ -f "${ENVS_DIR}/${goal}.json" ] || all_empty=false
  [ "$(goal_query "${goal}" '.')" = '{}' ] || all_empty=false
done
assert "T1: one file per goal, each an empty object" test "${all_empty}" = 'true'

# ----------------------------------------------------------------------
# T15 — directory is 0700, files are 0600
# ----------------------------------------------------------------------
assert_eq "T15: envs-dir mode is 0700" \
  '700' "$(stat -c '%a' "${ENVS_DIR}")"
assert_eq "T15: every resolved file is mode 0600" \
  '' "$(find "${ENVS_DIR}" -maxdepth 1 -name '*.json' ! -perm 600 -printf '%f ')"

# The resolved files must not sit in the workspace: artifact globs,
# 'terraform fmt -recursive' and stray 'git add' all live there.
assert "T15: envs-dir is outside GITHUB_WORKSPACE" \
  bash -c "[[ '${ENVS_DIR}' != '${GITHUB_WORKSPACE}'* ]]"
assert "T15: envs-dir is under RUNNER_TEMP" \
  bash -c "[[ '${ENVS_DIR}' == '${RUNNER_TEMP}'* ]]"

# The scratch copy of the secrets bag, and the bag the shim wrote, are gone.
assert "cleanup: the secrets file is removed on exit" \
  bash -c "[ ! -f '${input_secrets_file}' ]"
assert_eq "cleanup: no scratch work directory is left behind" \
  '' "$(find "${RUNNER_TEMP}" -maxdepth 1 -name 'resolve-goal-envs-work-*' -printf '%f ')"

# ----------------------------------------------------------------------
# T2 — global plain only → identical content in all eight files
# ----------------------------------------------------------------------
setup
export input_extra_envs='{"GOGC":50,"GOMEMLIMIT":"6GiB","ARM_USE_OIDC":true}'
run_step
assert "T2: step exits 0" test "${LAST_EXIT}" -eq 0
identical=true
for goal in "${GOALS[@]}"; do
  [ "$(goal_query "${goal}" '. | to_entries | sort_by(.key) | from_entries')" \
    = '{"ARM_USE_OIDC":true,"GOGC":50,"GOMEMLIMIT":"6GiB"}' ] || identical=false
done
assert "T2: all eight goals get the same global values" test "${identical}" = 'true'
assert_eq "T2: a JSON number stays a number" \
  '"number"' "$(goal_query plan '.GOGC | type')"
assert_eq "T2: a JSON boolean stays a boolean" \
  '"boolean"' "$(goal_query plan '.ARM_USE_OIDC | type')"

# ----------------------------------------------------------------------
# T3 — per-goal override of one key
# ----------------------------------------------------------------------
setup
export input_extra_envs='{"GOGC":50,"GOMEMLIMIT":"6GiB"}'
export input_extra_envs_per_goal='{"plan":{"GOMEMLIMIT":"12GiB"}}'
run_step
assert "T3: step exits 0" test "${LAST_EXIT}" -eq 0
assert_eq "T3: the goal sees the override" \
  '"12GiB"' "$(goal_query plan '.GOMEMLIMIT')"
assert_eq "T3: the goal keeps the global value of other keys" \
  '50' "$(goal_query plan '.GOGC')"
others_untouched=true
for goal in init format validate lint apply destroy-plan destroy; do
  [ "$(goal_query "${goal}" '.GOMEMLIMIT')" = '"6GiB"' ] || others_untouched=false
done
assert "T3: the other seven goals are untouched" test "${others_untouched}" = 'true'

# ----------------------------------------------------------------------
# T4 — per-goal null → JSON null present for that goal only
# ----------------------------------------------------------------------
setup
export input_extra_envs='{"GOMEMLIMIT":"6GiB"}'
export input_extra_envs_per_goal='{"apply":{"GOMEMLIMIT":null}}'
run_step
assert "T4: step exits 0" test "${LAST_EXIT}" -eq 0
assert_eq "T4: the key is present for the goal" \
  'true' "$(goal_query apply 'has("GOMEMLIMIT")')"
assert_eq "T4: its value is JSON null (an unset instruction)" \
  'null' "$(goal_query apply '.GOMEMLIMIT')"
assert_eq "T4: other goals keep the value" \
  '"6GiB"' "$(goal_query plan '.GOMEMLIMIT')"

# ----------------------------------------------------------------------
# T5 — secret resolution maps to the secret's VALUE, not its name
# ----------------------------------------------------------------------
setup
export input_extra_envs_from_secrets='{"ARM_TENANT_ID":"AZURE_TENANT_ID"}'
run_step
assert "T5: step exits 0" test "${LAST_EXIT}" -eq 0
assert_eq "T5: the environment variable holds the secret's value" \
  '"tenant-value"' "$(goal_query plan '.ARM_TENANT_ID')"
assert_eq "T5: the secret's NAME does not appear as a value" \
  'false' "$(goal_query plan '[.[] | tostring] | any(. == "AZURE_TENANT_ID")')"

# ----------------------------------------------------------------------
# T6/T7/T8 — precedence, one key present in all four inputs
# ----------------------------------------------------------------------
setup
export input_extra_envs='{"KEY":"1-global-plain"}'
export input_extra_envs_from_secrets='{"KEY":"AZURE_TENANT_ID"}'
export input_extra_envs_per_goal='{"plan":{"KEY":"3-per-goal-plain"},"lint":{"OTHER":"x"}}'
export input_extra_envs_from_secrets_per_goal='{"apply":{"KEY":"AZURE_APPLY_CONTRIBUTOR_CLIENT_ID"}}'
run_step
assert "T6: step exits 0" test "${LAST_EXIT}" -eq 0
assert_eq "T6: per-goal secret wins over everything (4 beats 3)" \
  '"contributor-value"' "$(goal_query apply '.KEY')"
assert_eq "T7: per-goal plain beats the global secret (3 beats 2)" \
  '"3-per-goal-plain"' "$(goal_query plan '.KEY')"
assert_eq "T8: global secret beats global plain (2 beats 1)" \
  '"tenant-value"' "$(goal_query lint '.KEY')"
assert_eq "T8: goals with no per-goal entry resolve the same way" \
  '"tenant-value"' "$(goal_query init '.KEY')"

# ----------------------------------------------------------------------
# T9 — unknown goal keys are hard errors
# ----------------------------------------------------------------------
setup
export input_extra_envs_per_goal='{"all":{"GOGC":50}}'
run_step
assert "T9: 'all' is rejected" test "${LAST_EXIT}" -ne 0
assert "T9: the error names the offending key" \
  grep -q '"all" is not a valid goal' "${OUT_FILE}"
assert "T9: the error lists the valid goals" \
  grep -q 'init, format, validate, lint, plan, apply, destroy-plan, destroy' "${OUT_FILE}"

setup
export input_extra_envs_per_goal='{"fmt":{"GOGC":50}}'
run_step
assert "T9: 'fmt' is rejected (the goal is named 'format')" test "${LAST_EXIT}" -ne 0
assert "T9: the error names 'fmt'" \
  grep -q '"fmt" is not a valid goal' "${OUT_FILE}"

setup
export input_extra_envs_from_secrets_per_goal='{"typo":{"A":"AZURE_TENANT_ID"}}'
run_step
assert "T9: unknown goal in the secrets map is rejected too" test "${LAST_EXIT}" -ne 0

# ----------------------------------------------------------------------
# T10 — a secret name absent from the bag is a hard error
# ----------------------------------------------------------------------
setup
export input_extra_envs_from_secrets='{"ARM_TENANT_ID":"NO_SUCH_SECRET"}'
run_step
assert "T10: missing global secret is rejected" test "${LAST_EXIT}" -ne 0
assert "T10: the error names the secret and the variable" \
  grep -q 'secret "NO_SUCH_SECRET", mapped to environment variable "ARM_TENANT_ID"' "${OUT_FILE}"

setup
export input_extra_envs_from_secrets_per_goal='{"apply":{"ARM_CLIENT_ID":"NO_SUCH_SECRET"}}'
run_step
assert "T10: missing per-goal secret is rejected" test "${LAST_EXIT}" -ne 0
assert "T10: the error names the goal it came from" \
  grep -q 'extra-envs-from-secrets-per-goal.apply' "${OUT_FILE}"

# A secret that exists but is empty is legitimate — it resolves to "".
setup
export input_extra_envs_from_secrets='{"MAYBE_EMPTY":"EMPTY_SECRET"}'
run_step
assert "T10: an existing but empty secret is accepted" test "${LAST_EXIT}" -eq 0
assert_eq "T10: it resolves to the empty string" \
  '""' "$(goal_query plan '.MAYBE_EMPTY')"

# ----------------------------------------------------------------------
# T11 — action-managed variable names are accepted (no reserved-name list)
# ----------------------------------------------------------------------
setup
export input_extra_envs='{"TF_IN_AUTOMATION":"false","TF_PLUGIN_CACHE_DIR":"/tmp/cache"}'
export input_extra_envs_per_goal='{"init":{"TF_PLUGIN_CACHE_DIR":"/tmp/init-cache"}}'
run_step
assert "T11: step exits 0 — nothing is reserved" test "${LAST_EXIT}" -eq 0
assert_eq "T11: TF_IN_AUTOMATION is written through" \
  '"false"' "$(goal_query plan '.TF_IN_AUTOMATION')"
assert_eq "T11: TF_PLUGIN_CACHE_DIR is written through per goal" \
  '"/tmp/init-cache"' "$(goal_query init '.TF_PLUGIN_CACHE_DIR')"

# ----------------------------------------------------------------------
# T12 — invalid environment variable names are hard errors
# ----------------------------------------------------------------------
setup
export input_extra_envs='{"FOO BAR":"1"}'
run_step
assert "T12: a name with a space is rejected" test "${LAST_EXIT}" -ne 0
assert "T12: the error names it" \
  grep -q '"FOO BAR" is not a valid environment variable name' "${OUT_FILE}"

setup
export input_extra_envs='{"FOO=BAR":"1"}'
run_step
assert "T12: a name with '=' is rejected" test "${LAST_EXIT}" -ne 0

setup
export input_extra_envs='{"1STARTS_WITH_DIGIT":"1"}'
run_step
assert "T12: a name starting with a digit is rejected" test "${LAST_EXIT}" -ne 0

setup
export input_extra_envs_per_goal='{"plan":{"BAD-NAME":"1"}}'
run_step
assert "T12: a bad name inside a per-goal map is rejected" test "${LAST_EXIT}" -ne 0
assert "T12: the error says which goal" \
  grep -q 'extra-envs-per-goal.plan' "${OUT_FILE}"

setup
export input_extra_envs='{"_LEADING_UNDERSCORE":"ok","MiXeD_case_9":"ok"}'
run_step
assert "T12: legal names are accepted" test "${LAST_EXIT}" -eq 0

# ----------------------------------------------------------------------
# T13 — object/array values are config errors, not values
# ----------------------------------------------------------------------
setup
export input_extra_envs='{"NESTED":{"a":1}}'
run_step
assert "T13: an object value is rejected" test "${LAST_EXIT}" -ne 0
assert "T13: the error names the type" \
  grep -q 'is of type object' "${OUT_FILE}"

setup
export input_extra_envs_per_goal='{"plan":{"LIST":[1,2]}}'
run_step
assert "T13: an array value is rejected" test "${LAST_EXIT}" -ne 0

setup
export input_extra_envs_per_goal='{"plan":"not-a-map"}'
run_step
assert "T13: a non-object goal value is rejected" test "${LAST_EXIT}" -ne 0
assert "T13: the error explains what was expected" \
  grep -q 'must be a mapping of environment variables' "${OUT_FILE}"

setup
export input_extra_envs='["not","an","object"]'
run_step
assert "T13: a non-object input is rejected" test "${LAST_EXIT}" -ne 0
assert "T13: the error names the input" \
  grep -q "input 'extra-envs' must be a JSON object" "${OUT_FILE}"

setup
export input_extra_envs='{ this is not json'
run_step
assert "T13: unparseable input is rejected" test "${LAST_EXIT}" -ne 0
assert "T13: the error says it is not valid JSON" \
  grep -q "input 'extra-envs' is not valid JSON" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Empty / absent inputs are legitimate: 'toJSON(...)' renders 'null' for a
# matrix key that does not exist, and an unset input arrives as ''.
# ----------------------------------------------------------------------
setup
export input_extra_envs='null'
export input_extra_envs_from_secrets=''
export input_extra_envs_per_goal='   '
unset input_extra_envs_from_secrets_per_goal
run_step
assert "empty inputs: step exits 0" test "${LAST_EXIT}" -eq 0
all_empty=true
for goal in "${GOALS[@]}"; do
  [ "$(goal_query "${goal}" '.')" = '{}' ] || all_empty=false
done
assert "empty inputs: every goal file is an empty object" test "${all_empty}" = 'true'

# ----------------------------------------------------------------------
# T14 — a multiline secret value survives byte-identically
# ----------------------------------------------------------------------
setup
export input_extra_envs_from_secrets='{"APP_PRIVATE_KEY":"MULTILINE_SECRET"}'
run_step
assert "T14: step exits 0" test "${LAST_EXIT}" -eq 0
assert_eq "T14: the multiline value round-trips exactly" \
  '"-----BEGIN RSA PRIVATE KEY-----\nline-two-of-the-key\n-----END RSA PRIVATE KEY-----\n"' \
  "$(goal_query plan '.APP_PRIVATE_KEY')"

# Shell-hostile characters survive too.
setup
set_secrets '{"WEIRD":"a $HOME `id` \"quoted\" * value"}'
export input_extra_envs_from_secrets='{"WEIRD_VALUE":"WEIRD"}'
export input_extra_envs='{"WEIRD_PLAIN":"b $HOME `id` * value"}'
run_step
assert "T14: step exits 0 with shell metacharacters in values" test "${LAST_EXIT}" -eq 0
assert_eq "T14: a secret value with shell metacharacters is intact" \
  'a $HOME `id` "quoted" * value' "$(jq -r '.WEIRD_VALUE' "${ENVS_DIR}/plan.json")"
assert_eq "T14: a plain value with shell metacharacters is intact" \
  'b $HOME `id` * value' "$(jq -r '.WEIRD_PLAIN' "${ENVS_DIR}/plan.json")"

# ----------------------------------------------------------------------
# T16 — no secret value appears in captured stdout/stderr
# ----------------------------------------------------------------------
setup
export input_extra_envs_from_secrets='{"ARM_TENANT_ID":"AZURE_TENANT_ID","APP_PRIVATE_KEY":"MULTILINE_SECRET"}'
export input_extra_envs_from_secrets_per_goal='{"apply":{"ARM_CLIENT_ID":"AZURE_APPLY_CONTRIBUTOR_CLIENT_ID"}}'
run_step
assert "T16: step exits 0" test "${LAST_EXIT}" -eq 0
assert "T16: no secret value is logged" \
  bash -c "! grep -qE 'tenant-value|contributor-value|line-two-of-the-key' '${OUT_FILE}'"
assert "T16: the keys ARE logged (so the log is still useful)" \
  grep -q 'ARM_TENANT_ID' "${OUT_FILE}"
assert "T16: the log still reports how many variables each goal got" \
  grep -q "goal 'apply': 3 environment variable(s):" "${OUT_FILE}"

setup
export input_extra_envs='{"PLAIN_ONE":"plain-value-should-not-be-logged"}'
run_step
assert "T16: plain values are not logged either" \
  bash -c "! grep -q 'plain-value-should-not-be-logged' '${OUT_FILE}'"

# ----------------------------------------------------------------------
# Missing secrets file — the shim always writes one, so its absence is a bug
# worth failing on rather than resolving everything to null.
# ----------------------------------------------------------------------
setup
export input_secrets_file="${RUNNER_TEMP}/does-not-exist.json"
run_step
assert "secrets file: absence is a hard error" test "${LAST_EXIT}" -ne 0
assert "secrets file: the error names the path" \
  grep -q 'does-not-exist.json' "${OUT_FILE}"

# ----------------------------------------------------------------------
# Every goal file always exists, even when only one goal is configured —
# the workflow references all eight paths unconditionally.
# ----------------------------------------------------------------------
setup
export input_extra_envs_per_goal='{"plan":{"GOGC":25}}'
run_step
all_present=true
for goal in "${GOALS[@]}"; do
  [ -f "${ENVS_DIR}/${goal}.json" ] || all_present=false
done
assert "coverage: all eight files exist when one goal is configured" \
  test "${all_present}" = 'true'
assert_eq "coverage: unconfigured goals are empty objects" \
  '{}' "$(goal_query destroy '.')"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
# An empty goal block is natural YAML for "nothing here yet" — yq renders
#   plan:
# as null — and must resolve the same as an absent key rather than failing.
# ----------------------------------------------------------------------
setup
export input_extra_envs='{"GOGC":50}'
export input_extra_envs_per_goal='{"plan":null,"apply":{"GOGC":25}}'
run_step
assert "empty goal block: step exits 0" test "${LAST_EXIT}" -eq 0
assert_eq "empty goal block: the goal falls back to the global value" \
  '50' "$(goal_query plan '.GOGC')"
assert_eq "empty goal block: other goals are unaffected" \
  '25' "$(goal_query apply '.GOGC')"

setup
export input_extra_envs_from_secrets_per_goal='{"apply":null}'
run_step
assert "empty goal block: accepted in the secrets map too" test "${LAST_EXIT}" -eq 0

# ----------------------------------------------------------------------
# Further negatives on the inputs
# ----------------------------------------------------------------------
# The secrets bag itself must be an object — anything else means the caller
# wired up 'secrets-json' wrong, and resolving every secret to null would be
# a silent, confusing failure.
setup
set_secrets '["not","an","object"]'
run_step
assert "negative: a non-object secrets bag is rejected" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the input" \
  grep -q "input 'secrets-json' must be a JSON object" "${OUT_FILE}"

setup
set_secrets '{ truncated'
run_step
assert "negative: an unparseable secrets bag is rejected" test "${LAST_EXIT}" -ne 0

# A secret NAME must be a string. A number or a boolean there is a config
# error, not something to look up.
setup
export input_extra_envs_from_secrets='{"ARM_TENANT_ID":123}'
run_step
assert "negative: a numeric secret name is rejected" test "${LAST_EXIT}" -ne 0
assert "negative: the error explains what is required" \
  grep -q 'must be a non-empty string' "${OUT_FILE}"

setup
export input_extra_envs_from_secrets_per_goal='{"plan":{"ARM_TENANT_ID":null}}'
run_step
assert "negative: a null secret name is rejected" test "${LAST_EXIT}" -ne 0

# Several problems at once: every one of them must be reported, not just the
# first — otherwise fixing a typo turns into one round-trip per typo.
setup
export input_extra_envs='{"BAD NAME":"x","OBJ":{"a":1}}'
export input_extra_envs_per_goal='{"all":{"A":"1"},"plan":{"ALSO BAD":"y"}}'
run_step
assert "negative: multiple problems fail the step" test "${LAST_EXIT}" -ne 0
assert "negative: all four problems are reported together" \
  bash -c "[ \$(grep -c 'ERROR' '${OUT_FILE}') -ge 5 ]"
assert "negative: the invalid name is reported" grep -q '"BAD NAME"' "${OUT_FILE}"
assert "negative: the object value is reported" grep -q '"OBJ"' "${OUT_FILE}"
assert "negative: the unknown goal is reported" grep -q '"all"' "${OUT_FILE}"
assert "negative: the per-goal invalid name is reported" grep -q '"ALSO BAD"' "${OUT_FILE}"
assert "negative: no files are written when validation fails" \
  bash -c "[ -z '${ENVS_DIR}' ] || [ ! -d '${ENVS_DIR}' ]"

# ======================================================================
# Cross-file contract: the goal vocabulary exists in three places and
# nothing else asserts they agree.
#
#   1. GOAL_KEYS here, which decides what is valid and what files are written
#   2. GOAL_KEYS in create-tf-vars-matrix, which decides what gets normalized
#   3. the '<goal>.json' file names in the reusable workflow
#
# A goal added to one and forgotten in another is a silent no-op or a hard
# error at run time on a calling repo. This suite owns the vocabulary, so the
# check lives here even though it reaches outside the action directory.
# ======================================================================
_repo_root="$(cd -- "${_this_script_dir}/.." &>/dev/null && pwd)"
_matrix_helpers="${_repo_root}/create-tf-vars-matrix/helpers_additional.sh"
_workflow="${_repo_root}/.github/workflows/terraform-ci-cd-default.yml"

# The GOAL_KEYS array as declared in a given helpers file, sorted.
declared_goal_keys() {
  sed -n '/^GOAL_KEYS=(/,/^)/p' "${1}" \
    | sed '1d;$d' \
    | tr -d ' ' \
    | sort \
    | paste -sd,
}

assert "contract: this action declares GOAL_KEYS" \
  test -n "$(declared_goal_keys "${_this_script_dir}/helpers_additional.sh")"
assert_eq "contract: create-tf-vars-matrix declares the same goals" \
  "$(declared_goal_keys "${_this_script_dir}/helpers_additional.sh")" \
  "$(declared_goal_keys "${_matrix_helpers}")"

# The goal file names the workflow asks for, sorted and de-suffixed.
workflow_goal_files() {
  grep -o 'envs-dir }}/[a-z-]*\.json' "${_workflow}" \
    | sed 's|.*/||; s|\.json$||' \
    | sort -u \
    | paste -sd,
}

assert_eq "contract: the workflow references exactly the declared goals" \
  "$(declared_goal_keys "${_this_script_dir}/helpers_additional.sh")" \
  "$(workflow_goal_files)"

assert_eq "contract: the workflow wires up all eight goal steps" \
  '8' "$(grep -c 'extra-envs-file: ${{ steps.goal-envs.outputs.envs-dir }}/' "${_workflow}")"

# Every file the workflow names must actually be produced.
setup
run_step
_all_referenced_present=true
for _goal in $(workflow_goal_files | tr ',' ' '); do
  [ -f "${ENVS_DIR}/${_goal}.json" ] || _all_referenced_present=false
done
assert "contract: every file the workflow names is produced by this action" \
  test "${_all_referenced_present}" = 'true'

# apply-extra-envs is duplicated verbatim into the six goal actions rather than
# shared (docs/Per-goal-environment-variables.md §9.6, consistent with
# helpers.sh). The copies are only useful if they stay identical, so that is
# asserted rather than trusted.
_goal_actions=(terraform-init terraform-validate terraform-plan terraform-fmt lint-with-tflint terraform-apply)

# The apply-extra-envs function body from one action's helpers_additional.sh.
extract_apply_extra_envs() {
  sed -n '/^# Apply a JSON environment-variable map/,/^}$/p' \
    "${_repo_root}/${1}/helpers_additional.sh"
}

_reference="$(extract_apply_extra_envs "${_goal_actions[0]}")"
assert "contract: the reference copy of apply-extra-envs is non-empty" \
  test -n "${_reference}"
for _action in "${_goal_actions[@]:1}"; do
  assert "contract: ${_action}'s copy of apply-extra-envs is byte-identical" \
    bash -c "diff <(printf '%s' \"\$(sed -n '/^# Apply a JSON environment-variable map/,/^}\$/p' '${_repo_root}/${_goal_actions[0]}/helpers_additional.sh')\") <(printf '%s' \"\$(sed -n '/^# Apply a JSON environment-variable map/,/^}\$/p' '${_repo_root}/${_action}/helpers_additional.sh')\") >/dev/null"
done

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}          step_resolve.sh SUMMARY           ${NC}"
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
