#!/bin/env bash
#
# Local testing/debugging script for step_summary.sh
# Simulates GitHub Actions environment for testing locally.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/step-summary.md"
export GITHUB_SERVER_URL="https://github.com"
export GITHUB_REPOSITORY="example/repo"
export GITHUB_RUN_ID="12345678"

cd "${RUNNER_TEMP}"
cat > matrix-job-meta-dev.json <<'EOF'
{"metadata":{"environment":"dev"},"workflow":{"run_id":"12345678"},
 "steps":{"init":{"outcome":"success","outputs":{}},"plan":{"outcome":"success","outputs":{"plan-time":"0:04"}},
          "parse-plan":{"outcome":"success","outputs":{"count-add":"1","count-change":"0","count-destroy":"0"}},
          "apply":{"outcome":"success","outputs":{"apply-time":"1:07"}},
          "parse-apply":{"outcome":"success","outputs":{"count-add":"1","count-change":"0","count-destroy":"0","completed":"true"}}}}
EOF
cat > matrix-job-meta-prod.json <<'EOF'
{"metadata":{"environment":"prod"},"workflow":{"run_id":"12345678"},
 "steps":{"init":{"outcome":"success","outputs":{}},"plan":{"outcome":"failure","outputs":{"plan-time":"9:49"}}}}
EOF
export input_metadata_files_pattern="matrix-job-meta-*.json"
# Relevance: 'staging' was not affected by the change. Unset to see the
# rendering without relevance.
cat > relevance.json <<'EOF'
{"schema_version":1,"relevance":{"mode":"diff","reason":"diff","changed_count":2},
 "counts":{"affected":2,"unaffected":1},
 "environments":[
   {"environment":"dev","github-environment":"dev","verdict":"run","reasons":["relevance: envs/dev/**"]},
   {"environment":"staging","github-environment":"staging","verdict":"skip","reasons":["relevance: no changed file matches"]},
   {"environment":"prod","github-environment":"prod","verdict":"run","reasons":["relevance: modules/**"]}],
 "comments":{},"notices":[],"record":[]}
EOF
export input_relevance_file="${RUNNER_TEMP}/relevance.json"

(
  set -o allexport
  source "${_this_script_dir}/step_summary.sh"
)
echo ""
echo "step exit code: ${?}"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
echo ""
echo "========================================"
echo "GITHUB_STEP_SUMMARY:"
echo "========================================"
cat "${GITHUB_STEP_SUMMARY}"
