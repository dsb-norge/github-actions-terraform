#!/bin/env bash
#
# Source for the evaluate step
#
# Evaluates whether a pull request is eligible for automatic merging based on
# Terraform plan changes, configured limits, and actor restrictions.
#
# This script processes multiple metadata files from capture-matrix-job-meta
# and produces an aggregated eligibility decision across all environments.
#

# do not allow unset variables
set -o nounset

# load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Helper Functions
# ============================================================================

# Check if a value is a valid integer (including negative numbers)
function is_valid_integer {
  local val="${1}"
  [[ "${val}" =~ ^-?[0-9]+$ ]]
}

# Check if a value is empty or null
function is_empty_or_null {
  local val="${1}"
  [[ -z "${val}" || "${val}" == "null" ]]
}

# Parse boolean string to bash boolean (0=true, 1=false)
function parse_bool {
  local val="${1}"
  [[ "${val}" == "true" ]]
}

# Add a failure reason to the list (for current environment)
function add_failure_reason {
  local reason="${1}"
  ENV_FAILURE_REASONS+=("${reason}")
  log-warn "${reason}"
}

# ============================================================================
# Evaluation Functions
# ============================================================================

# 1. Configuration Validation
function validate_configuration {
  log-info "Validating configuration..."

  local limit_fields=(
    "plan-max-count-add"
    "plan-max-count-change"
    "plan-max-count-destroy"
    "plan-max-count-import"
    "plan-max-count-move"
    "plan-max-count-remove"
  )

  local config_valid=true

  for field in "${limit_fields[@]}"; do
    local val
    val=$(echo "${input_pr_auto_merge_limits_json}" | jq -r ".\"${field}\" // empty")

    if is_empty_or_null "${val}"; then
      log-error "Configuration error: '${field}' is missing, null, or empty"
      config_valid=false
    elif ! is_valid_integer "${val}"; then
      log-error "Configuration error: '${field}' value '${val}' is not a valid integer"
      config_valid=false
    else
      log-info "  ${field}: ${val} [OK]"
    fi
  done

  if [[ "${config_valid}" == "false" ]]; then
    log-error "Configuration validation failed"
    return 1
  fi

  log-info "Configuration validation: PASS"
  RESULT_CONFIG_VALIDATION="PASS"
  return 0
}

# 2. PR Auto-merge Enabled Check
function check_pr_automerge_enabled {
  log-info "Checking if PR automerge is enabled for environment..."

  if parse_bool "${input_pr_auto_merge_enabled}"; then
    log-info "PR automerge is enabled for this environment: PASS"
    RESULT_PR_AUTOMERGE_ENABLED="PASS"
    return 0
  else
    add_failure_reason "PR automerge is disabled for this environment"
    log-info "PR automerge enabled check: FAIL"
    RESULT_PR_AUTOMERGE_ENABLED="FAIL"
    return 1
  fi
}

# 3. Actor Authorization Check
function check_actor_authorization {
  log-info "Checking actor authorization..."
  log-info "  Current actor: ${GITHUB_ACTOR}"

  local actor_count
  actor_count=$(echo "${input_pr_auto_merge_from_actors_json}" | jq -r 'length')

  if [[ "${actor_count}" -eq 0 ]]; then
    log-info "  Actor list is empty, all actors are allowed"
    log-info "Actor authorization: PASS"
    RESULT_ACTOR_AUTH="PASS"
    return 0
  fi

  local actor_found
  actor_found=$(echo "${input_pr_auto_merge_from_actors_json}" | jq -r --arg actor "${GITHUB_ACTOR}" 'map(select(. == $actor)) | length')

  if [[ "${actor_found}" -gt 0 ]]; then
    log-info "  Actor '${GITHUB_ACTOR}' found in allowed list"
    log-info "Actor authorization: PASS"
    RESULT_ACTOR_AUTH="PASS"
    return 0
  else
    add_failure_reason "Actor '${GITHUB_ACTOR}' is not authorized for PR automerge"
    log-info "Actor authorization: FAIL"
    RESULT_ACTOR_AUTH="FAIL"
    return 1
  fi
}

# 4. Plan Creation Validation
function validate_plan_creation {
  log-info "Validating plan creation..."
  local validation_passed=true

  # Regular plan validation
  if parse_bool "${input_plan_shouldve_been_created}"; then
    if parse_bool "${input_plan_was_created}"; then
      log-info "  Plan creation: expected and succeeded - PASS"
      RESULT_PLAN_CREATION="PASS"
    else
      add_failure_reason "Plan was expected to have been created but was not, environment is ineligible for PR auto merge"
      RESULT_PLAN_CREATION="FAIL"
      validation_passed=false
    fi
  else
    log-info "  Plan creation: not expected - SKIPPED"
    RESULT_PLAN_CREATION="SKIPPED"
  fi

  # Destroy plan validation
  if parse_bool "${input_destroy_plan_shouldve_been_created}"; then
    if parse_bool "${input_destroy_plan_was_created}"; then
      log-info "  Destroy plan creation: expected and succeeded - PASS"
      RESULT_DESTROY_PLAN_CREATION="PASS"
    else
      add_failure_reason "Destroy plan was expected to have been created but was not, environment is ineligible for PR auto merge"
      RESULT_DESTROY_PLAN_CREATION="FAIL"
      validation_passed=false
    fi
  else
    log-info "  Destroy plan creation: not expected - SKIPPED"
    RESULT_DESTROY_PLAN_CREATION="SKIPPED"
  fi

  if [[ "${validation_passed}" == "true" ]]; then
    log-info "Plan creation validation: PASS"
    return 0
  else
    log-info "Plan creation validation: FAIL"
    return 1
  fi
}

# 5. Apply/Destroy Operation Success Check
function check_operation_success {
  log-info "Checking operation success..."
  local check_passed=true

  # Apply on PR check
  if parse_bool "${input_performing_apply_on_pr}"; then
    if parse_bool "${input_apply_on_pr_succeeded}"; then
      log-info "  Apply on PR: performed and succeeded - PASS"
      RESULT_APPLY_SUCCESS="PASS"
    else
      add_failure_reason "Apply operation on PR was not expected to fail, environment is ineligible for PR auto merge"
      RESULT_APPLY_SUCCESS="FAIL"
      check_passed=false
    fi
  else
    log-info "  Apply on PR: not performed - SKIPPED"
    RESULT_APPLY_SUCCESS="SKIPPED"
  fi

  # Destroy on PR check
  if parse_bool "${input_performing_destroy_on_pr}"; then
    if parse_bool "${input_destroy_on_pr_succeeded}"; then
      log-info "  Destroy on PR: performed and succeeded - PASS"
      RESULT_DESTROY_SUCCESS="PASS"
    else
      add_failure_reason "Destroy operation on PR was not expected to fail, environment is ineligible for PR auto merge"
      RESULT_DESTROY_SUCCESS="FAIL"
      check_passed=false
    fi
  else
    log-info "  Destroy on PR: not performed - SKIPPED"
    RESULT_DESTROY_SUCCESS="SKIPPED"
  fi

  if [[ "${check_passed}" == "true" ]]; then
    log-info "Operation success check: PASS"
    return 0
  else
    log-info "Operation success check: FAIL"
    return 1
  fi
}

# 6. Determine Limit Applicability
function determine_limit_applicability {
  log-info "Determining limit applicability..."

  # Plan limits should be included when:
  # - plan-shouldve-been-created is true AND
  # - performing-apply-on-pr is false
  if parse_bool "${input_plan_shouldve_been_created}" && ! parse_bool "${input_performing_apply_on_pr}"; then
    INCLUDE_PLAN_LIMITS=true
    log-info "  Plan limits: INCLUDED"
  else
    INCLUDE_PLAN_LIMITS=false
    if ! parse_bool "${input_plan_shouldve_been_created}"; then
      log-info "  Plan limits: IGNORED (plan was not supposed to be created)"
    else
      log-info "  Plan limits: IGNORED (apply is being performed on PR)"
    fi
  fi

  # Destroy plan limits should be included when:
  # - destroy-plan-shouldve-been-created is true AND
  # - performing-destroy-on-pr is false
  if parse_bool "${input_destroy_plan_shouldve_been_created}" && ! parse_bool "${input_performing_destroy_on_pr}"; then
    INCLUDE_DESTROY_PLAN_LIMITS=true
    log-info "  Destroy plan limits: INCLUDED"
  else
    INCLUDE_DESTROY_PLAN_LIMITS=false
    if ! parse_bool "${input_destroy_plan_shouldve_been_created}"; then
      log-info "  Destroy plan limits: IGNORED (destroy plan was not supposed to be created)"
    else
      log-info "  Destroy plan limits: IGNORED (destroy is being performed on PR)"
    fi
  fi

  RESULT_PLAN_LIMITS_APPLICABILITY=$([[ "${INCLUDE_PLAN_LIMITS}" == "true" ]] && echo "INCLUDED" || echo "IGNORED")
  RESULT_DESTROY_PLAN_LIMITS_APPLICABILITY=$([[ "${INCLUDE_DESTROY_PLAN_LIMITS}" == "true" ]] && echo "INCLUDED" || echo "IGNORED")

  # Check if all limits are ignored
  if [[ "${INCLUDE_PLAN_LIMITS}" == "false" && "${INCLUDE_DESTROY_PLAN_LIMITS}" == "false" ]]; then
    log-info "All limits ignored, no evaluation needed for environment"
    ALL_LIMITS_IGNORED=true
    return 0
  fi

  ALL_LIMITS_IGNORED=false
  return 0
}

# 7. Validate Counts
function validate_counts {
  log-info "Validating plan counts..."
  local counts_valid=true

  local count_types=("add" "change" "destroy" "import" "move" "remove")

  if [[ "${INCLUDE_PLAN_LIMITS}" == "true" ]]; then
    log-info "  Checking plan counts..."
    for count_type in "${count_types[@]}"; do
      local var_name="input_plan_count_${count_type}"
      local val="${!var_name}"

      if is_empty_or_null "${val}" || ! is_valid_integer "${val}"; then
        log-warn "  Plan count '${count_type}' is missing or invalid: '${val}'"
        counts_valid=false
      else
        log-info "    plan-count-${count_type}: ${val} [OK]"
      fi
    done
  fi

  if [[ "${INCLUDE_DESTROY_PLAN_LIMITS}" == "true" ]]; then
    log-info "  Checking destroy plan counts..."
    for count_type in "${count_types[@]}"; do
      local var_name="input_destroy_plan_count_${count_type}"
      local val="${!var_name}"

      if is_empty_or_null "${val}" || ! is_valid_integer "${val}"; then
        log-warn "  Destroy plan count '${count_type}' is missing or invalid: '${val}'"
        counts_valid=false
      else
        log-info "    destroy-plan-count-${count_type}: ${val} [OK]"
      fi
    done
  fi

  if [[ "${counts_valid}" == "false" ]]; then
    add_failure_reason "Required plan counts are missing or invalid. Plan parsing may have failed, environment is ineligible for PR auto merge"
    log-info "Count validation: FAIL"
    return 1
  fi

  log-info "Count validation: PASS"
  return 0
}

# 8. Aggregate Counts
function aggregate_counts {
  log-info "Aggregating counts..."

  local count_types=("add" "change" "destroy" "import" "move" "remove")

  for count_type in "${count_types[@]}"; do
    local total=0
    local plan_var="input_plan_count_${count_type}"
    local destroy_var="input_destroy_plan_count_${count_type}"

    if [[ "${INCLUDE_PLAN_LIMITS}" == "true" ]]; then
      total=$((total + ${!plan_var}))
    fi

    if [[ "${INCLUDE_DESTROY_PLAN_LIMITS}" == "true" ]]; then
      total=$((total + ${!destroy_var}))
    fi

    # Store in global associative array
    TOTAL_COUNTS["${count_type}"]="${total}"
    log-info "  total-count-${count_type}: ${total}"
  done
}

# 9. Evaluate Limits
function evaluate_limits {
  log-info "Evaluating limits..."

  local limit_map=(
    "add:plan-max-count-add"
    "change:plan-max-count-change"
    "destroy:plan-max-count-destroy"
    "import:plan-max-count-import"
    "move:plan-max-count-move"
    "remove:plan-max-count-remove"
  )

  local all_passed=true

  for entry in "${limit_map[@]}"; do
    # Extract the count type (e.g., "add") from before the colon
    local count_type="${entry%%:*}"

    # Extract the limit field name (e.g., "plan-max-count-add") from after the colon
    local limit_field="${entry#*:}"

    local count="${TOTAL_COUNTS[${count_type}]}"
    local limit
    limit=$(echo "${input_pr_auto_merge_limits_json}" | jq -r ".\"${limit_field}\"")

    if [[ "${limit}" -eq -1 ]]; then
      log-info "  ${count_type^}: ${count} / unlimited - PASS"
      LIMIT_RESULTS["${count_type}"]="${count} / unlimited - PASS"
    elif [[ "${count}" -le "${limit}" ]]; then
      log-info "  ${count_type^}: ${count} / ${limit} - PASS"
      LIMIT_RESULTS["${count_type}"]="${count} / ${limit} - PASS"
    else
      log-info "  ${count_type^}: ${count} / ${limit} - FAIL"
      LIMIT_RESULTS["${count_type}"]="${count} / ${limit} - FAIL"
      add_failure_reason "${count_type^} count (${count}) exceeds limit (${limit}) in environment"
      all_passed=false
    fi
  done

  if [[ "${all_passed}" == "true" ]]; then
    log-info "Limit evaluation: PASS"
    return 0
  else
    log-info "Limit evaluation: FAIL"
    return 1
  fi
}

# ============================================================================
# Single Environment Evaluation Logic
# ============================================================================

# Evaluate a single environment's eligibility
# All input_* variables must be set before calling this function
# Returns: 0 if evaluation completed (check ENV_IS_ELIGIBLE for result), 1 on fatal error
function evaluate_single_environment {
  log-info "Starting automerge eligibility evaluation for environment '${input_environment_name}'..."

  # Initialize per-environment state
  declare -g -a ENV_FAILURE_REASONS=()
  declare -g -A TOTAL_COUNTS=()
  declare -g -A LIMIT_RESULTS=()
  declare -g INCLUDE_PLAN_LIMITS=false
  declare -g INCLUDE_DESTROY_PLAN_LIMITS=false
  declare -g ALL_LIMITS_IGNORED=true
  declare -g RESULT_CONFIG_VALIDATION="SKIPPED"
  declare -g RESULT_PR_AUTOMERGE_ENABLED="SKIPPED"
  declare -g RESULT_ACTOR_AUTH="SKIPPED"
  declare -g RESULT_PLAN_CREATION="SKIPPED"
  declare -g RESULT_DESTROY_PLAN_CREATION="SKIPPED"
  declare -g RESULT_APPLY_SUCCESS="SKIPPED"
  declare -g RESULT_DESTROY_SUCCESS="SKIPPED"
  declare -g RESULT_PLAN_LIMITS_APPLICABILITY="SKIPPED"
  declare -g RESULT_DESTROY_PLAN_LIMITS_APPLICABILITY="SKIPPED"

  ENV_IS_ELIGIBLE="true"

  # Log all inputs for debugging
  start-group "Inputs for ${input_environment_name}"
  log-info "Environment: ${input_environment_name}"
  log-info "Actor: ${GITHUB_ACTOR}"
  log-info "PR automerge enabled: ${input_pr_auto_merge_enabled}"
  log-info ""
  log-info "Plan inputs:"
  log-info "  plan-shouldve-been-created: ${input_plan_shouldve_been_created}"
  log-info "  plan-was-created: ${input_plan_was_created}"
  log-info "  performing-apply-on-pr: ${input_performing_apply_on_pr}"
  log-info "  apply-on-pr-succeeded: ${input_apply_on_pr_succeeded}"
  log-info "  plan-count-add: ${input_plan_count_add:-<empty>}"
  log-info "  plan-count-change: ${input_plan_count_change:-<empty>}"
  log-info "  plan-count-destroy: ${input_plan_count_destroy:-<empty>}"
  log-info "  plan-count-import: ${input_plan_count_import:-<empty>}"
  log-info "  plan-count-move: ${input_plan_count_move:-<empty>}"
  log-info "  plan-count-remove: ${input_plan_count_remove:-<empty>}"
  log-info ""
  log-info "Destroy plan inputs:"
  log-info "  destroy-plan-shouldve-been-created: ${input_destroy_plan_shouldve_been_created}"
  log-info "  destroy-plan-was-created: ${input_destroy_plan_was_created}"
  log-info "  performing-destroy-on-pr: ${input_performing_destroy_on_pr}"
  log-info "  destroy-on-pr-succeeded: ${input_destroy_on_pr_succeeded}"
  log-info "  destroy-plan-count-add: ${input_destroy_plan_count_add:-<empty>}"
  log-info "  destroy-plan-count-change: ${input_destroy_plan_count_change:-<empty>}"
  log-info "  destroy-plan-count-destroy: ${input_destroy_plan_count_destroy:-<empty>}"
  log-info "  destroy-plan-count-import: ${input_destroy_plan_count_import:-<empty>}"
  log-info "  destroy-plan-count-move: ${input_destroy_plan_count_move:-<empty>}"
  log-info "  destroy-plan-count-remove: ${input_destroy_plan_count_remove:-<empty>}"
  log-info ""
  log-info "Limits configuration:"
  log-info "  ${input_pr_auto_merge_limits_json}"
  log-info ""
  log-info "Allowed actors:"
  log-info "  ${input_pr_auto_merge_from_actors_json}"
  end-group

  # 1. Configuration Validation
  start-group "Step 1: Configuration Validation (${input_environment_name})"
  if ! validate_configuration; then
    # Configuration errors are fatal - exit with error
    end-group
    log-error "Configuration validation failed - cannot continue evaluation"
    return 1
  fi
  end-group

  # 2. PR Auto-merge Enabled Check
  start-group "Step 2: PR Auto-merge Enabled Check (${input_environment_name})"
  if ! check_pr_automerge_enabled; then
    ENV_IS_ELIGIBLE="false"
  fi
  end-group

  # 3. Actor Authorization Check
  start-group "Step 3: Actor Authorization Check (${input_environment_name})"
  if ! check_actor_authorization; then
    ENV_IS_ELIGIBLE="false"
  fi
  end-group

  # 4. Plan Creation Validation
  start-group "Step 4: Plan Creation Validation (${input_environment_name})"
  if ! validate_plan_creation; then
    ENV_IS_ELIGIBLE="false"
  fi
  end-group

  # 5. Apply/Destroy Operation Success Check
  start-group "Step 5: Operation Success Check (${input_environment_name})"
  if ! check_operation_success; then
    ENV_IS_ELIGIBLE="false"
  fi
  end-group

  # 6. Determine Limit Applicability
  start-group "Step 6: Limit Applicability (${input_environment_name})"
  determine_limit_applicability
  end-group

  # Only proceed with count validation and limit evaluation if limits are not all ignored
  if [[ "${ALL_LIMITS_IGNORED}" == "false" ]]; then
    local counts_valid=true

    # 7. Count Validation
    start-group "Step 7: Count Validation (${input_environment_name})"
    if ! validate_counts; then
      ENV_IS_ELIGIBLE="false"
      counts_valid=false
    fi
    end-group

    # Only proceed with aggregation and limit evaluation if counts are valid
    if [[ "${counts_valid}" == "true" ]]; then
      # 8. Count Aggregation
      start-group "Step 8: Count Aggregation (${input_environment_name})"
      aggregate_counts
      end-group

      # 9. Limit Evaluation
      start-group "Step 9: Limit Evaluation (${input_environment_name})"
      if ! evaluate_limits; then
        ENV_IS_ELIGIBLE="false"
      fi
      end-group
    fi
  else
    log-info "Skipping count validation and limit evaluation (all limits ignored)"
  fi

  # 10. Final Eligibility Determination for this environment
  start-group "Step 10: Final Eligibility Determination (${input_environment_name})"
  log-info "Final eligibility: ${ENV_IS_ELIGIBLE}"
  if [[ "${ENV_IS_ELIGIBLE}" == "true" ]]; then
    log-info "Environment '${input_environment_name}' is ELIGIBLE for PR automerge"
  else
    log-info "Environment '${input_environment_name}' is NOT ELIGIBLE for PR automerge"
  fi
  end-group

  return 0
}

# ============================================================================
# Main Multi-File Processing Logic
# ============================================================================

function main {
  log-info "Starting automerge eligibility evaluation..."
  log-info "Metadata files pattern: ${input_metadata_files_pattern}"

  # Track overall results
  local overall_eligible="true"
  local environments_processed=0
  local environments_eligible=0
  local environments_ineligible=0
  declare -a ENVIRONMENT_RESULTS=()

  # Find all metadata files matching the pattern
  start-group "File Discovery"
  shopt -s nullglob
  local files=(${input_metadata_files_pattern})
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    log-warn "No metadata files found matching pattern: ${input_metadata_files_pattern}"
    log-info "Setting is-eligible=false (no files to process)"
    set-output "is-eligible" "false"
    end-group
    return 0
  fi

  log-info "Found ${#files[@]} metadata file(s):"
  for file in "${files[@]}"; do
    log-info "  - ${file}"
  done
  end-group

  # Process each metadata file
  for file in "${files[@]}"; do
    start-group "Processing: ${file}"

    # Validate metadata file
    if ! validate_metadata_file "${file}"; then
      log-error "Skipping invalid metadata file: ${file}"
      overall_eligible="false"
      ENVIRONMENT_RESULTS+=("INVALID:${file}")
      end-group
      continue
    fi

    # Extract environment data from metadata file
    extract_environment_data "${file}"
    local env_name="${input_environment_name}"

    log-info "Extracted data for environment: ${env_name}"
    end-group

    # Evaluate this environment
    if ! evaluate_single_environment; then
      # Fatal error during evaluation (e.g., configuration validation failure)
      log-error "Fatal error evaluating environment '${env_name}'"
      end-group
      log-error "Exiting due to fatal error in environment evaluation"
      return 1
    fi

    environments_processed=$((environments_processed + 1))

    if [[ "${ENV_IS_ELIGIBLE}" == "true" ]]; then
      environments_eligible=$((environments_eligible + 1))
      ENVIRONMENT_RESULTS+=("ELIGIBLE:${env_name}")
      log-info "✅ Environment '${env_name}' is eligible for automerge"
    else
      environments_ineligible=$((environments_ineligible + 1))
      ENVIRONMENT_RESULTS+=("INELIGIBLE:${env_name}")
      overall_eligible="false"
      log-info "❌ Environment '${env_name}' is NOT eligible for automerge"
    fi
  done

  # Final summary
  start-group "Final Summary"
  log-info ""
  log-info "=========================================="
  log-info "Automerge Eligibility Summary"
  log-info "=========================================="
  log-info "Files found: ${#files[@]}"
  log-info "Environments processed: ${environments_processed}"
  log-info "Environments eligible: ${environments_eligible}"
  log-info "Environments ineligible: ${environments_ineligible}"
  log-info ""
  log-info "Per-environment results:"
  for result in "${ENVIRONMENT_RESULTS[@]}"; do
    local status="${result%%:*}"
    local name="${result#*:}"
    case "${status}" in
      ELIGIBLE)
        log-info "  ✅ ${name}"
        ;;
      INELIGIBLE)
        log-info "  ❌ ${name}"
        ;;
      INVALID)
        log-info "  ⚠️  ${name} (invalid file)"
        ;;
      ERROR)
        log-info "  💥 ${name} (error during evaluation)"
        ;;
    esac
  done
  log-info ""
  if [[ "${overall_eligible}" == "true" ]]; then
    log-info "✅ FINAL RESULT: All environments eligible - PR CAN be automerged"
  else
    log-info "❌ FINAL RESULT: Not all environments eligible - PR CANNOT be automerged"
  fi
  log-info "=========================================="
  end-group

  # Set output
  set-output "is-eligible" "${overall_eligible}"

  return 0
}

# Run main function and propagate exit code
# Use return when sourced (GitHub Actions), exit when executed directly (testing)
main
_main_exit_code=$?
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced - return to allow caller to capture exit code
  return ${_main_exit_code}
else
  # Script is being executed directly - exit with the code
  exit ${_main_exit_code}
fi