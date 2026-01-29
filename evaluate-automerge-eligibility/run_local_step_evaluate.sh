#!/bin/env bash
_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
# Create a temporary file for outputs
export GITHUB_OUTPUT=$(mktemp)

# required system variables
GITHUB_ACTION_PATH="${_this_script_dir}"
GITHUB_ACTOR="renovat"

# required input variables
input_environment_name=sandbox
input_plan_shouldve_been_created=true
input_plan_was_created=true
input_performing_apply_on_pr=false
input_apply_on_pr_succeeded=false
input_plan_count_add=0
input_plan_count_change=0
input_plan_count_destroy=0
input_plan_count_import=0
input_plan_count_move=0
input_plan_count_remove=100000
input_destroy_plan_shouldve_been_created=false
input_destroy_plan_was_created=false
input_performing_destroy_on_pr=false
input_destroy_on_pr_succeeded=false
input_destroy_plan_count_add=0
input_destroy_plan_count_change=0
input_destroy_plan_count_destroy=0
input_destroy_plan_count_import=0
input_destroy_plan_count_move=0
input_destroy_plan_count_remove=0

# required input json variables
input_pr_auto_merge_limits_json=$(
  cat <<'EOF'
{
  "plan-max-count-add": 0,
  "plan-max-count-change": -1,
  "plan-max-count-destroy": 0,
  "plan-max-count-import": 10000,
  "plan-max-count-move": 10000,
  "plan-max-count-remove": -1
}
EOF
)
input_pr_auto_merge_from_actors_json=$(
  cat <<'EOF'
[
  "dependabot[bot]",
  "Laffs2k5"
]
EOF
)

set -o allexport
source "${_this_script_dir}/step_evaluate.sh"
set +o allexport

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
