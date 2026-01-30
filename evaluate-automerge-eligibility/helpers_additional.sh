#!/bin/env bash
#
# Additional helper functions for evaluate-automerge-eligibility action
# These functions support the new multi-file processing mode
#

# ============================================================================
# Metadata Extraction Functions
# ============================================================================

# Extract a value from a metadata JSON file using jq path
# Args: $1 = file path, $2 = jq path expression
# Returns: The extracted value or empty string if not found
function extract_from_metadata {
  local file="${1}"
  local jq_path="${2}"
  jq -r "${jq_path} // empty" "${file}" 2>/dev/null || echo ""
}

# Extract environment name from metadata file
# Args: $1 = metadata file path
function get_environment_name {
  local file="${1}"
  extract_from_metadata "${file}" ".metadata.environment"
}

# Extract pr-auto-merge-enabled from metadata file
# Args: $1 = metadata file path
function get_pr_auto_merge_enabled {
  local file="${1}"
  local val
  val=$(extract_from_metadata "${file}" '.matrix_context.vars."pr-auto-merge-enabled"')
  # Convert to "true" or "false" string
  if [[ "${val}" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Extract pr-auto-merge-limits as JSON string from metadata file
# Args: $1 = metadata file path
function get_pr_auto_merge_limits_json {
  local file="${1}"
  jq -c '.matrix_context.vars."pr-auto-merge-limits" // {}' "${file}" 2>/dev/null || echo "{}"
}

# Extract pr-auto-merge-from-actors as JSON array string from metadata file
# Args: $1 = metadata file path
function get_pr_auto_merge_from_actors_json {
  local file="${1}"
  jq -c '.matrix_context.vars."pr-auto-merge-from-actors" // []' "${file}" 2>/dev/null || echo "[]"
}

# Check if goals array contains a specific goal
# Args: $1 = metadata file path, $2 = goal to check for
function goals_contain {
  local file="${1}"
  local goal="${2}"
  local contains
  contains=$(jq -r --arg goal "${goal}" '.matrix_context.vars.goals | if . then map(select(. == $goal)) | length else 0 end' "${file}" 2>/dev/null || echo "0")
  [[ "${contains}" -gt 0 ]]
}

# Derive plan-shouldve-been-created from goals
# Returns "true" if goals contains 'all' or 'plan'
# Args: $1 = metadata file path
function get_plan_shouldve_been_created {
  local file="${1}"
  if goals_contain "${file}" "all" || goals_contain "${file}" "plan"; then
    echo "true"
  else
    echo "false"
  fi
}

# Derive destroy-plan-shouldve-been-created from goals
# Returns "true" if goals contains 'destroy-plan'
# Args: $1 = metadata file path
function get_destroy_plan_shouldve_been_created {
  local file="${1}"
  if goals_contain "${file}" "destroy-plan"; then
    echo "true"
  else
    echo "false"
  fi
}

# Derive performing-apply-on-pr from goals
# Returns "true" if goals contains 'apply-on-pr'
# Args: $1 = metadata file path
function get_performing_apply_on_pr {
  local file="${1}"
  if goals_contain "${file}" "apply-on-pr"; then
    echo "true"
  else
    echo "false"
  fi
}

# Derive performing-destroy-on-pr from goals
# Returns "true" if goals contains 'destroy-on-pr'
# Args: $1 = metadata file path
function get_performing_destroy_on_pr {
  local file="${1}"
  if goals_contain "${file}" "destroy-on-pr"; then
    echo "true"
  else
    echo "false"
  fi
}

# Get step outcome from metadata file
# Args: $1 = metadata file path, $2 = step name
# Returns: "true" if outcome is "success", "false" otherwise
function get_step_outcome_success {
  local file="${1}"
  local step_name="${2}"
  local outcome
  outcome=$(extract_from_metadata "${file}" ".steps.\"${step_name}\".outcome")
  if [[ "${outcome}" == "success" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Get step output value from metadata file
# Args: $1 = metadata file path, $2 = step name, $3 = output name
# Returns: The output value or empty string
function get_step_output {
  local file="${1}"
  local step_name="${2}"
  local output_name="${3}"
  extract_from_metadata "${file}" ".steps.\"${step_name}\".outputs.\"${output_name}\""
}

# ============================================================================
# Environment Data Extraction
# ============================================================================

# Extract all required data from a metadata file and set as global variables
# This function sets all the input_* variables needed by the evaluation functions
# Args: $1 = metadata file path
function extract_environment_data {
  local file="${1}"

  # Environment name
  input_environment_name=$(get_environment_name "${file}")

  # PR auto-merge settings
  input_pr_auto_merge_enabled=$(get_pr_auto_merge_enabled "${file}")
  input_pr_auto_merge_limits_json=$(get_pr_auto_merge_limits_json "${file}")
  input_pr_auto_merge_from_actors_json=$(get_pr_auto_merge_from_actors_json "${file}")

  # Plan-related derived values
  input_plan_shouldve_been_created=$(get_plan_shouldve_been_created "${file}")
  input_plan_was_created=$(get_step_outcome_success "${file}" "plan")
  input_performing_apply_on_pr=$(get_performing_apply_on_pr "${file}")
  input_apply_on_pr_succeeded=$(get_step_outcome_success "${file}" "apply")

  # Plan counts from parse-plan step
  input_plan_count_add=$(get_step_output "${file}" "parse-plan" "count-add")
  input_plan_count_change=$(get_step_output "${file}" "parse-plan" "count-change")
  input_plan_count_destroy=$(get_step_output "${file}" "parse-plan" "count-destroy")
  input_plan_count_import=$(get_step_output "${file}" "parse-plan" "count-import")
  input_plan_count_move=$(get_step_output "${file}" "parse-plan" "count-move")
  input_plan_count_remove=$(get_step_output "${file}" "parse-plan" "count-remove")

  # Destroy plan-related derived values
  input_destroy_plan_shouldve_been_created=$(get_destroy_plan_shouldve_been_created "${file}")
  input_destroy_plan_was_created=$(get_step_outcome_success "${file}" "destroy-plan")
  input_performing_destroy_on_pr=$(get_performing_destroy_on_pr "${file}")
  input_destroy_on_pr_succeeded=$(get_step_outcome_success "${file}" "destroy")

  # Destroy plan counts from parse-destroy-plan step
  input_destroy_plan_count_add=$(get_step_output "${file}" "parse-destroy-plan" "count-add")
  input_destroy_plan_count_change=$(get_step_output "${file}" "parse-destroy-plan" "count-change")
  input_destroy_plan_count_destroy=$(get_step_output "${file}" "parse-destroy-plan" "count-destroy")
  input_destroy_plan_count_import=$(get_step_output "${file}" "parse-destroy-plan" "count-import")
  input_destroy_plan_count_move=$(get_step_output "${file}" "parse-destroy-plan" "count-move")
  input_destroy_plan_count_remove=$(get_step_output "${file}" "parse-destroy-plan" "count-remove")
}

# ============================================================================
# File Discovery Functions
# ============================================================================

# Find all metadata files matching a glob pattern
# Args: $1 = glob pattern (e.g., "matrix-job-meta-*.json")
# Returns: Array of matching file paths via stdout (one per line)
function find_metadata_files {
  local pattern="${1}"

  # Enable nullglob so that if no files match, the array is empty
  shopt -s nullglob
  local files=(${pattern})
  shopt -u nullglob

  # Output files one per line
  for file in "${files[@]}"; do
    echo "${file}"
  done
}

# ============================================================================
# Validation Functions
# ============================================================================

# Validate that a metadata file has the expected structure
# Args: $1 = metadata file path
# Returns: 0 if valid, 1 if invalid
function validate_metadata_file {
  local file="${1}"

  # Check file exists and is readable
  if [[ ! -r "${file}" ]]; then
    log-warn "Metadata file '${file}' does not exist or is not readable"
    return 1
  fi

  # Check it's valid JSON
  if ! jq empty "${file}" 2>/dev/null; then
    log-warn "Metadata file '${file}' is not valid JSON"
    return 1
  fi

  # Check required fields exist
  local env_name
  env_name=$(get_environment_name "${file}")
  if [[ -z "${env_name}" ]]; then
    log-warn "Metadata file '${file}' is missing .metadata.environment field"
    return 1
  fi

  # Check matrix_context.vars exists
  local has_vars
  has_vars=$(jq -r '.matrix_context.vars | if . then "yes" else "no" end' "${file}" 2>/dev/null || echo "no")
  if [[ "${has_vars}" != "yes" ]]; then
    log-warn "Metadata file '${file}' is missing .matrix_context.vars field"
    return 1
  fi

  return 0
}

# ============================================================================

log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
