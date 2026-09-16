#!/bin/env bash
#
# Local testing/debugging script for step_annotate.sh
# Simulates GitHub Actions environment for testing locally.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/step-summary.md"

# A rendered block as create-validation-summary would write it.
cat >"${RUNNER_TEMP}/tf-comment-sandbox-step-summary.md" <<'EOF'
### Terraform validation summary for environment: `sandbox`
|  | Step | Result |
|:---:|---|---|
| <span title="Plan">📖</span> | Plan | `success` |
| <span title="Apply">🐙</span> | Apply | `success` |

[Job log](https://github.com/example/repo/actions/runs/1/job/2#logs)
EOF

export input_environment_name="sandbox"
export input_step_summary_file="${RUNNER_TEMP}/tf-comment-sandbox-step-summary.md"
export input_status_apply="success"
export input_apply_count_add="3"
export input_apply_count_change="1"
export input_apply_count_destroy="0"
export input_apply_time="1:07"
export input_status_destroy=""

(
  set -o allexport
  source "${_this_script_dir}/step_annotate.sh"
)
echo ""
echo "step exit code: ${?}"

echo ""
echo "========================================"
echo "GITHUB_STEP_SUMMARY:"
echo "========================================"
cat "${GITHUB_STEP_SUMMARY}"
