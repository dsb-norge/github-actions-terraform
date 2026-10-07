#!/bin/env bash
#
# Source for the post step.
#
# Posts one markdown text message to the Teams notification relay
# (POST <bot-url>/v1/notify/<alias>) as the identity az is logged in with, and
# reports what the relay answered. docs/Notifications.md §11.
#
# Never fails the job: a notification that cannot be sent is a ::warning and
# accepted=false, and the caller decides what that means.
#
# 429, 5xx and no answer are retried up to three times, after Retry-After or
# 1, 2 and 4 seconds. Every request is counted at its full timeout against a
# budget of 180 seconds, so the step ends within the budget whatever the relay
# does. Any other 4xx is not retried: the same request gets the same answer.
#
# Required environment variables:
#   input_bot_url          - the relay's API base, https://…/api
#   input_bot_audience     - the relay API's application ID URI; the token is for it
#   input_alias            - the alias to post to
#   input_message_file     - path of the markdown text to post
#
# Optional environment variables:
#   input_reply_to         - messageId to reply to, in its thread
#   input_update           - messageId to replace
#   input_idempotency_key  - Idempotency-Key; the relay answers a repeat with its first answer
#   input_dry_run          - 'true': print the request, send nothing, ask for no token
#
# Outputs:
#   message-id   - the relay's messageId when it accepted the message
#   http-status  - the relay's last status, '000' when there was no answer
#   accepted     - 'true' when the relay queued the message (not: delivered it)
#

set +o nounset

# Load helpers (provides the escape-* helpers)
source "${GITHUB_ACTION_PATH}/helpers.sh"

_budget_seconds=180
_max_time_seconds=30
_retries=3

# The tests define their own, to record the waits instead of waiting them.
if ! declare -F _post_teams_notification_sleep >/dev/null; then
  function _post_teams_notification_sleep { sleep "${1}"; }
fi

_message_id=""
_http_status="000"
_accepted="false"

function not_sent {
  echo "::warning title=$(escape-annotation-property "Teams notification not sent")::$(escape-annotation-message "${input_alias:-no alias} — ${1}")"
}

function validate {
  if [ -z "${input_bot_url:-}" ] || [ -z "${input_bot_audience:-}" ] || [ -z "${input_alias:-}" ]; then
    not_sent "bot-url, bot-audience and alias are all required"
    return 1
  fi
  # The relay's own rule for alias names. The alias is a path segment of the
  # URL, so anything else could address another route.
  if ! [[ "${input_alias}" =~ ^[a-z0-9][a-z0-9-]{0,48}[a-z0-9]$ ]]; then
    not_sent "not an alias: 2 to 50 of a-z 0-9 -, starting and ending with a letter or a digit"
    return 1
  fi
  if [ -n "${input_reply_to:-}" ] && [ -n "${input_update:-}" ]; then
    not_sent "reply-to and update cannot both be set; the relay takes one or the other"
    return 1
  fi
  # A header value: a line break in it would start a header of its own.
  if [ -n "${input_idempotency_key:-}" ] && ! [[ "${input_idempotency_key}" =~ ^[[:graph:]]{1,256}$ ]]; then
    not_sent "the idempotency key is not 1 to 256 printable characters without spaces"
    return 1
  fi
  if ! [ -f "${input_message_file:-}" ] || ! [ -r "${input_message_file}" ]; then
    not_sent "the message file ${input_message_file:-<unset>} cannot be read"
    return 1
  fi
  if ! [ -s "${input_message_file}" ]; then
    not_sent "the message file ${input_message_file} is empty"
    return 1
  fi
  return 0
}

# The request body, from the file: the text is never held in a variable, which
# allexport would put in the environment of every process the step starts.
function build_body {
  jq -n --rawfile message "${input_message_file}" \
    --arg reply_to "${input_reply_to:-}" --arg update "${input_update:-}" \
    '{format: "text", message: $message}
     + (if $reply_to != "" then {replyTo: $reply_to} else {} end)
     + (if $update != "" then {update: $update} else {} end)' >"${1}"
}

# The token goes from az into a header file in the step's 0700 work directory
# and nowhere else: not a variable (allexport exports it) and not an argument
# (argv is readable by every user in /proc).
function get_token {
  local work="${1}"
  if ! az account get-access-token --resource "${input_bot_audience}" --query accessToken -o tsv \
    >"${work}/token" 2>"${work}/az-error"; then
    local first_line
    first_line="$(head -n 1 "${work}/az-error")"
    not_sent "no token for ${input_bot_audience}: ${first_line:-az failed without a message}"
    return 1
  fi
  {
    printf 'Authorization: Bearer '
    tr -d '\r\n' <"${work}/token"
    printf '\n'
  } >"${work}/auth-header"
  rm -f "${work}/token"
  return 0
}

# Retry-After in seconds, or nothing. The HTTP-date form is not used by the
# relay, and is ignored.
function retry_after {
  local value
  value="$(awk -F': *' 'tolower($1) == "retry-after" { v = $2 } END { gsub(/\r/, "", v); print v }' "${1}" 2>/dev/null || true)"
  if [[ "${value}" =~ ^[0-9]{1,6}$ ]]; then printf '%s' "$((10#${value}))"; fi
  return 0
}

# What a refused request says: the relay's problem detail, or, for the bare
# 401 its platform authentication answers with, what to check.
function refusal {
  local status="${1}" response="${2}" detail
  detail="$(jq -r 'if type == "object" then (.detail // .title // "") | tostring | .[0:300] else "" end' \
    "${response}" 2>/dev/null || true)"
  if [ -z "${detail}" ] && [ "${status}" = '401' ]; then
    detail="the relay did not accept the token; is bot-audience (${input_bot_audience}) its API?"
  elif [ -z "${detail}" ] && [ "${status}" = '403' ]; then
    detail="the sender lacks the relay API's Notifications.Send app role"
  fi
  printf '%s' "HTTP ${status}${detail:+: ${detail}}"
}

function post {
  local url="${1}" work="${2}"
  local -a idempotency=()
  if [ -n "${input_idempotency_key:-}" ]; then
    idempotency=(--header "Idempotency-Key: ${input_idempotency_key}")
  fi

  local attempt=0 waited=0 delay status what
  while true; do
    attempt=$((attempt + 1))
    rm -f "${work}/response" "${work}/headers"
    status="$(curl --silent --show-error --max-time "${_max_time_seconds}" --connect-timeout 10 \
      --output "${work}/response" --dump-header "${work}/headers" --write-out '%{http_code}' \
      --request POST --header @"${work}/auth-header" --header 'Content-Type: application/json' \
      "${idempotency[@]}" --data-binary @"${work}/body.json" "${url}" 2>"${work}/curl-error" || true)"
    [[ "${status}" =~ ^[0-9]{3}$ ]] || status='000'
    _http_status="${status}"

    case "${status}" in
      2??)
        _accepted='true'
        _message_id="$(jq -r 'if type == "object" then .messageId // "" else "" end' \
          "${work}/response" 2>/dev/null || true)"
        # It becomes an output line: nothing but an ID may pass.
        [[ "${_message_id}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || _message_id=""
        log-info "attempt ${attempt}: HTTP ${status}, accepted as ${_message_id:-a message without an ID}"
        return 0
        ;;
      429 | 5?? | 000) ;;
      *)
        log-info "attempt ${attempt}: HTTP ${status}"
        not_sent "$(refusal "${status}" "${work}/response")"
        return 0
        ;;
    esac

    if [ "${status}" = '000' ]; then
      what="no answer from the relay"
      log-info "attempt ${attempt}: no answer: $(head -n 1 "${work}/curl-error")"
    else
      what="HTTP ${status}"
      log-info "attempt ${attempt}: HTTP ${status}"
    fi
    local attempts="${attempt} attempts"
    [ "${attempt}" -eq 1 ] && attempts="1 attempt"

    if [ "${attempt}" -gt "${_retries}" ]; then
      not_sent "${what} after ${attempts}"
      return 0
    fi
    delay="$(retry_after "${work}/headers")"
    [ -n "${delay}" ] || delay=$((1 << (attempt - 1)))
    # The wait, and the request after it at its full timeout, must fit.
    if [ $((waited + delay + (attempt + 1) * _max_time_seconds)) -gt "${_budget_seconds}" ]; then
      not_sent "${what} after ${attempts}; the retry budget is spent"
      return 0
    fi
    log-info "retrying in ${delay}s ..."
    _post_teams_notification_sleep "${delay}"
    waited=$((waited + delay))
  done
}

function main {
  log-info "posting to alias '${input_alias:-}' ..."

  if validate; then
    local work url
    work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/post-teams-notification.XXXXXX")"
    url="${input_bot_url%/}/v1/notify/${input_alias}"
    if ! build_body "${work}/body.json"; then
      not_sent "the message file ${input_message_file} could not be encoded"
    elif [ "${input_dry_run:-false}" = 'true' ]; then
      log-info "dry run: would POST to ${url}"
      start-group "dry run: the request body"
      jq . "${work}/body.json"
      end-group
    elif get_token "${work}"; then
      post "${url}" "${work}"
    fi
    rm -rf "${work}"
  fi

  set-output message-id "${_message_id}"
  set-output http-status "${_http_status}"
  set-output accepted "${_accepted}"
  log-info "post completed: accepted=${_accepted}, http-status=${_http_status}."
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
