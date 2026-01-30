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
  local default_val="{}"
  local default="${2:-$default_val}"

  if [[ -z "${json_input}" || "${json_input}" == "null" ]]; then
    echo "${default}"
    return 0
  fi

  # Validate JSON
  if echo "${json_input}" | jq -e '.' >/dev/null 2>&1; then
    echo "${json_input}" | jq -c '.'
  else
    log-warn "Invalid JSON input, using default" >&2
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
  local default_outputs="{}"
  local outputs_json="${4:-$default_outputs}"

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
