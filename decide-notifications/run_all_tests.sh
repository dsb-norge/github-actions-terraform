#!/bin/env bash
#
# Tests for decide-notifications: the action's own run block, end to end.
#
# The adapter (engine/dsb_tf_engine/notify_evidence.py) and the rules (notify_decide.py) are unit
# tested in engine/ under the coverage and mutation gates. This suite runs what only a runner runs:
# the run block of action.yml, extracted with yq, with its expressions pasted into the script text
# as GitHub pastes them, the step's env: set, a stub gh on PATH, and nothing else of this suite's
# environment.
#
# To run the command by hand, in a directory holding the metadata files:
#   GITHUB_REPOSITORY=o/r GITHUB_EVENT_NAME=push GITHUB_RUN_ID=1 GITHUB_RUN_NUMBER=1 GITHUB_RUN_ATTEMPT=1 \
#   GITHUB_OUTPUT=<file> python3 -I -B <repo>/engine/run.py decide-notifications \
#     --metadata-files-pattern='matrix-job-meta-*.json' --matrix-file=<file> --relevance-file=relevance.json \
#     --stage-results-file=<file> --state-file=<file> --out-dir=<dir>
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

# The step's log, one file per run of this suite: suites run side by side.
OUT_FILE="$(mktemp)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${OUT_FILE}" "${SCRATCH}"' EXIT

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

BEFORE="$(printf 'b%.0s' {1..40})"
AFTER="$(printf 'a%.0s' {1..40})"

# A workspace holding one environment's metadata, the relevance file and the event, and a stub gh
# that answers from ${SANDBOX}/api/<endpoint with / as __>.json, a GraphQL identity lookup from
# ${SANDBOX}/api/graphql__<login>.json, and logs the token of every call to ${SANDBOX}/tokens.
make_sandbox() {
  SANDBOX="$(mktemp -d "${SCRATCH}/sandbox.XXXXXX")"
  mkdir -p "${SANDBOX}/ws" "${SANDBOX}/bin" "${SANDBOX}/api" "${SANDBOX}/temp"
  cat >"${SANDBOX}/ws/matrix-job-meta-prod.json" <<'EOF'
{"metadata": {"environment": "prod"}, "steps": {"plan": {"outcome": "success"}, "apply": {"outcome": "failure"}}}
EOF
  cat >"${SANDBOX}/relevance.json" <<'EOF'
{"environments": [{"environment": "prod", "verdict": "run", "stage": 1}],
 "notify": {"active": true, "reason": "on", "runs-on": "ubuntu-latest",
            "target": {"bot-url": "https://relay.example.net/api", "bot-audience": "api://relay", "alias": "tf-alerts"},
            "senders": {"prod": {"github-environment": "prod", "extra-envs": {"ARM_TENANT_ID": "t"},
                                 "extra-envs-from-secrets": {"ARM_CLIENT_ID": "PROD_CLIENT_ID"}}}}}
EOF
  jq -n --arg before "${BEFORE}" --arg after "${AFTER}" \
    '{repository: {default_branch: "main"}, before: $before, after: $after, sender: {login: "asmith", type: "User"}}' \
    >"${SANDBOX}/event.json"
  jq -n --arg after "${AFTER}" --arg before "${BEFORE}" '{commits: [{sha: $after, parents: [{sha: $before}]}]}' \
    >"${SANDBOX}/api/repos__o__r__compare__${BEFORE}...${AFTER}.json"
  echo '[{"number": 7, "merged_at": "2026-10-07T11:00:00Z", "base": {"ref": "main"}}]' \
    >"${SANDBOX}/api/repos__o__r__commits__${AFTER}__pulls.json"
  echo '{"number": 7, "title": "Add a storage account", "user": {"login": "jdoe", "type": "User"}, "merged_by": {"login": "asmith", "type": "User"}}' \
    >"${SANDBOX}/api/repos__o__r__pulls__7.json"
  echo '{"name": "prod", "protection_rules": []}' >"${SANDBOX}/api/repos__o__r__environments__prod.json"
  cat >"${SANDBOX}/bin/gh" <<EOF
#!/bin/env bash
[ "\$1" = "api" ] || exit 64
echo "\$2 \${GH_TOKEN}" >>"${SANDBOX}/tokens"
file="${SANDBOX}/api/\${2//\//__}.json"
[ "\$2" = "graphql" ] && file="${SANDBOX}/api/graphql__\${8#login=}.json"
[ -f "\${file}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "\${file}"
EOF
  chmod +x "${SANDBOX}/bin/gh"
  MATRIX_JSON='{"environment":["prod"],"include":[{"environment":"prod","vars":{"environment":"prod","github-environment":"prod","goals-granted":["init","plan","apply"],"notifications":null}}]}'
  STAGE_RESULTS_JSON='{"1": "success", "2": "skipped", "3": "skipped"}'
}

# The run block of action.yml with its expressions substituted, as the runner pastes them.
render_run_block() {
  MATRIX_JSON="${MATRIX_JSON}" STAGE_RESULTS_JSON="${STAGE_RESULTS_JSON}" python3 - "${_this_script_dir}" <<'PY'
import os, subprocess, sys
action_dir = sys.argv[1]
block = subprocess.run(["yq", ".runs.steps[0].run", f"{action_dir}/action.yml"],
                       capture_output=True, text=True, check=True).stdout
print(block.replace("${{ inputs.matrix-json }}", os.environ["MATRIX_JSON"])
      .replace("${{ inputs.stage-results-json }}", os.environ["STAGE_RESULTS_JSON"])
      .replace("${{ github.action_path }}", action_dir), end="")
PY
}

run_step() {
  : >"${SANDBOX}/output.txt"
  : >"${SANDBOX}/summary.md"
  render_run_block >"${SANDBOX}/step.sh"
  (
    cd "${SANDBOX}/ws" || exit 1
    unset $(compgen -e | grep '^GITHUB_')
    export GITHUB_REPOSITORY="o/r" GITHUB_EVENT_NAME="push" GITHUB_RUN_ID="4711" GITHUB_RUN_NUMBER="42"
    export GITHUB_RUN_ATTEMPT="1" GITHUB_SERVER_URL="https://github.com" GITHUB_EVENT_PATH="${SANDBOX}/event.json"
    export GITHUB_OUTPUT="${SANDBOX}/output.txt" GITHUB_STEP_SUMMARY="${SANDBOX}/summary.md" GH_TOKEN="fake-token"
    export RUNNER_TEMP="${SANDBOX}/temp" PATH="${SANDBOX}/bin:${PATH}"
    # The step's env:, as action.yml sets it from its inputs.
    export METADATA_FILES_PATTERN="matrix-job-meta-*.json" RELEVANCE_FILE="${SANDBOX}/relevance.json"
    export STATE_FILE="${SANDBOX}/state/state.json" OUT_DIR="${SANDBOX}/notify"
    for assignment in "$@"; do export "${assignment?}"; done
    bash --noprofile --norc -eo pipefail "${SANDBOX}/step.sh"
  ) >"${OUT_FILE}" 2>&1
  STEP_EXIT=$?
}

step_output() {
  awk -v name="${1}" 'index($0, name "<<EOF_") == 1 {getline; print; exit}' "${SANDBOX}/output.txt"
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}        DECIDE-NOTIFICATIONS TESTS          ${NC}"
echo -e "${YELLOW}============================================${NC}"

begin "run block: a description comment first, JSON to files through quoted, unique heredocs, python3 -I"
run_block="$(yq '.runs.steps[0].run' "${_this_script_dir}/action.yml")"
if [[ "$(head -n 1 <<<"${run_block}")" == "# "* ]] \
  && grep -qx "cat >\"\${matrix_file}\" <<'DECIDE_NOTIFICATIONS_MATRIX_JSON'" <<<"${run_block}" \
  && grep -qx "cat >\"\${stage_results_file}\" <<'DECIDE_NOTIFICATIONS_STAGE_RESULTS_JSON'" <<<"${run_block}" \
  && grep -q '^python3 -I -B "${{ github.action_path }}/../engine/run.py" decide-notifications \\$' <<<"${run_block}" \
  && [[ "$(grep -c '\${{' <<<"${run_block}")" == "3" ]]; then
  pass
else
  fail "the run block no longer has its hardened shape"
fi

begin "the step's env: the identity token and the people domains come from their inputs alone"
if [[ "$(yq '.runs.steps[0].env.NOTIFY_IDENTITY_TOKEN' "${_this_script_dir}/action.yml")" == '${{ inputs.identity-token }}' ]] \
  && [[ "$(yq '.runs.steps[0].env.NOTIFY_PEOPLE_DOMAINS' "${_this_script_dir}/action.yml")" == '${{ inputs.people-domains }}' ]] \
  && [[ "$(yq '.inputs.identity-token.required' "${_this_script_dir}/action.yml")" == "false" ]] \
  && [[ "$(yq '.inputs.people-domains.required' "${_this_script_dir}/action.yml")" == "false" ]]; then
  pass
else
  fail "action.yml does not map the two inputs to the step's env"
fi

begin "a failed apply on a push: one deliver row, its message, the observations and the summary"
make_sandbox
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(step_output deliver-count)" == "1" ]] \
  && [[ "$(step_output deliver-matrix-json | jq -r '.include[0] | [.id, .sender, .alias] | join(",")')" == "e1,prod,tf-alerts" ]] \
  && [[ "$(head -n 1 "${SANDBOX}/notify/events/e1.md")" == '❌ **Apply failed** in `prod` · o/r' ]] \
  && grep -qF 'Change: [#7](https://github.com/o/r/pull/7) `Add a storage account` by jdoe, merged by asmith.' "${SANDBOX}/notify/events/e1.md" \
  && [[ "$(jq -r '.observations[0].action' "${SANDBOX}/notify/observations.json")" == "open" ]] \
  && grep -qF '| `prod` | apply failed | to `tf-alerts` as `prod` |' "${SANDBOX}/summary.md"; then
  pass
else
  fail "exit ${STEP_EXIT}, deliver-count '$(step_output deliver-count)'"
fi

begin "with the identity App: gh looks people up with its token, and the message names them"
make_sandbox
saml() {
  jq -n --arg upn "${1}" --arg given "${2}" --arg family "${3}" --arg oid "${4}" '{data: {organization: {samlIdentityProvider:
    {externalIdentities: {nodes: [{samlIdentity: {username: $upn, givenName: $given, familyName: $family, attributes: [
    {name: "http://schemas.microsoft.com/identity/claims/objectidentifier", value: $oid}]}}]}}}}}'
}
saml 100001@example.org Jane Doe oid-jdoe >"${SANDBOX}/api/graphql__jdoe.json"
saml github-admin@admin.example.net Ola Admin oid-asmith >"${SANDBOX}/api/graphql__asmith.json"
run_step NOTIFY_IDENTITY_TOKEN=identity-token NOTIFY_PEOPLE_DOMAINS=example.org
if [[ ${STEP_EXIT} -eq 0 ]] \
  && grep -qF 'Change: [#7](https://github.com/o/r/pull/7) `Add a storage account` by Jane Doe, merged by asmith.' "${SANDBOX}/notify/events/e1.md" \
  && [[ "$(jq -c '.mentions' "${SANDBOX}/notify/events/e1.json")" == '[{"login":"jdoe","object_id":"oid-jdoe","name":"Jane Doe"}]' ]] \
  && [[ "$(grep -c '^graphql identity-token$' "${SANDBOX}/tokens")" == "2" ]] \
  && [[ "$(grep -vc ' fake-token$' "${SANDBOX}/tokens")" == "2" ]] \
  && ! grep -rqF identity-token "${SANDBOX}/notify" "${SANDBOX}/output.txt" "${SANDBOX}/summary.md" "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}, gh calls: $(cat "${SANDBOX}/tokens" 2>/dev/null | tr '\n' ';')"
fi

begin "a stored state is read: the next success resolves the incident"
make_sandbox
mkdir -p "${SANDBOX}/state"
jq -n '{schema_version: 1, incidents: {"prod/apply": {kind: "apply-failed", status: "open", message_id: "msg-1",
  alias: "tf-alerts", sender: "prod", opened_at: "2026-10-05T08:30:00Z", opened_run: 40, seen_run: 40, people: [],
  resolved_at: null}}}' >"${SANDBOX}/state/state.json"
jq '.steps.apply.outcome = "success"' "${SANDBOX}/ws/matrix-job-meta-prod.json" >"${SANDBOX}/meta" \
  && mv "${SANDBOX}/meta" "${SANDBOX}/ws/matrix-job-meta-prod.json"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ "$(step_output deliver-matrix-json | jq -r '.include[0]["reply-to"]')" == "msg-1" ]] \
  && [[ "$(head -n 1 "${SANDBOX}/notify/events/e1.md")" == '✅ **Applied** in `prod` · o/r' ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, deliver-matrix-json '$(step_output deliver-matrix-json)'"
fi

begin "shell syntax in the pasted JSON is data, never run"
make_sandbox
MATRIX_JSON='{"environment":["prod"],"include":[{"environment":"prod","vars":{"environment":"prod","github-environment":"prod","goals-granted":["apply"],"notifications":null,"x":"$(touch pwned) `touch pwned2`"}}]}'
STAGE_RESULTS_JSON='{"1": "success $(touch pwned3)"}'
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && [[ ! -e "${SANDBOX}/ws/pwned" ]] && [[ ! -e "${SANDBOX}/ws/pwned2" ]] \
  && [[ ! -e "${SANDBOX}/ws/pwned3" ]]; then
  pass
else
  fail "exit ${STEP_EXIT}, or a command in the JSON ran"
fi

begin "the caller's checkout stays off Python's import path"
make_sandbox
echo "raise SystemExit('caller json.py imported')" >"${SANDBOX}/ws/json.py"
run_step
if [[ ${STEP_EXIT} -eq 0 ]] && ! grep -q 'caller json.py imported' "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}"
fi

begin "a relevance file that is missing fails the step"
make_sandbox
run_step "RELEVANCE_FILE=${SANDBOX}/missing.json"
if [[ ${STEP_EXIT} -eq 1 ]] && grep -q '^::error title=decide-notifications::the relevance file cannot be read' "${OUT_FILE}"; then
  pass
else
  fail "exit ${STEP_EXIT}"
fi

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
