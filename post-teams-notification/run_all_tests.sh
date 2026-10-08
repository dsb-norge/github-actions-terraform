#!/bin/env bash
#
# Tests for step_post.sh
#
# The step posts one markdown text message to the Teams notification relay. These tests run it against a
# fake relay, a local HTTP server answering a scripted list of responses and recording every
# request, and a stub `az` that hands out a fake token. Sleeps between retries are recorded, not
# slept. (docs/Notifications.md §11)
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# The step's output, one file per run of this suite: suites run side by side.
_test_output=$(mktemp)
_work=$(mktemp -d)
trap 'stop_relay; rm -rf "${_test_output}" "${_work}"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

OUT_FILE="${_test_output}"
RELAY_PID=""

# ----------------------------------------------------------------------------
# The fake relay: answers the responses in ${_work}/script.json in order (500 once they run out)
# and appends every request to ${_work}/requests.jsonl.
# ----------------------------------------------------------------------------
cat >"${_work}/fake_relay.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

work = sys.argv[1]
with open(f"{work}/script.json", encoding="utf-8") as handle:
    script = json.load(handle)

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8")
        with open(f"{work}/requests.jsonl", "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()},
                                     "body": body}) + "\n")
        answer = script.pop(0) if script else {"status": 500, "body": ""}
        payload = answer.get("body", "")
        payload = payload if isinstance(payload, str) else json.dumps(payload)
        self.send_response(answer["status"])
        for name, value in (answer.get("headers") or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload.encode("utf-8"))))
        self.end_headers()
        self.wfile.write(payload.encode("utf-8"))

    def log_message(self, *args):
        pass

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(f"{work}/port", "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PYEOF

# start_relay '<json list of responses>'
start_relay() {
  printf '%s' "${1}" >"${_work}/script.json"
  : >"${_work}/requests.jsonl"
  rm -f "${_work}/port"
  python3 "${_work}/fake_relay.py" "${_work}" &
  RELAY_PID=$!
  local i
  for i in $(seq 1 50); do [ -s "${_work}/port" ] && break; sleep 0.1; done
  export input_bot_url="http://127.0.0.1:$(cat "${_work}/port")/api"
}

stop_relay() {
  if [ -n "${RELAY_PID}" ]; then
    kill "${RELAY_PID}" 2>/dev/null || true
    wait "${RELAY_PID}" 2>/dev/null || true
    RELAY_PID=""
  fi
}

request_count() { grep -c . "${_work}/requests.jsonl" 2>/dev/null || true; }
# request_field <n> <jq filter>: a field of the n-th request (1-based)
request_field() { sed -n "${1}p" "${_work}/requests.jsonl" | jq -r "${2}"; }

# ----------------------------------------------------------------------------
# The stub az: prints a fake token for `az account get-access-token`, or fails when FAKE_AZ_FAIL is set.
# ----------------------------------------------------------------------------
mkdir -p "${_work}/bin"
cat >"${_work}/bin/az" <<'EOF'
#!/bin/env bash
echo "$*" >>"${FAKE_AZ_LOG}"
if [ -n "${FAKE_AZ_FAIL:-}" ]; then
  echo "ERROR: AADSTS700024: Client assertion is not within its valid time range." >&2
  exit 1
fi
echo "fake-token-0123456789"
EOF
chmod +x "${_work}/bin/az"

setup() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export PATH="${_work}/bin:${PATH}"
  export FAKE_AZ_LOG="${RUNNER_TEMP}/az.log"
  unset FAKE_AZ_FAIL
  : >"${FAKE_AZ_LOG}"
  export SLEEPS_FILE="${RUNNER_TEMP}/sleeps"
  : >"${SLEEPS_FILE}"

  MESSAGE="${RUNNER_TEMP}/message.md"
  printf '%s\n' '**Apply failed** in `prod`' '' '[Open run](https://github.com/o/r/actions/runs/1) "quoted"' >"${MESSAGE}"

  export input_bot_url=""
  export input_bot_audience="api://00000000-0000-0000-0000-000000000000"
  export input_alias="tf-alerts"
  export input_message_file="${MESSAGE}"
  export input_reply_to=""
  export input_update=""
  export input_idempotency_key="o/r/101/1/prod/apply/open"
  export input_dry_run="false"
  export input_mentions_file=""
  export input_direct_to=""
}

teardown() {
  stop_relay
  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${RUNNER_TEMP}"
}

# The step's sleep between retries, recorded instead of slept. The step defines its own only when
# none is defined, so this one, inherited by the subshell, is used.
_post_teams_notification_sleep() { echo "${1}" >>"${SLEEPS_FILE}"; }

run_step() {
  (
    set -eo pipefail
    set -o allexport
    source "${_this_script_dir}/step_post.sh"
  ) >"${OUT_FILE}" 2>&1
  LAST_EXIT=$?
}

get_output() { grep "^${1}=" "${GITHUB_OUTPUT}" 2>/dev/null | head -n1 | cut -d= -f2-; }
sleeps() { paste -sd' ' "${SLEEPS_FILE}"; }

assert() {
  local name="${1}"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "$@"; then
    echo -e "${GREEN}✓ PASSED${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo "--- step output ---"; cat "${OUT_FILE}" 2>/dev/null || true
    echo "--- GITHUB_OUTPUT ---"; cat "${GITHUB_OUTPUT}" 2>/dev/null || true
    echo "--- requests ---"; cat "${_work}/requests.jsonl" 2>/dev/null || true
    echo "--- end ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}      POST-TEAMS-NOTIFICATION STEP TESTS     ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# P1 — accepted: one request, the text as the message, the outputs
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 202, "body": {"status": "queued", "messageId": "msg-0a1b2c", "correlationId": "c1"}}]'
run_step
assert "P1: exits 0" test "${LAST_EXIT}" -eq 0
assert "P1: one request" test "$(request_count)" -eq 1
assert "P1: posted to <bot-url>/v1/notify/<alias>" test "$(request_field 1 .path)" = "/api/v1/notify/tf-alerts"
assert "P1: a bearer token from az for the audience" \
  test "$(request_field 1 '.headers.authorization')" = "Bearer fake-token-0123456789"
assert "P1: az was asked for the audience's token" \
  grep -qF -- "account get-access-token --resource api://00000000-0000-0000-0000-000000000000" "${FAKE_AZ_LOG}"
assert "P1: JSON content type" test "$(request_field 1 '.headers["content-type"]')" = "application/json"
assert "P1: the idempotency key" test "$(request_field 1 '.headers["idempotency-key"]')" = "o/r/101/1/prod/apply/open"
assert "P1: the body is the file's text as it is, trailing newline kept, as a text message; nothing else" \
  test "$(request_field 1 '.body | fromjson | tojson')" = '{"format":"text","message":"**Apply failed** in `prod`\n\n[Open run](https://github.com/o/r/actions/runs/1) \"quoted\"\n"}'
assert "P1: message-id" test "$(get_output message-id)" = "msg-0a1b2c"
assert "P1: http-status" test "$(get_output http-status)" = "202"
assert "P1: accepted" test "$(get_output accepted)" = "true"
assert "P1: no sleep" test -z "$(sleeps)"
assert "P1: the token is never printed" bash -c "! grep -q 'fake-token' '${OUT_FILE}'"
teardown

# ----------------------------------------------------------------------
# P2 — reply-to and update travel in the body; without them, no key at all
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 202, "body": {"messageId": "msg-2"}}]'
export input_reply_to="msg-root"
run_step
assert "P2: replyTo is in the body, and no update" \
  test "$(request_field 1 '.body | fromjson | [.replyTo, .update // "none"] | join(",")')" = "msg-root,none"
teardown

setup
start_relay '[{"status": 202, "body": {"messageId": "msg-2"}}]'
export input_update="msg-first"
run_step
assert "P2: update is in the body, and no replyTo" \
  test "$(request_field 1 '.body | fromjson | [.update, .replyTo // "none"] | join(",")')" = "msg-first,none"
teardown

setup
start_relay '[{"status": 202, "body": {"messageId": "msg-3"}}]'
export input_idempotency_key=""
run_step
assert "P2: no idempotency key, no header" test "$(request_field 1 '.headers["idempotency-key"] // "absent"')" = "absent"
teardown

# ----------------------------------------------------------------------
# P3 — 429 honours Retry-After, then succeeds
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 429, "headers": {"Retry-After": "7"}, "body": ""}, {"status": 202, "body": {"messageId": "msg-4"}}]'
run_step
assert "P3: two requests" test "$(request_count)" -eq 2
assert "P3: slept what Retry-After said" test "$(sleeps)" = "7"
assert "P3: accepted after the retry" test "$(get_output accepted)" = "true"
assert "P3: message-id from the second answer" test "$(get_output message-id)" = "msg-4"
assert "P3: the same idempotency key on the retry" \
  test "$(request_field 2 '.headers["idempotency-key"]')" = "o/r/101/1/prod/apply/open"
teardown

# ----------------------------------------------------------------------
# P4 — 5xx is retried three times, then given up; the step never fails
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 503}, {"status": 503}, {"status": 503}, {"status": 503}, {"status": 202, "body": {"messageId": "never"}}]'
run_step
assert "P4: exits 0" test "${LAST_EXIT}" -eq 0
assert "P4: one request and three retries" test "$(request_count)" -eq 4
assert "P4: backoff without Retry-After: 1, 2 and 4 seconds" test "$(sleeps)" = "1 2 4"
assert "P4: not accepted" test "$(get_output accepted)" = "false"
assert "P4: the last status" test "$(get_output http-status)" = "503"
assert "P4: no message-id" test -z "$(get_output message-id)"
assert "P4: a warning annotation names the alias and the status" \
  grep -qxF '::warning title=Teams notification not sent::tf-alerts — HTTP 503 after 4 attempts' "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# P5 — a 4xx is not retried; its problem detail is reported, escaped
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 404, "headers": {"Content-Type": "application/problem+json"}, "body": {"title": "Not Found", "detail": "Alias tf-alerts not found.\n100% sure"}}]'
run_step
assert "P5: one request" test "$(request_count)" -eq 1
assert "P5: no sleep" test -z "$(sleeps)"
assert "P5: not accepted, status 404" bash -c "[ '$(get_output accepted)' = false ] && [ '$(get_output http-status)' = 404 ]"
assert "P5: the warning carries the detail, escaped for a workflow command" \
  grep -qxF '::warning title=Teams notification not sent::tf-alerts — HTTP 404: Alias tf-alerts not found.%0A100%25 sure' "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# P6 — the budget: a wait that would pass it is not waited
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 429, "headers": {"Retry-After": "100"}}, {"status": 429, "headers": {"Retry-After": "100"}}, {"status": 202, "body": {"messageId": "late"}}]'
run_step
assert "P6: the first 100-second wait fits the 180-second budget, the second does not" test "$(sleeps)" = "100"
assert "P6: two requests" test "$(request_count)" -eq 2
assert "P6: not accepted" test "$(get_output accepted)" = "false"
assert "P6: the warning says the budget is spent" \
  grep -qxF '::warning title=Teams notification not sent::tf-alerts — HTTP 429 after 2 attempts; the retry budget is spent' "${OUT_FILE}"
teardown

setup
start_relay '[{"status": 429, "headers": {"Retry-After": "900"}}]'
run_step
assert "P6: a Retry-After beyond the budget is not waited at all" bash -c "[ -z '$(sleeps)' ] && [ $(request_count) -eq 1 ]"
teardown

# ----------------------------------------------------------------------
# P7 — a relay that cannot be reached is retried like a 5xx
# ----------------------------------------------------------------------
setup
start_relay '[]'
stop_relay
run_step
assert "P7: exits 0" test "${LAST_EXIT}" -eq 0
assert "P7: retried with backoff" test "$(sleeps)" = "1 2 4"
assert "P7: status 000, not accepted" bash -c "[ '$(get_output http-status)' = 000 ] && [ '$(get_output accepted)' = false ]"
assert "P7: the warning says no answer" \
  grep -qxF '::warning title=Teams notification not sent::tf-alerts — no answer from the relay after 4 attempts' "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# P8 — no token: nothing is posted
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
export FAKE_AZ_FAIL=1
run_step
assert "P8: exits 0" test "${LAST_EXIT}" -eq 0
assert "P8: no request" test "$(request_count)" -eq 0
assert "P8: not accepted, status 000" bash -c "[ '$(get_output accepted)' = false ] && [ '$(get_output http-status)' = 000 ]"
assert "P8: the warning names the audience and az's first error line" \
  grep -qxF '::warning title=Teams notification not sent::tf-alerts — no token for api://00000000-0000-0000-0000-000000000000: ERROR: AADSTS700024: Client assertion is not within its valid time range.' "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# P9 — dry run: the request is printed, nothing is sent, no token is asked for
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
export input_dry_run="true"
run_step
assert "P9: no request" test "$(request_count)" -eq 0
assert "P9: no token" test ! -s "${FAKE_AZ_LOG}"
assert "P9: the URL it would post to" grep -qF "dry run: would POST to ${input_bot_url}/v1/notify/tf-alerts" "${OUT_FILE}"
assert "P9: not accepted" test "$(get_output accepted)" = "false"
teardown

# ----------------------------------------------------------------------
# P10 — what cannot be posted is a warning, never a request
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
export input_message_file="${RUNNER_TEMP}/missing.json"
run_step
assert "P10: a missing message file: no request, a warning" \
  bash -c "[ $(request_count) -eq 0 ] && grep -qxF '::warning title=Teams notification not sent::tf-alerts — the message file ${RUNNER_TEMP}/missing.json cannot be read' '${OUT_FILE}'"
teardown

setup
start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
export input_alias="../aliases"
run_step
assert "P10: an alias the relay could not have made: no request, a warning" \
  bash -c "[ $(request_count) -eq 0 ] && grep -qxF \"::warning title=Teams notification not sent::../aliases — not an alias: 2 to 50 of a-z 0-9 -, starting and ending with a letter or a digit\" '${OUT_FILE}'"
teardown

setup
export input_bot_url=""
run_step
assert "P10: no target: no token, no request, a warning" \
  bash -c "[ ! -s '${FAKE_AZ_LOG}' ] && grep -qxF '::warning title=Teams notification not sent::tf-alerts — bot-url, bot-audience and alias are all required' '${OUT_FILE}'"
assert "P10: and the outputs say so" bash -c "[ '$(get_output accepted)' = false ] && [ '$(get_output http-status)' = 000 ]"
teardown

setup
start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
: >"${MESSAGE}"
run_step
assert "P10: an empty message: no request, a warning" \
  bash -c "[ $(request_count) -eq 0 ] && grep -qxF \"::warning title=Teams notification not sent::tf-alerts — the message file ${MESSAGE} is empty\" '${OUT_FILE}'"
teardown

setup
start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
export input_idempotency_key=$'o/r/1\nX-Injected: yes'
run_step
assert "P10: an idempotency key that is not one header-safe word: no request, a warning" \
  bash -c "[ $(request_count) -eq 0 ] && grep -qxF '::warning title=Teams notification not sent::tf-alerts — the idempotency key is not 1 to 256 printable characters without spaces' '${OUT_FILE}'"
teardown

setup
start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
export input_reply_to="msg-root"; export input_update="msg-first"
run_step
assert "P10: reply-to and update together: no request, a warning" \
  bash -c "[ $(request_count) -eq 0 ] && grep -qxF '::warning title=Teams notification not sent::tf-alerts — reply-to and update cannot both be set; the relay takes one or the other' '${OUT_FILE}'"
teardown

# ----------------------------------------------------------------------
# P13 — mentions travel in the body as the file has them; none, no key
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 202, "body": {"messageId": "msg-m"}}]'
MENTIONS="${RUNNER_TEMP}/e1.mentions.json"
printf '%s' '[{"key":"p1","id":"oid-1","name":"Jane Doe"},{"key":"p2","id":"oid-2","name":"Ola Nordmann"}]' >"${MENTIONS}"
export input_mentions_file="${MENTIONS}"
run_step
assert "P13: the mentions are in the body as the file has them" \
  test "$(request_field 1 '.body | fromjson | .mentions | tojson')" = '[{"key":"p1","id":"oid-1","name":"Jane Doe"},{"key":"p2","id":"oid-2","name":"Ola Nordmann"}]'
assert "P13: and the message beside them" test "$(request_field 1 '.body | fromjson | .format')" = "text"
teardown

setup
start_relay '[{"status": 202, "body": {"messageId": "msg-m"}}]'
MENTIONS="${RUNNER_TEMP}/e1.mentions.json"
printf '%s\n' '[]' >"${MENTIONS}"
export input_mentions_file="${MENTIONS}"
run_step
assert "P13: an empty list: no mentions key" test "$(request_field 1 '.body | fromjson | has("mentions")')" = "false"
teardown

setup
start_relay '[{"status": 202, "body": {"messageId": "msg-m"}}]'
run_step
assert "P13: no mentions file: no mentions key" test "$(request_field 1 '.body | fromjson | has("mentions")')" = "false"
teardown

for broken in missing not-json object; do
  setup
  start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
  MENTIONS="${RUNNER_TEMP}/e1.mentions.json"
  case "${broken}" in
    not-json) printf '%s' 'p1' >"${MENTIONS}" ;;
    object) printf '%s' '{"key":"p1"}' >"${MENTIONS}" ;;
  esac
  export input_mentions_file="${MENTIONS}"
  run_step
  # A message that places <at>key</at> without its mentions is refused (400): say so before sending it.
  assert "P13: a mentions file that is ${broken}: no request, a warning" \
    bash -c "[ $(request_count) -eq 0 ] && grep -qxF '::warning title=Teams notification not sent::tf-alerts — the mentions file ${MENTIONS} is not a JSON list' '${OUT_FILE}'"
  teardown
done

# ----------------------------------------------------------------------
# P14 — a direct message goes to /v1/send, to one person by object ID
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 202, "body": {"messageId": "msg-d"}}]'
export input_direct_to="72d8e6a5-ca8b-4770-8b07-03fea54be3cf"
run_step
assert "P14: posted to <bot-url>/v1/send" test "$(request_field 1 .path)" = "/api/v1/send"
assert "P14: to the person, as text, the message as it is" \
  test "$(request_field 1 '.body | fromjson | [.target.type, .target.userId, .format, (.message | startswith("**Apply failed**"))] | map(tostring) | join(",")')" = "personal,72d8e6a5-ca8b-4770-8b07-03fea54be3cf,text,true"
assert "P14: with the idempotency key" test "$(request_field 1 '.headers["idempotency-key"]')" = "o/r/101/1/prod/apply/open"
assert "P14: accepted" test "$(get_output accepted)" = "true"
teardown

for refused in reply-to mentions not-an-id; do
  setup
  start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
  export input_direct_to="72d8e6a5-ca8b-4770-8b07-03fea54be3cf"
  case "${refused}" in
    reply-to) export input_reply_to="msg-root"; reason="a direct message takes no reply-to: a personal chat has no threads" ;;
    mentions)
      printf '%s' '[{"key":"p1","id":"oid-1","name":"Jane Doe"}]' >"${RUNNER_TEMP}/m.json"
      export input_mentions_file="${RUNNER_TEMP}/m.json"; reason="a direct message takes no mentions: a personal chat cannot show them" ;;
    not-an-id) export input_direct_to="jane.doe@example.org/../x"; reason="direct-to is not an Entra object ID" ;;
  esac
  run_step
  assert "P14: a direct message with ${refused}: no request, a warning" \
    bash -c "[ $(request_count) -eq 0 ] && grep -qxF '::warning title=Teams notification not sent::tf-alerts — ${reason}' '${OUT_FILE}'"
  teardown
done

setup
start_relay '[{"status": 202, "body": {"messageId": "x"}}]'
printf '%s\n' '[]' >"${RUNNER_TEMP}/m.json"
export input_mentions_file="${RUNNER_TEMP}/m.json"
export input_direct_to="72d8e6a5-ca8b-4770-8b07-03fea54be3cf"
run_step
assert "P14: an empty mentions list beside a direct message is no mention" \
  bash -c "[ $(request_count) -eq 1 ] && [ \"\$(jq -r '.body | fromjson | has(\"mentions\")' <(head -n 1 '${_work}/requests.jsonl'))\" = false ]"
teardown

# ----------------------------------------------------------------------
# P12 — a refused token says what to check; the platform's 401 has no body
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 401, "body": ""}]'
run_step
assert "P12: 401 without a body: not retried, the audience named" \
  bash -c "[ $(request_count) -eq 1 ] && grep -qxF '::warning title=Teams notification not sent::tf-alerts — HTTP 401: the relay did not accept the token; is bot-audience (api://00000000-0000-0000-0000-000000000000) its API?' '${OUT_FILE}'"
teardown

setup
start_relay '[{"status": 403, "body": ""}]'
run_step
assert "P12: 403 without a body: the role named" \
  grep -qxF '::warning title=Teams notification not sent::tf-alerts — HTTP 403: the sender lacks the relay API'"'"'s Notifications.Send app role' "${OUT_FILE}"
teardown

# ----------------------------------------------------------------------
# P11 — an accepted answer without a messageId is still accepted, with no ID
# ----------------------------------------------------------------------
setup
start_relay '[{"status": 202, "body": "not json"}]'
run_step
assert "P11: accepted, no message-id" bash -c "[ '$(get_output accepted)' = true ] && [ -z '$(get_output message-id)' ]"
teardown

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
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
