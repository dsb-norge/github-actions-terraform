#!/bin/env bash
#
# Tests for the export-env-vars action.
#
# The step's 'run:' block is extracted from action.yml by
# extract_step_source.py (literal expression substitution, as GitHub does it,
# no shell escaping — the inputs are JSON blobs full of quotes) and executed
# with the same shell flags the runner uses. Assertions are on the resulting
# $GITHUB_ENV file, which is the action's only real output, and on the log.
#
# Two layers:
#   - targeted assertions, one behaviour each;
#   - goldens: test-data/golden_<scenario>.txt holds the exit code, the
#     $GITHUB_ENV file and the log the LEGACY inline-bash action produced for
#     each scenario, byte for byte after normalisation (random heredoc
#     delimiters numbered in order of appearance; jq's own error text, which
#     varies between jq releases, elided). Quirks are pinned as they are, not
#     as they should be: a golden that changes is a behaviour change, and the
#     diff is the review.
#
# UPDATE_GOLDENS=1 rewrites the goldens from the current action instead of
# comparing. Never in the same commit as a refactor of the action.
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
GOLDEN_DIR="${_this_script_dir}/test-data"

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
  # What GitHub substitutes for an input the caller does not pass: its
  # declared default. Every golden runs with it.
  PREFIXES='[]'
}

# run_step — extract the action's step source with the current inputs
# substituted in, then run it under the runner's shell flags.
run_step() {
  printf '%s' "${EXTRA_ENVS}" >"${WORK_DIR}/extra-envs.json"
  printf '%s' "${EXTRA_SECRETS}" >"${WORK_DIR}/extra-envs-from-secrets.json"
  printf '%s' "${SECRETS}" >"${WORK_DIR}/secrets.json"
  printf '%s' "${PREFIXES}" >"${WORK_DIR}/prefixes.json"

  python3 "${_this_script_dir}/extract_step_source.py" \
    "${_this_script_dir}/action.yml" export-envs "${WORK_DIR}/step.sh" \
    "inputs.extra-envs=@${WORK_DIR}/extra-envs.json" \
    "inputs.extra-envs-from-secrets=@${WORK_DIR}/extra-envs-from-secrets.json" \
    "inputs.secrets-json=@${WORK_DIR}/secrets.json" \
    "inputs.export-secrets-with-prefixes-json=@${WORK_DIR}/prefixes.json" \
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

# The variable names in $GITHUB_ENV, one per line, in the order appended.
env_file_names() {
  sed -n 's/^\([^<]*\)<<"[0-9a-f]\{20\}"$/\1/p' "${GITHUB_ENV}"
}

# The effective value of a variable: $GITHUB_ENV is last-wins, so the value of
# the LAST entry for it.
env_file_last_eq() {
  local var="${1}" expected="${2}" actual
  actual="$(python3 - "${var}" "${GITHUB_ENV}" <<'PY'
import re
import sys

name, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
matches = list(re.finditer(
    r'^%s<<"([^"]+)"\n(.*?)\n"\1"$' % re.escape(name), text, re.S | re.M
))
sys.stdout.write(matches[-1].group(2) if matches else "<absent>")
PY
printf 'x')"
  [[ "${actual}" == "${expected}x" ]]
}

# The names appended, in order, equal the expected list (one per argument).
env_file_names_are() {
  [[ "$(env_file_names)" == "$(printf '%s\n' "$@" | sed '/^$/d')" ]]
}

# Normalised transcript of the last run: exit code, $GITHUB_ENV, log.
# Each random heredoc delimiter becomes <DELIM-n>, numbered in order of first
# appearance, so the pairing of opening and closing lines stays visible.
transcript() {
  python3 - "${LAST_EXIT}" "${GITHUB_ENV}" "${OUT_FILE}" <<'PY'
import re
import sys

exit_code, env_path, log_path = sys.argv[1:4]
with open(env_path, encoding="utf-8") as handle:
    env = handle.read()
with open(log_path, encoding="utf-8") as handle:
    log = handle.read()

labels = {}
for delimiter in re.findall(r'<<"([0-9a-f]{20})"', env):
    labels.setdefault(delimiter, f"<DELIM-{len(labels) + 1}>")
for delimiter, label in labels.items():
    env = env.replace(delimiter, label)

log = re.sub(r"(?m)^jq: .*$", "jq: <error text elided>", log)

sys.stdout.write(f"exit: {exit_code}\n")
sys.stdout.write("--- GITHUB_ENV ---\n")
sys.stdout.write(env)
sys.stdout.write("--- log ---\n")
sys.stdout.write(log)
PY
}

# Byte-exact comparison of the last run against its golden, with a diff on
# failure. Under UPDATE_GOLDENS=1 the golden is (re)written instead.
matches_golden() {
  local golden="${GOLDEN_DIR}/golden_${1}.txt"
  local actual="${WORK_DIR}/transcript.txt"
  transcript >"${actual}"
  if [[ "${UPDATE_GOLDENS:-}" == "1" ]]; then
    cp "${actual}" "${golden}"
    return 0
  fi
  if cmp -s "${golden}" "${actual}"; then
    return 0
  fi
  echo "  transcript differs from ${golden##*/}:"
  diff "${golden}" "${actual}" | sed 's/^/    /'
  return 1
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

# ======================================================================
# Goldens — the legacy action's full behaviour per scenario
# ======================================================================

# Both maps empty, as toJSON delivers an empty map.
setup
run_step
assert "golden: empty maps" matches_golden empty_maps

# Every input the empty string: both export blocks are skipped entirely.
setup
EXTRA_ENVS=''
EXTRA_SECRETS=''
SECRETS=''
run_step
assert "golden: empty strings" matches_golden empty_strings

# The shape toJSON actually delivers: pretty-printed over several lines.
setup
EXTRA_ENVS='{
  "ARM_USE_OIDC": "true",
  "TF_IN_AUTOMATION": "1"
}'
EXTRA_SECRETS='{
  "ARM_CLIENT_ID": "AZURE_CLIENT_ID",
  "ARM_TENANT_ID": "AZURE_TENANT_ID"
}'
SECRETS='{
  "AZURE_CLIENT_ID": "client-id-value",
  "AZURE_TENANT_ID": "tenant-id-value",
  "github_token": "ghs_unused"
}'
run_step
assert "golden: toJSON shape" matches_golden tojson_shape

# Keys are exported in jq 'keys' order (codepoint-sorted), not input order.
setup
EXTRA_ENVS='{"b_lower":"1","A_UPPER":"2","a_lower":"3","B_UPPER":"4"}'
EXTRA_SECRETS='{"Z_S":"S1","A_S":"S2"}'
SECRETS='{"S1":"one","S2":"two"}'
run_step
assert "golden: key order" matches_golden key_order

# Shell metacharacters, quotes, backslashes, unicode: exported verbatim,
# plain values logged verbatim.
setup
EXTRA_ENVS=$(cat <<'JSON'
{"DOLLAR":"$HOME ${HOME} $(id) `id`","QUOTES":"it's \"quoted\"","BACKSLASH":"C:\\path\\to","LITERAL_BACKSLASH_N":"a\\nb","GLOB":"0 * * * *","EQUALS":"a=b=c","HASH":"# not a comment","UNICODE":"blåbærsyltetøy ✓","SPACES":"  padded  ","TAB":"a\tb"}
JSON
)
run_step
assert "golden: plain special characters" matches_golden plain_special_chars

# Multi-line values: embedded and leading newlines survive; TRAILING newlines
# are stripped (the value passes through a command substitution).
setup
EXTRA_ENVS='{"EMBEDDED":"line1\nline2\nline3","LEADING":"\nafter-newline","TRAILING":"before-newlines\n\n","ONLY_NEWLINES":"\n\n"}'
run_step
assert "golden: plain multi-line values" matches_golden plain_multiline

# Non-string values go through 'jq -r': booleans and numbers as their JSON
# text, null as the four characters 'null', objects and arrays pretty-printed.
setup
EXTRA_ENVS='{"BOOL":true,"INT":1,"FLOAT":1.5,"NULL":null,"OBJECT":{"a":1,"b":[true]},"ARRAY":[1,"two"]}'
run_step
assert "golden: plain non-string values" matches_golden plain_non_string

# Legacy quirk: the value is written with 'echo', so a value that is exactly
# an echo option ('-n', '-e', '-E', '-neE') is swallowed and exported empty.
setup
EXTRA_ENVS='{"OPT_N":"-n","OPT_E":"-e","OPT_BIG_E":"-E","OPT_COMBO":"-neE","NOT_AN_OPTION":"-x"}'
run_step
assert "golden: plain values that are echo options (quirk)" matches_golden plain_echo_options

# Legacy quirk: keys are word-split, so a key with a space becomes two
# variables, each holding the lookup of a key that does not exist: 'null'.
setup
EXTRA_ENVS='{"TWO WORDS":"value"}'
run_step
assert "golden: plain key containing a space (quirk)" matches_golden plain_key_with_space

# Secret-sourced values: names logged, values never; secrets in the bag that
# nothing maps to are not exported.
setup
EXTRA_SECRETS='{"ARM_CLIENT_ID":"AZURE_CLIENT_ID","ARM_SUBSCRIPTION_ID":"AZURE_SUBSCRIPTION_ID"}'
SECRETS='{"AZURE_CLIENT_ID":"secret-client-id","AZURE_SUBSCRIPTION_ID":"secret-subscription-id","ARM_UNMAPPED":"secret-unmapped","TF_VAR_unmapped":"secret-tf-var"}'
run_step
assert "golden: secrets mapping" matches_golden secrets_mapping

# One secret mapped to two variables.
setup
EXTRA_SECRETS='{"FIRST":"SHARED","SECOND":"SHARED"}'
SECRETS='{"SHARED":"shared-secret-value"}'
run_step
assert "golden: one secret mapped twice" matches_golden secrets_mapped_twice

# Multi-line and special-character secret values.
setup
EXTRA_SECRETS='{"PEM":"PEM_SECRET","SPECIAL":"SPECIAL_SECRET","TRAILING":"TRAILING_SECRET"}'
SECRETS=$(cat <<'JSON'
{"PEM_SECRET":"-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----","SPECIAL_SECRET":"p@$$w0rd `id` $(id) \"q\" 'q' \\","TRAILING_SECRET":"value\n\n"}
JSON
)
run_step
assert "golden: secret values, multi-line and special characters" matches_golden secrets_special_values

# Existing secrets whose value is 'null' or empty are exported as such.
setup
EXTRA_SECRETS='{"IS_NULL_STRING":"NULL_STRING","IS_EMPTY":"EMPTY"}'
SECRETS='{"NULL_STRING":"null","EMPTY":""}'
run_step
assert "golden: secret values 'null' and empty" matches_golden secrets_null_and_empty

# The same key in both maps: both are appended, plain first, so the
# secret-sourced value wins ($GITHUB_ENV is last-wins).
setup
EXTRA_ENVS='{"SHARED_KEY":"from-plain","PLAIN_ONLY":"p"}'
EXTRA_SECRETS='{"SHARED_KEY":"THE_SECRET"}'
SECRETS='{"THE_SECRET":"from-secret"}'
run_step
assert "golden: key in both maps, secret appended last" matches_golden precedence_plain_then_secret

# A mapped secret missing from the bag fails the step; everything processed
# before it (all plain variables, earlier mapped secrets) is already written.
setup
EXTRA_ENVS='{"PLAIN":"written"}'
EXTRA_SECRETS='{"A_FIRST":"PRESENT","B_MISSING":"ABSENT","C_NEVER_REACHED":"PRESENT"}'
SECRETS='{"PRESENT":"present-value"}'
run_step
assert "golden: missing secret, partial export before the failure" matches_golden missing_secret_partial

# A mapping onto a 'null' bag: every lookup fails as "not available".
setup
EXTRA_SECRETS='{"X":"ANY"}'
SECRETS='null'
run_step
assert "golden: secrets bag is null" matches_golden secrets_bag_null

# An empty mapping never reads the bag, so even an unparsable bag passes.
setup
EXTRA_ENVS='{"PLAIN":"ok"}'
SECRETS='not json at all'
run_step
assert "golden: empty mapping ignores an unparsable bag" matches_golden empty_mapping_bad_bag

# 'null' for either map fails the step in jq ('null has no keys').
setup
EXTRA_ENVS='null'
run_step
assert "golden: extra-envs is null" matches_golden plain_null

setup
EXTRA_SECRETS='null'
run_step
assert "golden: extra-envs-from-secrets is null" matches_golden secrets_map_null

# Invalid JSON fails the step in jq.
setup
EXTRA_ENVS='{"A":'
run_step
assert "golden: extra-envs is invalid JSON" matches_golden plain_invalid_json

# A JSON array instead of an object: 'keys' of an array are its indices, and
# indexing an array by a string fails the step.
setup
EXTRA_ENVS='["A","B"]'
run_step
assert "golden: extra-envs is an array" matches_golden plain_array

# ======================================================================
# export-secrets-with-prefixes-json — every golden above runs with the
# declared default '[]', so they double as "the default changes nothing".
# ======================================================================

# A bag with every kind of near miss for the prefixes ARM_ and TF_VAR_.
PREFIX_BAG='{
  "ARM_CLIENT_ID": "secret-arm-client-id",
  "ARM_TENANT_ID": "secret-arm-tenant-id",
  "TF_VAR_admin_password": "secret-tf-var-password",
  "AZURE_CLIENT_ID": "secret-azure-client-id",
  "REPO_ARM_CLIENT_ID": "secret-repo-arm",
  "TF_VARIABLE": "secret-tf-variable",
  "arm_lower_case": "secret-arm-lower",
  "Arm_Mixed_Case": "secret-arm-mixed",
  "github_token": "ghs_secret-token"
}'

# Every value in PREFIX_BAG starts with 'secret-' or 'ghs_secret-', so a
# single grep catches any of them leaking into the log.
no_secret_value_logged() {
  ! grep -q 'secret-' "${OUT_FILE}"
}

# Selection: exactly the names that start with a listed prefix.
setup
SECRETS="${PREFIX_BAG}"
PREFIXES='["ARM_", "TF_VAR_"]'
run_step
assert "prefix: step exits 0" test "${LAST_EXIT}" -eq 0
assert "prefix: exactly the names with a listed prefix are exported, in name order" \
  env_file_names_are ARM_CLIENT_ID ARM_TENANT_ID TF_VAR_admin_password
assert "prefix: each is exported under its own name with its own value" \
  env_file_eq ARM_CLIENT_ID 'secret-arm-client-id'
assert "prefix: a TF_VAR_ secret keeps its lower-case name" \
  env_file_eq TF_VAR_admin_password 'secret-tf-var-password'
assert "prefix: a prefix inside a name does not select it (REPO_ARM_...)" \
  bash -c "! grep -q '^REPO_ARM_CLIENT_ID<<' '${GITHUB_ENV}'"
assert "prefix: 'TF_VAR_' does not select 'TF_VARIABLE'" \
  bash -c "! grep -q '^TF_VARIABLE<<' '${GITHUB_ENV}'"
assert "prefix: the names are logged" \
  grep -q "Exporting environment variable 'ARM_TENANT_ID'" "${OUT_FILE}"
assert "prefix: no secret value is logged" no_secret_value_logged
assert "prefix: no value is masked, as for the mapped secrets" \
  bash -c "! grep -q '::add-mask::' '${OUT_FILE}'"
assert "golden: prefix export" matches_golden prefix_export

# Case-sensitive, both ways.
setup
SECRETS="${PREFIX_BAG}"
PREFIXES='["ARM_"]'
run_step
assert "case: upper-case prefix selects only upper-case names" \
  env_file_names_are ARM_CLIENT_ID ARM_TENANT_ID

setup
SECRETS="${PREFIX_BAG}"
PREFIXES='["arm_"]'
run_step
assert "case: lower-case prefix selects only lower-case names" \
  env_file_names_are arm_lower_case

# Ordering: the prefix export comes first, so the explicit mapping overrides it.
setup
SECRETS="${PREFIX_BAG}"
PREFIXES='["ARM_"]'
EXTRA_SECRETS='{"ARM_CLIENT_ID":"AZURE_CLIENT_ID"}'
run_step
assert "override by mapping: step exits 0" test "${LAST_EXIT}" -eq 0
assert "override by mapping: prefix entries first, mapped entry appended last" \
  env_file_names_are ARM_CLIENT_ID ARM_TENANT_ID ARM_CLIENT_ID
assert "override by mapping: the mapped secret's value wins" \
  env_file_last_eq ARM_CLIENT_ID 'secret-azure-client-id'

# ... and the plain variables override it too.
setup
SECRETS="${PREFIX_BAG}"
PREFIXES='["ARM_", "TF_VAR_"]'
EXTRA_ENVS='{"TF_VAR_admin_password":"plain-override","ARM_USE_OIDC":"true"}'
run_step
assert "override by plain: step exits 0" test "${LAST_EXIT}" -eq 0
assert "override by plain: prefix entries first, plain entries after" \
  env_file_names_are ARM_CLIENT_ID ARM_TENANT_ID TF_VAR_admin_password ARM_USE_OIDC TF_VAR_admin_password
assert "override by plain: the plain value wins" \
  env_file_last_eq TF_VAR_admin_password 'plain-override'

# All three sources on one key: plain, then mapped (the existing order), both
# after the prefix export.
setup
SECRETS="${PREFIX_BAG}"
PREFIXES='["ARM_"]'
EXTRA_ENVS='{"ARM_TENANT_ID":"plain-tenant"}'
EXTRA_SECRETS='{"ARM_TENANT_ID":"AZURE_CLIENT_ID"}'
run_step
assert "override by both: appended prefix, plain, mapped" \
  env_file_names_are ARM_CLIENT_ID ARM_TENANT_ID ARM_TENANT_ID ARM_TENANT_ID
assert "override by both: the mapped value wins, as it does over plain today" \
  env_file_last_eq ARM_TENANT_ID 'secret-azure-client-id'
assert "golden: prefix export overridden by both maps" matches_golden prefix_overridden

# A multi-line secret round-trips through the prefix export.
setup
SECRETS='{"TF_VAR_pem":"-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----"}'
PREFIXES='["TF_VAR_"]'
run_step
assert "prefix: a multi-line secret value round-trips" \
  env_file_eq TF_VAR_pem '-----BEGIN PRIVATE KEY-----
MIIB
-----END PRIVATE KEY-----'

# Prefixes that match nothing: nothing exported, and the log says so.
setup
SECRETS="${PREFIX_BAG}"
PREFIXES='["NO_SUCH_"]'
run_step
assert "no match: step exits 0" test "${LAST_EXIT}" -eq 0
assert "no match: nothing is written to GITHUB_ENV" test ! -s "${GITHUB_ENV}"
assert "no match: the log says so" grep -q "No secret has a listed name prefix." "${OUT_FILE}"

# The empty list does nothing, and says nothing: same log as without prefixes.
setup
SECRETS="${PREFIX_BAG}"
EXTRA_ENVS='{"PLAIN":"p"}'
PREFIXES='[]'
run_step
_empty_list_log="$(mktemp)"
cp "${OUT_FILE}" "${_empty_list_log}"
assert "empty list: only the plain variable is exported" env_file_names_are PLAIN
assert "empty list: the input is not mentioned in the log" \
  bash -c "! grep -q 'prefix' '${OUT_FILE}'"

# An expression that evaluates to '' arrives as '', not as the default.
setup
SECRETS="${PREFIX_BAG}"
EXTRA_ENVS='{"PLAIN":"p"}'
PREFIXES=''
run_step
assert "empty string: treated as the default" env_file_names_are PLAIN
assert "empty string: same log as the empty list" \
  cmp -s "${OUT_FILE}" "${_empty_list_log}"
rm -f "${_empty_list_log}"

# Invalid prefix lists fail the step before ANYTHING is exported, the plain
# variables included.
prefix_error_case() {
  local label="${1}" value="${2}" message="${3}"
  setup
  SECRETS="${PREFIX_BAG}"
  EXTRA_ENVS='{"PLAIN":"p"}'
  EXTRA_SECRETS='{"MAPPED":"AZURE_CLIENT_ID"}'
  PREFIXES="${value}"
  run_step
  assert "invalid (${label}): the step fails" test "${LAST_EXIT}" -ne 0
  assert "invalid (${label}): nothing is written to GITHUB_ENV" test ! -s "${GITHUB_ENV}"
  assert "invalid (${label}): the error names the input and the problem" \
    grep -qF "ERROR: export-env-vars: input 'export-secrets-with-prefixes-json' ${message}" "${OUT_FILE}"
}
prefix_error_case "object" '{"ARM_":true}' "must be a JSON array of prefixes, not object"
prefix_error_case "string" '"ARM_"' "must be a JSON array of prefixes, not string"
prefix_error_case "null" 'null' "must be a JSON array of prefixes, not null"
prefix_error_case "number" '1' "must be a JSON array of prefixes, not number"
prefix_error_case "not JSON" 'ARM_,TF_VAR_' "is not valid JSON"
prefix_error_case "two values" '["ARM_"] ["TF_VAR_"]' "must hold exactly one JSON array"
prefix_error_case "non-string element" '["ARM_", 1]' "must hold non-empty strings only"
prefix_error_case "empty prefix" '[""]' "must hold non-empty strings only"

# A bag that is not an object cannot be exported from by prefix.
setup
SECRETS='null'
PREFIXES='["ARM_"]'
run_step
assert "bag not an object: the step fails" test "${LAST_EXIT}" -ne 0
assert "bag not an object: the error says so" \
  grep -qF "input 'secrets-json' is not a JSON object" "${OUT_FILE}"

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
