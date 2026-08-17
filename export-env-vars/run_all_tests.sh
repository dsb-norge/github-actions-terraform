#!/bin/env bash
#
# Tests for the export-env-vars action.
#
# The action's logic is still inline bash in action.yml, so the step's 'run:'
# block is extracted by extract_step_source.py (literal expression
# substitution, no shell escaping — the inputs are JSON blobs full of quotes)
# and executed with the same shell flags the runner uses. Assertions are on the
# resulting $GITHUB_ENV file, which is the action's only real output.
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

OUT_FILE=/tmp/test_output_export_env_vars.txt

# --------------------------------------------------------------------------
# Test helpers
# --------------------------------------------------------------------------

setup() {
  WORK_DIR="$(mktemp -d)"
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_ENV="${WORK_DIR}/github_env.txt"
  : >"${GITHUB_ENV}"

  EXTRA_ENVS='{}'
  EXTRA_SECRETS='{}'
  SECRETS='{}'
}

# run_step — extract the action's step source with the current inputs
# substituted in, then run it under the runner's shell flags.
run_step() {
  printf '%s' "${EXTRA_ENVS}" >"${WORK_DIR}/extra-envs.json"
  printf '%s' "${EXTRA_SECRETS}" >"${WORK_DIR}/extra-envs-from-secrets.json"
  printf '%s' "${SECRETS}" >"${WORK_DIR}/secrets.json"

  python3 "${_this_script_dir}/extract_step_source.py" \
    "${_this_script_dir}/action.yml" export-envs "${WORK_DIR}/step.sh" \
    "inputs.extra-envs=@${WORK_DIR}/extra-envs.json" \
    "inputs.extra-envs-from-secrets=@${WORK_DIR}/extra-envs-from-secrets.json" \
    "inputs.secrets-json=@${WORK_DIR}/secrets.json" \
    "github.action_path=${_this_script_dir}"

  bash --noprofile --norc -eo pipefail "${WORK_DIR}/step.sh" >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

# Exact value of one variable as written to $GITHUB_ENV. The action uses the
# heredoc-delimiter form, so this has to parse it rather than split on '='.
env_file_value() {
  python3 - "${1}" "${GITHUB_ENV}" <<'PY'
import re
import sys

name, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
match = re.search(
    r'^%s<<"([^"]+)"\n(.*?)\n"\1"\s*$' % re.escape(name), text, re.S | re.M
)
sys.stdout.write(match.group(2) if match else "")
PY
}

env_file_has() {
  grep -q "^${1}<<" "${GITHUB_ENV}"
}

env_file_eq() {
  local var="${1}" expected="${2}" actual
  env_file_has "${var}" || return 1
  actual="$(env_file_value "${var}"; printf 'x')"
  [[ "${actual}" == "${expected}x" ]]
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
    echo "--- GITHUB_ENV ---"
    cat "${GITHUB_ENV}" 2>/dev/null || true
    echo "--- /GITHUB_ENV ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}         EXPORT-ENV-VARS TESTS              ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# Empty maps — the default for a caller that configures neither input
# ----------------------------------------------------------------------
setup
run_step
assert "empty: step exits 0" test "${LAST_EXIT}" -eq 0
assert "empty: nothing is written to GITHUB_ENV" test ! -s "${GITHUB_ENV}"

# ----------------------------------------------------------------------
# Plain environment variables
# ----------------------------------------------------------------------
setup
EXTRA_ENVS='{"ARM_USE_OIDC":"true","ANOTHER_ENV":"1 2 3"}'
run_step
assert "plain: step exits 0" test "${LAST_EXIT}" -eq 0
assert "plain: a value is written" env_file_eq ARM_USE_OIDC 'true'
assert "plain: a value containing spaces is written intact" \
  env_file_eq ANOTHER_ENV '1 2 3'
assert "plain: the value is logged (this action logs plain values)" \
  grep -q "ARM_USE_OIDC' -> '1\|ARM_USE_OIDC' -> 'true'" "${OUT_FILE}"

# ----------------------------------------------------------------------
# Secret-sourced environment variables
# ----------------------------------------------------------------------
setup
EXTRA_SECRETS='{"ARM_CLIENT_ID":"AZURE_CLIENT_ID"}'
SECRETS='{"AZURE_CLIENT_ID":"the-client-id-value","UNUSED":"x"}'
run_step
assert "secrets: step exits 0" test "${LAST_EXIT}" -eq 0
assert "secrets: the variable holds the secret's value, not its name" \
  env_file_eq ARM_CLIENT_ID 'the-client-id-value'
assert "secrets: the secret name is logged" \
  grep -q "Secret is named 'AZURE_CLIENT_ID'" "${OUT_FILE}"
assert "secrets: the secret VALUE is never logged" \
  bash -c "! grep -q 'the-client-id-value' '${OUT_FILE}'"

# ----------------------------------------------------------------------
# A multiline secret value — the heredoc-delimiter form exists for this
# ----------------------------------------------------------------------
setup
EXTRA_SECRETS='{"APP_PRIVATE_KEY":"PEM"}'
SECRETS='{"PEM":"-----BEGIN RSA PRIVATE KEY-----\nline-two\n-----END RSA PRIVATE KEY-----"}'
run_step
assert "multiline: step exits 0" test "${LAST_EXIT}" -eq 0
assert "multiline: the value round-trips through GITHUB_ENV" \
  env_file_eq APP_PRIVATE_KEY '-----BEGIN RSA PRIVATE KEY-----
line-two
-----END RSA PRIVATE KEY-----'

# ----------------------------------------------------------------------
# Precedence: a key in both maps resolves to the secret-sourced value.
# resolve-goal-envs preserves this deliberately, so it needs a guard here.
# ----------------------------------------------------------------------
setup
EXTRA_ENVS='{"SHARED_KEY":"from-plain"}'
EXTRA_SECRETS='{"SHARED_KEY":"THE_SECRET"}'
SECRETS='{"THE_SECRET":"from-secret"}'
run_step
assert "precedence: step exits 0" test "${LAST_EXIT}" -eq 0
# $GITHUB_ENV is append-only and last-wins, and the secrets loop runs second.
assert "precedence: both entries are appended" \
  test "$(grep -c '^SHARED_KEY<<' "${GITHUB_ENV}")" -eq 2
assert "precedence: the secret-sourced entry is appended last, so it wins" \
  bash -c "tail -n 3 '${GITHUB_ENV}' | grep -q 'from-secret'"

# ----------------------------------------------------------------------
# A secret name that is not available to the workflow.
#
# This used to export the literal four characters 'null' with no warning; the
# error then surfaced far from its cause, usually as an opaque Azure login
# failure two steps later.
# ----------------------------------------------------------------------
setup
EXTRA_SECRETS='{"ARM_CLIENT_ID":"TYPOED_SECRET_NAME"}'
SECRETS='{"AZURE_CLIENT_ID":"the-client-id-value"}'
run_step
assert "negative: a missing secret fails the step" test "${LAST_EXIT}" -ne 0
assert "negative: the error names the secret and the variable" \
  grep -q "the secret 'TYPOED_SECRET_NAME', configured for environment variable 'ARM_CLIENT_ID'" "${OUT_FILE}"
assert "negative: the error hints at the likely causes" \
  grep -q "secrets: inherit" "${OUT_FILE}"
assert "negative: the literal string 'null' is NOT exported" \
  bash -c "! grep -qx 'null' '${GITHUB_ENV}'"

# ----------------------------------------------------------------------
# The distinction the fix turns on: a secret that EXISTS and whose value
# happens to be the string "null" must still be exported. Checking the value
# instead of the key's existence would reject this one.
# ----------------------------------------------------------------------
setup
EXTRA_SECRETS='{"WEIRD_BUT_VALID":"A_SECRET"}'
SECRETS='{"A_SECRET":"null"}'
run_step
assert "existence check: a secret whose value is the string 'null' is accepted" \
  test "${LAST_EXIT}" -eq 0
assert "existence check: and it is exported verbatim" \
  env_file_eq WEIRD_BUT_VALID 'null'

# An existing but empty secret is legitimate too.
setup
EXTRA_SECRETS='{"MAYBE_EMPTY":"EMPTY_SECRET"}'
SECRETS='{"EMPTY_SECRET":""}'
run_step
assert "existence check: an existing but empty secret is accepted" \
  test "${LAST_EXIT}" -eq 0
assert "existence check: and exported as the empty string" \
  env_file_eq MAYBE_EMPTY ''

# ----------------------------------------------------------------------
# Only the first bad secret needs to fail the step, but the plain
# variables processed before it must already have been written — the step is
# not transactional and callers should not be told otherwise.
# ----------------------------------------------------------------------
setup
EXTRA_ENVS='{"GOOD_PLAIN":"written"}'
EXTRA_SECRETS='{"BAD":"NO_SUCH_SECRET"}'
SECRETS='{"OTHER":"x"}'
run_step
assert "negative: the step still fails" test "${LAST_EXIT}" -ne 0
assert "negative: plain variables written before the failure are kept" \
  env_file_eq GOOD_PLAIN 'written'

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}          EXPORT-ENV-VARS SUMMARY           ${NC}"
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
