#!/bin/env bash
#
# Local testing/debugging script for step_export_envs.sh
# Simulates GitHub Actions environment for testing locally.
#
# Prints the resulting $GITHUB_ENV file, which is the step's only output.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_ENV like GitHub Actions does
export GITHUB_ENV=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

# Inputs. The action.yml shim captures them as shell-locals, never exported;
# mirror that here.
input_extra_envs='{
  "ARM_USE_OIDC": "true",
  "TF_IN_AUTOMATION": "1"
}'

input_extra_envs_from_secrets='{
  "ARM_TENANT_ID": "AZURE_TENANT_ID",
  "ARM_CLIENT_ID": "AZURE_CLIENT_ID"
}'

input_secrets_json='{
  "AZURE_TENANT_ID": "11111111-1111-1111-1111-111111111111",
  "AZURE_CLIENT_ID": "22222222-2222-2222-2222-222222222222",
  "github_token": "ghs_not-a-real-token"
}'

# Source the main script in a subshell so 'exit' doesn't terminate this
# runner, under the shell flags the runner uses.
(
  set -eo pipefail
  source "${_this_script_dir}/step_export_envs.sh"
)
echo "step exit code: $?"

# Display the exported environment
echo ""
echo "========================================"
echo "Exported environment (GITHUB_ENV):"
echo "========================================"
cat "${GITHUB_ENV}"
