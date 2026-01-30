#!/usr/bin/env bash
_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export GITHUB_WORKSPACE="${_this_script_dir}/.."

# Enable automatic export of all variables
set -o allexport

# Required system variables
GITHUB_ACTION_PATH="${_this_script_dir}"
GITHUB_RUN_ID="12345678"
GITHUB_RUN_NUMBER="42"
GITHUB_RUN_ATTEMPT="1"
GITHUB_WORKFLOW="Terraform CI/CD"
GITHUB_JOB="terraform-ci-cd"
GITHUB_ACTOR="test-user"
GITHUB_EVENT_NAME="pull_request"
GITHUB_REF="refs/pull/123/merge"
GITHUB_SHA="abc123def456"

# Required input variables
input_environment_name="sandbox"

# Matrix vars JSON (example)
input_matrix_vars_json=$(cat <<'EOF'
{
  "github-environment": "sandbox",
  "project-dir": "./envs/sandbox",
  "goals": ["all"],
  "runs-on": "ubuntu-latest",
  "terraform-version": "latest",
  "tflint-version": "latest",
  "add-pr-comment": "true",
  "allow-failing-terraform-operations": "false"
}
EOF
)

# GitHub context JSON (example - filtered)
input_github_context_json=$(cat <<'EOF'
{
  "repository": "dsb-norge/example-repo",
  "event_name": "pull_request",
  "ref": "refs/pull/123/merge",
  "sha": "abc123def456"
}
EOF
)

# Step outcomes and results
input_step_init_outcome="success"
input_step_init_result="success"
input_step_fmt_outcome="success"
input_step_fmt_result="success"
input_step_validate_outcome="success"
input_step_validate_result="success"
input_step_lint_outcome="success"
input_step_lint_result="success"
input_step_plan_outcome="success"
input_step_plan_result="success"
input_step_parse_plan_outcome="success"
input_step_parse_plan_result="success"
input_step_apply_outcome="skipped"
input_step_apply_result="skipped"
input_step_destroy_plan_outcome="skipped"
input_step_destroy_plan_result="skipped"
input_step_parse_destroy_plan_outcome="skipped"
input_step_parse_destroy_plan_result="skipped"
input_step_destroy_outcome="skipped"
input_step_destroy_result="skipped"
input_step_evaluate_automerge_outcome="success"
input_step_evaluate_automerge_result="success"
input_step_create_validation_summary_outcome="success"
input_step_create_validation_summary_result="success"

# Step outputs JSON
input_step_init_outputs_json='{}'
input_step_fmt_outputs_json='{"stdout": "All files formatted correctly"}'
input_step_validate_outputs_json='{"stdout": "Success! The configuration is valid."}'
input_step_lint_outputs_json='{}'
input_step_plan_outputs_json=$(cat <<'EOF'
{
  "console-output-file": "/tmp/plan-console.txt",
  "txt-output-file": "/tmp/plan.txt",
  "terraform-plan-file": "/tmp/plan.tfplan"
}
EOF
)
input_step_parse_plan_outputs_json=$(cat <<'EOF'
{
  "count-add": "2",
  "count-change": "1",
  "count-destroy": "0",
  "count-import": "0",
  "count-move": "0",
  "count-remove": "0"
}
EOF
)
input_step_apply_outputs_json='{}'
input_step_destroy_plan_outputs_json='{}'
input_step_parse_destroy_plan_outputs_json='{}'
input_step_destroy_outputs_json='{}'
input_step_evaluate_automerge_outputs_json=$(cat <<'EOF'
{
  "is-eligible": "true",
  "result-json-file": "/tmp/automerge-result.json"
}
EOF
)
input_step_create_validation_summary_outputs_json=$(cat <<'EOF'
{
  "summary": "## Terraform Validation Summary\n...",
  "prefix": "<!-- terraform-validation-sandbox -->"
}
EOF
)
input_step_setup_terraform_cache_outputs_json=$(cat <<'EOF'
{
  "plugin-cache-directory": "/home/runner/.terraform.d/plugin-cache"
}
EOF
)
input_step_setup_tflint_outputs_json='{}'

# Source the script (variables are already exported due to allexport)
source "${_this_script_dir}/step_capture.sh"
set +o allexport

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
