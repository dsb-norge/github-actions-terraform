#!/bin/env bash
#
# Local testing/debugging script for step_capture.sh
# Simulates GitHub Actions environment for testing the capture logic locally.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_RUN_ID="12345678"
export GITHUB_RUN_NUMBER="42"
export GITHUB_RUN_ATTEMPT="1"
export GITHUB_WORKFLOW="Terraform CI/CD"
export GITHUB_JOB="terraform-ci-cd"
export GITHUB_ACTOR="test-user"
export GITHUB_EVENT_NAME="pull_request"
export GITHUB_REF="refs/pull/123/merge"
export GITHUB_SHA="abc123def456"

# Required input variables
export input_environment_name="sandbox"

# Matrix context JSON (example - full matrix context with nested vars)
export input_matrix_context_json='{
  "environment": "sandbox",
  "vars": {
    "github-environment": "sandbox",
    "project-dir": "./envs/sandbox",
    "goals": ["all"],
    "runs-on": "ubuntu-latest",
    "terraform-version": "latest",
    "tflint-version": "latest",
    "add-pr-comment": "true",
    "allow-failing-terraform-operations": false
  }
}'

# GitHub context JSON (example - filtered)
export input_github_context_json='{"repository":"dsb-norge/example-repo","event_name":"pull_request","ref":"refs/pull/123/merge","sha":"abc123def456"}'

# Steps context JSON - simulates ${{ toJSON(steps) }} from GitHub Actions
export input_steps_context_json='{
  "setup-terraform-cache": {
    "outputs": {"plugin-cache-directory": "/home/runner/.terraform.d/plugin-cache", "plugin-cache-key-monthly-rolling": "terraform-provider-plugin-cache-linux-x64-Jan-26"},
    "outcome": "success",
    "conclusion": "success"
  },
  "setup-tflint": {
    "outputs": {"installed-version": "v0.59.1", "bin-path": "/opt/hostedtoolcache/tflint_v0.59.1/tflint"},
    "outcome": "success",
    "conclusion": "success"
  },
  "init": {
    "outputs": {},
    "outcome": "success",
    "conclusion": "success"
  },
  "fmt": {
    "outputs": {},
    "outcome": "success",
    "conclusion": "success"
  },
  "validate": {
    "outputs": {},
    "outcome": "success",
    "conclusion": "success"
  },
  "lint": {
    "outputs": {},
    "outcome": "success",
    "conclusion": "success"
  },
  "plan": {
    "outputs": {"exitcode": "0", "console-output-file": "/tmp/plan-console.txt", "terraform-plan-file": "/tmp/plan.tfplan", "txt-output-file": "/tmp/plan.txt"},
    "outcome": "success",
    "conclusion": "success"
  },
  "parse-plan": {
    "outputs": {"count-add": "2", "count-change": "1", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"},
    "outcome": "success",
    "conclusion": "success"
  },
  "create-validation-summary": {
    "outputs": {"prefix": "### Terraform validation summary", "summary": "validation passed", "can-automerge": "true"},
    "outcome": "success",
    "conclusion": "success"
  },
  "apply": {
    "outputs": {},
    "outcome": "skipped",
    "conclusion": "skipped"
  },
  "destroy-plan": {
    "outputs": {},
    "outcome": "skipped",
    "conclusion": "skipped"
  },
  "destroy": {
    "outputs": {},
    "outcome": "skipped",
    "conclusion": "skipped"
  },
  "evaluate-automerge": {
    "outputs": {"is-eligible": "true", "result-json-file": "/tmp/automerge-result.json"},
    "outcome": "success",
    "conclusion": "success"
  },
  "upload-automerge-evaluation": {
    "outputs": {"artifact-id": "123456789"},
    "outcome": "success",
    "conclusion": "success"
  }
}'

# Source the main script
source "${_this_script_dir}/step_capture.sh"

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
