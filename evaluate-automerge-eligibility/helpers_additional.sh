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

# The pr-auto-merge-* getters read the same resolved values from two places: a
# metadata file's matrix row, and an environment's entry in relevance.json,
# which carries the values that row would have had. One reader for both keeps
# an unaffected environment judged exactly as an affected one would be.
_METADATA_VARS='.matrix_context.vars'

# Extract pr-auto-merge-enabled from a metadata or relevance file
# Args: $1 = JSON file path, $2 = jq path of the object holding the value (default: the matrix row)
function get_pr_auto_merge_enabled {
  local file="${1}"
  local base="${2:-${_METADATA_VARS}}"
  local val
  val=$(extract_from_metadata "${file}" "${base}.\"pr-auto-merge-enabled\"")
  # Convert to "true" or "false" string
  if [[ "${val}" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Extract pr-auto-merge-limits as JSON string from a metadata or relevance file
# Args: $1 = JSON file path, $2 = jq path of the object holding the value (default: the matrix row)
function get_pr_auto_merge_limits_json {
  local file="${1}"
  local base="${2:-${_METADATA_VARS}}"
  jq -c "${base}.\"pr-auto-merge-limits\" // {}" "${file}" 2>/dev/null || echo "{}"
}

# Extract pr-auto-merge-from-actors as compact JSON from a metadata or relevance file,
# as it is: null when absent, so a missing list is refused rather than read as empty
# Args: $1 = JSON file path, $2 = jq path of the object holding the value (default: the matrix row)
function get_pr_auto_merge_from_actors_json {
  local file="${1}"
  local base="${2:-${_METADATA_VARS}}"
  jq -c "${base}.\"pr-auto-merge-from-actors\"" "${file}" 2>/dev/null || echo "null"
}

# The goals the engine grants (goals-granted), the vocabulary of the workflow's
# operation gates: no 'all', no '-on-pr'. On a pull request 'apply' and
# 'destroy' are granted only through apply-on-pr and destroy-on-pr.
_GRANTED_GOALS=(init format validate lint plan apply destroy-plan destroy)

# Why the metadata's goals-granted cannot be read, or nothing when it can. The
# raw goals are not a fallback: they are what the caller asked for, not what the
# run's gates did, and "a plan should have been created" must mean the same to
# this check as to the plan step.
# Args: $1 = metadata file path
function get_goals_granted_problem {
  local file="${1}"
  jq -r --args '
    .matrix_context.vars as $vars
    | if ($vars | type) != "object" or ($vars | has("goals-granted") | not) then
        "The metadata has no goals-granted, the goals this run granted the environment, so what it should have planned is unknown (metadata from an older workflow?), environment is ineligible for PR auto merge"
      elif ($vars["goals-granted"] | type) != "array" then
        "The metadata'\''s goals-granted is \($vars["goals-granted"] | tojson), not a list of goals, so what the environment should have planned is unknown, environment is ineligible for PR auto merge"
      else
        [$vars["goals-granted"][] | select(type != "string" or (. as $g | $ARGS.positional | index($g) | not))] as $unknown
        | if ($unknown | length) > 0 then
            "The metadata'\''s goals-granted holds \($unknown[0] | tojson), which is not a goal (\($ARGS.positional | join(", "))), so what the environment should have planned is unknown, environment is ineligible for PR auto merge"
          else "" end
      end' "${_GRANTED_GOALS[@]}" <"${file}" 2>/dev/null ||
    echo "The metadata's goals-granted could not be read, environment is ineligible for PR auto merge"
}

# "true" if the metadata's goals-granted holds the goal, "false" otherwise
# Args: $1 = metadata file path, $2 = goal
function get_goal_granted {
  local file="${1}"
  local goal="${2}"
  jq -r --arg goal "${goal}" '
    .matrix_context.vars["goals-granted"]
    | if type == "array" and index($goal) != null then "true" else "false" end' "${file}" 2>/dev/null || echo "false"
}

# The step ids of the Terraform operations, as the workflow's environment job
# names them. A tolerated failure of any of them blocks auto-merge:
# allow-failing-terraform-operations keeps the check green, it never merges
# without review. An absent or skipped step is not a failure.
_OPERATION_STEP_IDS=(init verify-lock fmt validate lint plan apply destroy-plan destroy)

# The operation steps that ended failure or cancelled, as "id (outcome)" joined
# by ", ", or nothing
# Args: $1 = metadata file path
function get_failed_operations {
  local file="${1}"
  jq -r --args '
    (.steps // {}) as $steps
    | [$ARGS.positional[] as $id
       | (($steps[$id] // {}) | if type == "object" then (.outcome // "") else "" end) as $outcome
       | select($outcome == "failure" or $outcome == "cancelled")
       | "\($id) (\($outcome))"]
    | join(", ")' "${_OPERATION_STEP_IDS[@]}" <"${file}" 2>/dev/null || echo "steps (unreadable)"
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

  # The goals the run granted decide what should have run; see get_goals_granted_problem
  input_goals_granted_json=$(jq -c '.matrix_context.vars["goals-granted"]' "${file}" 2>/dev/null || echo "null")
  input_goals_granted_problem=$(get_goals_granted_problem "${file}")

  # The operation steps that failed or were cancelled, tolerated or not
  input_failed_operations=$(get_failed_operations "${file}")

  # Plan-related derived values
  input_plan_shouldve_been_created=$(get_goal_granted "${file}" "plan")
  input_plan_was_created=$(get_step_outcome_success "${file}" "plan")
  input_performing_apply_on_pr=$(get_goal_granted "${file}" "apply")
  input_apply_on_pr_succeeded=$(get_step_outcome_success "${file}" "apply")

  # Plan counts from parse-plan step
  input_plan_count_add=$(get_step_output "${file}" "parse-plan" "count-add")
  input_plan_count_change=$(get_step_output "${file}" "parse-plan" "count-change")
  input_plan_count_destroy=$(get_step_output "${file}" "parse-plan" "count-destroy")
  input_plan_count_import=$(get_step_output "${file}" "parse-plan" "count-import")
  input_plan_count_move=$(get_step_output "${file}" "parse-plan" "count-move")
  input_plan_count_remove=$(get_step_output "${file}" "parse-plan" "count-remove")
  # Where the counts came from and whether the plan covers every change; see validate_count_evidence
  input_plan_counts_source=$(get_step_output "${file}" "parse-plan" "counts-source")
  input_plan_complete=$(get_step_output "${file}" "parse-plan" "plan-complete")

  # Destroy plan-related derived values
  input_destroy_plan_shouldve_been_created=$(get_goal_granted "${file}" "destroy-plan")
  input_destroy_plan_was_created=$(get_step_outcome_success "${file}" "destroy-plan")
  input_performing_destroy_on_pr=$(get_goal_granted "${file}" "destroy")
  input_destroy_on_pr_succeeded=$(get_step_outcome_success "${file}" "destroy")

  # Destroy plan counts from parse-destroy-plan step
  input_destroy_plan_count_add=$(get_step_output "${file}" "parse-destroy-plan" "count-add")
  input_destroy_plan_count_change=$(get_step_output "${file}" "parse-destroy-plan" "count-change")
  input_destroy_plan_count_destroy=$(get_step_output "${file}" "parse-destroy-plan" "count-destroy")
  input_destroy_plan_count_import=$(get_step_output "${file}" "parse-destroy-plan" "count-import")
  input_destroy_plan_count_move=$(get_step_output "${file}" "parse-destroy-plan" "count-move")
  input_destroy_plan_count_remove=$(get_step_output "${file}" "parse-destroy-plan" "count-remove")
  input_destroy_plan_counts_source=$(get_step_output "${file}" "parse-destroy-plan" "counts-source")
  input_destroy_plan_complete=$(get_step_output "${file}" "parse-destroy-plan" "plan-complete")
}

# Set the input_* variables of the configuration, enabled and actor checks from
# one environment's entry in relevance.json. An unaffected environment has no
# job and so no metadata; its plan inputs are never read.
# Args: $1 = relevance file path, $2 = index into .environments
function extract_relevance_entry_data {
  local file="${1}"
  local index="${2}"
  local base=".environments[${index}]"

  input_environment_name=$(extract_from_metadata "${file}" "${base}.\"github-environment\"")
  input_pr_auto_merge_enabled=$(get_pr_auto_merge_enabled "${file}" "${base}")
  input_pr_auto_merge_limits_json=$(get_pr_auto_merge_limits_json "${file}" "${base}")
  input_pr_auto_merge_from_actors_json=$(get_pr_auto_merge_from_actors_json "${file}" "${base}")
  input_unplanned_reason=$(get_unplanned_reason "${file}" "${index}")
}

# Why an environment the relevance file skips was never planned although the
# change may concern it, or nothing when the skip means "not affected". On a
# pull request an environment whose trigger-events lack pull_request is dropped
# before relevance is applied, so its skip says nothing about the change; the
# engine publishes whether a changed file is relevant to it all the same
# (docs/Auto-merge.md D6). A file from before that field fails closed for such
# an environment; a plain relevance skip without it is judged as before.
# Args: $1 = relevance file path, $2 = index into .environments
function get_unplanned_reason {
  local file="${1}"
  local index="${2}"
  jq -r --argjson index "${index}" '
    .environments[$index] as $entry
    | (($entry.environment // $entry["github-environment"]) | tostring) as $name
    | (($entry.reasons // [])[0] // "") as $reason
    | (($reason | startswith("trigger-events:"))
       or (($entry["trigger-events"] | type) == "array" and (any($entry["trigger-events"][]; . == "pull_request") | not))
      ) as $out_of_pull_requests
    | if $entry.relevant == true and $out_of_pull_requests then
        "The change touches '\''\($name)'\'', which takes no part in pull requests, so it was never planned, environment is ineligible for PR auto merge"
      elif $entry.relevant == true then
        "The change touches '\''\($name)'\'', which was skipped (\($reason)), so it was never planned, environment is ineligible for PR auto merge"
      elif ($entry | has("relevant") | not) and $out_of_pull_requests then
        "'\''\($name)'\'' takes no part in pull requests and the relevance file does not say whether the change touches it, so it may never have been planned, environment is ineligible for PR auto merge"
      else "" end' "${file}" 2>/dev/null ||
    echo "The relevance entry at index ${index} could not be read, environment is ineligible for PR auto merge"
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
# Test Job Metadata
# ============================================================================

# Describe a test job whose test ended 'fail' or 'error', as one tab-separated
# line: tolerated ("true" or "false"), status, test file, lane. Prints nothing for
# any other status. The conclusion judges the test jobs, so nothing read here
# decides eligibility (docs/Auto-merge.md D13); it is read only to name a
# tolerated failure, so a merge past a failing test is never silent.
# Args: $1 = test metadata file path (from capture-matrix-job-meta in the test job)
function describe_failing_test {
  local file="${1}"
  jq -r '
    def truthy: . == true or . == "true";
    . as $root
    | ((.steps.test.outputs.status // "") | tostring) as $status
    | select($status == "fail" or $status == "error")
    | (.matrix_context.test // {}) as $test
    | [(if ($test["allow-failing-terraform-tests"] | truthy) then "true" else "false" end),
       $status,
       ((($test.file // "") | tostring) | if . == "" then (($root.metadata.environment // "unknown test") | tostring) else . end),
       (($test.lane // "") | tostring)]
    | @tsv' "${file}"
}

# Escape a value for the message part of a GitHub workflow command
# (everything after '::'). Only %, CR and LF are special there.
function escape-annotation-message {
  local s="${1}"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "${s}"
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

# Validate that a relevance file can be trusted to name every environment
# Args: $1 = relevance file path
# Returns: 0 if valid, 1 if invalid
function validate_relevance_file {
  local file="${1}"

  if [[ ! -r "${file}" ]]; then
    log-warn "Relevance file '${file}' is not readable"
    return 1
  fi

  if ! jq empty "${file}" 2>/dev/null; then
    log-warn "Relevance file '${file}' is not valid JSON"
    return 1
  fi

  if [[ "$(jq -r '.environments | type' "${file}")" != "array" ]]; then
    log-warn "Relevance file '${file}' has no 'environments' list"
    return 1
  fi

  # Metadata is matched on github-environment, so each entry must name one, and only once.
  # relevant, reasons and trigger-events decide whether a skip counts as unaffected, so a
  # present one of the wrong shape must not be read as absent.
  local bad_entries
  bad_entries=$(jq '[.environments[] | select(
      type != "object"
      or ((."github-environment" | type) != "string")
      or ."github-environment" == ""
      or ((.verdict == "run" or .verdict == "skip") | not)
      or (has("relevant") and ((.relevant | type) != "boolean"))
      or (has("reasons") and ((.reasons | type) != "array" or any(.reasons[]; type != "string")))
      or (has("trigger-events") and ((."trigger-events" | type) != "array"))
    )] | length' "${file}")
  if [[ "${bad_entries}" -gt 0 ]]; then
    log-warn "Relevance file '${file}' has ${bad_entries} malformed environment entr(y/ies): each needs a non-empty 'github-environment' and a 'verdict' of 'run' or 'skip', and 'relevant' is a boolean, 'reasons' a list of text and 'trigger-events' a list where given"
    return 1
  fi

  local duplicates
  duplicates=$(jq -r '[.environments[]."github-environment"] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "${file}")
  if [[ -n "${duplicates}" ]]; then
    log-warn "Relevance file '${file}' lists these github-environments more than once: ${duplicates}"
    return 1
  fi

  return 0
}

# ============================================================================
# Environment Ordering (docs/Environment-ordering.md §7.5)
# ============================================================================
#
# Mirror of create-run-summary's and aggregate-validation-summaries' reading of
# the stage results, kept duplicated per the self-containment convention. When
# touching one, audit the others.

# The stage results the workflow passes (stage-results-json), normalised to an
# object of result strings in a temp file whose path is left in
# STAGE_RESULTS_FILE; empty when the input is absent, blank or not an object,
# which judges exactly as before ordering. The value is a shell-local the shim
# captured before allexport; it reaches jq through a here-string, never argv.
function read_stage_results {
  STAGE_RESULTS_FILE=""
  local raw="${input_stage_results_json:-}"
  [[ "${raw}" =~ ^[[:space:]]*$ ]] && return 0
  local file
  file=$(mktemp)
  if ! jq -ce 'if type == "object" then with_entries(select(.value | type == "string")) else error("not an object") end' \
    <<<"${raw}" >"${file}" 2>/dev/null; then
    log-warn "stage-results-json is not a JSON object of stage results, an environment without metadata is reported as cancelled or crashed"
    rm -f "${file}"
    return 0
  fi
  STAGE_RESULTS_FILE="${file}"
}

# Why each affected environment a failed stage held back was never planned, one
# per line: github-environment, the unit separator, the reason. Nothing without
# stage results. A stage job skipped for having no environments and one skipped
# because an earlier stage failed both report 'skipped'; only the builder's row
# count tells them apart (P5). Stage 1 is never held back: nothing runs before
# it, so a skipped stage 1 is a cancelled run, reported as it always was.
# Args: $1 = relevance file path
function get_held_back_reasons {
  local file="${1}"
  [[ -z "${STAGE_RESULTS_FILE:-}" ]] && return 0
  jq -r --slurpfile sr "${STAGE_RESULTS_FILE}" '
    $sr[0] as $results
    | (.counts.by_stage // {}) as $by
    | .environments[]
    | select(.verdict == "run")
    | ((.stage // 1) | tonumber? // 1) as $stage
    | select($stage >= 2
             and ($results[$stage | tostring] // "") == "skipped"
             and ((($by[$stage | tostring] // 0) | tonumber? // 0) > 0))
    | ([range(1; $stage) | select(($results[tostring] // "") as $r | $r == "failure" or $r == "cancelled")] | first) as $cause
    | (."github-environment" | tostring) as $name
    | (if $cause == null then "it is in stage \($stage), which did not run"
       elif $results[$cause | tostring] == "cancelled" then "it is in stage \($stage) and stage \($cause) was cancelled"
       else "it is in stage \($stage) and stage \($cause) failed" end) as $why
    | "\($name)\u001f'\''\($name)'\'' was held back: \($why), so it was never planned, environment is ineligible for PR auto merge"' \
    "${file}" 2>/dev/null || true
}

# ============================================================================

log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
