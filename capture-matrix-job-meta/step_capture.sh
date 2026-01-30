#!/bin/env bash
#
# Source for the capture step
#
# Captures comprehensive metadata from all steps in a matrix job.
# Best-effort collection: missing data will not cause failure.
#
# Uses the steps context directly from GitHub Actions, making it future-proof
# for any new steps added to the workflow.
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

  # Trim leading/trailing whitespace
  json_input=$(echo "${json_input}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Check if empty after trimming
  if [[ -z "${json_input}" ]]; then
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

# Filter sensitive keys from JSON object (recursive)
# Removes keys containing: token, secret, password, key, credential, auth
function filter_sensitive_keys {
  local json_input="${1}"

  # Handle empty/null input
  if [[ -z "${json_input}" || "${json_input}" == "null" ]]; then
    echo "{}"
    return 0
  fi

  echo "${json_input}" | jq '
    def filter_sensitive:
      if type == "object" then
        to_entries
        | map(
            select(
              (.key | ascii_downcase) as $k |
              (["token", "secret", "password", "credential", "auth"] | map(. as $p | $k | contains($p)) | any | not)
              and
              # Also filter out keys that end with "_key" but keep regular keys like "event_name"
              (($k | test("_key$"; "i") or $k == "key") | not)
            )
            | .value = (.value | filter_sensitive)
          )
        | from_entries
      elif type == "array" then
        map(filter_sensitive)
      else
        .
      end;
    filter_sensitive
  '
}

# Normalize the steps context object
# Ensures each step has outcome, conclusion, and outputs fields
# Input/Output format: { "step-id": { "outputs": {}, "outcome": "success", "conclusion": "success" }, ... }
function normalize_steps_context {
  local steps_json="${1}"

  # Handle empty/null input
  if [[ -z "${steps_json}" || "${steps_json}" == "null" ]]; then
    echo "{}"
    return 0
  fi

  echo "${steps_json}" | jq '
    to_entries | map({
      key: .key,
      value: {
        outcome: (.value.outcome // ""),
        conclusion: (.value.conclusion // ""),
        outputs: (.value.outputs // {})
      }
    }) | from_entries
  '
}

# ============================================================================
# Main Capture Logic
# ============================================================================

function main {
  log-info "Starting metadata capture for environment '${input_environment_name:-unknown}'..."

  local result_file
  result_file="${RUNNER_TEMP:-/tmp}/matrix-job-meta-${input_environment_name:-unknown}.json"

  # Start building the metadata structure
  local capture_timestamp
  capture_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Parse matrix context (filter sensitive data)
  start-group "Processing matrix context"
  local matrix_context
  matrix_context=$(safe_parse_json "${input_matrix_context_json:-}" "{}")
  matrix_context=$(filter_sensitive_keys "${matrix_context}")
  log-info "Matrix context captured (sensitive data filtered)"
  end-group

  # Parse github context (filter sensitive data)
  start-group "Processing GitHub context"
  local github_context
  github_context=$(safe_parse_json "${input_github_context_json:-}" "{}")
  github_context=$(filter_sensitive_keys "${github_context}")
  log-info "GitHub context captured (sensitive data filtered)"
  end-group

  # Process the steps context directly
  start-group "Processing steps context"
  local steps_context
  steps_context=$(safe_parse_json "${input_steps_context_json:-}" "{}")

  # Normalize the steps context (ensure consistent structure)
  local steps_json
  steps_json=$(normalize_steps_context "${steps_context}")

  # Count the steps
  local step_count
  step_count=$(echo "${steps_json}" | jq 'keys | length')
  log-info "Captured ${step_count} steps from workflow"
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
    --argjson matrix_context "${matrix_context}" \
    --argjson github_context "${github_context}" \
    --argjson steps "${steps_json}" \
    '{
      "metadata": {
        "environment": $environment,
        "captured_at": $captured_at,
        "schema_version": "2.0.0"
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
      "matrix_context": $matrix_context,
      "github_context": $github_context,
      "steps": $steps
    }' > "${result_file}"

  log-info "Result file written to: ${result_file}"
  end-group

  # Show result file contents in its own group (log-multiline creates its own group)
  log-multiline "Result file contents" "$(cat "${result_file}")"

  # Set outputs
  set-output "result-json-file" "${result_file}"

  log-info "Metadata capture completed successfully"
  return 0
}

# Run main function
main
_main_exit_code=$?
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced - return to allow caller to capture exit code
  return ${_main_exit_code}
else
  # Script is being executed directly - exit with the code
  exit ${_main_exit_code}
fi