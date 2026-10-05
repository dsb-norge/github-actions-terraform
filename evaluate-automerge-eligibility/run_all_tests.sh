#!/bin/env bash
#
# Comprehensive test runner for step_evaluate.sh
# Tests multi-file processing with metadata files
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

# Test directory
TEST_DIR=""

# The step's output, one file per run of this suite: a fixed path in /tmp is
# shared with every other suite that uses it, and suites run in parallel.
_test_output=$(mktemp)
trap 'rm -f "${_test_output}"' EXIT

# Setup test directory
setup_test_dir() {
  TEST_DIR=$(mktemp -d)
  cd "${TEST_DIR}"
}

# Cleanup test directory
cleanup_test_dir() {
  if [[ -n "${TEST_DIR}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
}

# The goals the engine grants for raw goals on a pull request against the
# default branch (engine/dsb_tf_engine/triggers.py expand), so a test that
# describes its environment by raw goals gets the granted goals the workflow
# would have captured. Tests of goals-granted itself pass --goals-granted.
_GRANTED_FOR_RAW_GOALS='
  ["init", "format", "validate", "lint", "plan"] as $standard
  | . as $goals
  | (if index("all") != null then $standard else [$standard[] | select(. as $s | $goals | index($s) != null)] end)
    + (if index("apply-on-pr") != null then ["apply"] else [] end)
    + (if index("destroy-plan") != null then ["destroy-plan"] else [] end)
    + (if index("destroy-on-pr") != null then ["destroy"] else [] end)'

# Create a metadata file with specified parameters
# Usage: create_metadata_file <filename> <env_name> <options...>
#   --goals-granted=<json>         the row's goals-granted (default: what the engine grants for --goals)
#   --no-goals-granted             metadata without goals-granted, as an older workflow captured it
#   --step-outcome=<id>:<outcome>  a step's outcome, tolerated (conclusion success); repeatable
#   --edit=<jq>                    a jq filter applied to the finished file; repeatable
# --plan-counts and --destroy-plan-counts carry counts-source json and plan-complete true
# unless they set those keys themselves; '{}' is a parse step that produced nothing.
create_metadata_file() {
  local filename="${1}"
  local env_name="${2}"
  shift 2

  # Default values
  local pr_auto_merge_enabled="true"
  local goals='["all"]'
  local goals_granted=""
  local no_goals_granted="false"
  local step_outcomes=()
  local file_edits=()
  local actors='["dependabot[bot]"]'
  local limits='{
    "plan-max-count-add": -1,
    "plan-max-count-change": -1,
    "plan-max-count-destroy": -1,
    "plan-max-count-import": -1,
    "plan-max-count-move": -1,
    "plan-max-count-remove": -1
  }'
  local plan_outcome="success"
  local apply_outcome="skipped"
  local destroy_plan_outcome="skipped"
  local destroy_outcome="skipped"
  local plan_counts='{"count-add": "0", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}'
  local destroy_plan_counts='{}'

  # Parse options
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --pr-auto-merge-enabled=*)
        pr_auto_merge_enabled="${1#*=}"
        ;;
      --goals=*)
        goals="${1#*=}"
        ;;
      --goals-granted=*)
        goals_granted="${1#*=}"
        ;;
      --no-goals-granted)
        no_goals_granted="true"
        ;;
      --step-outcome=*)
        step_outcomes+=("${1#*=}")
        ;;
      --edit=*)
        file_edits+=("${1#*=}")
        ;;
      --actors=*)
        actors="${1#*=}"
        ;;
      --limits=*)
        limits="${1#*=}"
        ;;
      --plan-outcome=*)
        plan_outcome="${1#*=}"
        ;;
      --apply-outcome=*)
        apply_outcome="${1#*=}"
        ;;
      --destroy-plan-outcome=*)
        destroy_plan_outcome="${1#*=}"
        ;;
      --destroy-outcome=*)
        destroy_outcome="${1#*=}"
        ;;
      --plan-counts=*)
        plan_counts="${1#*=}"
        ;;
      --destroy-plan-counts=*)
        destroy_plan_counts="${1#*=}"
        ;;
    esac
    shift
  done

  # Counts come from a complete JSON plan unless the counts given say otherwise
  local count_evidence='{"counts-source": "json", "plan-complete": "true"}'

  # Build parse-plan outputs
  local parse_plan_outputs
  if [[ "${plan_counts}" == "{}" ]]; then
    parse_plan_outputs='{}'
  else
    parse_plan_outputs=$(jq -c --argjson evidence "${count_evidence}" '$evidence + .' <<<"${plan_counts}")
  fi

  # Build parse-destroy-plan outputs
  local parse_destroy_plan_outputs
  if [[ "${destroy_plan_counts}" == "{}" ]]; then
    parse_destroy_plan_outputs='{}'
  else
    parse_destroy_plan_outputs=$(jq -c --argjson evidence "${count_evidence}" '$evidence + .' <<<"${destroy_plan_counts}")
  fi

  if [[ -z "${goals_granted}" ]]; then
    goals_granted=$(jq -c "${_GRANTED_FOR_RAW_GOALS}" <<<"${goals}")
  fi

  cat > "${filename}" << EOF
{
  "metadata": {
    "environment": "${env_name}",
    "captured_at": "2026-01-30T12:00:00Z",
    "schema_version": "2.0.0"
  },
  "workflow": {
    "actor": "${GITHUB_ACTOR}",
    "event_name": "pull_request"
  },
  "matrix_context": {
    "environment": "${env_name}",
    "vars": {
      "environment": "${env_name}",
      "pr-auto-merge-enabled": ${pr_auto_merge_enabled},
      "goals": ${goals},
      "goals-granted": ${goals_granted},
      "pr-auto-merge-from-actors": ${actors},
      "pr-auto-merge-limits": ${limits}
    }
  },
  "github_context": {
    "actor": "${GITHUB_ACTOR}"
  },
  "steps": {
    "init": {"outcome": "success", "conclusion": "success", "outputs": {}},
    "verify-lock": {"outcome": "skipped", "conclusion": "skipped", "outputs": {}},
    "fmt": {"outcome": "success", "conclusion": "success", "outputs": {}},
    "validate": {"outcome": "success", "conclusion": "success", "outputs": {}},
    "lint": {"outcome": "success", "conclusion": "success", "outputs": {}},
    "plan": {
      "outcome": "${plan_outcome}",
      "conclusion": "${plan_outcome}",
      "outputs": {}
    },
    "parse-plan": {
      "outcome": "${plan_outcome}",
      "conclusion": "${plan_outcome}",
      "outputs": ${parse_plan_outputs}
    },
    "apply": {
      "outcome": "${apply_outcome}",
      "conclusion": "${apply_outcome}",
      "outputs": {}
    },
    "destroy-plan": {
      "outcome": "${destroy_plan_outcome}",
      "conclusion": "${destroy_plan_outcome}",
      "outputs": {}
    },
    "parse-destroy-plan": {
      "outcome": "${destroy_plan_outcome}",
      "conclusion": "${destroy_plan_outcome}",
      "outputs": ${parse_destroy_plan_outputs}
    },
    "destroy": {
      "outcome": "${destroy_outcome}",
      "conclusion": "${destroy_outcome}",
      "outputs": {}
    }
  }
}
EOF

  local edits='.' entry
  if [[ "${no_goals_granted}" == "true" ]]; then
    edits+=' | del(.matrix_context.vars["goals-granted"])'
  fi
  for entry in "${step_outcomes[@]}"; do
    edits+=" | .steps[\"${entry%%:*}\"] = ((.steps[\"${entry%%:*}\"] // {outputs: {}}) + {outcome: \"${entry#*:}\", conclusion: \"success\"})"
  done
  for entry in "${file_edits[@]}"; do
    edits+=" | ${entry}"
  done
  if [[ "${edits}" != "." ]]; then
    jq "${edits}" "${filename}" >"${filename}.tmp" && mv "${filename}.tmp" "${filename}"
  fi
}

# Create a test job's metadata file, shaped as capture-matrix-job-meta writes it in the test job
# Usage: create_test_metadata_file <slug> <test file> <lane> <status pass|fail|error> <allow-failing json>
create_test_metadata_file() {
  jq -n --arg slug "${1}" --arg file "${2}" --arg lane "${3}" --arg status "${4}" --argjson allow "${5}" '{
    metadata: {environment: $slug, captured_at: "2026-09-25T10:10:00Z", schema_version: "2.0.0"},
    workflow: {run_id: "4242", run_attempt: "1"},
    matrix_context: {slug: $slug, test: {file: $file, lane: $lane, root: ".", "allow-failing-terraform-tests": $allow,
      "github-environment": "", "root-kind": "repo-root"}},
    steps: {
      init: {outcome: "success", conclusion: "success", outputs: {}},
      test: {outcome: (if $status == "pass" then "success" else "failure" end), conclusion: "success",
             outputs: {status: $status, reason: (if $status == "pass" then "" else "assertion" end), passed: "1",
                       failed: (if $status == "fail" then "1" else "0" end), errored: (if $status == "error" then "1" else "0" end)}}
    }
  }' >"terraform-test-meta-${1}.json"
}

# Function to run a single test
# Usage: run_test <name> <expected is-eligible> [<text the output must contain>...]
# A text starting with '!' is one the output must not contain.
# TEST_RELEVANCE_FILE, when set, is handed to the step as its relevance-file input;
# TEST_TEST_METADATA_PATTERN, when set, replaces the test-metadata-files-pattern default.
run_test() {
  local test_name="${1}"
  local expected_eligible="${2}"
  shift 2
  local expected_texts=("$@")

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Set up GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)

  # Required system variables
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export input_metadata_files_pattern="matrix-job-meta-*.json"
  export input_relevance_file="${TEST_RELEVANCE_FILE:-}"
  export input_test_metadata_files_pattern="${TEST_TEST_METADATA_PATTERN-terraform-test-meta-*.json}"

  # Run the step_evaluate.sh script in a subshell. TEST_STAGE_RESULTS is the stage-results-json
  # input, a shell-local captured before allexport as the shim does, empty when not given.
  (
    input_stage_results_json="${TEST_STAGE_RESULTS:-}"
    set -o allexport
    source "${_this_script_dir}/step_evaluate.sh"
  ) > "${_test_output}" 2>&1

  # Check the result
  local actual_eligible
  actual_eligible=$(grep "^is-eligible=" "${GITHUB_OUTPUT}" | cut -d= -f2)

  local missing_texts=()
  local text
  for text in "${expected_texts[@]}"; do
    if [[ "${text}" == '!'* ]]; then
      grep -qF -- "${text#!}" "${_test_output}" && missing_texts+=("${text}")
    else
      grep -qF -- "${text}" "${_test_output}" || missing_texts+=("${text}")
    fi
  done

  if [[ "${actual_eligible}" == "${expected_eligible}" && ${#missing_texts[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: Expected is-eligible=${expected_eligible}, got ${actual_eligible}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: Expected is-eligible=${expected_eligible}, got ${actual_eligible}"
    for text in "${missing_texts[@]}"; do
      if [[ "${text}" == '!'* ]]; then
        echo "  output holds: ${text#!}"
      else
        echo "  output lacks: ${text}"
      fi
    done
    echo ""
    echo "Test output:"
    cat "${_test_output}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
  rm -f matrix-job-meta-*.json terraform-test-meta-*.json
}

# Function to run a test expecting an error (exit code != 0)
run_error_test() {
  local test_name="${1}"

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Set up GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export input_metadata_files_pattern="matrix-job-meta-*.json"
  export input_relevance_file="${TEST_RELEVANCE_FILE:-}"
  export input_test_metadata_files_pattern="${TEST_TEST_METADATA_PATTERN-terraform-test-meta-*.json}"

  # Run the step_evaluate.sh script in a subshell
  (
    set -o allexport
    source "${_this_script_dir}/step_evaluate.sh"
  ) > "${_test_output}" 2>&1
  local exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: Script exited with error code ${exit_code}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: Script should have exited with error"
    echo ""
    echo "Test output:"
    cat "${_test_output}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
  rm -f matrix-job-meta-*.json
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}  AUTOMERGE ELIGIBILITY EVALUATION TESTS   ${NC}"
echo -e "${YELLOW}  (Multi-File Processing Mode)             ${NC}"
echo -e "${YELLOW}============================================${NC}"

# Set default actor for all tests
export GITHUB_ACTOR="dependabot[bot]"

# ============================================================================
# Test 1: Single file - basic eligible scenario
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
run_test "Single file - basic eligible scenario" "true"
cleanup_test_dir

# ============================================================================
# Test 2: No metadata files found
# ============================================================================
setup_test_dir
# Don't create any files
run_test "No metadata files found" "false"
cleanup_test_dir

# ============================================================================
# Test 3: Multiple files - all eligible
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
create_metadata_file "matrix-job-meta-production.json" "production"
run_test "Multiple files - all eligible" "true"
cleanup_test_dir

# ============================================================================
# Test 4: Multiple files - one not eligible (PR automerge disabled)
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
create_metadata_file "matrix-job-meta-production.json" "production" --pr-auto-merge-enabled=false
run_test "Multiple files - one not eligible (PR automerge disabled)" "false"
cleanup_test_dir

# ============================================================================
# Test 5: Actor not in allowed list
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="unknown-actor"
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --actors='["dependabot[bot]", "renovate[bot]"]'
run_test "Actor not in allowed list" "false"
export GITHUB_ACTOR="dependabot[bot]"
cleanup_test_dir

# ============================================================================
# Test 6: Plan creation failed
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --plan-outcome=failure
run_test "Plan creation failed" "false"
cleanup_test_dir

# ============================================================================
# Test 7: Count exceeds single limit
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts='{"count-add": "5", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 3, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Count exceeds single limit" "false"
cleanup_test_dir

# ============================================================================
# Test 8: All counts at exactly the limit
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts='{"count-add": "5", "count-change": "10", "count-destroy": "3", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 5, "plan-max-count-change": 10, "plan-max-count-destroy": 3, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "All counts at exactly the limit" "true"
cleanup_test_dir

# ============================================================================
# Test 9: Zero changes - zero limits
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 0, "plan-max-count-change": 0, "plan-max-count-destroy": 0, "plan-max-count-import": 0, "plan-max-count-move": 0, "plan-max-count-remove": 0}'
run_test "Zero changes - zero limits" "true"
cleanup_test_dir

# ============================================================================
# Test 10: Plan limits ignored when performing apply-on-pr
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all", "apply-on-pr"]' \
  --apply-outcome=success \
  --plan-counts='{"count-add": "1000", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 0, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Plan limits ignored when performing apply-on-pr" "true"
cleanup_test_dir

# ============================================================================
# Test 11: Apply on PR failed
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all", "apply-on-pr"]' \
  --apply-outcome=failure
run_test "Apply on PR failed" "false"
cleanup_test_dir

# ============================================================================
# Test 12: Actor in allowed list
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="renovate[bot]"
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --actors='["dependabot[bot]", "renovate[bot]"]'
run_test "Actor in allowed list" "true"
export GITHUB_ACTOR="dependabot[bot]"
cleanup_test_dir

# ============================================================================
# Test 13: Empty actor list names nobody - never "all actors allowed"
# (docs/Auto-merge.md D7; it used to allow every actor)
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="any-random-actor"
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --actors='[]'
run_test "Empty actor list names nobody" "false" \
  "(pr-auto-merge-from-actors) names nobody, so no pull request may auto-merge"
export GITHUB_ACTOR="dependabot[bot]"
cleanup_test_dir

# ============================================================================
# Test 14: Invalid configuration (empty limit value)
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --limits='{"plan-max-count-add": "", "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_error_test "Invalid configuration (empty limit value)"
cleanup_test_dir

# ============================================================================
# Test 15: Invalid configuration (null limit)
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --limits='{"plan-max-count-add": null, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_error_test "Invalid configuration (null limit)"
cleanup_test_dir

# ============================================================================
# Test 16: Invalid configuration (non-numeric limit)
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --limits='{"plan-max-count-add": "abc", "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_error_test "Invalid configuration (non-numeric limit)"
cleanup_test_dir

# ============================================================================
# Test 17: Destroy plan with limits
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["destroy-plan"]' \
  --plan-outcome=skipped \
  --destroy-plan-outcome=success \
  --plan-counts='{}' \
  --destroy-plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "5", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": -1, "plan-max-count-destroy": 10, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Destroy plan within limits" "true"
cleanup_test_dir

# ============================================================================
# Test 18: Destroy plan exceeds limits
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["destroy-plan"]' \
  --plan-outcome=skipped \
  --destroy-plan-outcome=success \
  --plan-counts='{}' \
  --destroy-plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "15", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": -1, "plan-max-count-destroy": 10, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Destroy plan exceeds limits" "false"
cleanup_test_dir

# ============================================================================
# Test 19: Multiple files - three environments, all eligible
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-dev.json" "dev"
create_metadata_file "matrix-job-meta-staging.json" "staging"
create_metadata_file "matrix-job-meta-production.json" "production"
run_test "Multiple files - three environments, all eligible" "true"
cleanup_test_dir

# ============================================================================
# Test 20: Multiple files - middle environment fails
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-dev.json" "dev"
create_metadata_file "matrix-job-meta-staging.json" "staging" --plan-outcome=failure
create_metadata_file "matrix-job-meta-production.json" "production"
run_test "Multiple files - middle environment fails" "false"
cleanup_test_dir

# ============================================================================
# Test 21: Malformed metadata file (invalid JSON)
# ============================================================================
setup_test_dir
echo "not valid json" > matrix-job-meta-sandbox.json
run_test "Malformed metadata file (invalid JSON)" "false"
cleanup_test_dir

# ============================================================================
# Test 22: Metadata file missing environment field
# ============================================================================
setup_test_dir
cat > matrix-job-meta-sandbox.json << 'EOF'
{
  "metadata": {},
  "matrix_context": {
    "vars": {
      "pr-auto-merge-enabled": true
    }
  },
  "steps": {}
}
EOF
run_test "Metadata file missing environment field" "false"
cleanup_test_dir

# ============================================================================
# Test 23: PR automerge disabled
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --pr-auto-merge-enabled=false
run_test "PR automerge disabled" "false"
cleanup_test_dir

# ============================================================================
# Test 24: Actors compare without case, as GitHub logins do (docs/Auto-merge.md
# D7; it used to be an exact, case-sensitive match)
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="Renovate[bot]"  # Capital R vs lowercase
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --actors='["dependabot[bot]", "renovate[bot]"]'
run_test "Actor compared without case - other case is the same login" "true" \
  "Actor 'Renovate[bot]' found in allowed list"
export GITHUB_ACTOR="dependabot[bot]"
cleanup_test_dir

# ============================================================================
# Test 25: Both plan and destroy-plan - aggregated counts exceed limit
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all", "destroy-plan"]' \
  --destroy-plan-outcome=success \
  --plan-counts='{"count-add": "0", "count-change": "5", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --destroy-plan-counts='{"count-add": "0", "count-change": "5", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": 9, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
# Total change count = 5 + 5 = 10, limit is 9
run_test "Both plan and destroy-plan - aggregated counts exceed limit" "false"
cleanup_test_dir

# ============================================================================
# Test 26: Both plan and destroy-plan - aggregated counts within limit
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all", "destroy-plan"]' \
  --destroy-plan-outcome=success \
  --plan-counts='{"count-add": "0", "count-change": "5", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --destroy-plan-counts='{"count-add": "0", "count-change": "5", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": 10, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
# Total change count = 5 + 5 = 10, limit is 10 (exactly at limit)
run_test "Both plan and destroy-plan - aggregated counts within limit" "true"
cleanup_test_dir

# ============================================================================
# Test 27: Destroy-on-pr succeeds - limits ignored
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["destroy-plan", "destroy-on-pr"]' \
  --plan-outcome=skipped \
  --destroy-plan-outcome=success \
  --destroy-outcome=success \
  --plan-counts='{}' \
  --destroy-plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "1000", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": -1, "plan-max-count-destroy": 0, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Destroy-on-pr succeeds - limits ignored" "true"
cleanup_test_dir

# ============================================================================
# Test 28: Destroy-on-pr fails
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["destroy-plan", "destroy-on-pr"]' \
  --plan-outcome=skipped \
  --destroy-plan-outcome=success \
  --destroy-outcome=failure \
  --plan-counts='{}' \
  --destroy-plan-counts='{}'
run_test "Destroy-on-pr fails" "false"
cleanup_test_dir

# ============================================================================
# Test 29: All limits ignored (apply-on-pr + destroy-on-pr)
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all", "apply-on-pr", "destroy-plan", "destroy-on-pr"]' \
  --apply-outcome=success \
  --destroy-plan-outcome=success \
  --destroy-outcome=success \
  --plan-counts='{"count-add": "100", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --destroy-plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "100", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 0, "plan-max-count-change": 0, "plan-max-count-destroy": 0, "plan-max-count-import": 0, "plan-max-count-move": 0, "plan-max-count-remove": 0}'
run_test "All limits ignored (apply-on-pr + destroy-on-pr)" "true"
cleanup_test_dir

# ============================================================================
# Test 30: Large count values
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts='{"count-add": "999999999", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 1000000000, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Large count values within limit" "true"
cleanup_test_dir

# ============================================================================
# MULTI-FILE SPECIFIC TESTS
# ============================================================================

# ============================================================================
# Test 31: Multiple files - last environment fails
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-alpha.json" "alpha"
create_metadata_file "matrix-job-meta-beta.json" "beta"
create_metadata_file "matrix-job-meta-gamma.json" "gamma" --plan-outcome=failure
run_test "Multiple files - last environment fails" "false"
cleanup_test_dir

# ============================================================================
# Test 32: Multiple files - all fail for different reasons
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-dev.json" "dev" --pr-auto-merge-enabled=false
create_metadata_file "matrix-job-meta-staging.json" "staging" --plan-outcome=failure
export GITHUB_ACTOR="unauthorized-user"
create_metadata_file "matrix-job-meta-prod.json" "prod" --actors='["dependabot[bot]"]'
run_test "Multiple files - all fail for different reasons" "false"
export GITHUB_ACTOR="dependabot[bot]"
cleanup_test_dir

# ============================================================================
# Test 33: Many environments (5+) - scalability test
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-env1.json" "env1"
create_metadata_file "matrix-job-meta-env2.json" "env2"
create_metadata_file "matrix-job-meta-env3.json" "env3"
create_metadata_file "matrix-job-meta-env4.json" "env4"
create_metadata_file "matrix-job-meta-env5.json" "env5"
run_test "Many environments (5+) - all eligible" "true"
cleanup_test_dir

# ============================================================================
# Test 34: Many environments - one in the middle fails
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-env1.json" "env1"
create_metadata_file "matrix-job-meta-env2.json" "env2"
create_metadata_file "matrix-job-meta-env3.json" "env3" --pr-auto-merge-enabled=false
create_metadata_file "matrix-job-meta-env4.json" "env4"
create_metadata_file "matrix-job-meta-env5.json" "env5"
run_test "Many environments - one in the middle fails" "false"
cleanup_test_dir

# ============================================================================
# Test 35: Different limits per environment - all pass
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-dev.json" "dev" \
  --plan-counts='{"count-add": "10", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 20, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
create_metadata_file "matrix-job-meta-staging.json" "staging" \
  --plan-counts='{"count-add": "5", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 10, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
create_metadata_file "matrix-job-meta-prod.json" "prod" \
  --plan-counts='{"count-add": "1", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 5, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Different limits per environment - all pass" "true"
cleanup_test_dir

# ============================================================================
# Test 36: Different limits per environment - strictest fails
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-dev.json" "dev" \
  --plan-counts='{"count-add": "10", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 100, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
create_metadata_file "matrix-job-meta-prod.json" "prod" \
  --plan-counts='{"count-add": "10", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 5, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Different limits per environment - strictest fails" "false"
cleanup_test_dir

# ============================================================================
# Test 37: Configuration error in second file - should exit with error
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-alpha.json" "alpha"
create_metadata_file "matrix-job-meta-beta.json" "beta" \
  --limits='{"plan-max-count-add": "invalid", "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_error_test "Configuration error in second file - should exit with error"
cleanup_test_dir

# ============================================================================
# Test 38: Multiple invalid JSON files
# ============================================================================
setup_test_dir
echo "invalid json 1" > matrix-job-meta-first.json
echo "invalid json 2" > matrix-job-meta-second.json
run_test "Multiple invalid JSON files" "false"
cleanup_test_dir

# ============================================================================
# Test 39: Mix of valid and invalid JSON files
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-alpha.json" "alpha"
echo "invalid json" > matrix-job-meta-beta.json
run_test "Mix of valid and invalid JSON files" "false"
cleanup_test_dir

# ============================================================================
# Test 40: Different goals per environment - all eligible
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-dev.json" "dev" \
  --goals='["all"]'
create_metadata_file "matrix-job-meta-staging.json" "staging" \
  --goals='["all", "apply-on-pr"]' \
  --apply-outcome=success
create_metadata_file "matrix-job-meta-prod.json" "prod" \
  --goals='["destroy-plan", "destroy-on-pr"]' \
  --plan-outcome=skipped \
  --destroy-plan-outcome=success \
  --destroy-outcome=success
run_test "Different goals per environment - all eligible" "true"
cleanup_test_dir

# ============================================================================
# Test 41: Different goals per environment - one fails apply
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-dev.json" "dev" \
  --goals='["all"]'
create_metadata_file "matrix-job-meta-staging.json" "staging" \
  --goals='["all", "apply-on-pr"]' \
  --apply-outcome=failure
run_test "Different goals per environment - one fails apply" "false"
cleanup_test_dir

# ============================================================================
# Test 42: Actor allowed in some environments but not others
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="renovate[bot]"
create_metadata_file "matrix-job-meta-dev.json" "dev" \
  --actors='["renovate[bot]", "dependabot[bot]"]'
create_metadata_file "matrix-job-meta-prod.json" "prod" \
  --actors='["dependabot[bot]"]'
run_test "Actor allowed in some environments but not others" "false"
export GITHUB_ACTOR="dependabot[bot]"
cleanup_test_dir

# ============================================================================
# Test 43: Actor allowed in all environments with different actor lists
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="dependabot[bot]"
create_metadata_file "matrix-job-meta-dev.json" "dev" \
  --actors='["renovate[bot]", "dependabot[bot]"]'
create_metadata_file "matrix-job-meta-staging.json" "staging" \
  --actors='["dependabot[bot]"]'
create_metadata_file "matrix-job-meta-prod.json" "prod" \
  --actors='["dependabot[bot]", "github-actions[bot]"]'
run_test "Actor allowed in all environments with different actor lists" "true"
cleanup_test_dir

# ============================================================================
# Test 44: Empty environment in one file
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-dev.json" "dev"
cat > matrix-job-meta-empty.json << 'EOF'
{
  "metadata": {
    "environment": "",
    "captured_at": "2026-01-30T12:00:00Z"
  },
  "matrix_context": {
    "vars": {}
  },
  "steps": {}
}
EOF
run_test "Empty environment in one file" "false"
cleanup_test_dir

# ============================================================================
# Test 45: File with missing steps section
# ============================================================================
setup_test_dir
cat > matrix-job-meta-nosteps.json << 'EOF'
{
  "metadata": {
    "environment": "nosteps",
    "captured_at": "2026-01-30T12:00:00Z"
  },
  "matrix_context": {
    "vars": {
      "pr-auto-merge-enabled": true,
      "goals": ["all"],
      "goals-granted": ["init", "format", "validate", "lint", "plan"],
      "pr-auto-merge-from-actors": ["dependabot[bot]"],
      "pr-auto-merge-limits": {
        "plan-max-count-add": -1,
        "plan-max-count-change": -1,
        "plan-max-count-destroy": -1,
        "plan-max-count-import": -1,
        "plan-max-count-move": -1,
        "plan-max-count-remove": -1
      }
    }
  }
}
EOF
run_test "File with missing steps section" "false" \
  "Plan was expected to have been created but was not"
cleanup_test_dir

# ============================================================================
# Test 46: Multiple files - different schema handling
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-normal.json" "normal"
# File with minimal structure but valid: no operation step but the plan, which
# is no failure, and no raw goals, which the evaluator does not read
cat > matrix-job-meta-minimal.json << 'EOF'
{
  "metadata": {
    "environment": "minimal"
  },
  "matrix_context": {
    "vars": {
      "pr-auto-merge-enabled": true,
      "goals-granted": ["init", "format", "validate", "lint", "plan"],
      "pr-auto-merge-from-actors": ["dependabot[bot]"],
      "pr-auto-merge-limits": {
        "plan-max-count-add": -1,
        "plan-max-count-change": -1,
        "plan-max-count-destroy": -1,
        "plan-max-count-import": -1,
        "plan-max-count-move": -1,
        "plan-max-count-remove": -1
      }
    }
  },
  "steps": {
    "plan": {"outcome": "success", "outputs": {}},
    "parse-plan": {"outcome": "success", "outputs": {"count-add": "0", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0", "counts-source": "json", "plan-complete": "true"}}
  }
}
EOF
run_test "Multiple files - different schema handling" "true"
cleanup_test_dir

# ============================================================================
# Test 47: File processing order - alphabetical verification
# This test verifies files are processed in alphabetical order
# ============================================================================
setup_test_dir
# Create files in reverse alphabetical order to verify sorting
create_metadata_file "matrix-job-meta-zebra.json" "zebra"
create_metadata_file "matrix-job-meta-alpha.json" "alpha"
create_metadata_file "matrix-job-meta-middle.json" "middle"
run_test "File processing order - alphabetical verification" "true"
cleanup_test_dir

# ============================================================================
# Test 48: Single environment with all count types at limits
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-complex.json" "complex" \
  --plan-counts='{"count-add": "5", "count-change": "10", "count-destroy": "3", "count-import": "2", "count-move": "1", "count-remove": "4"}' \
  --limits='{"plan-max-count-add": 5, "plan-max-count-change": 10, "plan-max-count-destroy": 3, "plan-max-count-import": 2, "plan-max-count-move": 1, "plan-max-count-remove": 4}'
run_test "Single environment with all count types at limits" "true"
cleanup_test_dir

# ============================================================================
# Test 49: Multiple environments with counts - different count types exceed
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-env1.json" "env1" \
  --plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "0", "count-import": "5", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": 10, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
create_metadata_file "matrix-job-meta-env2.json" "env2" \
  --plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "10", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": 5, "plan-max-count-remove": -1}'
run_test "Multiple environments - second env exceeds move limit" "false"
cleanup_test_dir

# ============================================================================
# Test 50: Environment with remove count at zero limit
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-strict.json" "strict" \
  --plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "1"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": 0}'
run_test "Environment with remove count exceeds zero limit" "false"
cleanup_test_dir

# ============================================================================
# Granted goals (docs/Auto-merge.md D4, §5.1)
#
# What should have been planned, applied or destroyed is read from
# goals-granted, the goals the run's gates granted, never from the raw goals.
# Each case sets raw goals that say otherwise, so reading the wrong one fails.
# ============================================================================

# G1: raw goals ask for a plan, the run granted none (a dispatch cap, say)
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all"]' --goals-granted='["init", "format", "validate", "lint"]' \
  --plan-outcome=skipped --plan-counts='{}'
run_test "Granted goals: no plan granted although the raw goals say all - no plan expected" "true" \
  "Plan creation: not expected - SKIPPED" "Plan limits: IGNORED (plan was not supposed to be created)"
cleanup_test_dir

# G2: raw goals say apply-on-pr, the run did not grant apply - the plan limits apply
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all", "apply-on-pr"]' --goals-granted='["init", "format", "validate", "lint", "plan"]' \
  --plan-counts='{"count-add": "5", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 0, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Granted goals: apply-on-pr in the raw goals but apply not granted - plan limits apply" "false" \
  "Apply on PR: not performed - SKIPPED" "Add count (5) exceeds limit (0) in environment" \
  "!Apply operation on PR was not expected to fail"
cleanup_test_dir

# G3: apply granted without apply-on-pr in the raw goals - the apply is what counts
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all"]' --goals-granted='["init", "format", "validate", "lint", "plan", "apply"]' \
  --apply-outcome=success \
  --plan-counts='{"count-add": "1000", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 0, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Granted goals: apply granted - plan limits ignored, the apply succeeded" "true" \
  "Apply on PR: performed and succeeded - PASS" "Plan limits: IGNORED (apply is being performed on PR)"
cleanup_test_dir

# G4: destroy-plan granted without it in the raw goals, and it did not run
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all"]' --goals-granted='["init", "format", "validate", "lint", "plan", "destroy-plan"]'
run_test "Granted goals: destroy-plan granted but not created" "false" \
  "Destroy plan was expected to have been created but was not"
cleanup_test_dir

# G5: destroy granted (destroy-on-pr) and it failed
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["destroy-plan"]' --goals-granted='["destroy-plan", "destroy"]' \
  --plan-outcome=skipped --plan-counts='{}' \
  --destroy-plan-outcome=success --destroy-outcome=failure
run_test "Granted goals: destroy granted and failed" "false" \
  "Destroy operation on PR was not expected to fail"
cleanup_test_dir

# G6: metadata without goals-granted (an older workflow) - never the raw goals instead
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --no-goals-granted
run_test "Granted goals: absent from the metadata - not eligible" "false" \
  "The metadata has no goals-granted" "Plan creation: UNKNOWN"
cleanup_test_dir

# G7: goals-granted that is not a list
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --goals-granted='"plan"'
run_test "Granted goals: not a list - not eligible" "false" \
  "The metadata's goals-granted is \"plan\", not a list of goals"
cleanup_test_dir

# G8: goals-granted holding a raw goal name, which no gate reads
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --goals-granted='["all"]'
run_test "Granted goals: a name that is not a granted goal - not eligible" "false" \
  "The metadata's goals-granted holds \"all\", which is not a goal (init, format, validate, lint, plan, apply, destroy-plan, destroy)"
cleanup_test_dir

# ============================================================================
# Count evidence (docs/Auto-merge.md D1, §5.2)
#
# Counts judged against the limits must come from the environment's JSON plan
# (counts-source json) and a complete one (plan-complete true), read from the
# parse step whose counts are judged. Anything else, absent included, is not
# eligible: console text can forge its summary line, and an incomplete plan
# counts only part of the change.
# ============================================================================
_zero_counts='"count-add": "0", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"'

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts="{${_zero_counts}, \"counts-source\": \"console\", \"plan-complete\": \"\"}"
run_test "Count evidence: plan counted from the console text - not eligible" "false" \
  "The plan of 'sandbox' was not counted from its JSON plan (counts-source: console), so its counts cannot be trusted for auto-merge" \
  "!does not say it is complete" "!Required plan counts are missing or invalid"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts="{${_zero_counts}, \"plan-complete\": \"false\"}"
run_test "Count evidence: plan not complete - not eligible" "false" \
  "The plan of 'sandbox' is not complete (a -target plan, or changes deferred to a later plan), so its counts do not cover every change"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts="{${_zero_counts}, \"plan-complete\": \"?\"}"
run_test "Count evidence: plan completeness unknown (?) - not eligible" "false" \
  "The plan of 'sandbox' does not say it is complete (plan-complete: ?), so its counts may not cover every change"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --edit='del(.steps["parse-plan"].outputs["counts-source"], .steps["parse-plan"].outputs["plan-complete"])'
run_test "Count evidence: counts-source and plan-complete absent - not eligible" "false" \
  "The plan of 'sandbox' was not counted from its JSON plan (no counts-source)"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --edit='del(.steps["parse-plan"].outputs["plan-complete"])'
run_test "Count evidence: plan-complete absent from a JSON count - not eligible" "false" \
  "The plan of 'sandbox' does not say it is complete (no plan-complete)"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts="{${_zero_counts}, \"counts-source\": \"\"}"
run_test "Count evidence: counts-source empty - not eligible" "false" \
  "The plan of 'sandbox' was not counted from its JSON plan (no counts-source)"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --plan-counts="{${_zero_counts}, \"plan-complete\": \"\"}"
run_test "Count evidence: plan-complete empty - not eligible" "false" \
  "The plan of 'sandbox' does not say it is complete (no plan-complete)"
cleanup_test_dir

# The destroy plan's evidence comes from parse-destroy-plan
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["destroy-plan"]' --plan-outcome=skipped --plan-counts='{}' --destroy-plan-outcome=success \
  --destroy-plan-counts="{${_zero_counts}, \"counts-source\": \"console\", \"plan-complete\": \"\"}"
run_test "Count evidence: destroy plan counted from the console text - not eligible" "false" \
  "The destroy plan of 'sandbox' was not counted from its JSON plan (counts-source: console)"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["destroy-plan"]' --plan-outcome=skipped --plan-counts='{}' --destroy-plan-outcome=success \
  --destroy-plan-counts="{${_zero_counts}, \"plan-complete\": \"false\"}"
run_test "Count evidence: destroy plan not complete - not eligible" "false" \
  "The destroy plan of 'sandbox' is not complete"
cleanup_test_dir

# Both judged: the plan's evidence holds, the destroy plan's does not
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all", "destroy-plan"]' --destroy-plan-outcome=success \
  --destroy-plan-counts="{${_zero_counts}, \"plan-complete\": \"?\"}"
run_test "Count evidence: plan and destroy plan judged, only the destroy plan's evidence fails" "false" \
  "The destroy plan of 'sandbox' does not say it is complete (plan-complete: ?)" "!The plan of 'sandbox'"
cleanup_test_dir

# Counts that are not judged need no evidence: the apply on the pull request already happened
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --goals='["all", "apply-on-pr"]' --apply-outcome=success \
  --plan-counts="{${_zero_counts}, \"counts-source\": \"console\", \"plan-complete\": \"\"}"
run_test "Count evidence: plan limits ignored for an apply on the pull request - not needed" "true" \
  "Plan limits: IGNORED (apply is being performed on PR)" "!was not counted from its JSON plan"
cleanup_test_dir

# ============================================================================
# Operation outcomes (docs/Auto-merge.md D13)
#
# A Terraform operation that failed or was cancelled blocks auto-merge, also
# when allow-failing-terraform-operations kept the job green: every case
# records the step's conclusion as success, as a tolerated failure is captured.
# ============================================================================
for _operation in init verify-lock fmt validate lint plan apply destroy-plan destroy; do
  setup_test_dir
  create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --step-outcome="${_operation}:failure"
  run_test "Operation outcomes: a tolerated ${_operation} failure - not eligible" "false" \
    "Terraform operation(s) did not succeed: ${_operation} (failure)" "Operation outcomes: FAIL"
  cleanup_test_dir
done

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --step-outcome="validate:cancelled"
run_test "Operation outcomes: a cancelled step - not eligible" "false" \
  "Terraform operation(s) did not succeed: validate (cancelled)"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --step-outcome="fmt:failure" --step-outcome="lint:failure"
run_test "Operation outcomes: every failed step is named" "false" \
  "Terraform operation(s) did not succeed: fmt (failure), lint (failure)"
cleanup_test_dir

# Every operation step ran and succeeded or was skipped
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --step-outcome="verify-lock:success"
run_test "Operation outcomes: success and skipped steps pass" "true" \
  "No operation failed or was cancelled" "Operation outcomes: PASS"
cleanup_test_dir

# A failed step that is not a Terraform operation (a reporting step) is not judged here
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --step-outcome="parse-init-warnings:failure" --step-outcome="post-plan-tag:failure"
run_test "Operation outcomes: a failed reporting step does not block" "true" \
  "No operation failed or was cancelled"
cleanup_test_dir

# ============================================================================
# Actors (docs/Auto-merge.md D7): named, never "everyone", compared without case
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="dependabot[bot]"
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --actors='["Dependabot[Bot]"]'
run_test "Actors: a login listed in another case" "true" \
  "Actor 'dependabot[bot]' found in allowed list"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --actors=null
run_test "Actors: no list at all - not eligible" "false" \
  "(pr-auto-merge-from-actors) is null, not a list of logins"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --actors='"dependabot[bot]"'
run_test "Actors: a single login that is not a list - not eligible" "false" \
  "(pr-auto-merge-from-actors) is \"dependabot[bot]\", not a list of logins"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --actors='[7, ""]'
run_test "Actors: a list without a login - not eligible" "false" \
  "(pr-auto-merge-from-actors) names nobody"
cleanup_test_dir

# ============================================================================
# Tolerated tests (docs/Auto-merge.md D13, §5.1)
#
# A test job tolerated by allow-failing-terraform-tests never makes the pull
# request ineligible, and is named in the log and in a notice.
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
create_test_metadata_file "root--int-x" "tests/int-x.tftest.hcl" "integration" "fail" true
create_test_metadata_file "root--unit-a" "tests/unit-a.tftest.hcl" "unit" "pass" false
run_test "Tolerated tests: a tolerated failing test is named and does not block" "true" \
  "::notice title=Auto-merge::auto-merge eligible despite the tolerated failing test tests/int-x.tftest.hcl (lane integration)" \
  "Tolerated failing or erroring tests: 1" "!tests/unit-a.tftest.hcl"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
create_test_metadata_file "root--unit-b" "tests/unit-b.tftest.hcl" "" "error" '"true"'
run_test "Tolerated tests: an erroring test, tolerated as text, without a lane" "true" \
  "::notice title=Auto-merge::auto-merge eligible despite the tolerated erroring test tests/unit-b.tftest.hcl" \
  "!unit-b.tftest.hcl (lane"
cleanup_test_dir

# Not eligible for another reason: the notice must not say eligible
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --pr-auto-merge-enabled=false
create_test_metadata_file "root--int-x" "tests/int-x.tftest.hcl" "integration" "fail" true
run_test "Tolerated tests: named when the pull request is not eligible for another reason" "false" \
  "::notice title=Auto-merge::The tolerated failing test tests/int-x.tftest.hcl (lane integration) does not block auto-merge; the pull request is not eligible for other reasons" \
  "!auto-merge eligible despite"
cleanup_test_dir

# An untolerated failure would have turned the conclusion red; here it is only logged
setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
create_test_metadata_file "root--int-y" "tests/int-y.tftest.hcl" "integration" "fail" false
run_test "Tolerated tests: an untolerated failure is logged, not noticed, and does not decide" "true" \
  "tests/int-y.tftest.hcl (lane integration): fail and not tolerated" "!::notice"
cleanup_test_dir

setup_test_dir
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
echo "not json" > terraform-test-meta-broken.json
run_test "Tolerated tests: an unreadable test metadata file names no test and does not decide" "true" \
  "Test metadata file 'terraform-test-meta-broken.json' is not valid JSON" "!::notice"
cleanup_test_dir

setup_test_dir
export TEST_TEST_METADATA_PATTERN=""
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
create_test_metadata_file "root--int-x" "tests/int-x.tftest.hcl" "integration" "fail" true
run_test "Tolerated tests: an empty pattern reads no test metadata" "true" \
  "No test metadata files pattern" "!::notice"
unset TEST_TEST_METADATA_PATTERN
cleanup_test_dir

# ============================================================================
# Relevance file (docs/Path-relevance.md §8)
#
# With a relevance file, every environment of environments-yml is judged:
# an affected one on its metadata (which must exist, exactly once), an
# unaffected one on configuration, enabled flag and actor allowlist from the
# file. A docs-only pull request has zero metadata files and must still pass
# the enabled and actor checks, never merge blindly.
# ============================================================================

_all_unlimited='{"plan-max-count-add": -1, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'

# Build one environments[] entry of relevance.json, shaped as the matrix builder writes it
# Usage: relevance_entry <github-environment> <run|skip> [--enabled=<true|false>] [--actors=<json>] [--limits=<json>]
#          [--relevant=<json>|--relevant=absent] [--trigger-events=<json>|--trigger-events=absent] [--reason=<text>]
# --relevant defaults to the verdict (run: true, skip: false); "absent" leaves the key out, as a
# file from before the engine published it. --reason replaces the first reason.
relevance_entry() {
  local github_env="${1}"
  local verdict="${2}"
  shift 2
  local enabled="true"
  local actors='["dependabot[bot]"]'
  local limits="${_all_unlimited}"
  local relevant=""
  local trigger_events='["pull_request", "push", "workflow_dispatch"]'
  local reason=""
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --enabled=*) enabled="${1#*=}" ;;
      --actors=*) actors="${1#*=}" ;;
      --limits=*) limits="${1#*=}" ;;
      --relevant=*) relevant="${1#*=}" ;;
      --trigger-events=*) trigger_events="${1#*=}" ;;
      --reason=*) reason="${1#*=}" ;;
    esac
    shift
  done
  [[ -n "${relevant}" ]] || relevant=$([[ "${verdict}" == "run" ]] && echo true || echo false)
  [[ "${relevant}" == "absent" ]] && relevant='"absent"'
  [[ "${trigger_events}" == "absent" ]] && trigger_events='"absent"'
  jq -nc --arg ge "${github_env}" --arg verdict "${verdict}" --arg enabled "${enabled}" \
    --argjson actors "${actors}" --argjson limits "${limits}" --argjson relevant "${relevant}" \
    --argjson events "${trigger_events}" --arg reason "${reason}" '{
      "environment": $ge, "github-environment": $ge, "verdict": $verdict,
      "reasons": [(if $reason != "" then $reason elif $verdict == "run" then "relevance: **" else "relevance: no changed file matches" end)],
      "relevant": $relevant, "trigger-events": $events,
      "add-pr-comment": "true", "pr-comment-group": "", "mutates-on-pr": [],
      "pr-auto-merge-enabled": $enabled, "pr-auto-merge-from-actors": $actors, "pr-auto-merge-limits": $limits,
      "paths": ["**"], "paths-ignore": []
    }
    | if .relevant == "absent" then del(.relevant) else . end
    | if ."trigger-events" == "absent" then del(."trigger-events") else . end'
}

# Write relevance.json from environments[] entries
# Usage: create_relevance_file <file> [<entry json>...]
create_relevance_file() {
  local file="${1}"
  shift
  { [[ $# -gt 0 ]] && printf '%s\n' "$@"; } | jq -s '{
    "schema_version": 1,
    "relevance": {"mode": "diff", "reason": "diff", "changed_count": 1},
    "counts": {"affected": (map(select(.verdict == "run")) | length), "unaffected": (map(select(.verdict == "skip")) | length)},
    "environments": .,
    "comments": {"heads": [], "gc": [], "purge_tags_for": []},
    "notices": [],
    "record": {}
  }' > "${file}"
}

# ============================================================================
# Test R1: Zero affected, actor in every allowlist - eligible
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
export GITHUB_ACTOR="renovate[bot]"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --actors='["renovate[bot]"]')" \
  "$(relevance_entry staging skip --actors='["dependabot[bot]", "renovate[bot]"]')"
run_test "Relevance: zero affected, allowed actor" "true" \
  "Plan creation: NOT AFFECTED" \
  "✅ prod (not affected)" \
  "✅ staging (not affected)"
export GITHUB_ACTOR="dependabot[bot]"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R2: Zero affected, actor outside one allowlist - not eligible
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
export GITHUB_ACTOR="some-human"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --actors='["renovate[bot]"]')" \
  "$(relevance_entry staging skip --actors='["renovate[bot]", "some-human"]')"
run_test "Relevance: zero affected, disallowed actor" "false" \
  "Actor 'some-human' is not authorized for PR automerge" \
  "❌ prod (not affected)" \
  "✅ staging (not affected)"
export GITHUB_ACTOR="dependabot[bot]"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R3: Zero affected, auto-merge disabled on one environment - not eligible
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --enabled=false)" \
  "$(relevance_entry staging skip)"
run_test "Relevance: zero affected, auto-merge disabled on one environment" "false" \
  "PR automerge is disabled for this environment" \
  "❌ prod (not affected)"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R4: Zero affected, empty and null allowlists allow nobody (docs/Auto-merge.md
# D7; they used to allow every actor)
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
export GITHUB_ACTOR="any-random-actor"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --actors='[]')" \
  "$(relevance_entry staging skip --actors=null)"
run_test "Relevance: zero affected, empty and null allowlists allow nobody" "false" \
  "(pr-auto-merge-from-actors) names nobody" \
  "(pr-auto-merge-from-actors) is null, not a list of logins" \
  "❌ prod (not affected)" "❌ staging (not affected)"
export GITHUB_ACTOR="dependabot[bot]"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R5: An affected environment without metadata - not eligible, named
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod run)" \
  "$(relevance_entry staging run)"
create_metadata_file "matrix-job-meta-staging.json" "staging"
run_test "Relevance: affected environment without metadata" "false" \
  "No metadata file for affected environment 'prod'" \
  "❌ prod (affected, no metadata)" \
  "✅ staging"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R6: Mixed - affected with passing metadata, unaffected passing
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --actors='["dependabot[bot]"]')" \
  "$(relevance_entry staging run)" \
  "$(relevance_entry sandbox skip)"
create_metadata_file "matrix-job-meta-staging.json" "staging"
run_test "Relevance: mixed affected and unaffected, all pass" "true" \
  "✅ prod (not affected)" \
  "✅ staging" \
  "✅ sandbox (not affected)"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R7: Mixed - affected passes, unaffected disallows the actor
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --actors='["renovate[bot]"]')" \
  "$(relevance_entry staging run)"
create_metadata_file "matrix-job-meta-staging.json" "staging"
run_test "Relevance: mixed, unaffected environment disallows the actor" "false" \
  "❌ prod (not affected)" \
  "✅ staging"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R8: Mixed - affected exceeds a limit, unaffected passes
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip)" \
  "$(relevance_entry staging run)"
create_metadata_file "matrix-job-meta-staging.json" "staging" \
  --plan-counts='{"count-add": "2", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": 1, "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Relevance: mixed, affected environment exceeds a limit" "false" \
  "Add count (2) exceeds limit (1) in environment" \
  "❌ staging"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R9: Relevance file given but absent on disk - today's behaviour (eligible)
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/no-such-dir/relevance.json"
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
run_test "Relevance: file absent on disk behaves as no file (eligible)" "true" \
  "does not exist, evaluating the metadata files alone"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R10: Relevance file given but absent, no metadata - today's behaviour
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/no-such-dir/relevance.json"
run_test "Relevance: file absent on disk and no metadata files" "false" \
  "No metadata files found matching pattern"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R11: Metadata for an environment the relevance file does not list
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod run)"
create_metadata_file "matrix-job-meta-prod.json" "prod"
create_metadata_file "matrix-job-meta-ghost.json" "ghost"
run_test "Relevance: metadata for an environment not in the relevance file" "false" \
  "Metadata file 'matrix-job-meta-ghost.json' is for environment 'ghost', which the relevance file does not list" \
  "❓ ghost (not in the relevance file)" \
  "✅ prod"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R12: Two metadata files for one environment
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod run)"
create_metadata_file "matrix-job-meta-prod.json" "prod"
create_metadata_file "matrix-job-meta-prod-copy.json" "prod"
run_test "Relevance: two metadata files for one environment" "false" \
  "2 metadata files for environment 'prod', expected exactly one" \
  "❌ prod (2 metadata files)"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R13: Relevance file lists no environments
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}"
run_test "Relevance: file lists no environments" "false" \
  "lists no environments, nothing establishes that auto-merge is permitted"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R14: Relevance file is not valid JSON
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
echo "not json" > "${TEST_RELEVANCE_FILE}"
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox"
run_test "Relevance: file is not valid JSON" "false" \
  "is not valid JSON"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R15: Relevance entry with an unknown verdict
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod maybe)"
run_test "Relevance: entry with an unknown verdict" "false" \
  "each needs a non-empty 'github-environment' and a 'verdict' of 'run' or 'skip'"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R16: Unaffected environment with invalid limits - configuration error
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --limits='{"plan-max-count-add": "abc", "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}')"
run_error_test "Relevance: unaffected environment with invalid limits exits with error"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R17: Unaffected environment with null limits - configuration error
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --limits=null)"
run_error_test "Relevance: unaffected environment with null limits exits with error"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R18: Metadata for an environment the file marks unaffected - its plan
# is still judged, so a run that did happen is never ignored
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip)"
create_metadata_file "matrix-job-meta-prod.json" "prod" \
  --plan-counts='{"count-add": "0", "count-change": "0", "count-destroy": "1", "count-import": "0", "count-move": "0", "count-remove": "0"}' \
  --limits='{"plan-max-count-add": -1, "plan-max-count-change": -1, "plan-max-count-destroy": 0, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}'
run_test "Relevance: metadata for an unaffected environment is still judged" "false" \
  "has a metadata file although the relevance file marks it unaffected" \
  "Destroy count (1) exceeds limit (0) in environment"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R19: Relevance values are not read for an affected environment - its
# metadata decides, as without the file
# ============================================================================
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod run --enabled=false)"
create_metadata_file "matrix-job-meta-prod.json" "prod"
run_test "Relevance: affected environment is judged on its metadata" "true" \
  "✅ prod"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Environments out of pull requests (docs/Auto-merge.md D6, §8)
#
# nightly has trigger-events [push, schedule]: on a pull request it is dropped
# before relevance, so its skip means "never planned", not "not affected". The
# engine says whether the change is relevant to it all the same.
# ============================================================================
_nightly_dropped=(--trigger-events='["push", "schedule"]' --reason="trigger-events: pull_request not enabled")

# D6-1: the change touches nightly - not eligible
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry dev run)" \
  "$(relevance_entry nightly skip --relevant=true "${_nightly_dropped[@]}")"
create_metadata_file "matrix-job-meta-dev.json" "dev"
run_test "Out of pull requests: the change touches nightly - not eligible" "false" \
  "The change touches 'nightly', which takes no part in pull requests, so it was never planned" \
  "Plan creation: NOT PLANNED" "❌ nightly (skipped, never planned)" "✅ dev"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# D6-2: the change touches only dev - nightly is judged as unaffected
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry dev run)" \
  "$(relevance_entry nightly skip --relevant=false "${_nightly_dropped[@]}")"
create_metadata_file "matrix-job-meta-dev.json" "dev"
run_test "Out of pull requests: the change does not touch nightly - eligible" "true" \
  "✅ nightly (not affected)" "✅ dev" "!never planned"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# D6-3: a file from before the engine published relevant - fails closed for nightly
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry dev run --relevant=absent)" \
  "$(relevance_entry nightly skip --relevant=absent "${_nightly_dropped[@]}")"
create_metadata_file "matrix-job-meta-dev.json" "dev"
run_test "Out of pull requests: no relevant field, nightly dropped by trigger events - not eligible" "false" \
  "'nightly' takes no part in pull requests and the relevance file does not say whether the change touches it" \
  "❌ nightly (skipped, never planned)"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# D6-4: a file from before relevant and trigger-events, a plain relevance skip - judged as before
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry dev run --relevant=absent --trigger-events=absent)" \
  "$(relevance_entry staging skip --relevant=absent --trigger-events=absent)"
create_metadata_file "matrix-job-meta-dev.json" "dev"
run_test "Out of pull requests: no relevant field, a plain relevance skip - unaffected as before" "true" \
  "✅ staging (not affected)" "!never planned"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# D6-5: no relevant field, and trigger-events without pull_request whatever the reason says
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry nightly skip --relevant=absent --trigger-events='["push"]')"
run_test "Out of pull requests: no relevant field, trigger-events without pull_request - not eligible" "false" \
  "'nightly' takes no part in pull requests and the relevance file does not say" \
  "❌ nightly (skipped, never planned)"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# D6-6: relevant but skipped for another reason - never planned either
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry prod skip --relevant=true --reason="dispatch: not the requested environment")"
run_test "Out of pull requests: relevant and skipped for another reason - not eligible" "false" \
  "The change touches 'prod', which was skipped (dispatch: not the requested environment), so it was never planned"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# D6-7: relevant of the wrong shape is a malformed file, not an absent field
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry nightly skip --relevant='"true"' "${_nightly_dropped[@]}")"
run_test "Out of pull requests: relevant as text - the file is malformed" "false" \
  "'relevant' is a boolean"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# D6-8: the limits of an environment never planned are still validated, as defence in depth
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry nightly skip --relevant=true "${_nightly_dropped[@]}" \
    --limits='{"plan-max-count-add": "abc", "plan-max-count-change": -1, "plan-max-count-destroy": -1, "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": -1}')"
run_error_test "Out of pull requests: invalid limits on a never-planned environment exit with error"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# D6-9: a relevant, never-planned environment is still judged on enabled and actor
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
export GITHUB_ACTOR="some-human"
create_relevance_file "${TEST_RELEVANCE_FILE}" \
  "$(relevance_entry nightly skip --relevant=true "${_nightly_dropped[@]}")"
run_test "Out of pull requests: the enabled and actor checks still run" "false" \
  "Actor 'some-human' is not authorized for PR automerge" "takes no part in pull requests, so it was never planned"
export GITHUB_ACTOR="dependabot[bot]"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# A tolerated failing test with a relevance file and no affected environment
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" "$(relevance_entry prod skip)"
create_test_metadata_file "modules-rg--int-rg" "modules/rg/tests/int-rg.tftest.hcl" "integration" "fail" true
run_test "Relevance: a tolerated failing test is named, the test metadata is no environment's" "true" \
  "✅ prod (not affected)" "!not in the relevance file" \
  "::notice title=Auto-merge::auto-merge eligible despite the tolerated failing test modules/rg/tests/int-rg.tftest.hcl (lane integration)"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Tests O1-O6: Environment ordering (docs/Environment-ordering.md §7.5). An affected environment a
# failed stage held back has no metadata, which is not eligible as before; only the reason
# changes. TEST_STAGE_RESULTS is the stage-results-json input.
# ============================================================================
# Give a relevance file stages as the engine writes them: each run entry's stage (1 unless named),
# counts.by_stage counted from them, depends-on on every entry and the ordering block.
# Usage: stage_relevance_file <file> <stages used> [<github-environment>:<stage>]...
stage_relevance_file() {
  local file="${1}" used="${2}"
  shift 2
  local stages='{}' spec
  for spec in "$@"; do
    stages=$(jq -c --arg e "${spec%%:*}" --argjson s "${spec##*:}" '.[$e] = $s' <<<"${stages}")
  done
  jq --argjson st "${stages}" --argjson used "${used}" '
    .environments |= map(. + {"depends-on": []} | if .verdict == "run" then .stage = ($st[."github-environment"] // 1) else . end)
    | .environments as $envs
    | def in_stage($n): [$envs[] | select(.verdict == "run" and .stage == $n)] | length;
      .counts.by_stage = {"1": in_stage(1), "2": in_stage(2), "3": in_stage(3)}
    | .ordering = {"declared": true, "stages_used": $used, "cap": 3, "bypass": null}' "${file}" >"${file}.tmp" &&
    mv "${file}.tmp" "${file}"
}
# shared in stage 1, with metadata; prod in stage 2, without
held_back_setup() {
  setup_test_dir
  export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
  create_relevance_file "${TEST_RELEVANCE_FILE}" "$(relevance_entry shared run)" "$(relevance_entry prod run)"
  stage_relevance_file "${TEST_RELEVANCE_FILE}" 2 prod:2
  create_metadata_file "matrix-job-meta-shared.json" "shared"
}

held_back_setup
export TEST_STAGE_RESULTS='{"1": "failure", "2": "skipped", "3": "skipped"}'
run_test "Ordering O1: a held-back environment is not eligible, and the reason says it was held back" "false" \
  "'prod' was held back: it is in stage 2 and stage 1 failed, so it was never planned, environment is ineligible for PR auto merge" \
  "❌ prod (held back)" "✅ shared" \
  "!No metadata file for affected environment 'prod'" "!cancelled or failed"
export TEST_STAGE_RESULTS='{"1": "cancelled", "2": "skipped", "3": "skipped"}'
run_test "Ordering O2: held back by a cancelled stage" "false" \
  "'prod' was held back: it is in stage 2 and stage 1 was cancelled, so it was never planned, environment is ineligible for PR auto merge"
export TEST_STAGE_RESULTS='{"1": "success", "2": "skipped", "3": "skipped"}'
run_test "Ordering O2: held back with no earlier stage to blame (a run cancelled between stages)" "false" \
  "'prod' was held back: it is in stage 2, which did not run, so it was never planned, environment is ineligible for PR auto merge"
# Held back told apart from crashed: prod's stage ran, so its job left no metadata for another reason
export TEST_STAGE_RESULTS='{"1": "success", "2": "failure", "3": "skipped"}'
run_test "Ordering O3: an environment whose stage ran and left no metadata crashed, as before" "false" \
  "No metadata file for affected environment 'prod': its job was cancelled or failed before capturing metadata" \
  "❌ prod (affected, no metadata)" "!held back"
unset TEST_STAGE_RESULTS TEST_RELEVANCE_FILE
cleanup_test_dir

# O4: the lowest earlier stage that failed or was cancelled is the one named; a stage the builder
# counts no environment in holds nothing back, whatever an entry says
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" "$(relevance_entry hub run)" "$(relevance_entry spoke run)" "$(relevance_entry app run)"
stage_relevance_file "${TEST_RELEVANCE_FILE}" 3 spoke:2 app:3
export TEST_STAGE_RESULTS='{"1": "failure", "2": "cancelled", "3": "skipped"}'
run_test "Ordering O4: held back by the lowest failed stage" "false" \
  "'app' was held back: it is in stage 3 and stage 1 failed" "❌ spoke (affected, no metadata)"
jq '.counts.by_stage["3"] = 0' "${TEST_RELEVANCE_FILE}" >"${TEST_RELEVANCE_FILE}.tmp" && mv "${TEST_RELEVANCE_FILE}.tmp" "${TEST_RELEVANCE_FILE}"
run_test "Ordering O4: a stage with a row count of 0 holds nothing back" "false" \
  "❌ app (affected, no metadata)" "!was held back"
unset TEST_STAGE_RESULTS TEST_RELEVANCE_FILE
cleanup_test_dir

# O5: an environment with metadata ran, whatever its stage's result says: judged on its metadata
held_back_setup
create_metadata_file "matrix-job-meta-prod.json" "prod"
export TEST_STAGE_RESULTS='{"1": "failure", "2": "skipped", "3": "skipped"}'
run_test "Ordering O5: metadata wins over a skipped stage" "true" "✅ prod" "!held back"
unset TEST_STAGE_RESULTS TEST_RELEVANCE_FILE
cleanup_test_dir

# O6: without stage results (absent, blank, or not an object of results), and with every
# environment in stage 1, an affected environment without metadata is reported as before
for _o6_results in "" " " '{not json' '["failure"]'; do
  held_back_setup
  export TEST_STAGE_RESULTS="${_o6_results}"
  run_test "Ordering O6: stage results '${_o6_results}' → reported as cancelled or crashed, as before" "false" \
    "No metadata file for affected environment 'prod': its job was cancelled or failed before capturing metadata" \
    "❌ prod (affected, no metadata)" "!held back"
  unset TEST_STAGE_RESULTS TEST_RELEVANCE_FILE
  cleanup_test_dir
done
for _o6_results in '{not json' '["failure"]'; do
  held_back_setup
  export TEST_STAGE_RESULTS="${_o6_results}"
  run_test "Ordering O6: the unusable value '${_o6_results}' is warned about" "false" \
    "stage-results-json is not a JSON object of stage results"
  unset TEST_STAGE_RESULTS TEST_RELEVANCE_FILE
  cleanup_test_dir
done
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
create_relevance_file "${TEST_RELEVANCE_FILE}" "$(relevance_entry shared run)" "$(relevance_entry prod run)"
stage_relevance_file "${TEST_RELEVANCE_FILE}" 1
create_metadata_file "matrix-job-meta-shared.json" "shared"
for _o6_results in '{"1": "failure", "2": "skipped", "3": "skipped"}' '{"1": "skipped", "2": "skipped", "3": "skipped"}'; do
  export TEST_STAGE_RESULTS="${_o6_results}"
  run_test "Ordering O6: everything in stage 1, results ${_o6_results} → as before" "false" \
    "❌ prod (affected, no metadata)" "!held back"
  # run_test removes the metadata after each run
  create_metadata_file "matrix-job-meta-shared.json" "shared"
done
unset TEST_STAGE_RESULTS TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Test R20: The contract - the relevance.json the engine publishes, not a
# hand-written one. A key the engine renames or drops fails here, where the
# hand-written files above would stay green.
# ============================================================================
engine_relevance() {
  python3 -I -B "${_this_script_dir}/../engine/tests/relevance_fixture.py" "${1}" "${TEST_RELEVANCE_FILE}"
}
# The engine refuses an enabled environment whose actor list names nobody
# (docs/Configuration-validation.md §3.6), so every list here names someone:
# prod its own renovate[bot], staging and sandbox the global two.
setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
engine_relevance docs-only
export GITHUB_ACTOR="renovate[bot]"
run_test "Contract: the engine's docs-only file, an actor every environment allows" "true" \
  "✅ prod-gh (not affected)" "✅ staging (not affected)" "✅ sandbox (not affected)" \
  "Environments in relevance file: 3 (0 affected)"
export GITHUB_ACTOR="dependabot[bot]"
run_test "Contract: the engine's docs-only file, an actor prod does not allow" "false" \
  "❌ prod-gh (not affected)" "✅ staging (not affected)"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

setup_test_dir
export TEST_RELEVANCE_FILE="${TEST_DIR}/relevance.json"
engine_relevance one-environment
run_test "Contract: the engine's one-environment file without the affected environment's metadata" "false" \
  "❌ staging (affected, no metadata)"
# The metadata's row is the engine's row for staging, so it carries the same actor list
create_metadata_file "matrix-job-meta-staging.json" "staging" \
  --actors="$(jq -c '.environments[] | select(."github-environment" == "staging") | ."pr-auto-merge-from-actors"' "${TEST_RELEVANCE_FILE}")" \
  --goals-granted="$(jq -c '.environments[] | select(."github-environment" == "staging") | .goals' "${TEST_RELEVANCE_FILE}")"
export GITHUB_ACTOR="renovate[bot]"
run_test "Contract: the engine's one-environment file with its metadata" "true" \
  "✅ prod-gh (not affected)" "✅ sandbox (not affected)" "Environments in relevance file: 3 (1 affected)"
export GITHUB_ACTOR="dependabot[bot]"
unset TEST_RELEVANCE_FILE
cleanup_test_dir

# ============================================================================
# Golden cases (docs/Auto-merge.md §14): every case under engine/tests/evaluator_port, run
# through the action's own run block as the runner runs it: the block's expressions pasted
# into the script text, the step's env: set, nothing else of this suite's environment.
# The engine's suite replays the same cases through its adapter; this one holds the shim.
# ============================================================================
_cases_dir="$(cd -- "${_this_script_dir}/../engine/tests/evaluator_port" &>/dev/null && pwd)"
_step_json="$(mktemp)"
yq -o json '.runs.steps[0]' "${_this_script_dir}/action.yml" >"${_step_json}"

# A sandbox for the case in $1: its files in a workspace, the run block with the case's inputs
# pasted in (step.sh), and the step's env: with them substituted, one assignment a line (env).
make_golden_sandbox() {
  SANDBOX="$(mktemp -d)"
  python3 - "${_this_script_dir}" "${_step_json}" "${1}" "${SANDBOX}" <<'PY'
import json, os, shlex, sys
action_dir, step_file, case_file, sandbox = sys.argv[1:5]
with open(step_file, encoding="utf-8") as handle:
    step = json.load(handle)
with open(case_file, encoding="utf-8") as handle:
    case = json.load(handle)
os.makedirs(f"{sandbox}/ws")
for name, content in case["files"].items():
    with open(f"{sandbox}/ws/{name}", "w", encoding="utf-8") as handle:
        handle.write(content["text"] if "text" in content else json.dumps(content["json"], indent=2))
inputs = {"metadata-files-pattern": case["metadata_files_pattern"], "relevance-file": case["relevance_file"],
          "test-metadata-files-pattern": case["test_metadata_files_pattern"],
          "stage-results-json": case["stage_results_json"]}
def paste(text):
    for name, value in inputs.items():
        text = text.replace("${{ inputs." + name + " }}", value)
    return text.replace("${{ github.action_path }}", action_dir)
with open(f"{sandbox}/step.sh", "w", encoding="utf-8") as handle:
    handle.write(paste(step["run"]))
with open(f"{sandbox}/env", "w", encoding="utf-8") as handle:
    for key, value in (step.get("env") or {}).items():
        handle.write(f"{key}={shlex.quote(paste(str(value)))}\n")
    handle.write(f"GITHUB_ACTOR={shlex.quote(case['actor'])}\n")
PY
}

# A step output by name, in either form GitHub reads: name=value or name<<delimiter.
golden_output() {
  python3 - "${1}" "${2}" <<'PY'
import sys
path, name = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
for index, line in enumerate(lines):
    if line.startswith(name + "="):
        print(line[len(name) + 1:])
        break
    if line.startswith(name + "<<"):
        print("\n".join(lines[index + 1:lines.index(line[len(name) + 2:], index + 1)]))
        break
PY
}

for case_file in "${_cases_dir}"/*.json; do
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: golden $(basename "${case_file}" .json)${NC}"
  make_golden_sandbox "${case_file}"
  : >"${SANDBOX}/output.txt"
  (
    cd "${SANDBOX}/ws" || exit 1
    # What the runner sets for a composite step; the rest comes from the step's env:.
    env -i PATH="${PATH}" HOME="${HOME}" LANG="${LANG:-C.UTF-8}" GITHUB_OUTPUT="${SANDBOX}/output.txt" \
      GITHUB_ACTION_PATH="${_this_script_dir}" \
      bash --noprofile --norc -c 'set -a; source "${1}"; set +a; exec bash --noprofile --norc -eo pipefail "${2}"' \
      _ "${SANDBOX}/env" "${SANDBOX}/step.sh"
  ) >"${_test_output}" 2>&1
  exit_code=$?
  expected_exit="$(jq -r '.expected.exit' "${case_file}")"
  expected_eligible="$(jq -r '.expected.is_eligible' "${case_file}")"
  actual_eligible="$(golden_output "${SANDBOX}/output.txt" is-eligible)"
  problems=()
  [[ "${exit_code}" == "${expected_exit}" ]] || problems+=("exit code ${exit_code}, expected ${expected_exit}")
  [[ "${actual_eligible}" == "${expected_eligible}" ]] ||
    problems+=("is-eligible '${actual_eligible}', expected '${expected_eligible}'")
  while IFS= read -r text; do
    if [[ "${text}" == '!'* ]]; then
      grep -qF -- "${text#!}" "${_test_output}" && problems+=("output holds: ${text#!}")
    else
      grep -qF -- "${text}" "${_test_output}" || problems+=("output lacks: ${text}")
    fi
  done < <(jq -r '.expected.texts[]' "${case_file}")
  if [[ ${#problems[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: exit ${exit_code}, is-eligible '${actual_eligible}'"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}:"
    printf '  %s\n' "${problems[@]}"
    echo "Step output:"
    cat "${_test_output}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -rf "${SANDBOX}"
done
rm -f "${_step_json}"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}                 SUMMARY                    ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -eq 0 ]]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
fi
