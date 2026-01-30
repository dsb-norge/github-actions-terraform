# Implementation Plan: `capture-terraform-ci-cd-meta` GitHub Action

## Overview

This document outlines the implementation plan for a new GitHub Action called `capture-terraform-ci-cd-meta`. The action will gather comprehensive metadata from all steps in the `terraform-ci-cd` job within the `terraform-ci-cd-default.yml` workflow and save it as an artifact for later analysis, debugging, or integration purposes.

## Goal

Capture all relevant information from the `terraform-ci-cd` job (which runs per environment in a matrix) into a JSON file named `terraform-ci-cd-meta-${environment_name}.json` and upload it as an artifact. This includes:

- All step outputs (as JSON)
- Step outcomes and results
- Matrix variables (`matrix.vars`)
- Workflow/job context information
- **Best effort collection**: gather as much as possible without failing on missing info

## Design Decisions

### 1. Input Pattern: `toJSON()` Bulk Passing

Following the pattern from `create-tf-vars-matrix` action (line 280-285 of workflow), all step outputs will be passed as JSON objects rather than individual named outputs. This approach:

- Reduces boilerplate in the action.yml
- Makes it easier to add new steps without modifying the action
- Allows graceful handling of missing/empty outputs

Example usage pattern:
```yaml
with:
  step-init-outputs-json: ${{ toJSON(steps.init.outputs) }}
  step-init-outcome: ${{ steps.init.outcome }}
  step-init-result: ${{ steps.init.result || '' }}
```

### 2. Best Effort Collection

The action will:
- Use `continue-on-error: true` in the workflow
- Run with `if: always()` to capture data even when previous steps fail
- Handle missing/null/empty values gracefully in the script
- Never fail due to missing step outputs

### 3. File Structure (Mirroring `evaluate-automerge-eligibility`)

```
capture-terraform-ci-cd-meta/
├── action.yml                      # Action definition, wrapper for bash script
├── helpers.sh                      # Standard helper functions (copied from evaluate-automerge-eligibility)
├── step_capture.sh                 # Main capture logic script
├── run_local_step_capture.sh       # Local debugging/testing script
└── run_all_tests.sh                # Comprehensive test runner
```

---

## Detailed Implementation

### Phase 1: Create Action Directory and Files

#### 1.1 Create `capture-terraform-ci-cd-meta/action.yml`

```yaml
name: "Capture Terraform CI/CD Metadata"
description: |
  Captures comprehensive metadata from all steps in the terraform-ci-cd job.
  Gathers step outputs, outcomes, results, and matrix variables into a single
  JSON file for artifact upload and later analysis.

  ## Behavior Notes

  - Runs with best-effort collection: missing data will not cause failure
  - Handles null/empty values gracefully
  - Designed to run with if: always() to capture data even on job failure
  - Excludes secret values from output

author: "Peder Schmedling"
inputs:
  environment-name:
    description: |
      Name of the current deployment environment (e.g., "sandbox", "production").
      Used for naming the output JSON file.
    required: true

  # Matrix variables
  matrix-vars-json:
    description: |
      JSON object containing all matrix.vars values.
      Pass as: ${{ toJSON(matrix.vars) }}
    required: true

  # GitHub context
  github-context-json:
    description: |
      JSON object containing github context (filtered for non-sensitive data).
      Pass as: ${{ toJSON(github) }}
    required: true

  # Step outcomes and results (outcome = before continue-on-error, result = after)
  step-init-outcome:
    description: "Outcome of terraform init step"
    required: false
    default: ""
  step-init-result:
    description: "Result of terraform init step"
    required: false
    default: ""
  step-fmt-outcome:
    description: "Outcome of terraform fmt step"
    required: false
    default: ""
  step-fmt-result:
    description: "Result of terraform fmt step"
    required: false
    default: ""
  step-validate-outcome:
    description: "Outcome of terraform validate step"
    required: false
    default: ""
  step-validate-result:
    description: "Result of terraform validate step"
    required: false
    default: ""
  step-lint-outcome:
    description: "Outcome of tflint step"
    required: false
    default: ""
  step-lint-result:
    description: "Result of tflint step"
    required: false
    default: ""
  step-plan-outcome:
    description: "Outcome of terraform plan step"
    required: false
    default: ""
  step-plan-result:
    description: "Result of terraform plan step"
    required: false
    default: ""
  step-parse-plan-outcome:
    description: "Outcome of parse terraform plan step"
    required: false
    default: ""
  step-parse-plan-result:
    description: "Result of parse terraform plan step"
    required: false
    default: ""
  step-apply-outcome:
    description: "Outcome of terraform apply step"
    required: false
    default: ""
  step-apply-result:
    description: "Result of terraform apply step"
    required: false
    default: ""
  step-destroy-plan-outcome:
    description: "Outcome of terraform destroy plan step"
    required: false
    default: ""
  step-destroy-plan-result:
    description: "Result of terraform destroy plan step"
    required: false
    default: ""
  step-parse-destroy-plan-outcome:
    description: "Outcome of parse destroy plan step"
    required: false
    default: ""
  step-parse-destroy-plan-result:
    description: "Result of parse destroy plan step"
    required: false
    default: ""
  step-destroy-outcome:
    description: "Outcome of terraform destroy step"
    required: false
    default: ""
  step-destroy-result:
    description: "Result of terraform destroy step"
    required: false
    default: ""
  step-evaluate-automerge-outcome:
    description: "Outcome of evaluate automerge step"
    required: false
    default: ""
  step-evaluate-automerge-result:
    description: "Result of evaluate automerge step"
    required: false
    default: ""
  step-create-validation-summary-outcome:
    description: "Outcome of create validation summary step"
    required: false
    default: ""
  step-create-validation-summary-result:
    description: "Result of create validation summary step"
    required: false
    default: ""

  # Step outputs as JSON objects
  step-init-outputs-json:
    description: |
      JSON object containing init step outputs.
      Pass as: ${{ toJSON(steps.init.outputs) }}
    required: false
    default: "{}"
  step-fmt-outputs-json:
    description: |
      JSON object containing fmt step outputs.
      Pass as: ${{ toJSON(steps.fmt.outputs) }}
    required: false
    default: "{}"
  step-validate-outputs-json:
    description: |
      JSON object containing validate step outputs.
      Pass as: ${{ toJSON(steps.validate.outputs) }}
    required: false
    default: "{}"
  step-lint-outputs-json:
    description: |
      JSON object containing lint step outputs.
      Pass as: ${{ toJSON(steps.lint.outputs) }}
    required: false
    default: "{}"
  step-plan-outputs-json:
    description: |
      JSON object containing plan step outputs.
      Pass as: ${{ toJSON(steps.plan.outputs) }}
    required: false
    default: "{}"
  step-parse-plan-outputs-json:
    description: |
      JSON object containing parse-plan step outputs.
      Pass as: ${{ toJSON(steps.parse-plan.outputs) }}
    required: false
    default: "{}"
  step-apply-outputs-json:
    description: |
      JSON object containing apply step outputs.
      Pass as: ${{ toJSON(steps.apply.outputs) }}
    required: false
    default: "{}"
  step-destroy-plan-outputs-json:
    description: |
      JSON object containing destroy-plan step outputs.
      Pass as: ${{ toJSON(steps.destroy-plan.outputs) }}
    required: false
    default: "{}"
  step-parse-destroy-plan-outputs-json:
    description: |
      JSON object containing parse-destroy-plan step outputs.
      Pass as: ${{ toJSON(steps.parse-destroy-plan.outputs) }}
    required: false
    default: "{}"
  step-destroy-outputs-json:
    description: |
      JSON object containing destroy step outputs.
      Pass as: ${{ toJSON(steps.destroy.outputs) }}
    required: false
    default: "{}"
  step-evaluate-automerge-outputs-json:
    description: |
      JSON object containing evaluate-automerge step outputs.
      Pass as: ${{ toJSON(steps.evaluate-automerge.outputs) }}
    required: false
    default: "{}"
  step-create-validation-summary-outputs-json:
    description: |
      JSON object containing create-validation-summary step outputs.
      Pass as: ${{ toJSON(steps.create-validation-summary.outputs) }}
    required: false
    default: "{}"

  # Setup step outputs
  step-setup-terraform-cache-outputs-json:
    description: |
      JSON object containing setup-terraform-cache step outputs.
      Pass as: ${{ toJSON(steps.setup-terraform-cache.outputs) }}
    required: false
    default: "{}"
  step-setup-tflint-outputs-json:
    description: |
      JSON object containing setup-tflint step outputs.
      Pass as: ${{ toJSON(steps.setup-tflint.outputs) }}
    required: false
    default: "{}"

outputs:
  result-json-file:
    description: |
      Absolute path to the JSON file containing all captured metadata.
      Use this path with actions/upload-artifact to save the result.
    value: ${{ steps.capture.outputs.result-json-file }}

runs:
  using: "composite"
  steps:
    - id: capture
      shell: bash
      env:
        input_environment_name: ${{ inputs.environment-name }}
        # outcomes and results
        input_step_init_outcome: ${{ inputs.step-init-outcome }}
        input_step_init_result: ${{ inputs.step-init-result }}
        input_step_fmt_outcome: ${{ inputs.step-fmt-outcome }}
        input_step_fmt_result: ${{ inputs.step-fmt-result }}
        input_step_validate_outcome: ${{ inputs.step-validate-outcome }}
        input_step_validate_result: ${{ inputs.step-validate-result }}
        input_step_lint_outcome: ${{ inputs.step-lint-outcome }}
        input_step_lint_result: ${{ inputs.step-lint-result }}
        input_step_plan_outcome: ${{ inputs.step-plan-outcome }}
        input_step_plan_result: ${{ inputs.step-plan-result }}
        input_step_parse_plan_outcome: ${{ inputs.step-parse-plan-outcome }}
        input_step_parse_plan_result: ${{ inputs.step-parse-plan-result }}
        input_step_apply_outcome: ${{ inputs.step-apply-outcome }}
        input_step_apply_result: ${{ inputs.step-apply-result }}
        input_step_destroy_plan_outcome: ${{ inputs.step-destroy-plan-outcome }}
        input_step_destroy_plan_result: ${{ inputs.step-destroy-plan-result }}
        input_step_parse_destroy_plan_outcome: ${{ inputs.step-parse-destroy-plan-outcome }}
        input_step_parse_destroy_plan_result: ${{ inputs.step-parse-destroy-plan-result }}
        input_step_destroy_outcome: ${{ inputs.step-destroy-outcome }}
        input_step_destroy_result: ${{ inputs.step-destroy-result }}
        input_step_evaluate_automerge_outcome: ${{ inputs.step-evaluate-automerge-outcome }}
        input_step_evaluate_automerge_result: ${{ inputs.step-evaluate-automerge-result }}
        input_step_create_validation_summary_outcome: ${{ inputs.step-create-validation-summary-outcome }}
        input_step_create_validation_summary_result: ${{ inputs.step-create-validation-summary-result }}
      run: |
        # JSON inputs require special handling (heredocs)
        input_matrix_vars_json=$(cat <<'EOF'
        ${{ inputs.matrix-vars-json }}
        EOF
        )
        input_github_context_json=$(cat <<'EOF'
        ${{ inputs.github-context-json }}
        EOF
        )
        input_step_init_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-init-outputs-json }}
        EOF
        )
        input_step_fmt_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-fmt-outputs-json }}
        EOF
        )
        input_step_validate_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-validate-outputs-json }}
        EOF
        )
        input_step_lint_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-lint-outputs-json }}
        EOF
        )
        input_step_plan_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-plan-outputs-json }}
        EOF
        )
        input_step_parse_plan_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-parse-plan-outputs-json }}
        EOF
        )
        input_step_apply_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-apply-outputs-json }}
        EOF
        )
        input_step_destroy_plan_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-destroy-plan-outputs-json }}
        EOF
        )
        input_step_parse_destroy_plan_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-parse-destroy-plan-outputs-json }}
        EOF
        )
        input_step_destroy_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-destroy-outputs-json }}
        EOF
        )
        input_step_evaluate_automerge_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-evaluate-automerge-outputs-json }}
        EOF
        )
        input_step_create_validation_summary_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-create-validation-summary-outputs-json }}
        EOF
        )
        input_step_setup_terraform_cache_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-setup-terraform-cache-outputs-json }}
        EOF
        )
        input_step_setup_tflint_outputs_json=$(cat <<'EOF'
        ${{ inputs.step-setup-tflint-outputs-json }}
        EOF
        )

        # Run step and exit with its exit code
        set -o allexport
        source "${{ github.action_path }}/step_capture.sh"
        exit_code=$?
        set +o allexport
        exit ${exit_code}
```

#### 1.2 Create `capture-terraform-ci-cd-meta/helpers.sh`

Copy the exact `helpers.sh` from `evaluate-automerge-eligibility/helpers.sh`. This file is identical across all actions in this repository.

```bash
#!/bin/env bash

# Helper consts
_action_name="$(basename "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)")"

# Helper functions
function _log { echo "${1}${_action_name}: ${2}"; }
function log-info { _log "" "${*}"; }
function log-debug { _log "DEBUG: " "${*}"; }
function log-warn { _log "WARN: " "${*}"; }
function log-error { _log "ERROR: " "${*}"; }
function start-group { echo "::group::${_action_name}: ${*}"; }
function end-group { echo "::endgroup::"; }
function log-multiline {
  start-group "${1}"
  echo "${2}"
  end-group
}
function mask-value { echo "::add-mask::${*}"; }
function set-output { echo "${1}=${2}" >>$GITHUB_OUTPUT; }
function set-multiline-output {
  local outputName outputValue delimiter
  outputName="${1}"
  outputValue="${2}"
  delimiter=$(echo $RANDOM | md5sum | head -c 20)
  echo "${outputName}<<\"${delimiter}\"" >>$GITHUB_OUTPUT
  echo "${outputValue}" >>$GITHUB_OUTPUT
  echo "\"${delimiter}\"" >>$GITHUB_OUTPUT
}
function ws-path {
  local inPath
  inPath="${1}"
  realpath --relative-to="${GITHUB_WORKSPACE}" "${inPath}"
}

log-info "'$(basename ${BASH_SOURCE[0]})' loaded."

if [ -f "${GITHUB_ACTION_PATH}/helpers_additional.sh" ]; then
  source "${GITHUB_ACTION_PATH}/helpers_additional.sh"
fi
```

#### 1.3 Create `capture-terraform-ci-cd-meta/step_capture.sh`

Main script implementation:

```bash
#!/bin/env bash
#
# Source for the capture step
#
# Captures comprehensive metadata from all steps in the terraform-ci-cd job.
# Best-effort collection: missing data will not cause failure.
#

# Do not fail on unset variables - we need to handle missing data gracefully
set +o nounset

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Helper Functions
# ============================================================================

# Safely parse JSON, returns empty object if invalid/empty
function safe_parse_json {
  local json_input="${1:-}"
  local default="${2:-{}}"

  if [[ -z "${json_input}" || "${json_input}" == "null" ]]; then
    echo "${default}"
    return 0
  fi

  # Validate JSON
  if echo "${json_input}" | jq -e '.' >/dev/null 2>&1; then
    echo "${json_input}" | jq -c '.'
  else
    log-warn "Invalid JSON input, using default"
    echo "${default}"
  fi
}

# Get value or empty string
function get_value_or_empty {
  local val="${1:-}"
  if [[ -z "${val}" || "${val}" == "null" ]]; then
    echo ""
  else
    echo "${val}"
  fi
}

# Filter sensitive keys from JSON object
function filter_sensitive_keys {
  local json_input="${1}"
  local sensitive_patterns='["token", "secret", "password", "key", "credential", "auth"]'

  echo "${json_input}" | jq --argjson patterns "${sensitive_patterns}" '
    . as $orig |
    if type == "object" then
      to_entries | map(
        select(
          (.key | ascii_downcase) as $k |
          ($patterns | map(. as $p | $k | contains($p)) | any | not)
        ) |
        if .value | type == "object" then
          .value = (.value | to_entries | map(
            select(
              (.key | ascii_downcase) as $k |
              ($patterns | map(. as $p | $k | contains($p)) | any | not)
            )
          ) | from_entries)
        else
          .
        end
      ) | from_entries
    else
      .
    end
  '
}

# Build step metadata object
function build_step_metadata {
  local step_name="${1}"
  local outcome="${2:-}"
  local result="${3:-}"
  local outputs_json="${4:-{}}"

  local safe_outputs
  safe_outputs=$(safe_parse_json "${outputs_json}" "{}")

  jq -n \
    --arg name "${step_name}" \
    --arg outcome "$(get_value_or_empty "${outcome}")" \
    --arg result "$(get_value_or_empty "${result}")" \
    --argjson outputs "${safe_outputs}" \
    '{
      "name": $name,
      "outcome": $outcome,
      "result": $result,
      "outputs": $outputs
    }'
}

# ============================================================================
# Main Capture Logic
# ============================================================================

function main {
  log-info "Starting metadata capture for environment '${input_environment_name:-unknown}'..."

  local result_file
  result_file="${GITHUB_WORKSPACE:-/tmp}/terraform-ci-cd-meta-${input_environment_name:-unknown}.json"

  # Start building the metadata structure
  local capture_timestamp
  capture_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Parse matrix.vars (filter sensitive data)
  start-group "Processing matrix.vars"
  local matrix_vars
  matrix_vars=$(safe_parse_json "${input_matrix_vars_json:-}" "{}")
  matrix_vars=$(filter_sensitive_keys "${matrix_vars}")
  log-info "Matrix vars captured (sensitive data filtered)"
  end-group

  # Parse github context (filter sensitive data)
  start-group "Processing GitHub context"
  local github_context
  github_context=$(safe_parse_json "${input_github_context_json:-}" "{}")
  github_context=$(filter_sensitive_keys "${github_context}")
  log-info "GitHub context captured (sensitive data filtered)"
  end-group

  # Build steps metadata
  start-group "Processing step metadata"

  local steps_json="[]"

  # Setup steps
  local setup_terraform_cache
  setup_terraform_cache=$(build_step_metadata "setup-terraform-cache" "" "" "${input_step_setup_terraform_cache_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${setup_terraform_cache}" '. + [$step]')

  local setup_tflint
  setup_tflint=$(build_step_metadata "setup-tflint" "" "" "${input_step_setup_tflint_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${setup_tflint}" '. + [$step]')

  # Core terraform steps
  local step_init
  step_init=$(build_step_metadata "init" "${input_step_init_outcome:-}" "${input_step_init_result:-}" "${input_step_init_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_init}" '. + [$step]')

  local step_fmt
  step_fmt=$(build_step_metadata "fmt" "${input_step_fmt_outcome:-}" "${input_step_fmt_result:-}" "${input_step_fmt_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_fmt}" '. + [$step]')

  local step_validate
  step_validate=$(build_step_metadata "validate" "${input_step_validate_outcome:-}" "${input_step_validate_result:-}" "${input_step_validate_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_validate}" '. + [$step]')

  local step_lint
  step_lint=$(build_step_metadata "lint" "${input_step_lint_outcome:-}" "${input_step_lint_result:-}" "${input_step_lint_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_lint}" '. + [$step]')

  local step_plan
  step_plan=$(build_step_metadata "plan" "${input_step_plan_outcome:-}" "${input_step_plan_result:-}" "${input_step_plan_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_plan}" '. + [$step]')

  local step_parse_plan
  step_parse_plan=$(build_step_metadata "parse-plan" "${input_step_parse_plan_outcome:-}" "${input_step_parse_plan_result:-}" "${input_step_parse_plan_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_parse_plan}" '. + [$step]')

  local step_apply
  step_apply=$(build_step_metadata "apply" "${input_step_apply_outcome:-}" "${input_step_apply_result:-}" "${input_step_apply_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_apply}" '. + [$step]')

  local step_destroy_plan
  step_destroy_plan=$(build_step_metadata "destroy-plan" "${input_step_destroy_plan_outcome:-}" "${input_step_destroy_plan_result:-}" "${input_step_destroy_plan_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_destroy_plan}" '. + [$step]')

  local step_parse_destroy_plan
  step_parse_destroy_plan=$(build_step_metadata "parse-destroy-plan" "${input_step_parse_destroy_plan_outcome:-}" "${input_step_parse_destroy_plan_result:-}" "${input_step_parse_destroy_plan_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_parse_destroy_plan}" '. + [$step]')

  local step_destroy
  step_destroy=$(build_step_metadata "destroy" "${input_step_destroy_outcome:-}" "${input_step_destroy_result:-}" "${input_step_destroy_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_destroy}" '. + [$step]')

  local step_create_validation_summary
  step_create_validation_summary=$(build_step_metadata "create-validation-summary" "${input_step_create_validation_summary_outcome:-}" "${input_step_create_validation_summary_result:-}" "${input_step_create_validation_summary_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_create_validation_summary}" '. + [$step]')

  local step_evaluate_automerge
  step_evaluate_automerge=$(build_step_metadata "evaluate-automerge" "${input_step_evaluate_automerge_outcome:-}" "${input_step_evaluate_automerge_result:-}" "${input_step_evaluate_automerge_outputs_json:-}")
  steps_json=$(echo "${steps_json}" | jq --argjson step "${step_evaluate_automerge}" '. + [$step]')

  log-info "All step metadata processed"
  end-group

  # Build the final JSON structure
  start-group "Building result file"

  jq -n \
    --arg environment "${input_environment_name:-unknown}" \
    --arg captured_at "${capture_timestamp}" \
    --arg github_run_id "${GITHUB_RUN_ID:-}" \
    --arg github_run_number "${GITHUB_RUN_NUMBER:-}" \
    --arg github_run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
    --arg github_workflow "${GITHUB_WORKFLOW:-}" \
    --arg github_job "${GITHUB_JOB:-}" \
    --arg github_actor "${GITHUB_ACTOR:-}" \
    --arg github_event_name "${GITHUB_EVENT_NAME:-}" \
    --arg github_ref "${GITHUB_REF:-}" \
    --arg github_sha "${GITHUB_SHA:-}" \
    --argjson matrix_vars "${matrix_vars}" \
    --argjson github_context "${github_context}" \
    --argjson steps "${steps_json}" \
    '{
      "metadata": {
        "environment": $environment,
        "captured_at": $captured_at,
        "schema_version": "1.0.0"
      },
      "workflow": {
        "run_id": $github_run_id,
        "run_number": $github_run_number,
        "run_attempt": $github_run_attempt,
        "workflow_name": $github_workflow,
        "job_name": $github_job,
        "actor": $github_actor,
        "event_name": $github_event_name,
        "ref": $github_ref,
        "sha": $github_sha
      },
      "matrix_vars": $matrix_vars,
      "github_context": $github_context,
      "steps": $steps
    }' > "${result_file}"

  log-info "Result file written to: ${result_file}"
  log-multiline "Result file contents" "$(cat "${result_file}")"
  end-group

  # Set outputs
  set-output "result-json-file" "${result_file}"

  log-info "Metadata capture completed successfully"
  return 0
}

# Run main function
main
```

#### 1.4 Create `capture-terraform-ci-cd-meta/run_local_step_capture.sh`

Local testing/debugging script:

```bash
#!/bin/env bash
_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export GITHUB_WORKSPACE="${_this_script_dir}/.."

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

set -o allexport
source "${_this_script_dir}/step_capture.sh"
set +o allexport

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
```

#### 1.5 Create `capture-terraform-ci-cd-meta/run_all_tests.sh`

Comprehensive test runner:

```bash
#!/bin/env bash
#
# Comprehensive test runner for step_capture.sh
# Tests various scenarios including edge cases and missing data handling
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# Function to run a single test
run_test() {
  local test_name="${1}"
  local expected_field_check="${2}"  # jq expression to validate
  local expected_result="${3}"

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Set up GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_WORKSPACE=$(mktemp -d)

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

  # Run the step_capture.sh script in a subshell
  (
    set -o allexport
    bash "${_this_script_dir}/step_capture.sh"
  ) > /tmp/test_output.txt 2>&1
  local exit_code=$?

  # Get the result file path
  local result_file
  result_file=$(grep "^result-json-file=" "${GITHUB_OUTPUT}" | cut -d= -f2)

  # Validate
  local actual_result=""
  if [[ -f "${result_file}" ]]; then
    actual_result=$(cat "${result_file}" | jq -r "${expected_field_check}")
  fi

  if [[ "${exit_code}" -eq 0 && "${actual_result}" == "${expected_result}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: Exit code=${exit_code}, field check passed"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: Expected '${expected_result}', got '${actual_result}', exit code=${exit_code}"
    echo ""
    echo "Test output:"
    cat /tmp/test_output.txt
    if [[ -f "${result_file}" ]]; then
      echo ""
      echo "Result file:"
      cat "${result_file}" | jq '.'
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${GITHUB_WORKSPACE}"
}

# Function to reset all variables to defaults
reset_defaults() {
  export input_environment_name="test-env"
  export input_matrix_vars_json='{"github-environment": "test-env", "goals": ["all"]}'
  export input_github_context_json='{"repository": "test/repo"}'

  # Default outcomes - all empty
  export input_step_init_outcome=""
  export input_step_init_result=""
  export input_step_fmt_outcome=""
  export input_step_fmt_result=""
  export input_step_validate_outcome=""
  export input_step_validate_result=""
  export input_step_lint_outcome=""
  export input_step_lint_result=""
  export input_step_plan_outcome=""
  export input_step_plan_result=""
  export input_step_parse_plan_outcome=""
  export input_step_parse_plan_result=""
  export input_step_apply_outcome=""
  export input_step_apply_result=""
  export input_step_destroy_plan_outcome=""
  export input_step_destroy_plan_result=""
  export input_step_parse_destroy_plan_outcome=""
  export input_step_parse_destroy_plan_result=""
  export input_step_destroy_outcome=""
  export input_step_destroy_result=""
  export input_step_evaluate_automerge_outcome=""
  export input_step_evaluate_automerge_result=""
  export input_step_create_validation_summary_outcome=""
  export input_step_create_validation_summary_result=""

  # Default outputs - all empty
  export input_step_init_outputs_json='{}'
  export input_step_fmt_outputs_json='{}'
  export input_step_validate_outputs_json='{}'
  export input_step_lint_outputs_json='{}'
  export input_step_plan_outputs_json='{}'
  export input_step_parse_plan_outputs_json='{}'
  export input_step_apply_outputs_json='{}'
  export input_step_destroy_plan_outputs_json='{}'
  export input_step_parse_destroy_plan_outputs_json='{}'
  export input_step_destroy_outputs_json='{}'
  export input_step_evaluate_automerge_outputs_json='{}'
  export input_step_create_validation_summary_outputs_json='{}'
  export input_step_setup_terraform_cache_outputs_json='{}'
  export input_step_setup_tflint_outputs_json='{}'
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}  TERRAFORM CI/CD METADATA CAPTURE TESTS   ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ============================================================================
# Test 1: Basic capture with minimal inputs
# ============================================================================
reset_defaults
run_test "Basic capture with minimal inputs" '.metadata.environment' "test-env"

# ============================================================================
# Test 2: Capture with step outcomes
# ============================================================================
reset_defaults
input_step_init_outcome="success"
input_step_plan_outcome="success"
run_test "Capture with step outcomes" '.steps[] | select(.name == "init") | .outcome' "success"

# ============================================================================
# Test 3: Handle missing/empty JSON gracefully
# ============================================================================
reset_defaults
unset input_matrix_vars_json
run_test "Handle missing matrix vars JSON" '.matrix_vars' "{}"

# ============================================================================
# Test 4: Capture plan outputs correctly
# ============================================================================
reset_defaults
input_step_parse_plan_outputs_json='{"count-add": "5", "count-change": "2"}'
run_test "Capture plan outputs" '.steps[] | select(.name == "parse-plan") | .outputs["count-add"]' "5"

# ============================================================================
# Test 5: Filter sensitive data from matrix vars
# ============================================================================
reset_defaults
input_matrix_vars_json='{"github-environment": "test", "secret-value": "should-be-removed", "password": "hidden"}'
run_test "Filter sensitive data from matrix vars" '.matrix_vars | has("secret-value")' "false"

# ============================================================================
# Test 6: Schema version is set
# ============================================================================
reset_defaults
run_test "Schema version is set" '.metadata.schema_version' "1.0.0"

# ============================================================================
# Test 7: All core steps are captured
# ============================================================================
reset_defaults
run_test "All core steps captured" '.steps | length' "14"

# ============================================================================
# Test 8: Handle invalid JSON in outputs gracefully
# ============================================================================
reset_defaults
input_step_plan_outputs_json="not-valid-json"
run_test "Handle invalid JSON gracefully" '.steps[] | select(.name == "plan") | .outputs' "{}"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}               TEST SUMMARY                ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  echo -e "${RED}SOME TESTS FAILED!${NC}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED!${NC}"
  exit 0
fi
```

---

### Phase 2: Extend the Workflow

#### 2.1 Add Step to `terraform-ci-cd-default.yml`

Add the following step as the **last step** in the `terraform-ci-cd` job (after the `upload-automerge-evaluation` step):

```yaml
      # Capture comprehensive metadata from all steps for debugging and analysis
      - name: "📊 Capture CI/CD metadata"
        id: capture-metadata
        if: always()
        # TODO revert to @v0
        uses: dsb-norge/github-actions-terraform/capture-terraform-ci-cd-meta@automerge
        with:
          environment-name: ${{ matrix.vars.github-environment }}
          matrix-vars-json: ${{ toJSON(matrix.vars) }}
          github-context-json: ${{ toJSON(github) }}
          # Step outcomes and results
          step-init-outcome: ${{ steps.init.outcome }}
          step-init-result: ${{ steps.init.result || '' }}
          step-fmt-outcome: ${{ steps.fmt.outcome }}
          step-fmt-result: ${{ steps.fmt.result || '' }}
          step-validate-outcome: ${{ steps.validate.outcome }}
          step-validate-result: ${{ steps.validate.result || '' }}
          step-lint-outcome: ${{ steps.lint.outcome }}
          step-lint-result: ${{ steps.lint.result || '' }}
          step-plan-outcome: ${{ steps.plan.outcome }}
          step-plan-result: ${{ steps.plan.result || '' }}
          step-parse-plan-outcome: ${{ steps.parse-plan.outcome }}
          step-parse-plan-result: ${{ steps.parse-plan.result || '' }}
          step-apply-outcome: ${{ steps.apply.outcome }}
          step-apply-result: ${{ steps.apply.result || '' }}
          step-destroy-plan-outcome: ${{ steps.destroy-plan.outcome }}
          step-destroy-plan-result: ${{ steps.destroy-plan.result || '' }}
          step-parse-destroy-plan-outcome: ${{ steps.parse-destroy-plan.outcome }}
          step-parse-destroy-plan-result: ${{ steps.parse-destroy-plan.result || '' }}
          step-destroy-outcome: ${{ steps.destroy.outcome }}
          step-destroy-result: ${{ steps.destroy.result || '' }}
          step-evaluate-automerge-outcome: ${{ steps.evaluate-automerge.outcome }}
          step-evaluate-automerge-result: ${{ steps.evaluate-automerge.result || '' }}
          step-create-validation-summary-outcome: ${{ steps.create-validation-summary.outcome }}
          step-create-validation-summary-result: ${{ steps.create-validation-summary.result || '' }}
          # Step outputs as JSON
          step-init-outputs-json: ${{ toJSON(steps.init.outputs) }}
          step-fmt-outputs-json: ${{ toJSON(steps.fmt.outputs) }}
          step-validate-outputs-json: ${{ toJSON(steps.validate.outputs) }}
          step-lint-outputs-json: ${{ toJSON(steps.lint.outputs) }}
          step-plan-outputs-json: ${{ toJSON(steps.plan.outputs) }}
          step-parse-plan-outputs-json: ${{ toJSON(steps.parse-plan.outputs) }}
          step-apply-outputs-json: ${{ toJSON(steps.apply.outputs) }}
          step-destroy-plan-outputs-json: ${{ toJSON(steps.destroy-plan.outputs) }}
          step-parse-destroy-plan-outputs-json: ${{ toJSON(steps.parse-destroy-plan.outputs) }}
          step-destroy-outputs-json: ${{ toJSON(steps.destroy.outputs) }}
          step-evaluate-automerge-outputs-json: ${{ toJSON(steps.evaluate-automerge.outputs) }}
          step-create-validation-summary-outputs-json: ${{ toJSON(steps.create-validation-summary.outputs) }}
          step-setup-terraform-cache-outputs-json: ${{ toJSON(steps.setup-terraform-cache.outputs) }}
          step-setup-tflint-outputs-json: ${{ toJSON(steps.setup-tflint.outputs) }}
        continue-on-error: true # best effort - never fail the job

      - name: "📦 Upload CI/CD metadata"
        id: upload-metadata
        if: always() && steps.capture-metadata.outcome == 'success'
        uses: actions/upload-artifact@v4
        with:
          name: terraform-ci-cd-meta-${{ matrix.vars.github-environment }}
          path: ${{ steps.capture-metadata.outputs.result-json-file }}
        continue-on-error: true # best effort - never fail the job
```

---

### Phase 3: Expected Output JSON Schema

The captured metadata file will have the following structure:

```json
{
  "metadata": {
    "environment": "sandbox",
    "captured_at": "2026-01-30T12:00:00Z",
    "schema_version": "1.0.0"
  },
  "workflow": {
    "run_id": "12345678901",
    "run_number": "42",
    "run_attempt": "1",
    "workflow_name": "DSB terraform CI/CD workflow",
    "job_name": "terraform-ci-cd",
    "actor": "dependabot[bot]",
    "event_name": "pull_request",
    "ref": "refs/pull/123/merge",
    "sha": "abc123def456789"
  },
  "matrix_vars": {
    "github-environment": "sandbox",
    "project-dir": "./envs/sandbox",
    "goals": ["all"],
    "runs-on": "ubuntu-latest",
    "terraform-version": "latest",
    "tflint-version": "latest",
    "add-pr-comment": "true",
    "allow-failing-terraform-operations": "false",
    "pr-auto-merge-enabled": "true"
  },
  "github_context": {
    "repository": "dsb-norge/example-repo",
    "event_name": "pull_request",
    "ref": "refs/pull/123/merge"
  },
  "steps": [
    {
      "name": "setup-terraform-cache",
      "outcome": "",
      "result": "",
      "outputs": {
        "plugin-cache-directory": "/home/runner/.terraform.d/plugin-cache"
      }
    },
    {
      "name": "init",
      "outcome": "success",
      "result": "success",
      "outputs": {}
    },
    {
      "name": "plan",
      "outcome": "success",
      "result": "success",
      "outputs": {
        "console-output-file": "/tmp/plan-console.txt",
        "txt-output-file": "/tmp/plan.txt",
        "terraform-plan-file": "/tmp/plan.tfplan"
      }
    },
    {
      "name": "parse-plan",
      "outcome": "success",
      "result": "success",
      "outputs": {
        "count-add": "2",
        "count-change": "1",
        "count-destroy": "0",
        "count-import": "0",
        "count-move": "0",
        "count-remove": "0"
      }
    }
  ]
}
```

---

## Implementation Checklist

- [ ] **Phase 1: Create Action**
  - [ ] Create directory `capture-terraform-ci-cd-meta/`
  - [ ] Create `action.yml` with all inputs/outputs defined
  - [ ] Copy `helpers.sh` from `evaluate-automerge-eligibility/`
  - [ ] Create `step_capture.sh` with main capture logic
  - [ ] Create `run_local_step_capture.sh` for local testing
  - [ ] Create `run_all_tests.sh` with comprehensive tests
  - [ ] Make all `.sh` files executable (`chmod +x`)

- [ ] **Phase 2: Extend Workflow**
  - [ ] Add capture step to `terraform-ci-cd-default.yml`
  - [ ] Add upload artifact step after capture

- [ ] **Phase 3: Testing**
  - [ ] Run local tests with `run_local_step_capture.sh`
  - [ ] Run all tests with `run_all_tests.sh`
  - [ ] Test in actual workflow on a test branch

- [ ] **Phase 4: Documentation**
  - [ ] Update README.md if needed
  - [ ] Add example usage to workflow documentation

---

## Security Considerations

1. **Secret Filtering**: The `filter_sensitive_keys` function removes keys containing: `token`, `secret`, `password`, `key`, `credential`, `auth`
2. **GitHub Context Filtering**: The full `github` context is filtered to remove sensitive data
3. **No File Content Capture**: Only file paths are captured, not actual file contents

---

## Notes

- The action uses `if: always()` to ensure it runs even if previous steps fail
- Uses `continue-on-error: true` to never fail the job
- Designed for "best effort collection" - missing data is handled gracefully
- All steps from the `terraform-ci-cd` job are captured, including setup steps
