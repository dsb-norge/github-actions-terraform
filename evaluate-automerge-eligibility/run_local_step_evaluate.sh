#!/bin/env bash
#
# Script to run step_evaluate.sh locally for testing
# Creates test metadata files and runs the evaluation
#
_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
# Create a temporary file for outputs
export GITHUB_OUTPUT=$(mktemp)

# Create a temporary directory for test metadata files
TEST_DIR=$(mktemp -d)
echo "Using test directory: ${TEST_DIR}"
cd "${TEST_DIR}"

# Required system variables
GITHUB_ACTION_PATH="${_this_script_dir}"
# GITHUB_ACTOR="dependabot[bot]"
GITHUB_ACTOR="a-random-user"

# New input model - just the pattern for metadata files
input_metadata_files_pattern="matrix-job-meta-*.json"

# Create test metadata file(s)
# This simulates what capture-matrix-job-meta would produce

cat > matrix-job-meta-sandbox.json << 'EOF'
{
  "metadata": {
    "environment": "sandbox",
    "captured_at": "2026-01-30T12:28:54Z",
    "schema_version": "2.0.0"
  },
  "workflow": {
    "run_id": "21494130907",
    "run_number": "102",
    "run_attempt": "8",
    "workflow_name": "Terraform CI/CD",
    "job_name": "terraform-ci-cd",
    "actor": "a-random-user",
    "event_name": "pull_request",
    "ref": "refs/pull/60/merge",
    "sha": "03b530372841a10494f3d0cf838598a4eacee798"
  },
  "matrix_context": {
    "environment": "sandbox",
    "vars": {
      "environment": "sandbox",
      "pr-auto-merge-enabled": true,
      "goals": ["all"],
      "pr-auto-merge-from-actors": ["dependabot[bot]", "a-random-user"],
      "pr-auto-merge-limits": {
        "plan-max-count-add": 0,
        "plan-max-count-change": -1,
        "plan-max-count-destroy": 0,
        "plan-max-count-import": 10000,
        "plan-max-count-move": 10000,
        "plan-max-count-remove": -1
      }
    }
  },
  "github_context": {
    "actor": "a-random-user"
  },
  "steps": {
    "plan": {
      "outcome": "success",
      "conclusion": "success",
      "outputs": {}
    },
    "parse-plan": {
      "outcome": "success",
      "conclusion": "success",
      "outputs": {
        "count-add": "0",
        "count-change": "0",
        "count-destroy": "0",
        "count-import": "0",
        "count-move": "0",
        "count-remove": "0"
      }
    },
    "apply": {
      "outcome": "skipped",
      "conclusion": "skipped",
      "outputs": {}
    },
    "destroy-plan": {
      "outcome": "skipped",
      "conclusion": "skipped",
      "outputs": {}
    },
    "parse-destroy-plan": {
      "outcome": "skipped",
      "conclusion": "skipped",
      "outputs": {}
    },
    "destroy": {
      "outcome": "skipped",
      "conclusion": "skipped",
      "outputs": {}
    }
  }
}
EOF

echo ""
echo "Created test metadata file: matrix-job-meta-sandbox.json"
echo ""

# Run the step
set -o allexport
source "${_this_script_dir}/step_evaluate.sh"
set +o allexport

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"

# Cleanup
rm -rf "${TEST_DIR}"
