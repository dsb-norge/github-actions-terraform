#!/bin/env bash
#
# Local testing/debugging script for step_post.sh
# Simulates GitHub Actions environment for testing locally.
#
# A dry run by default: prints the request and sends nothing. To post for real,
# log in with az as an identity holding the relay's Notifications.Send role and
# set the target:
#   BOT_URL=https://<relay>/api BOT_AUDIENCE=api://<id> ALIAS=<alias> DRY_RUN=false \
#     bash post-teams-notification/run_local_step_post.sh
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"

cat >"${RUNNER_TEMP}/message.md" <<'EOF'
**❌ Apply failed** in `sandbox` of example/repo

The apply step failed after merging [#1 Add a storage account](https://github.com/example/repo/pull/1).

[Open run](https://github.com/example/repo/actions/runs/1)
EOF

export input_bot_url="${BOT_URL:-https://relay.example.invalid/api}"
export input_bot_audience="${BOT_AUDIENCE:-api://00000000-0000-0000-0000-000000000000}"
export input_alias="${ALIAS:-tf-alerts}"
export input_message_file="${RUNNER_TEMP}/message.md"
export input_reply_to="${REPLY_TO:-}"
export input_update="${UPDATE:-}"
export input_idempotency_key="local-$(date +%s)"
export input_dry_run="${DRY_RUN:-true}"

(
  set -o allexport
  source "${_this_script_dir}/step_post.sh"
)
echo ""
echo "step exit code: ${?}"

echo ""
echo "========================================"
echo "GITHUB_OUTPUT:"
echo "========================================"
cat "${GITHUB_OUTPUT}"
rm -rf "${GITHUB_OUTPUT}" "${RUNNER_TEMP}"
