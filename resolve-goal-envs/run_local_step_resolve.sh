#!/bin/env bash
#
# Local testing/debugging script for step_resolve.sh.
# Simulates GitHub Actions environment.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}/workspace"
mkdir -p "${GITHUB_WORKSPACE}"

# The shim writes toJSON(secrets) to a file before allexport and exports only
# the path — mirror that here.
export input_secrets_file="$(mktemp "${RUNNER_TEMP}/secrets-bag-XXXXXXXX.json")"
chmod 0600 "${input_secrets_file}"
cat >"${input_secrets_file}" <<'EOF'
{
  "AZURE_TENANT_ID": "11111111-1111-1111-1111-111111111111",
  "AZURE_PLAN_READER_CLIENT_ID": "22222222-2222-2222-2222-222222222222",
  "AZURE_APPLY_CONTRIBUTOR_CLIENT_ID": "33333333-3333-3333-3333-333333333333",
  "TF_CICD_APP_PRIVATE_KEY": "-----BEGIN RSA PRIVATE KEY-----\nnot-a-real-key\n-----END RSA PRIVATE KEY-----\n"
}
EOF

export input_extra_envs='{
  "ARM_USE_OIDC": true,
  "GOGC": 50,
  "GOMEMLIMIT": "6GiB"
}'

export input_extra_envs_from_secrets='{
  "ARM_TENANT_ID": "AZURE_TENANT_ID",
  "ARM_CLIENT_ID": "AZURE_PLAN_READER_CLIENT_ID"
}'

export input_extra_envs_per_goal='{
  "init": {},
  "format": {},
  "validate": {},
  "lint": { "GOGC": 400 },
  "plan": { "GOMEMLIMIT": "12GiB", "GOGC": 25 },
  "apply": { "GOMEMLIMIT": null },
  "destroy-plan": {},
  "destroy": {}
}'

export input_extra_envs_from_secrets_per_goal='{
  "init": {},
  "format": {},
  "validate": {},
  "lint": {},
  "plan": {},
  "apply": { "ARM_CLIENT_ID": "AZURE_APPLY_CONTRIBUTOR_CLIENT_ID" },
  "destroy-plan": {},
  "destroy": {}
}'

# Subshell: step_resolve.sh ends in 'exit', which would otherwise terminate
# this script before it gets to show what was produced.
( source "${_this_script_dir}/step_resolve.sh" )
echo ""
echo "step exit code: ${?}"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"

envs_dir=$(grep '^envs-dir=' "${GITHUB_OUTPUT}" | cut -d= -f2-)
echo ""
echo "========================================"
echo "Resolved files in ${envs_dir}"
echo "========================================"
ls -l "${envs_dir}"
for f in "${envs_dir}"/*.json; do
  echo ""
  echo "--- $(basename "${f}")"
  cat "${f}"
  echo ""
done
