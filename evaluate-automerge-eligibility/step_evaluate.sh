#!/bin/env bash
#
# Source for the evaluate step
#
# Evaluates whether a pull request is eligible for automatic merging based on
# Terraform plan changes, configured limits, and actor restrictions.
#
# This script processes multiple metadata files from capture-matrix-job-meta
# and produces an aggregated eligibility decision across all environments.
# With a relevance file from the matrix builder it judges every environment of
# the run, including those no job ran for (docs/Path-relevance.md §8). The test
# jobs' metadata only names the tolerated failing tests (docs/Auto-merge.md §5.1).
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
# The list names who may auto-merge; it never means "everyone". The engine
# refuses an enabled environment without one, so an empty or missing list here
# is a broken input and fails closed. Logins compare without case, as GitHub's do.
function check_actor_authorization {
  log-info "Checking actor authorization..."
  log-info "  Current actor: ${GITHUB_ACTOR}"

  local list_type login_count
  list_type=$(jq -r 'type' <<<"${input_pr_auto_merge_from_actors_json}" 2>/dev/null || echo "unreadable")
  if [[ "${list_type}" != "array" ]]; then
    add_failure_reason "The actor list that applies to this environment (pr-auto-merge-from-actors) is ${input_pr_auto_merge_from_actors_json:-empty}, not a list of logins, so no pull request may auto-merge"
    log-info "Actor authorization: FAIL"
    RESULT_ACTOR_AUTH="FAIL"
    return 1
  fi

  login_count=$(jq -r 'map(select(type == "string" and . != "")) | length' <<<"${input_pr_auto_merge_from_actors_json}")
  if [[ "${login_count}" -eq 0 ]]; then
    add_failure_reason "The actor list that applies to this environment (pr-auto-merge-from-actors) names nobody, so no pull request may auto-merge; name the accounts in pr-auto-merge-from-actors-yml"
    log-info "Actor authorization: FAIL"
    RESULT_ACTOR_AUTH="FAIL"
    return 1
  fi

  local actor_found
  actor_found=$(jq -r --arg actor "${GITHUB_ACTOR}" \
    'map(select(type == "string" and ascii_downcase == ($actor | ascii_downcase))) | length' <<<"${input_pr_auto_merge_from_actors_json}")

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
# Counts are judged only when they come from a complete JSON plan. The console
# text holds resource values, which can forge its summary line; an incomplete
# plan (-target, changes deferred to a later plan) counts only part of the change.
# Args: $1 = "plan" or "destroy plan", $2 = its counts-source, $3 = its plan-complete
# Returns: 0 when the counts can be judged, 1 otherwise (reason recorded)
function validate_count_evidence {
  local what="${1}"
  local source="${2}"
  local complete="${3}"

  # An empty output and an absent one read the same: the parse step said nothing
  if [[ "${source}" != "json" ]]; then
    add_failure_reason "The ${what} of '${input_environment_name}' was not counted from its JSON plan (${source:+counts-source: }${source:-no counts-source}), so its counts cannot be trusted for auto-merge"
    return 1
  fi
  if [[ "${complete}" == "true" ]]; then
    log-info "    counted from the JSON plan, which is complete [OK]"
    return 0
  fi
  if [[ "${complete}" == "false" ]]; then
    add_failure_reason "The ${what} of '${input_environment_name}' is not complete (a -target plan, or changes deferred to a later plan), so its counts do not cover every change"
  else
    add_failure_reason "The ${what} of '${input_environment_name}' does not say it is complete (${complete:+plan-complete: }${complete:-no plan-complete}), so its counts may not cover every change"
  fi
  return 1
}

function validate_counts {
  log-info "Validating plan counts..."
  local counts_valid=true
  local evidence_valid=true

  local count_types=("add" "change" "destroy" "import" "move" "remove")

  if [[ "${INCLUDE_PLAN_LIMITS}" == "true" ]]; then
    log-info "  Checking plan counts..."
    validate_count_evidence "plan" "${input_plan_counts_source}" "${input_plan_complete}" || evidence_valid=false
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
    validate_count_evidence "destroy plan" "${input_destroy_plan_counts_source}" "${input_destroy_plan_complete}" || evidence_valid=false
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
  fi
  if [[ "${counts_valid}" == "false" || "${evidence_valid}" == "false" ]]; then
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

# 10. Operation Outcomes
# allow-failing-terraform-operations keeps the job and the check green; it never
# means "merge without review", so a tolerated failure blocks auto-merge too.
function check_operation_outcomes {
  log-info "Checking the outcomes of the Terraform operations (${_OPERATION_STEP_IDS[*]})..."

  if [[ -z "${input_failed_operations}" ]]; then
    log-info "  No operation failed or was cancelled"
    log-info "Operation outcomes: PASS"
    RESULT_OPERATION_OUTCOMES="PASS"
    return 0
  fi

  add_failure_reason "Terraform operation(s) did not succeed: ${input_failed_operations}. A failure allow-failing-terraform-operations tolerates still blocks auto-merge, environment is ineligible for PR auto merge"
  log-info "Operation outcomes: FAIL"
  RESULT_OPERATION_OUTCOMES="FAIL"
  return 1
}

# 4-9, and 10 unless it still runs, for an environment whose plan-based checks
# cannot be run, recorded rather than skipped silently so the log shows they
# were considered
# Args: $1 = the result recorded for each check, $2 = why,
#       $3 = "with-operations" to record check 10 as well
function record_plan_checks {
  local result="${1}"
  log-info "${2}"
  RESULT_PLAN_CREATION="${result}"
  RESULT_DESTROY_PLAN_CREATION="${result}"
  RESULT_APPLY_SUCCESS="${result}"
  RESULT_DESTROY_SUCCESS="${result}"
  RESULT_PLAN_LIMITS_APPLICABILITY="${result}"
  RESULT_DESTROY_PLAN_LIMITS_APPLICABILITY="${result}"
  log-info "  Plan creation: ${RESULT_PLAN_CREATION}"
  log-info "  Destroy plan creation: ${RESULT_DESTROY_PLAN_CREATION}"
  log-info "  Apply on PR: ${RESULT_APPLY_SUCCESS}"
  log-info "  Destroy on PR: ${RESULT_DESTROY_SUCCESS}"
  log-info "  Plan limits: ${RESULT_PLAN_LIMITS_APPLICABILITY}"
  log-info "  Destroy plan limits: ${RESULT_DESTROY_PLAN_LIMITS_APPLICABILITY}"
  if [[ "${3:-}" == "with-operations" ]]; then
    RESULT_OPERATION_OUTCOMES="${result}"
    log-info "  Operation outcomes: ${RESULT_OPERATION_OUTCOMES}"
  fi
}

# Log the plan inputs read from an affected environment's metadata
function log_plan_inputs {
  log-info "Goals granted: ${input_goals_granted_json}"
  log-info "Failed or cancelled operations: ${input_failed_operations:-<none>}"
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
  log-info "  plan-counts-source: ${input_plan_counts_source:-<empty>}"
  log-info "  plan-complete: ${input_plan_complete:-<empty>}"
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
  log-info "  destroy-plan-counts-source: ${input_destroy_plan_counts_source:-<empty>}"
  log-info "  destroy-plan-complete: ${input_destroy_plan_complete:-<empty>}"
}

# 4-10 for an affected environment, from its metadata
# Clears ENV_IS_ELIGIBLE on any failure
function run_plan_checks {
  if [[ -n "${input_goals_granted_problem}" ]]; then
    start-group "Steps 4-9: Plan-based checks (${input_environment_name})"
    add_failure_reason "${input_goals_granted_problem}"
    record_plan_checks "UNKNOWN" "The goals this run granted are unknown, so no plan-based check can be judged"
    ENV_IS_ELIGIBLE="false"
    end-group
  else
    run_goal_checks
  fi

  # 10. Operation Outcomes
  start-group "Step 10: Operation Outcomes (${input_environment_name})"
  if ! check_operation_outcomes; then
    ENV_IS_ELIGIBLE="false"
  fi
  end-group
}

# 4-9 for an affected environment whose granted goals are known
# Clears ENV_IS_ELIGIBLE on any failure
function run_goal_checks {
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
}

# ============================================================================
# Single Environment Evaluation Logic
# ============================================================================

# Evaluate a single environment's eligibility
# Args: $1 = "affected" (default): every check, all input_* variables must be set
#       "unaffected": checks 1-3 only, from the pr-auto-merge input_* variables
#       "unplanned": checks 1-3 as for "unaffected", then not eligible for
#                    input_unplanned_reason (skipped although it may be relevant)
# Returns: 0 if evaluation completed (check ENV_IS_ELIGIBLE for result), 1 on fatal error
function evaluate_single_environment {
  local scope="${1:-affected}"
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
  declare -g RESULT_OPERATION_OUTCOMES="SKIPPED"

  ENV_IS_ELIGIBLE="true"

  # Log all inputs for debugging
  start-group "Inputs for ${input_environment_name}"
  log-info "Environment: ${input_environment_name}"
  log-info "Actor: ${GITHUB_ACTOR}"
  log-info "PR automerge enabled: ${input_pr_auto_merge_enabled}"
  log-info ""
  if [[ "${scope}" == "unaffected" ]]; then
    log-info "Not affected by this change: values from the relevance file, no plan inputs"
  elif [[ "${scope}" == "unplanned" ]]; then
    log-info "Skipped without a plan although the change may concern it: values from the relevance file, no plan inputs"
  else
    log_plan_inputs
  fi
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

  if [[ "${scope}" == "unaffected" ]]; then
    # No job ran, so there is no plan to validate and nothing to count
    start-group "Steps 4-10: Plan-based checks (${input_environment_name})"
    record_plan_checks "NOT AFFECTED" "Environment is not affected by this change and no job ran for it" with-operations
    end-group
  elif [[ "${scope}" == "unplanned" ]]; then
    start-group "Steps 4-10: Plan-based checks (${input_environment_name})"
    add_failure_reason "${input_unplanned_reason}"
    record_plan_checks "NOT PLANNED" "No job ran for the environment, so nothing shows what the change does to it" with-operations
    ENV_IS_ELIGIBLE="false"
    end-group
  else
    run_plan_checks
  fi

  # 11. Final Eligibility Determination for this environment
  start-group "Step 11: Final Eligibility Determination (${input_environment_name})"
  log-info "Final eligibility: ${ENV_IS_ELIGIBLE}"
  if [[ "${ENV_IS_ELIGIBLE}" == "true" ]]; then
    log-info "Environment '${input_environment_name}' is ELIGIBLE for PR automerge"
  else
    log-info "Environment '${input_environment_name}' is NOT ELIGIBLE for PR automerge"
  fi
  end-group

  return 0
}

# Judge each metadata file on its own: the behaviour without a relevance file.
# Updates main's counters, like record_environment_result.
# Args: $@ = metadata files found
# Returns: 0 when evaluation completed, 1 on a fatal configuration error
function evaluate_metadata_files {
  local files=("$@")
  local file

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

  return 0
}

# ============================================================================
# Relevance File Processing Logic
# ============================================================================

# Record one environment's outcome in main's counters and result list, which
# this function reaches through bash's dynamic scoping
# Args: $1 = "true" if eligible, $2 = environment, $3 = note for the per-environment summary (optional)
function record_environment_result {
  local eligible="${1}"
  local name="${2}"
  local label="${2}${3:+ ${3}}"
  environments_processed=$((environments_processed + 1))
  if [[ "${eligible}" == "true" ]]; then
    environments_eligible=$((environments_eligible + 1))
    ENVIRONMENT_RESULTS+=("ELIGIBLE:${label}")
    log-info "✅ Environment '${name}' is eligible for automerge"
  else
    environments_ineligible=$((environments_ineligible + 1))
    ENVIRONMENT_RESULTS+=("INELIGIBLE:${label}")
    overall_eligible="false"
    log-info "❌ Environment '${name}' is NOT eligible for automerge"
  fi
}

# Judge every environment the relevance file lists. Without it an environment
# whose job never captured metadata is invisible, and a run with no metadata
# at all (every environment unaffected) could only be refused or merged
# blindly; with it, an affected environment needs its metadata and an
# unaffected one must still pass configuration, enabled and actor checks.
# Updates main's counters, like record_environment_result.
# Args: $1 = relevance file path, $2... = metadata files found
# Returns: 0 when evaluation completed, 1 on a fatal configuration error
function evaluate_with_relevance {
  local relevance_file="${1}"
  shift
  local files=("$@")

  start-group "Relevance File"
  if ! validate_relevance_file "${relevance_file}"; then
    log-warn "Relevance file '${relevance_file}' is unusable, the environments of this run are unknown, not eligible for PR auto merge"
    overall_eligible="false"
    end-group
    return 0
  fi

  local env_count
  env_count=$(jq '.environments | length' "${relevance_file}")
  RELEVANCE_ENV_COUNT="${env_count}"
  RELEVANCE_AFFECTED_COUNT=$(jq '[.environments[] | select(.verdict == "run")] | length' "${relevance_file}")
  if [[ "${env_count}" -eq 0 ]]; then
    # The matrix builder rejects an empty environments list, so this is a broken
    # input, and an empty set must not pass vacuously.
    log-warn "Relevance file '${relevance_file}' lists no environments, nothing establishes that auto-merge is permitted, not eligible for PR auto merge"
    overall_eligible="false"
    end-group
    return 0
  fi
  log-info "Relevance file lists ${env_count} environment(s), ${RELEVANCE_AFFECTED_COUNT} affected"
  end-group

  # An affected environment a failed stage held back has no metadata either,
  # because its job never ran. It is not eligible for the same reason as one
  # that crashed, but the operator is told the truth (docs/Environment-ordering.md §7.5).
  declare -A held_back_reason_for=()
  local held_env held_reason
  read_stage_results
  while IFS=$'\x1f' read -r held_env held_reason; do
    [[ -n "${held_env}" ]] && held_back_reason_for["${held_env}"]="${held_reason}"
  done < <(get_held_back_reasons "${relevance_file}")
  [[ -n "${STAGE_RESULTS_FILE}" ]] && rm -f "${STAGE_RESULTS_FILE}"

  # Index the metadata by github-environment, the key both files share
  start-group "Metadata Matching"
  declare -A metadata_file_for=()
  declare -A metadata_count_for=()
  local file github_env
  for file in "${files[@]}"; do
    if ! validate_metadata_file "${file}"; then
      log-error "Skipping invalid metadata file: ${file}"
      overall_eligible="false"
      ENVIRONMENT_RESULTS+=("INVALID:${file}")
      continue
    fi
    github_env=$(get_environment_name "${file}")
    # A job for an environment the builder never listed means the two inputs
    # describe different runs; nothing about either can then be trusted.
    if ! jq -e --arg ge "${github_env}" 'any(.environments[]; ."github-environment" == $ge)' "${relevance_file}" >/dev/null; then
      log-warn "Metadata file '${file}' is for environment '${github_env}', which the relevance file does not list, not eligible for PR auto merge"
      overall_eligible="false"
      ENVIRONMENT_RESULTS+=("UNKNOWN:${github_env}")
      continue
    fi
    metadata_count_for["${github_env}"]=$((${metadata_count_for["${github_env}"]:-0} + 1))
    metadata_file_for["${github_env}"]="${file}"
    log-info "  ${file} -> ${github_env}"
  done
  end-group

  local index verdict count
  for ((index = 0; index < env_count; index++)); do
    github_env=$(jq -r ".environments[${index}].\"github-environment\"" "${relevance_file}")
    verdict=$(jq -r ".environments[${index}].verdict" "${relevance_file}")
    count="${metadata_count_for["${github_env}"]:-0}"

    if [[ "${count}" -gt 1 ]]; then
      start-group "Completeness: ${github_env}"
      log-warn "${count} metadata files for environment '${github_env}', expected exactly one, environment is ineligible for PR auto merge"
      end-group
      record_environment_result "false" "${github_env}" "(${count} metadata files)"

    elif [[ "${count}" -eq 1 ]]; then
      if [[ "${verdict}" == "skip" ]]; then
        # A job that did run produced a plan; ignoring it would be the unsafe error
        log-warn "Environment '${github_env}' has a metadata file although the relevance file marks it unaffected, judging it on its metadata"
      fi
      extract_environment_data "${metadata_file_for["${github_env}"]}"
      if ! evaluate_single_environment "affected"; then
        log-error "Exiting due to fatal error in environment evaluation of '${github_env}'"
        return 1
      fi
      record_environment_result "${ENV_IS_ELIGIBLE}" "${github_env}"

    elif [[ "${verdict}" == "run" && -n "${held_back_reason_for["${github_env}"]:-}" ]]; then
      start-group "Completeness: ${github_env}"
      log-warn "${held_back_reason_for["${github_env}"]}"
      end-group
      record_environment_result "false" "${github_env}" "(held back)"

    elif [[ "${verdict}" == "run" ]]; then
      start-group "Completeness: ${github_env}"
      log-warn "No metadata file for affected environment '${github_env}': its job was cancelled or failed before capturing metadata, environment is ineligible for PR auto merge"
      end-group
      record_environment_result "false" "${github_env}" "(affected, no metadata)"

    else
      # Skipped, without a job: unaffected, unless it was dropped before
      # relevance and the change may concern it. Either way its enabled flag,
      # actors and limits are still judged, the limits as defence in depth.
      extract_relevance_entry_data "${relevance_file}" "${index}"
      if [[ -n "${input_unplanned_reason}" ]]; then
        if ! evaluate_single_environment "unplanned"; then
          log-error "Exiting due to fatal error in environment evaluation of '${github_env}'"
          return 1
        fi
        record_environment_result "${ENV_IS_ELIGIBLE}" "${github_env}" "(skipped, never planned)"
      else
        if ! evaluate_single_environment "unaffected"; then
          log-error "Exiting due to fatal error in environment evaluation of '${github_env}'"
          return 1
        fi
        record_environment_result "${ENV_IS_ELIGIBLE}" "${github_env}" "(not affected)"
      fi
    fi
  done

  return 0
}

# ============================================================================
# Test Jobs
# ============================================================================

# Keep every tolerated failing or erroring test in main's TOLERATED_TESTS, as
# "status<TAB>file<TAB>lane". The conclusion judges the test jobs: an untolerated
# failure turns it red and this job never runs, and allow-failing-terraform-tests
# is the lever that lets a pull request auto-merge although a lane fails
# (docs/Auto-merge.md D13). So nothing here changes eligibility, and an
# unreadable file is only logged.
# Args: $1 = glob pattern of the test jobs' metadata files
function collect_tolerated_tests {
  local pattern="${1}"
  local files=() file tolerated status test_file lane

  start-group "Test Jobs"
  if [[ -z "${pattern}" ]]; then
    log-info "No test metadata files pattern, no test job is named"
    end-group
    return 0
  fi
  shopt -s nullglob
  files=(${pattern})
  shopt -u nullglob
  log-info "Found ${#files[@]} test metadata file(s) matching: ${pattern}"

  for file in "${files[@]}"; do
    if ! jq empty "${file}" 2>/dev/null; then
      log-warn "Test metadata file '${file}' is not valid JSON, it names no test"
      continue
    fi
    while IFS=$'\t' read -r tolerated status test_file lane; do
      if [[ "${tolerated}" == "true" ]]; then
        TOLERATED_TESTS+=("${status}"$'\t'"${test_file}"$'\t'"${lane}")
        log-info "  ${test_file}${lane:+ (lane ${lane})}: ${status}, tolerated by allow-failing-terraform-tests, does not block auto-merge"
      else
        log-warn "  ${test_file}${lane:+ (lane ${lane})}: ${status} and not tolerated; the conclusion judges the test jobs, not this step"
      fi
    done < <(describe_failing_test "${file}")
  done
  log-info "Tolerated failing or erroring tests: ${#TOLERATED_TESTS[@]}"
  end-group
}

# Name every tolerated failing or erroring test in a notice, so a merge past a
# failing test is never silent
# Args: $1 = "true" when the pull request is eligible
function report_tolerated_tests {
  local eligible="${1}"
  local entry status test_file lane what message
  for entry in "${TOLERATED_TESTS[@]}"; do
    IFS=$'\t' read -r status test_file lane <<<"${entry}"
    what="the tolerated $([[ "${status}" == "error" ]] && echo "erroring" || echo "failing") test ${test_file}${lane:+ (lane ${lane})}"
    if [[ "${eligible}" == "true" ]]; then
      message="auto-merge eligible despite ${what}"
    else
      message="${what^} does not block auto-merge; the pull request is not eligible for other reasons"
    fi
    log-info "${message}"
    echo "::notice title=Auto-merge::$(escape-annotation-message "${message}")"
  done
}

# ============================================================================
# Main Multi-File Processing Logic
# ============================================================================

function main {
  log-info "Starting automerge eligibility evaluation..."
  log-info "Metadata files pattern: ${input_metadata_files_pattern}"
  log-info "Relevance file: ${input_relevance_file:-<none>}"
  log-info "Test metadata files pattern: ${input_test_metadata_files_pattern:-<none>}"

  local relevance_file="${input_relevance_file:-}"
  if [[ -n "${relevance_file}" && ! -e "${relevance_file}" ]]; then
    # The workflow downloads the relevance artifact with continue-on-error, as a
    # download by name of a missing artifact throws; no file then means no file.
    log-warn "Relevance file '${relevance_file}' does not exist, evaluating the metadata files alone"
    relevance_file=""
  fi

  # Track overall results
  local overall_eligible="true"
  local environments_processed=0
  local environments_eligible=0
  local environments_ineligible=0
  declare -a ENVIRONMENT_RESULTS=()
  declare -a TOLERATED_TESTS=()
  RELEVANCE_ENV_COUNT=""
  RELEVANCE_AFFECTED_COUNT=""

  collect_tolerated_tests "${input_test_metadata_files_pattern:-}"

  # Find all metadata files matching the pattern
  start-group "File Discovery"
  shopt -s nullglob
  local files=(${input_metadata_files_pattern})
  shopt -u nullglob

  # With a relevance file zero metadata files is a legitimate run: nothing was affected
  if [[ ${#files[@]} -eq 0 && -z "${relevance_file}" ]]; then
    log-warn "No metadata files found matching pattern: ${input_metadata_files_pattern}"
    log-info "Setting is-eligible=false (no files to process)"
    set-output "is-eligible" "false"
    end-group
    report_tolerated_tests "false"
    return 0
  fi

  log-info "Found ${#files[@]} metadata file(s):"
  for file in "${files[@]}"; do
    log-info "  - ${file}"
  done
  end-group

  if [[ -n "${relevance_file}" ]]; then
    if ! evaluate_with_relevance "${relevance_file}" "${files[@]}"; then
      return 1
    fi
  elif ! evaluate_metadata_files "${files[@]}"; then
    return 1
  fi

  # Final summary
  start-group "Final Summary"
  log-info ""
  log-info "=========================================="
  log-info "Automerge Eligibility Summary"
  log-info "=========================================="
  log-info "Files found: ${#files[@]}"
  if [[ -n "${RELEVANCE_ENV_COUNT}" ]]; then
    log-info "Environments in relevance file: ${RELEVANCE_ENV_COUNT} (${RELEVANCE_AFFECTED_COUNT} affected)"
  fi
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
      UNKNOWN)
        log-info "  ❓ ${name} (not in the relevance file)"
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
  log-info "Tolerated failing or erroring tests: ${#TOLERATED_TESTS[@]}"
  log-info "=========================================="
  end-group

  report_tolerated_tests "${overall_eligible}"

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