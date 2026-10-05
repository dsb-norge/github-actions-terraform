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
# F2 — the step id this action reads by literal name must exist in the
# reusable workflow (docs/Apply-and-destroy-reporting.md §5.1, P7, F2).
#
# extract_environment_data looks up .steps["parse-destroy-plan"].outputs.*
# in the captured metadata. For a long time no step with that id existed,
# so the destroy plan's counts read as empty and never reached the
# plan-max-count-* limits — with every test here green, because the tests
# write the metadata themselves. This is a structural check across the two
# files that have to agree; it is the only thing standing between that
# defect and a silent recurrence on the next workflow refactor.
# ============================================================================
_workflow="${_this_script_dir}/../.github/workflows/terraform-ci-cd-default.yml"
_helper="${_this_script_dir}/helpers_additional.sh"

# The step ids the helper reads out of the metadata, by literal string: the
# outputs and outcomes it reads one by one, and the operation steps whose
# outcomes block auto-merge. An operation step renamed in the workflow would
# read as absent, which the operations check takes for "did not fail".
_ids_read_by_helper=$( {
  grep -oE 'get_step_(output|outcome_success) "\$\{file\}" "[a-z-]+"' "${_helper}" | grep -oE '"[a-z-]+"$' | tr -d '"'
  sed -nE 's/^_OPERATION_STEP_IDS=\((.*)\)$/\1/p' "${_helper}" | tr ' ' '\n'
} | sort -u)
# The step ids the workflow's matrix job actually defines.
_ids_in_workflow=$(python3 - "${_workflow}" <<'PYEOF'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for step in wf["jobs"]["terraform-ci-cd"]["steps"]:
    if "id" in step:
        print(step["id"])
PYEOF
)

TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F2 - every step id the helper reads exists in the workflow${NC}"
echo -e "${BLUE}========================================${NC}"
_f2_missing=""
for _id in ${_ids_read_by_helper}; do
  if ! grep -qx "${_id}" <<<"${_ids_in_workflow}"; then
    _f2_missing+=" ${_id}"
  fi
done
if [[ -z "${_f2_missing}" ]] && grep -qx "parse-destroy-plan" <<<"${_ids_read_by_helper}" \
   && grep -qx "verify-lock" <<<"${_ids_read_by_helper}"; then
  echo -e "${GREEN}✓ PASSED${NC}: helper reads [$(echo ${_ids_read_by_helper} | tr '\n' ' ')] — all defined in the workflow"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: step id(s) read by helpers_additional.sh but not defined in terraform-ci-cd-default.yml:${_f2_missing:- (parse-destroy-plan or the operation step ids no longer read by the helper?)}"
  echo "  helper reads:  $(echo ${_ids_read_by_helper} | tr '\n' ' ')"
  echo "  workflow has:  $(echo ${_ids_in_workflow} | tr '\n' ' ')"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F5 — the three mutating-step outcome gates must come AFTER the phase-2
# comment steps (docs/Apply-and-destroy-reporting.md P1, F5).
#
# A gate exits 1. With allow-failing-terraform-operations=false that fails
# the job and skips every later step without always(). A gate placed
# before the phase-2 render would make a failed apply the one case that
# skips its own reporting. Structural, not behavioural — but P1 is the
# defect most likely to be reintroduced by a later refactor that "tidies"
# the gates together.
# ============================================================================
_step_order=$(python3 - "${_workflow}" <<'PYEOF'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for i, step in enumerate(wf["jobs"]["terraform-ci-cd"]["steps"]):
    print(i, step.get("id") or step.get("name"))
PYEOF
)
_pos() { grep -F -- " ${1}" <<<"${_step_order}" | head -n1 | cut -d' ' -f1; }
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F5 - apply/destroy outcome gates sit after the phase-2 comment steps${NC}"
echo -e "${BLUE}========================================${NC}"
_upsert=$(_pos "upsert-head-apply")
_gate_apply=$(_pos "🧐 Validation outcome: 🐙 Apply")
_gate_dplan=$(_pos "🧐 Validation outcome: ☠📖 Destroy Plan")
_gate_destroy=$(_pos "🧐 Validation outcome: ☠ Destroy")
_capture=$(_pos "capture-metadata")
if [[ -n "${_upsert}" && -n "${_gate_apply}" && -n "${_gate_dplan}" && -n "${_gate_destroy}" && -n "${_capture}" ]] \
   && [ "${_gate_apply}" -gt "${_upsert}" ] && [ "${_gate_dplan}" -gt "${_upsert}" ] && [ "${_gate_destroy}" -gt "${_upsert}" ] \
   && [ "${_gate_apply}" -lt "${_capture}" ] && [ "${_gate_dplan}" -lt "${_capture}" ] && [ "${_gate_destroy}" -lt "${_capture}" ]; then
  echo -e "${GREEN}✓ PASSED${NC}: upsert-head-apply@${_upsert} < gates@${_gate_apply},${_gate_dplan},${_gate_destroy} < capture-metadata@${_capture}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: gate ordering — upsert-head-apply=${_upsert:-?} gates=${_gate_apply:-?},${_gate_dplan:-?},${_gate_destroy:-?} capture=${_capture:-?}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# The phase-2 render must also come after every mutating step and its parsers.
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F5 - phase-2 render follows destroy and every parse step${NC}"
echo -e "${BLUE}========================================${NC}"
_cvs2=$(_pos "cvs-apply"); _destroy=$(_pos "destroy"); _pdw=$(_pos "parse-destroy-warnings"); _pda=$(_pos "parse-destroy-apply")
if [[ -n "${_cvs2}" && -n "${_destroy}" && -n "${_pdw}" && -n "${_pda}" ]] && [ "${_cvs2}" -gt "${_destroy}" ] && [ "${_cvs2}" -gt "${_pdw}" ] && [ "${_cvs2}" -gt "${_pda}" ]; then
  echo -e "${GREEN}✓ PASSED${NC}: cvs-apply@${_cvs2} after destroy@${_destroy}, parse-destroy-apply@${_pda}, parse-destroy-warnings@${_pdw}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: cvs-apply=${_cvs2:-?} destroy=${_destroy:-?} parse-destroy-apply=${_pda:-?} parse-destroy-warnings=${_pdw:-?}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F5c — every step from the first parse step after apply through the three
# gates must carry always() (docs/Apply-and-destroy-reporting.md P31).
#
# apply/destroy fail the job on the spot (continue-on-error is
# allow-failing-terraform-operations, default false), and a later step whose
# if: lacks always() is skipped even when the if: is true. The first real
# failed apply lost its parse step that way. F5 checks order; this checks
# the guard, mechanically, so the next step added here cannot forget it.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F5c - every step after apply up to the gates carries always()${NC}"
echo -e "${BLUE}========================================${NC}"
_missing_always=$(python3 - "${_workflow}" <<'PYEOF'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["terraform-ci-cd"]["steps"]
names = [s.get("id") or s.get("name") for s in steps]
start = names.index("parse-apply")
end = names.index("capture-metadata")
# The terraform steps themselves are deliberately NOT always(): destroy-plan
# must not run after a failed init, destroy not after a failed destroy-plan.
exempt = {"destroy-plan", "destroy"}
for s in steps[start:end]:
    name = s.get("id") or s.get("name")
    if name in exempt:
        continue
    if "always()" not in str(s.get("if", "")):
        print(name)
PYEOF
)
if [[ -z "${_missing_always}" ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: every parse / render / post / upsert / annotate / gate step between parse-apply and capture-metadata carries always()"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: steps missing always() in their if::"
  echo "${_missing_always}" | sed 's/^/    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F6 — no comment body travels inline anywhere in the workflows: every
# pr-comment upsert uses body-file, and no step interpolates a *-extract or
# head-summary output as a string (docs/Apply-and-destroy-reporting.md §7.10).
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F6 - no inline comment bodies in any workflow${NC}"
echo -e "${BLUE}========================================${NC}"
_wf_dir="${_this_script_dir}/../.github/workflows"
_inline_bodies=$(grep -nE '^\s+body:\s' "${_wf_dir}"/*.y*ml || true)
_string_outputs=$(grep -nE 'outputs\.(head-summary|plan-extract|apply-extract|destroy-plan-extract|destroy-extract|summary|prefix)\s*\}\}' "${_wf_dir}"/*.y*ml | grep -vE 'test\.outputs\.summary|-file\s*\}\}' || true)
_legacy=$(grep -n 'comment-on-pr' "${_wf_dir}"/*.y*ml || true)
if [[ -z "${_inline_bodies}" && -z "${_string_outputs}" && -z "${_legacy}" ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: every pr-comment upsert uses body-file; no body string is interpolated; comment-on-pr@v2 is gone"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  [ -n "${_inline_bodies}" ] && { echo "  inline 'body:' in a workflow:"; echo "${_inline_bodies}" | sed 's/^/    /'; }
  [ -n "${_string_outputs}" ] && { echo "  a body-string output interpolated:"; echo "${_string_outputs}" | sed 's/^/    /'; }
  [ -n "${_legacy}" ] && { echo "  comment-on-pr still referenced:"; echo "${_legacy}" | sed 's/^/    /'; }
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F7 — every `with:` key a workflow passes is declared by the thing it calls,
# and every required input without a default is passed. GitHub enforces
# neither for composite actions: an unknown key is a run-time warning nobody
# reads, and a missing required input arrives as an empty string. Both have
# already happened here — an undeclared `apply-count-import`, and a missing
# `status-verify-lock` that rendered an empty badge in every module repo's
# comment for as long as that call site existed.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F7 - workflow with-keys match the called action's inputs${NC}"
echo -e "${BLUE}========================================${NC}"
_contract_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import glob, os, sys, yaml

def load(path):
    with open(path, encoding='utf-8') as fh:
        return yaml.safe_load(fh) or {}

def declared_inputs(target):
    """Inputs of a composite action dir, or of a reusable workflow file."""
    for candidate in (f"{target}/action.yml", f"{target}/action.yaml"):
        if os.path.isfile(candidate):
            return (load(candidate).get('inputs') or {}), f"action {target}"
    if os.path.isfile(target):
        # 'on' is parsed as the boolean True by YAML 1.1, hence both lookups.
        doc = load(target)
        on = doc.get(True, doc.get('on')) or {}
        return ((on.get('workflow_call') or {}).get('inputs') or {}), f"workflow {target}"
    return None, None

def resolve(uses):
    if uses.startswith('./'):
        return uses[2:]
    if 'dsb-norge/github-actions-terraform/' in uses:
        return uses.split('dsb-norge/github-actions-terraform/')[1].split('@')[0]
    return None  # third-party action: not ours to check

problems, checked = [], 0
for wf in sorted(glob.glob('.github/workflows/*.y*ml')):
    doc = load(wf)
    call_sites, seen_steps = [], []
    for job_name, job in (doc.get('jobs') or {}).items():
        if isinstance(job.get('uses'), str):
            call_sites.append((job_name, job['uses'], job.get('with') or {}))
        steps = job.get('steps') or []
        # The stage jobs share one step list through a YAML anchor, which loads as one list: check it once.
        if any(steps is seen for seen in seen_steps):
            continue
        seen_steps.append(steps)
        for step in steps:
            if isinstance(step.get('uses'), str):
                call_sites.append((job_name, step['uses'], step.get('with') or {}))
    for job_name, uses, given in call_sites:
        target = resolve(uses)
        if target is None:
            continue
        declared, label = declared_inputs(target)
        if declared is None:
            problems.append(f"{wf} :: job '{job_name}' calls '{target}', which does not exist")
            continue
        checked += len(given)
        for key in sorted(set(given) - set(declared)):
            problems.append(f"{wf} :: job '{job_name}' passes '{key}' to {label}, which does not declare it")
        for key, spec in sorted(declared.items()):
            spec = spec or {}
            if spec.get('required') is True and 'default' not in spec and key not in given:
                problems.append(f"{wf} :: job '{job_name}' omits '{key}', required by {label} with no default")

print(f"checked {checked} with-key(s)")
for p in problems:
    print(f"PROBLEM {p}")
sys.exit(1 if problems else 0)
PYEOF
) && _contract_rc=0 || _contract_rc=$?
if [[ "${_contract_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_contract_out}" | head -n1), all declared by their target"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_contract_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F8 — no integer test reads an input variable without a default. `[ "${x}" -gt
# 0 ]` on an unset or empty value prints "integer expression expected" into the
# job log and returns 2, which a && chain then swallows. Two of these shipped on
# this branch (one found in review), both in the shape "defaulted in the regex
# test, bare in the integer test three characters later".
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F8 - integer tests always default their input${NC}"
echo -e "${BLUE}========================================${NC}"
_undefaulted=$(cd "${_this_script_dir}/.." && grep -rnE '\[ *"\$\{input_[a-zA-Z0-9_]+\}" *-(ne|eq|gt|lt|ge|le) ' \
  --include='step_*.sh' --include='helpers_additional.sh' --include='*.sh' . 2>/dev/null |
  grep -v 'run_all_tests\|run_local_step' || true)
if [[ -z "${_undefaulted}" ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: every integer test on an input variable supplies a default"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: integer test(s) on an undefaulted input variable:"
  echo "${_undefaulted}" | sed 's/^/    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F9 — an expression captured into a script through a heredoc is JSON, under a
# quoted delimiter unique in the repository. GitHub pastes the expression's value
# into the script before bash parses it, so a value holding the delimiter line
# ends the capture and the rest runs as shell. toJSON output cannot hold such a
# line (JSON escapes a string's newlines); free text can. So an action captures
# either toJSON(inputs.<input>) itself, or a JSON-contract input (its name ends
# in -json, or it is one of the listed older ones) that every call site in the
# workflows passes as toJSON(...) or a JSON literal; a workflow captures only
# toJSON(...); and no delimiter is a bare or shared name.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F9 - heredoc captures hold JSON under unique quoted delimiters${NC}"
echo -e "${BLUE}========================================${NC}"
_capture_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import glob, json, re, sys, yaml

def load(path):
    with open(path, encoding='utf-8') as fh:
        return yaml.safe_load(fh) or {}

def run_blocks(doc):
    steps, seen = list(((doc.get('runs') or {}).get('steps')) or []), []
    for job in (doc.get('jobs') or {}).values():
        job_steps = job.get('steps') or []
        # The stage jobs share one step list through a YAML anchor; counted once per alias, its
        # delimiters would read as used three times.
        if any(job_steps is other for other in seen):
            continue
        seen.append(job_steps)
        steps += job_steps
    return [step['run'] for step in steps if isinstance(step.get('run'), str)]

# JSON-contract inputs named before the -json suffix was the rule; each documents a JSON object.
JSON_CONTRACT = {('export-env-vars', 'extra-envs'), ('export-env-vars', 'extra-envs-from-secrets'),
                 ('resolve-goal-envs', 'extra-envs'), ('resolve-goal-envs', 'extra-envs-from-secrets'),
                 ('resolve-goal-envs', 'extra-envs-per-goal'), ('resolve-goal-envs', 'extra-envs-from-secrets-per-goal')}
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(.*?)\n[ \t]*\2[ \t]*(?:\n|$)", re.S)
EXPR = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
problems, captures, delimiters = [], {}, {}
files = sorted(glob.glob('*/action.yml') + glob.glob('*/action.yaml') + glob.glob('.github/workflows/*.y*ml'))
for path in files:
    for block in run_blocks(load(path)):
        for quote, delimiter, body in HEREDOC.findall(block):
            expressions = EXPR.findall(body)
            if not expressions:
                continue
            where = f"{path} :: heredoc {delimiter}"
            if not quote:
                problems.append(f"{where}: the delimiter is not quoted, so bash expands the captured value")
            if delimiter == 'EOF' or not delimiter.endswith('_JSON'):
                problems.append(f"{where}: the delimiter must name what it captures and end in _JSON")
            delimiters.setdefault(delimiter, []).append(path)
            for expression in expressions:
                if path.startswith('.github/'):
                    if not re.fullmatch(r"toJSON\(.+\)", expression):
                        problems.append(f"{where}: captures '{expression}', not toJSON(...)")
                elif re.fullmatch(r"toJSON\(inputs\.[a-z0-9-]+\)", expression):
                    pass  # JSON by construction, whatever the caller passes
                elif re.fullmatch(r"inputs\.[a-z0-9-]+", expression):
                    name, action = expression.split('.', 1)[1], path.split('/')[0]
                    if not name.endswith('-json') and (action, name) not in JSON_CONTRACT:
                        problems.append(f"{where}: captures input '{name}', which is not a JSON-contract input; capture toJSON(inputs.{name}) instead")
                    captures.setdefault(action, set()).add(name)
                else:
                    problems.append(f"{where}: captures '{expression}', neither an input nor toJSON of one")
for delimiter, paths in delimiters.items():
    if len(paths) > 1:
        problems.append(f"delimiter {delimiter} is used {len(paths)} times: {', '.join(paths)}")

def json_value(value):
    if isinstance(value, str):
        text = value.strip()
        if re.fullmatch(r"\$\{\{\s*toJSON\(.+\)\s*\}\}", text):
            return True
        try:
            json.loads(text)
            return True
        except ValueError:
            return False
    return value is None or isinstance(value, (bool, int, float))

checked = 0
for wf in sorted(glob.glob('.github/workflows/*.y*ml')):
    doc = load(wf)
    for job in (doc.get('jobs') or {}).values():
        for step in job.get('steps') or []:
            uses = step.get('uses') or ''
            action = uses[2:] if uses.startswith('./') else uses.split('dsb-norge/github-actions-terraform/')[-1].split('@')[0] if 'dsb-norge/github-actions-terraform/' in uses else None
            for name in sorted(captures.get(action, ())):
                if name in (step.get('with') or {}):
                    checked += 1
                    if not json_value(step['with'][name]):
                        problems.append(f"{wf} :: passes {action}'s captured input '{name}' as {step['with'][name]!r}, not toJSON(...) or JSON")

print(f"checked {sum(len(v) for v in delimiters.values())} capture(s), {checked} call site(s)")
for p in problems:
    print(f"PROBLEM {p}")
sys.exit(1 if problems else 0)
PYEOF
) && _capture_rc=0 || _capture_rc=$?
if [[ "${_capture_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_capture_out}" | head -n1): JSON only, unique quoted delimiters"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_capture_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F10 — the jobs around the matrix judge named results and the builder's counts
# (docs/Path-relevance.md §5.3, §7, §8; P3, P14).
#
# "Skipped" alone cannot tell "nothing to verify" from "something upstream
# broke"; only the builder's affected count can. So the conclusion reads named
# results, never contains(needs.*.result, ...); the matrix job does not test
# the seed's result (a broken seed skipped every environment while the
# conclusion stayed green) and keeps an empty matrix away from GitHub; and the
# automerge job carries a status function, or the implicit success() skips it
# whenever a stage job is skipped. The conclusion's script is also run, one case
# per row of §7.2, and with the environments in stages: every case of one stage
# must read exactly as it did before stages existed, and a held-back stage is
# named with its count (docs/Environment-ordering.md §7.3). The stage jobs'
# guards and needs are F15's.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F10 - conclusion, matrix gate and automerge read named results and the counts${NC}"
echo -e "${BLUE}========================================${NC}"
_f10_out=$(python3 - "${_workflow}" <<'PYEOF'
import os, subprocess, sys, tempfile, yaml

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
jobs = yaml.safe_load(text)["jobs"]
problems = []

if "contains(needs.*.result" in text:
    problems.append("the workflow still judges contains(needs.*.result, ...)")

matrix = jobs["terraform-ci-cd"]
if set(matrix.get("needs", [])) != {"create-matrix", "seed-pr-comments"}:
    problems.append(f"terraform-ci-cd needs {matrix.get('needs')}, expected create-matrix and seed-pr-comments")
condition = " ".join(str(matrix.get("if", "")).split())
for clause in ("!cancelled()", "needs.create-matrix.result == 'success'",
               "needs.create-matrix.outputs.stage-1-count != '0'"):
    if clause not in condition:
        problems.append(f"terraform-ci-cd's if lacks {clause}")
if "seed-pr-comments.result" in condition:
    problems.append("terraform-ci-cd's if tests the seed's result")
if (matrix.get("strategy") or {}).get("matrix") != "${{ fromJSON(needs.create-matrix.outputs.matrix-stage-1-json) }}":
    problems.append(f"terraform-ci-cd's matrix is {(matrix.get('strategy') or {}).get('matrix')!r}, expected stage 1's")

conclusion = jobs["conclusion"]
if str(conclusion.get("if")).strip() != "always()":
    problems.append(f"conclusion's if is {conclusion.get('if')!r}, expected always()")
if conclusion.get("needs") != ["create-matrix", "terraform-ci-cd", "terraform-ci-cd-2", "terraform-ci-cd-3", "terraform-test"]:
    problems.append(f"conclusion needs {conclusion.get('needs')}, expected [create-matrix, terraform-ci-cd, "
                    "terraform-ci-cd-2, terraform-ci-cd-3, terraform-test]")
steps = conclusion.get("steps", [])
env = steps[0].get("env", {}) if steps else {}
expected_env = {
    "CREATE_MATRIX_RESULT": "${{ needs.create-matrix.result }}",
    "AFFECTED_COUNT": "${{ needs.create-matrix.outputs.affected-count }}",
    "STAGE_1_RESULT": "${{ needs.terraform-ci-cd.result }}",
    "STAGE_1_COUNT": "${{ needs.create-matrix.outputs.stage-1-count }}",
    "STAGE_2_RESULT": "${{ needs.terraform-ci-cd-2.result }}",
    "STAGE_2_COUNT": "${{ needs.create-matrix.outputs.stage-2-count }}",
    "STAGE_3_RESULT": "${{ needs.terraform-ci-cd-3.result }}",
    "STAGE_3_COUNT": "${{ needs.create-matrix.outputs.stage-3-count }}",
    "TESTS_ACTIVE": "${{ needs.create-matrix.outputs.tests-active }}",
    "TESTS_RESULT": "${{ needs.terraform-test.result }}",
    "EVENT_NAME": "${{ github.event_name }}",
}
for name, value in expected_env.items():
    if env.get(name) != value:
        problems.append(f"conclusion's step env {name} is {env.get(name)!r}, expected {value!r}")

automerge = jobs["automerge"]
if set(automerge.get("needs", [])) != {"create-matrix", "terraform-ci-cd", "terraform-ci-cd-2", "terraform-ci-cd-3",
                                       "conclusion"}:
    problems.append(f"automerge needs {automerge.get('needs')}, expected create-matrix, the three stage jobs, conclusion")
condition = " ".join(str(automerge.get("if", "")).split())
clauses = ["!cancelled()", "needs.conclusion.result == 'success'"]
for stage, job_id in ((1, "terraform-ci-cd"), (2, "terraform-ci-cd-2"), (3, "terraform-ci-cd-3")):
    clauses.append(f"( needs.{job_id}.result == 'success' || (needs.{job_id}.result == 'skipped' "
                   f"&& needs.create-matrix.outputs.stage-{stage}-count == '0') )")
for clause in clauses:
    if clause not in condition:
        problems.append(f"automerge's if lacks {clause}")

# Every download of the relevance artifact may fail: a download by name of a missing artifact throws (P8).
downloads = 0
for name, job in jobs.items():
    for step in job.get("steps", []):
        if str(step.get("uses", "")).startswith("actions/download-artifact") and (step.get("with") or {}).get("name") == "relevance":
            downloads += 1
            if step.get("continue-on-error") is not True:
                problems.append(f"{name}: the relevance download is not continue-on-error")
if downloads != 5:
    problems.append(f"{downloads} relevance downloads, expected the seed, the aggregator, the run summary, automerge "
                    "and the tests summary")

# The conclusion's script, one case per row of §7.2. Stages 2 and 3 are empty, as on every run of a
# repository without depends-on; a matrix that was not built publishes no counts.
script = steps[0]["run"] if steps else "exit 3"


def conclude(**facts):
    with tempfile.NamedTemporaryFile("w+") as summary:
        # EVENT_NAME is set, never inherited: every case is a pull request unless it says otherwise.
        run_env = dict(os.environ, UNAFFECTED_COUNT="1", RELEVANCE_MODE="diff", RELEVANCE_REASON="diff",
                       TESTS_COUNT="3" if facts.get("TESTS_ACTIVE") == "true" else "0", GITHUB_STEP_SUMMARY=summary.name,
                       EVENT_NAME="pull_request")
        run_env.update(facts)
        done = subprocess.run(["bash", "-e", "-c", script], env=run_env, capture_output=True, text=True)
        return done, open(summary.name, encoding="utf-8").read()


cases = [
    ("failure", "", "skipped", "skipped", "", 1), ("cancelled", "", "skipped", "skipped", "", 1),
    ("skipped", "", "skipped", "skipped", "", 1),
    ("success", "2", "success", "skipped", "false", 0), ("success", "0", "skipped", "skipped", "false", 0),
    ("success", "2", "skipped", "skipped", "false", 1), ("success", "2", "failure", "skipped", "false", 1),
    ("success", "2", "cancelled", "skipped", "false", 1),
    # The tests, judged independently of the environments.
    ("success", "2", "success", "success", "true", 0), ("success", "0", "skipped", "success", "true", 0),
    ("success", "2", "success", "failure", "true", 1), ("success", "2", "success", "cancelled", "true", 1),
    ("success", "2", "success", "skipped", "true", 1), ("success", "0", "skipped", "failure", "true", 1),
]
for create_matrix, affected, environments, tests, active, expected in cases:
    empty = "0" if create_matrix == "success" else ""
    done, written = conclude(CREATE_MATRIX_RESULT=create_matrix, AFFECTED_COUNT=affected, STAGE_1_RESULT=environments,
                             STAGE_1_COUNT=affected, STAGE_2_RESULT="skipped", STAGE_2_COUNT=empty,
                             STAGE_3_RESULT="skipped", STAGE_3_COUNT=empty, TESTS_RESULT=tests, TESTS_ACTIVE=active)
    verdict = "green" if expected == 0 else "red"
    annotation = "::notice title=Terraform conclusion::" if expected == 0 else "::error title=Terraform conclusion::"
    label = f"create-matrix={create_matrix} affected={affected or '-'} environments={environments} tests={tests}/{active}"
    if done.returncode != expected:
        problems.append(f"conclusion exits {done.returncode} for {label}, expected {expected}")
    if f"conclusion: {verdict} — " not in written or annotation + f"conclusion: {verdict} — " not in done.stdout:
        problems.append(f"conclusion does not report {verdict} in the step summary and an annotation for {label}")

# The line itself. With one stage it reads exactly as before stages existed, for every repository
# without depends-on; with more, each stage that has environments is named, a held-back one with its
# count. Each fact overrides a green two-environment run of one stage.
one_stage = dict(CREATE_MATRIX_RESULT="success", AFFECTED_COUNT="2", STAGE_1_RESULT="success", STAGE_1_COUNT="2",
                 STAGE_2_RESULT="skipped", STAGE_2_COUNT="0", STAGE_3_RESULT="skipped", STAGE_3_COUNT="0",
                 TESTS_RESULT="skipped", TESTS_ACTIVE="false")
two_stages = dict(one_stage, AFFECTED_COUNT="3", STAGE_1_COUNT="1", STAGE_2_RESULT="success", STAGE_2_COUNT="2")
three_stages = dict(two_stages, AFFECTED_COUNT="4", STAGE_2_COUNT="1", STAGE_3_RESULT="success", STAGE_3_COUNT="2")
lines = [
    (one_stage, "green — environments: 2 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(one_stage, AFFECTED_COUNT="0", STAGE_1_RESULT="skipped", STAGE_1_COUNT="0"),
     "green — nothing to verify for this change; environments: 0 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(one_stage, AFFECTED_COUNT="0", STAGE_1_RESULT="skipped", STAGE_1_COUNT="0", EVENT_NAME="push"),
     "green — nothing to verify for this change; environments: 0 affected, 1 not affected (diff: diff); tests: 0"),
    # A schedule or a dispatch has no change to verify; pull requests and pushes read as before.
    (dict(one_stage, AFFECTED_COUNT="0", STAGE_1_RESULT="skipped", STAGE_1_COUNT="0", EVENT_NAME="schedule"),
     "green — nothing to run; environments: 0 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(one_stage, AFFECTED_COUNT="0", STAGE_1_RESULT="skipped", STAGE_1_COUNT="0", EVENT_NAME="workflow_dispatch"),
     "green — nothing to run; environments: 0 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(one_stage, STAGE_1_RESULT="skipped"),
     "red — the environments should have run but were skipped; environments: 2 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(one_stage, STAGE_1_RESULT="failure"),
     "red — the environments' result is failure; environments: 2 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(one_stage, CREATE_MATRIX_RESULT="failure", AFFECTED_COUNT="", STAGE_1_COUNT="", STAGE_2_COUNT="",
          STAGE_3_COUNT=""), "red — the matrix could not be built (failure)"),
    (dict(one_stage, TESTS_RESULT="failure", TESTS_ACTIVE="true"),
     "red — the tests' result is failure; environments: 2 affected, 1 not affected (diff: diff); tests: 3"),
    (two_stages, "green — stage 1 succeeded; stage 2 succeeded; environments: 3 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(two_stages, STAGE_1_RESULT="failure", STAGE_2_RESULT="skipped"),
     "red — stage 1 failed; stage 2 held back (2 environment(s)); environments: 3 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(two_stages, STAGE_2_RESULT="failure"),
     "red — stage 1 succeeded; stage 2 failed; environments: 3 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(two_stages, TESTS_RESULT="failure", TESTS_ACTIVE="true"),
     "red — the tests' result is failure; stage 1 succeeded; stage 2 succeeded; environments: 3 affected, 1 not affected (diff: diff); tests: 3"),
    (three_stages, "green — stage 1 succeeded; stage 2 succeeded; stage 3 succeeded; environments: 4 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(three_stages, STAGE_2_RESULT="failure", STAGE_3_RESULT="skipped"),
     "red — stage 1 succeeded; stage 2 failed; stage 3 held back (2 environment(s)); environments: 4 affected, 1 not affected (diff: diff); tests: 0"),
    (dict(three_stages, STAGE_1_RESULT="cancelled", STAGE_2_RESULT="skipped", STAGE_3_RESULT="skipped"),
     "red — stage 1's result is cancelled; stage 2 held back (1 environment(s)); stage 3 held back (2 environment(s)); environments: 4 affected, 1 not affected (diff: diff); tests: 0"),
    # An empty stage in the middle is left out and holds nothing back.
    (dict(three_stages, AFFECTED_COUNT="3", STAGE_2_RESULT="skipped", STAGE_2_COUNT="0"),
     "green — stage 1 succeeded; stage 3 succeeded; environments: 3 affected, 1 not affected (diff: diff); tests: 0"),
]
for facts, expected_line in lines:
    done, written = conclude(**facts)
    line = f"conclusion: {expected_line}"
    green = expected_line.startswith("green")
    annotation = ("::notice" if green else "::error") + f" title=Terraform conclusion::{line}"
    if done.returncode != (0 if green else 1) or written != line + "\n" or annotation not in done.stdout.splitlines():
        problems.append(f"conclusion reads {written.strip()!r} (exit {done.returncode}), expected {line!r}")

print(f"checked the conclusion, the matrix gate, automerge, the relevance downloads, {len(cases)} conclusion cases "
      f"and {len(lines)} conclusion lines")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f10_rc=0 || _f10_rc=$?
if [[ "${_f10_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f10_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f10_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F11 — the relevance decision travels from create-matrix to its readers intact
# (docs/Path-relevance.md §5.2, §6.3).
#
# create-matrix exposes the small values as job outputs and uploads the file;
# every reader downloads it to one place and is handed that path. The seed
# job's script, the one piece of bash in the workflow that reads it, is run on
# the engine's own relevance.json and on a missing one: the heads and purge
# rules it hands to pr-comments-reconcile must be the engine's, byte for byte,
# after the JSON-to-YAML round trip.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F11 - the relevance decision reaches the seed and the readers intact${NC}"
echo -e "${BLUE}========================================${NC}"
_f11_out=$(python3 - "${_workflow}" "${_this_script_dir}/../engine/tests/relevance_fixture.py" <<'PYEOF'
import json, os, subprocess, sys, tempfile, yaml

workflow, fixture = sys.argv[1], sys.argv[2]
jobs = yaml.safe_load(open(workflow, encoding="utf-8"))["jobs"]
problems = []

create = jobs["create-matrix"]
names = ["matrix-json", "affected-count", "matrix-stage-1-json", "matrix-stage-2-json", "matrix-stage-3-json",
         "stage-1-count", "stage-2-count", "stage-3-count", "unaffected-count", "relevance-mode", "relevance-reason",
         "changed-count", "tests-matrix-json", "tests-count", "tests-active", "admission-refused", "admission-reason"]
if create.get("outputs") != {name: f"${{{{ steps.create-matrix.outputs.{name} }}}}" for name in names}:
    problems.append(f"create-matrix's outputs are {create.get('outputs')}")
if create.get("permissions") != {"contents": "read", "pull-requests": "read"}:
    problems.append(f"create-matrix's permissions are {create.get('permissions')}")
uploads = [s for s in create["steps"] if str(s.get("uses", "")).startswith("actions/upload-artifact")]
if len(uploads) != 1 or uploads[0].get("with") != {"name": "relevance",
                                                   "path": "${{ steps.create-matrix.outputs.relevance-file }}"}:
    problems.append(f"create-matrix does not upload relevance-file as 'relevance': {uploads}")

readers = {"pr-comment-aggregator": "aggregate-validation-summaries", "run-summary": "create-run-summary",
           "automerge": "evaluate-automerge-eligibility"}
for name, job in jobs.items():
    for step in job.get("steps", []):
        with_ = step.get("with") or {}
        if str(step.get("uses", "")).startswith("actions/download-artifact") and with_.get("name") == "relevance":
            if with_.get("path") != "${{ runner.temp }}/relevance":
                problems.append(f"{name} downloads the relevance artifact to {with_.get('path')}")
        if "relevance-file" in with_ and with_["relevance-file"] != "${{ runner.temp }}/relevance/relevance.json":
            problems.append(f"{name} passes relevance-file {with_['relevance-file']}")
for job, action in readers.items():
    passed = [s for s in jobs[job]["steps"] if action in str(s.get("uses", "")) and "relevance-file" in (s.get("with") or {})]
    if len(passed) != 1:
        problems.append(f"{job} does not pass relevance-file to {action}")

seed = jobs["seed-pr-comments"]["steps"]
compose = [s for s in seed if s.get("id") == "compose"]
reconcile = [s for s in seed if "pr-comments-reconcile" in str(s.get("uses", ""))]
if len(compose) != 1 or len(reconcile) != 1:
    problems.append("the seed job lacks its compose step or its reconcile step")
else:
    with_ = reconcile[0].get("with") or {}
    for name in ("heads-yml", "gc-yml"):
        if with_.get(name) != f"${{{{ steps.compose.outputs.{name} }}}}":
            problems.append(f"the seed's reconcile gets {name}: {with_.get(name)!r}")

    def outputs(path):
        lines, result, index = open(path, encoding="utf-8").read().split("\n"), {}, 0
        while index < len(lines) and lines[index]:
            name, delimiter = lines[index].split("<<", 1)
            end = lines.index(delimiter, index + 1)
            result[name] = "\n".join(lines[index + 1:end])
            index = end + 1
        return result

    for scenario in ("one-environment", "docs-only", None):
        with tempfile.TemporaryDirectory() as temp:
            os.mkdir(os.path.join(temp, "relevance"))
            manifest = os.path.join(temp, "relevance", "relevance.json")
            if scenario:
                subprocess.run([sys.executable, "-I", "-B", fixture, scenario, manifest], check=True)
            out = os.path.join(temp, "output")
            open(out, "w").close()
            done = subprocess.run(["bash", "-e", "-c", compose[0]["run"]], capture_output=True, text=True,
                                  env=dict(os.environ, RUNNER_TEMP=temp, GITHUB_OUTPUT=out))
            label = scenario or "a missing manifest"
            if done.returncode != 0:
                problems.append(f"the compose script exits {done.returncode} on {label}: {done.stderr.strip()[:300]}")
                continue
            got = outputs(out)
            heads, gc = yaml.safe_load(got.get("heads-yml", "")), yaml.safe_load(got.get("gc-yml", ""))
            if scenario:
                published = json.load(open(manifest, encoding="utf-8"))["comments"]
                if heads != [{"marker": h["marker"], "body": h["body"]} for h in published["heads"]]:
                    problems.append(f"heads-yml on {label} is not the engine's heads: {heads}")
                if gc != published["gc"]:
                    problems.append(f"gc-yml on {label} is not the engine's purge rules: {gc}")
                if not published["heads"] or (scenario == "docs-only" and not published["gc"]):
                    problems.append(f"the {label} fixture no longer exercises heads and purges")
            else:
                if (heads, gc) != ([], []):
                    problems.append(f"a missing manifest seeds {heads} and purges {gc}")
                if "::warning title=Seed PR comment heads::" not in done.stdout:
                    problems.append("a missing manifest is not warned about")

print("checked create-matrix's outputs, permissions and upload, the readers' paths, and the seed script on 3 manifests")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f11_rc=0 || _f11_rc=$?
if [[ "${_f11_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f11_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f11_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  echo "${_f11_out}" | grep -v '^PROBLEM ' | tail -5
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F12 — the test stage's wiring (docs/Terraform-tests.md §5, §6, §9.6).
#
# One test job whose environment is the row's, empty meaning none; the gates
# after every reporting step, as in the environment job (a gate exits 1 and
# would skip the upload that explains the failure); the summary out of the
# conclusion's needs, since a reporting job must never redden a run; and the
# steps the summary reads by id.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F12 - the test job and the tests summary are wired as the spec says${NC}"
echo -e "${BLUE}========================================${NC}"
_f12_out=$(python3 - "${_workflow}" <<'PYEOF'
import sys, yaml

jobs = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["jobs"]
problems = []
test = jobs.get("terraform-test", {})
if test.get("name") != "${{ matrix.test.name }}":
    problems.append(f"the test job's name is {test.get('name')!r}, expected the row's name")
if test.get("environment") != {"name": "${{ matrix.test.github-environment }}", "deployment": False}:
    problems.append(f"the test job's environment is {test.get('environment')}")
if test.get("permissions") != {"contents": "read", "id-token": "write"}:
    problems.append(f"the test job's permissions are {test.get('permissions')}")
if set(test.get("needs", [])) != {"create-matrix", "seed-pr-comments"}:
    problems.append(f"the test job needs {test.get('needs')}")
condition = " ".join(str(test.get("if", "")).split())
for clause in ("!cancelled()", "needs.create-matrix.result == 'success'", "needs.create-matrix.outputs.tests-active == 'true'"):
    if clause not in condition:
        problems.append(f"the test job's if lacks {clause}")
if "seed-pr-comments.result" in condition:
    problems.append("the test job's if tests the seed's result")
steps = test.get("steps", [])
ids = [step.get("id") for step in steps]
for needed in ("verify-credentials", "provider-versions", "init", "test", "upload-test-output", "capture-metadata"):
    if needed not in ids:
        problems.append(f"the test job has no step with id '{needed}', which the summary reads")
# An environment lane's TF_VAR_ secrets arrive upper-cased; the export adds the lower-cased copies.
exports = [step for step in steps if str(step.get("uses", "")).split("@")[0].endswith("/export-env-vars")]
if len(exports) != 1 or "fromJSON('[\"TF_VAR_\"]')" not in str(exports[0].get("with", {}).get("lower-case-copies-for-prefixes-json", "")):
    problems.append("the lane export does not add lower-case copies of an environment lane's TF_VAR_ secrets")
# The lock check runs before init, so only lock-only mode can work, and after the plugin cache is
# restored so a warm cache spares the download (§5.2 step 7).
if "provider-versions" in ids and "init" in ids:
    check = steps[ids.index("provider-versions")]
    if check.get("with", {}).get("lock-only") != "true":
        problems.append("the lock check does not run lock-only, and nothing is initialised when it runs")
    restore = [index for index, step in enumerate(steps) if str(step.get("uses", "")).startswith("actions/cache@")]
    if not restore or not restore[0] < ids.index("provider-versions") < ids.index("init"):
        problems.append("the lock check does not run between the plugin cache restore and init")
gates = [index for index, step in enumerate(steps) if str(step.get("name", "")).startswith("🧐 Validation outcome")]
reporting = [ids.index(name) for name in ("test", "upload-test-output", "capture-metadata") if name in ids]
if len(gates) != 3 or not reporting or min(gates) < max(reporting):
    problems.append("the test job's three gates do not all come after the test, the upload and the capture")
for index in gates:
    if steps[index].get("continue-on-error") != "${{ fromJSON(matrix.test.allow-failing-terraform-tests) }}":
        problems.append(f"the gate '{steps[index].get('name')}' ignores allow-failing-terraform-tests")
if "terraform-test-summary" in jobs.get("conclusion", {}).get("needs", []):
    problems.append("the tests summary is in the conclusion's needs")
summary = jobs.get("terraform-test-summary", {})
if set(summary.get("needs", [])) != {"create-matrix", "terraform-test"}:
    problems.append(f"the tests summary needs {summary.get('needs')}")
if not str(summary.get("if", "")).strip().startswith("always()"):
    problems.append("the tests summary does not run always()")
for step in summary.get("steps", []):
    if step.get("continue-on-error") is not True:
        problems.append(f"the tests summary's step '{step.get('name')}' can fail the job")
# Every output create-matrix exposes must be one the create-tf-vars-matrix action declares; an
# undeclared one reads as an empty string, and an empty tests-active silently skips the stage.
import os, re
action = yaml.safe_load(open(os.path.join(os.path.dirname(sys.argv[1]), "..", "..", "create-tf-vars-matrix", "action.yml"),
                             encoding="utf-8"))
declared = set((action.get("outputs") or {}))
for name, value in (jobs["create-matrix"].get("outputs") or {}).items():
    match = re.fullmatch(r"\$\{\{ steps\.create-matrix\.outputs\.([a-z0-9-]+) \}\}", str(value))
    if match is None or match.group(1) not in declared:
        problems.append(f"create-matrix's output '{name}' reads an output create-tf-vars-matrix does not declare")
print("checked the test job's name, environment, permissions, needs, lock check, gates and step ids, the tests summary, and create-matrix's outputs")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f12_rc=0 || _f12_rc=$?
if [[ "${_f12_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f12_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f12_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F13 — the operation gates read the granted goals (docs/Decision-engine.md D10,
# docs/Dispatch-and-triggers.md D11).
#
# A dispatch's goal cap only works if no gate reads the raw goals: a step gated
# on contains(matrix.vars.goals, 'all') would plan or apply what the cap removed.
# The raw list stays for the renderers (goals-json). The apply and destroy gates
# keep their event and branch clauses as defence in depth, and destroy never
# accepts schedule. The trigger-events-yml input reaches the engine through
# toJSON(inputs), with schedule absent from its default.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F13 - the operation gates read goals-granted, with their event clauses kept${NC}"
echo -e "${BLUE}========================================${NC}"
_f13_out=$(python3 - "${_workflow}" <<'PYEOF'
import re, sys, yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs = workflow["jobs"]
problems = []
gated = []
seen = []
for job_id, job in jobs.items():
    job_steps = job.get("steps") or []
    # The stage jobs share one step list through a YAML anchor: check it once.
    if any(job_steps is other for other in seen):
        continue
    seen.append(job_steps)
    for step in job_steps:
        condition = " ".join(str(step.get("if", "")).split())
        label = f"{job_id}/{step.get('id') or step.get('name')}"
        if re.search(r"matrix\.vars\.goals\b(?!-)", condition):
            problems.append(f"the step '{label}' gates on the raw goals")
        if "matrix.vars.goals-granted" in condition:
            gated.append(label)
        for key, value in (step.get("with") or {}).items():
            if re.search(r"matrix\.vars\.goals\b(?!-)", str(value)) and key != "goals-json":
                problems.append(f"the step '{label}' passes the raw goals as '{key}'")
steps = {step.get("id"): step for step in jobs["terraform-ci-cd"]["steps"] if step.get("id")}
for goal, step_id in (("init", "init"), ("format", "fmt"), ("validate", "validate"), ("lint", "lint"),
                      ("plan", "plan"), ("apply", "apply"), ("destroy-plan", "destroy-plan"), ("destroy", "destroy")):
    condition = " ".join(str(steps.get(step_id, {}).get("if", "")).split())
    if f"contains(matrix.vars.goals-granted, '{goal}')" not in condition:
        problems.append(f"the step '{step_id}' does not gate on the granted goal '{goal}'")
for step_id, events in (("apply", ("push", "workflow_dispatch", "schedule")), ("destroy", ("push", "workflow_dispatch"))):
    condition = " ".join(str(steps[step_id].get("if", "")).split())
    for clause in [f"github.event_name == '{event}'" for event in events] + [
            "matrix.vars.caller-repo-is-on-default-branch == 'true'", "github.event.action != 'closed'",
            "github.event.action != 'converted_to_draft'", "github.base_ref == matrix.vars.caller-repo-default-branch"]:
        if clause not in condition:
            problems.append(f"the step '{step_id}' lost its defence-in-depth clause {clause}")
if "github.event_name == 'schedule'" in " ".join(str(steps["destroy"].get("if", "")).split()):
    problems.append("the destroy step accepts schedule")
inputs = workflow[True]["workflow_call"]["inputs"]
trigger = inputs.get("trigger-events-yml", {})
if trigger.get("type") != "string" or yaml.safe_load(str(trigger.get("default"))) != ["pull_request", "push",
                                                                                         "workflow_dispatch"]:
    problems.append(f"the trigger-events-yml input is {trigger}")
create = [step for step in jobs["create-matrix"]["steps"] if "create-tf-vars-matrix" in str(step.get("uses", ""))]
if len(create) != 1 or create[0].get("with", {}).get("inputs-json") != "${{ toJSON(inputs) }}":
    problems.append("create-matrix does not hand the engine toJSON(inputs)")
print(f"checked {len(gated)} gates on goals-granted, the apply and destroy clauses, and the trigger-events-yml input")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f13_rc=0 || _f13_rc=$?
if [[ "${_f13_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f13_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f13_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F14 — the auto-merge evidence and pins are wired (docs/Auto-merge.md D1, D2,
# D3, D9, D10, D13).
#
# Each piece works only when the workflow hands it over: the parse steps count
# from the JSON plan only when given its file, the merger pins nothing without
# the head and merge SHAs, and the evaluator names tolerated tests only from
# downloaded test metadata. The auto-merge job runs for the default branch and
# the same repository only, and no step uploads the JSON plan, which holds
# sensitive values in plain text.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F14 - the auto-merge evidence and pins are wired${NC}"
echo -e "${BLUE}========================================${NC}"
_f14_out=$(python3 - "${_workflow}" <<'PYEOF'
import sys, yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs = workflow["jobs"]
problems = []
steps = {step.get("id"): step for step in jobs["terraform-ci-cd"]["steps"] if step.get("id")}
for parse, plan in (("parse-plan", "plan"), ("parse-destroy-plan", "destroy-plan")):
    given = (steps.get(parse, {}).get("with") or {}).get("plan-json-file")
    if given != f"${{{{ steps.{plan}.outputs.json-output-file }}}}":
        problems.append(f"the step '{parse}' is given the JSON plan as {given!r}")
for job_id, job in jobs.items():
    for step in job.get("steps", []):
        if "upload-artifact" in str(step.get("uses", "")) and "json-output-file" in str(step.get("with", {})):
            problems.append(f"the job '{job_id}' uploads the JSON plan")
automerge = jobs["automerge"]
condition = " ".join(str(automerge.get("if", "")).split())
for clause in ("github.base_ref == github.event.repository.default_branch",
               "github.event.pull_request.head.repo.full_name == github.repository"):
    if clause not in condition:
        problems.append(f"the automerge job lacks the condition {clause}")
names = [step.get("id") or step.get("name") for step in automerge["steps"]]
by_uses = {str(step.get("uses", "")).split("@")[0].rsplit("/", 1)[-1]: step for step in automerge["steps"]}
downloads = [index for index, step in enumerate(automerge["steps"])
             if "download-artifact" in str(step.get("uses", ""))
             and (step.get("with") or {}).get("pattern") == "terraform-test-meta-*"
             and (step.get("with") or {}).get("merge-multiple") is True]
evaluator = names.index("evaluate-automerge")
if not downloads or downloads[0] > evaluator:
    problems.append("the automerge job does not download the test metadata before evaluating")
pattern = (by_uses["evaluate-automerge-eligibility"].get("with") or {}).get("test-metadata-files-pattern")
if pattern != "terraform-test-meta-*.json":
    problems.append(f"the evaluator reads the test metadata as {pattern!r}")
merger = by_uses["auto-merge-pr"].get("with") or {}
for key, value in (("head-sha", "${{ github.event.pull_request.head.sha }}"), ("merge-sha", "${{ github.sha }}")):
    if merger.get(key) != value:
        problems.append(f"the merger is given '{key}' as {merger.get(key)!r}")
print("checked the JSON plan wiring, the auto-merge scope, the test metadata and the merge pins")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f14_rc=0 || _f14_rc=$?
if [[ "${_f14_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f14_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f14_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F15 — the environments' three stage jobs are one job written three times
# (docs/Environment-ordering.md §4.2, §10; P2, P3, P4, P7, P13, P14).
#
# The anchor carries only the step list, so every other field is a copy that
# can drift: a stage job that silently loses its environment, concurrency or
# permissions deploys without them, and one named anything but "Terraform"
# breaks the aggregator's job-link lookup. So the three must differ only in
# if:, needs: and the matrix source, and share the steps as one list, which
# PyYAML loads as one object only when stages 2 and 3 alias stage 1's. That is
# also what lets F2, F5, F5c, F13 and F14 read stage 1's steps for all three.
# Each guard is exactly !cancelled(), the builder's success, every earlier
# stage succeeded or skipped, and its own count: no !failure(), which a failed
# seed would trip, and no stage without its count, whose empty matrix fails
# the run with no record. Every job after the environments waits for all
# three, three readers get their results, and no merge key appears, which
# PyYAML resolves silently and GitHub rejects.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F15 - the three stage jobs differ only in guard, needs and matrix, and all consumers wait for them${NC}"
echo -e "${BLUE}========================================${NC}"
_f15_out=$(python3 - "${_workflow}" <<'PYEOF'
import sys, yaml

text = open(sys.argv[1], encoding="utf-8").read()
jobs = yaml.safe_load(text)["jobs"]
problems = []
stages = ["terraform-ci-cd", "terraform-ci-cd-2", "terraform-ci-cd-3"]
missing = [job_id for job_id in stages if job_id not in jobs]
if missing:
    print(f"PROBLEM the stage job(s) {missing} do not exist")
    sys.exit(1)

named = sorted(job_id for job_id, job in jobs.items() if job.get("name") == "Terraform")
if named != stages:
    problems.append(f"the jobs named 'Terraform' are {named}, expected exactly the three stage jobs")
first = jobs[stages[0]]
for stage, job_id in enumerate(stages, start=1):
    job = jobs[job_id]
    if job.get("name") != "Terraform":
        problems.append(f"{job_id} is named {job.get('name')!r}, not 'Terraform'")
    if set(job) != set(first):
        problems.append(f"{job_id} has the fields {sorted(job)}, stage 1 has {sorted(first)}")
    for key in sorted(set(job) & set(first) - {"if", "needs"}):
        mine, theirs = job[key], first[key]
        if key == "strategy":
            mine, theirs = dict(mine or {}), dict(theirs or {})
            source = mine.pop("matrix", None)
            theirs.pop("matrix", None)
            expected = f"${{{{ fromJSON(needs.create-matrix.outputs.matrix-stage-{stage}-json) }}}}"
            if source != expected:
                problems.append(f"{job_id}'s matrix is {source!r}, expected {expected!r}")
        if mine != theirs:
            problems.append(f"{job_id}'s {key} differs from stage 1's")
    if job.get("steps") is not first.get("steps"):
        problems.append(f"{job_id} does not share stage 1's step list through the anchor")
    earlier = stages[:stage - 1]
    needs = job.get("needs") or []
    if sorted(needs) != sorted(["create-matrix", "seed-pr-comments"] + earlier):
        problems.append(f"{job_id} needs {needs}, expected create-matrix, seed-pr-comments and {earlier or 'no stage'}")
    condition = " ".join(str(job.get("if", "")).split())
    clauses = (["!cancelled()", "needs.create-matrix.result == 'success'"]
               + [f"(needs.{other}.result == 'success' || needs.{other}.result == 'skipped')" for other in earlier]
               + [f"needs.create-matrix.outputs.stage-{stage}-count != '0'"])
    for clause in clauses:
        if clause not in condition:
            problems.append(f"{job_id}'s if lacks {clause}")
    if "failure()" in condition:
        problems.append(f"{job_id}'s if uses failure(), which is transitive over every ancestor, the seed included")
    if condition != " && ".join(clauses):
        problems.append(f"{job_id}'s if is {condition!r}, expected {' && '.join(clauses)!r}")

for consumer in ("conclusion", "pr-comment-aggregator", "run-summary", "automerge"):
    needs = (jobs.get(consumer) or {}).get("needs") or []
    for job_id in stages:
        if job_id not in needs:
            problems.append(f"{consumer} does not need {job_id}")

results = ('{"1": "${{ needs.terraform-ci-cd.result }}", "2": "${{ needs.terraform-ci-cd-2.result }}", '
           '"3": "${{ needs.terraform-ci-cd-3.result }}"}')
for consumer, action in (("pr-comment-aggregator", "aggregate-validation-summaries"),
                         ("run-summary", "create-run-summary"), ("automerge", "evaluate-automerge-eligibility")):
    given = [(step.get("with") or {}).get("stage-results-json") for step in (jobs.get(consumer) or {}).get("steps", [])
             if f"/{action}@" in str(step.get("uses", ""))]
    if given != [results]:
        problems.append(f"{consumer} passes {action} the stage results as {given}, expected [{results!r}]")


def merge_keys(node, found):
    if isinstance(node, yaml.MappingNode):
        for key, value in node.value:
            if key.tag == "tag:yaml.org,2002:merge":
                found.add(key.start_mark.line + 1)
            merge_keys(value, found)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            merge_keys(item, found)
    return found


lines = sorted(merge_keys(yaml.compose(text, Loader=yaml.SafeLoader), set()))
if lines:
    problems.append(f"merge key(s) on line(s) {lines}: GitHub does not support them")

print("checked the three stage jobs' names, fields, steps, matrices, needs and guards, their consumers' needs, "
      "the stage results and merge keys")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f15_rc=0 || _f15_rc=$?
if [[ "${_f15_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f15_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f15_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F16 — no run: block pastes an input, a matrix value or a step output into its
# script text.
#
# GitHub substitutes an expression into the script before bash parses it, so a
# value is code: a quote in a path or an environment name ends the string it
# sits in, and the rest runs as shell. A value read from the step's env: is data
# whatever it holds. The one place an expression may stand in a script is a
# heredoc capture, which F9 holds to JSON under a unique quoted delimiter; the
# runner's own github.action_path and a step's fixed-word outcome are out of
# scope. Only small scalars go to env:, which reaches every fork's envp;
# anything large is captured the F9 way (docs/Action-implementation-guide.md,
# "Step shim pattern — JSON inputs").
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F16 - run blocks read inputs, matrix values and step outputs from env, not pasted${NC}"
echo -e "${BLUE}========================================${NC}"
_f16_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import glob, re, sys, yaml

def load(path):
    with open(path, encoding='utf-8') as fh:
        return yaml.safe_load(fh) or {}

def run_steps(doc):
    steps, seen = list(((doc.get('runs') or {}).get('steps')) or []), []
    for job in (doc.get('jobs') or {}).values():
        job_steps = job.get('steps') or []
        # The stage jobs share one step list through a YAML anchor: check it once.
        if any(job_steps is other for other in seen):
            continue
        seen.append(job_steps)
        steps += job_steps
    return [step for step in steps if isinstance(step.get('run'), str)]

# F9's heredoc, so a capture is exempt exactly when F9 judges it.
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(.*?)\n[ \t]*\2[ \t]*(?:\n|$)", re.S)
EXPR = re.compile(r"\$\{\{\s*(.*?)\s*\}\}", re.S)
# The context must start the reference: needs.create-matrix.outputs is not the matrix context.
PASTED = re.compile(r"(?<![\w.-])(?:inputs\.|matrix\.|steps\.[\w-]+\.outputs\b)")
problems, checked = [], 0
files = sorted(glob.glob('*/action.yml') + glob.glob('*/action.yaml') + glob.glob('.github/workflows/*.y*ml'))
for path in files:
    for step in run_steps(load(path)):
        checked += 1
        script = HEREDOC.sub('\n', step['run'])
        for expression in EXPR.findall(script):
            if PASTED.search(expression):
                problems.append(f"{path} :: step '{step.get('id') or step.get('name')}' pastes "
                                f"${{{{ {expression} }}}} into its script; read a small scalar from the step's "
                                "env:, capture anything else through a heredoc (F9)")
print(f"checked {checked} run block(s) in {len(files)} file(s)")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f16_rc=0 || _f16_rc=$?
if [[ "${_f16_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f16_out}" | head -n1): nothing pasted outside a heredoc capture"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f16_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F17 — the engine's mutation gate runs once in CI, in every shard, and gates.
#
# The suite jobs leave the gate out (ENGINE_MUTATION=shards) because the
# engine-mutation shards run it; that is safe only while the shards cover
# 1..N with N the same in the matrix, the command and the name, the merge job
# needs them and applies the gate, and tests-conclusion requires the merge
# (docs/Testing-in-ci.md §14). A shard left out would leave its mutants unjudged
# with every check green, which the merge refuses; a merge nothing requires
# would let a red gate merge.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F17 - the engine mutation gate runs once, in every shard, and gates tests-conclusion${NC}"
echo -e "${BLUE}========================================${NC}"
_f17_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import re, sys, yaml

with open('.github/workflows/action-tests.yml', encoding='utf-8') as fh:
    jobs = yaml.safe_load(fh)['jobs']
problems = []

def steps(job):
    return jobs.get(job, {}).get('steps') or []

def needs(job):
    value = jobs.get(job, {}).get('needs') or []
    return [value] if isinstance(value, str) else value

# Which jobs run the engine suite, and whether each leaves the gate to the shards.
skipping = []
for name, job in jobs.items():
    for step in steps(name):
        run = step.get('run') or ''
        if 'run_all_tests.sh' in run and ('engine/' in run or 'ACTION_NAME' in run):
            if (step.get('env') or {}).get('ENGINE_MUTATION') == 'shards':
                skipping.append(name)
            else:
                problems.append(f"job '{name}' runs the engine suite with its mutation gate; it runs once, in engine-mutation")
if not skipping:
    problems.append("no job runs the engine suite")

shard = jobs.get('engine-mutation')
if shard is None:
    problems.append("the engine-mutation job is missing")
else:
    listed = shard.get('strategy', {}).get('matrix', {}).get('shard')
    total = len(listed or [])
    if listed != list(range(1, total + 1)) or total < 1:
        problems.append(f"engine-mutation's shards must be 1..N, not {listed}")
    commands = [step['run'] for step in steps('engine-mutation') if '--shard' in (step.get('run') or '')]
    if len(commands) != 1 or f'/{total}"' not in commands[0]:
        problems.append(f"engine-mutation must run exactly one '--shard \"${{SHARD}}/{total}\"'")
    if f'/{total}' not in shard.get('name', ''):
        problems.append(f"engine-mutation's name must say /{total}")
    uploads = [step for step in steps('engine-mutation') if str(step.get('uses', '')).startswith('actions/upload-artifact@')]
    if len(uploads) != 1 or uploads[0].get('with', {}).get('if-no-files-found') != 'error':
        problems.append("engine-mutation must upload its result once, failing when the file is missing")

gate = jobs.get('engine-mutation-gate')
if gate is None:
    problems.append("the engine-mutation-gate job is missing")
else:
    if 'engine-mutation' not in needs('engine-mutation-gate'):
        problems.append("engine-mutation-gate must need engine-mutation")
    if '!cancelled()' not in str(gate.get('if', '')):
        problems.append("engine-mutation-gate must run when a shard fails (!cancelled()), to fail the gate")
    runs = ' '.join(step.get('run') or '' for step in steps('engine-mutation-gate'))
    if '--merge' not in runs or 'needs.engine-mutation.result' not in str(gate):
        problems.append("engine-mutation-gate must check the shards' result and apply the gate with --merge")
    # It reports like a suite, so the PR comment's totals cannot read green over a red gate.
    reports = [step for step in steps('engine-mutation-gate')
               if str(step.get('uses', '')).startswith('actions/upload-artifact@')
               and str(step.get('with', {}).get('name', '')).startswith('test-result-')]
    if len(reports) != 1 or reports[0].get('if') != 'always()':
        problems.append("engine-mutation-gate must upload a test-result-* artifact, always()")
    if 'engine-mutation-gate' not in needs('summary'):
        problems.append("summary must need engine-mutation-gate, so the PR comment includes the gate")

conclusion = jobs.get('tests-conclusion', {})
if 'engine-mutation-gate' not in needs('tests-conclusion'):
    problems.append("tests-conclusion must need engine-mutation-gate")
if 'needs.engine-mutation-gate.result' not in str(conclusion):
    problems.append("tests-conclusion must fail unless engine-mutation-gate succeeded")

print(f"{len(skipping)} suite job(s) leave the gate to {len((shard or {}).get('strategy', {}).get('matrix', {}).get('shard') or [])} shard(s)")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f17_rc=0 || _f17_rc=$?
if [[ "${_f17_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f17_out}" | head -n1), merged and required"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f17_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F18 — no test suite writes to a fixed path under /tmp.
#
# Suites run side by side (a local parallel run, two checkouts on one machine),
# and a fixed file is shared by every run that uses it: one suite then reads
# another's output. Each suite writes to a file of its own from mktemp
# (docs/Action-implementation-guide.md, the test runner template).
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F18 - no test suite writes to a fixed path under /tmp${NC}"
echo -e "${BLUE}========================================${NC}"
_f18_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import glob, re, sys

# A redirect or tee into /tmp/<name>, the name written out.
FIXED = re.compile(r"(?:>>?|\btee(?:\s+-a)?)\s*['\"]?/tmp/[\w.-]")
files = sorted(glob.glob('*/run_*.sh') + glob.glob('.github/scripts/test-*.sh'))
problems = []
for path in files:
    with open(path, encoding='utf-8') as fh:
        for number, line in enumerate(fh, 1):
            if not line.lstrip().startswith('#') and FIXED.search(line):
                problems.append(f"{path}:{number} writes to a fixed /tmp path: {line.strip()[:100]}")
print(f"checked {len(files)} suite script(s)")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f18_rc=0 || _f18_rc=$?
if [[ "${_f18_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f18_out}" | head -n1): every output goes to a file of its own"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f18_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F19 — no workflow or action file holds a non-breaking space.
#
# U+00A0 looks like a space and is not one: inside `${{ … }}` it is part of the
# expression, which actionlint rejects, and in YAML it is not indentation. One
# sat in the module workflow's secret expressions for two years, pasted from a
# document.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F19 - no workflow or action file holds a non-breaking space${NC}"
echo -e "${BLUE}========================================${NC}"
_f19_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import glob, sys

files = sorted(glob.glob('*/action.y*ml') + glob.glob('.github/workflows/*.y*ml'))
problems = []
for path in files:
    with open(path, encoding='utf-8') as fh:
        for number, line in enumerate(fh, 1):
            if ' ' in line:
                problems.append(f"{path}:{number} holds U+00A0 (a non-breaking space); replace it with a space")
print(f"checked {len(files)} file(s)")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f19_rc=0 || _f19_rc=$?
if [[ "${_f19_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f19_out}" | head -n1): no non-breaking space"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f19_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F20 — the module workflow's test jobs and seed job are the project workflow's, step for step.
#
# docs/Module-ci.md D2: one test stage for both kinds of repository, written out in each workflow
# and held together here. Everything but `needs` and `if` must be equal: the name, the runner, the
# timeout, the permissions, the environment, the strategy, the concurrency and every step. The
# module test job waits for the docs job and skips when it pushed; the module summary job runs on
# every event with test files, since a module tests on dispatches and schedules too. The seed job
# posts a refused Dependabot pull request's admission head in both (docs/Dependabot-admission.md
# D21); the module's runs on Dependabot's pull requests alone.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F20 - the module workflow's test and seed jobs are the project workflow's${NC}"
echo -e "${BLUE}========================================${NC}"
_f20_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import sys, yaml

def jobs(path):
    with open(path, encoding='utf-8') as fh:
        return yaml.safe_load(fh)['jobs']

project = jobs('.github/workflows/terraform-ci-cd-default.yml')
module = jobs('.github/workflows/terraform-module-ci.yaml')
problems = []
for name in ('terraform-test', 'terraform-test-summary', 'seed-pr-comments'):
    if name not in module:
        problems.append(f"the module workflow has no job '{name}'")
        continue
    ours = {k: v for k, v in module[name].items() if k not in ('needs', 'if')}
    theirs = {k: v for k, v in project[name].items() if k not in ('needs', 'if')}
    for key in sorted(set(ours) | set(theirs)):
        if ours.get(key) != theirs.get(key):
            problems.append(f"job '{name}': '{key}' differs from the project workflow's")
    if len(module[name].get('steps', [])) != len(project[name].get('steps', [])):
        problems.append(f"job '{name}': {len(module[name].get('steps', []))} steps, the project workflow has "
                        f"{len(project[name].get('steps', []))}")

# The module's seed posts the admission head alone, which only a pull request Dependabot opened can hold
# (docs/Dependabot-admission.md D21): the project's condition and that one clause more.
seed = module.get('seed-pr-comments', {})
if seed.get('needs') != 'create-matrix':
    problems.append(f"the module seed job must need create-matrix, not {seed.get('needs')}")
seed_if = ' '.join(str(seed.get('if', '')).split())
project_if = ' '.join(str(project['seed-pr-comments'].get('if', '')).split())
if seed_if != f"{project_if} && github.event.pull_request.user.login == 'dependabot[bot]'":
    problems.append(f"the module seed job's if is not the project's for Dependabot's pull requests: {seed_if!r}")

test = module.get('terraform-test', {})
if sorted(test.get('needs', [])) != ['create-matrix', 'generate-docs']:
    problems.append(f"the module test job must need create-matrix and generate-docs, not {test.get('needs')}")
condition = ' '.join(str(test.get('if', '')).split())
for part in ("!cancelled()", "needs.create-matrix.result == 'success'",
             "needs.create-matrix.outputs.tests-active == 'true'", "needs.generate-docs.outputs.pushed != 'true'"):
    if part not in condition:
        problems.append(f"the module test job's if lacks {part!r}")
summary = module.get('terraform-test-summary', {})
if sorted(summary.get('needs', [])) != ['create-matrix', 'generate-docs', 'terraform-test', 'validate']:
    problems.append(f"the module summary job must need create-matrix, generate-docs, validate and terraform-test, not {summary.get('needs')}")
condition = ' '.join(str(summary.get('if', '')).split())
for part in ("always()", "needs.create-matrix.result == 'success'", "inputs.terraform-test-enabled == true",
             "needs.create-matrix.outputs.tests-count != '0' || github.event_name == 'pull_request'",
             "needs.generate-docs.outputs.pushed != 'true'"):
    if part not in condition:
        problems.append(f"the module summary job's if lacks {part!r}")
if "github.event_name == 'push'" in condition:
    problems.append("the module summary job must run on every event with test files, not only pull_request and push")

print(f"compared {sum(len(module.get(n, {}).get('steps', [])) for n in ('terraform-test', 'terraform-test-summary'))} step(s)")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f20_rc=0 || _f20_rc=$?
if [[ "${_f20_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f20_out}" | head -n1), equal but for needs and if"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f20_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F21 — the module workflow's conclusion judges named results (docs/Module-ci.md §8).
#
# The one required check: it needs the jobs that decide (never the reporting ones), reads each
# by name with the engine's outputs, and states its verdict; the module test job reads the
# engine's matrix, and the docs job's push gates validation and tests.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F21 - the module conclusion judges named results${NC}"
echo -e "${BLUE}========================================${NC}"
_f21_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import sys, yaml

with open('.github/workflows/terraform-module-ci.yaml', encoding='utf-8') as fh:
    workflow = yaml.safe_load(fh)
jobs = workflow['jobs']
inputs = workflow[True]['workflow_call']['inputs'] if True in workflow else workflow['on']['workflow_call']['inputs']
problems = []
conclusion = jobs.get('conclusion', {})
if conclusion.get('name') != 'Terraform conclusion' or conclusion.get('if') != 'always()':
    problems.append("the conclusion must be named 'Terraform conclusion' and run always()")
if conclusion.get('needs') != ['create-matrix', 'generate-docs', 'validate', 'terraform-test']:
    problems.append(f"the conclusion must need create-matrix, generate-docs, validate and terraform-test, not {conclusion.get('needs')}")
env = (conclusion.get('steps') or [{}])[0].get('env', {})
expected = {
    'CREATE_MATRIX_RESULT': '${{ needs.create-matrix.result }}', 'DOCS_RESULT': '${{ needs.generate-docs.result }}',
    'DOCS_PUSHED': '${{ needs.generate-docs.outputs.pushed }}', 'VALIDATE_RESULT': '${{ needs.validate.result }}',
    'TESTS_ACTIVE': '${{ needs.create-matrix.outputs.tests-active }}',
    'TESTS_COUNT': '${{ needs.create-matrix.outputs.tests-count }}',
    'TESTS_REQUIRED_MISSING': '${{ needs.create-matrix.outputs.tests-required-missing }}',
    'TESTS_RESULT': '${{ needs.terraform-test.result }}',
}
for key, value in expected.items():
    if env.get(key) != value:
        problems.append(f"the conclusion's env {key} must be {value}")
run = (conclusion.get('steps') or [{}])[0].get('run', '')
for needle in ('GITHUB_STEP_SUMMARY', '::notice title=Terraform conclusion::', '::error title=Terraform conclusion::', 'exit 1'):
    if needle not in run:
        problems.append(f"the conclusion must write {needle!r}")
if 'contains(needs.' in str(conclusion):
    problems.append("the conclusion must read named results, not contains(needs.*.result, …)")
create = jobs.get('create-matrix', {})
step = next((s for s in create.get('steps', []) if 'create-tf-vars-matrix' in str(s.get('uses'))), {})
if step.get('with', {}).get('mode') != 'module':
    problems.append("create-matrix must run create-tf-vars-matrix with mode: module")
for output in ('tests-matrix-json', 'tests-count', 'tests-active', 'tests-required-missing'):
    if output not in create.get('outputs', {}):
        problems.append(f"create-matrix must publish {output}")
validate = jobs.get('validate', {})
if "needs.generate-docs.outputs.pushed != 'true'" not in str(validate.get('if', '')):
    problems.append("validation must skip when the docs job pushed a commit")
for name in ('terraform-test-enabled', 'terraform-test-required', 'allow-failing-terraform-tests',
             'terraform-test-runs-on', 'terraform-test-timeout-minutes', 'terraform-test-lanes-yml',
             'terraform-test-exclude-paths-yml', 'runs-on', 'add-pr-comment', 'cache-terraform-modules'):
    if name not in inputs:
        problems.append(f"the module workflow must declare the input {name}")
print(f"checked {len(expected)} named results")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f21_rc=0 || _f21_rc=$?
if [[ "${_f21_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f21_out}" | head -n1), the wiring holds"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f21_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F22 — the documentation index lists every document, and only documents that exist.
#
# docs/README.md is where a reader starts; a document missing from it is one
# nobody finds, and a row for a deleted document is a dead link.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F22 - docs/README.md indexes every document${NC}"
echo -e "${BLUE}========================================${NC}"
_f22_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import glob, os, re, sys

with open('docs/README.md', encoding='utf-8') as fh:
    index = fh.read()
targets = set(re.findall(r'\]\(([^)#]+)(?:#[^)]*)?\)', index))
docs = sorted(os.path.basename(path) for path in glob.glob('docs/*.md') if not path.endswith('/README.md'))
problems = [f"docs/{doc} is not linked from docs/README.md; add a row under its kind" for doc in docs if doc not in targets]
problems += [f"docs/README.md links {target}, which does not exist" for target in sorted(targets)
             if not os.path.exists(os.path.normpath(os.path.join('docs', target)))]
print(f"checked {len(docs)} document(s) and {len(targets)} link(s)")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f22_rc=0 || _f22_rc=$?
if [[ "${_f22_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f22_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f22_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F23 — every step script ends with an exit, and never returns at the top level.
#
# The shim sources the script in a `bash -eo pipefail` shell, so `exit` ends
# the step with main's code and nothing after the `source` line runs
# (docs/Action-implementation-guide.md, "Why only exit"). A top-level
# `return` behind a "sourced or executed" test is a second path that behaves
# the same only while every shim stays one line long; six scripts carried it.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F23 - every step script ends with an exit${NC}"
echo -e "${BLUE}========================================${NC}"
_f23_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import glob, re, sys

files = sorted(glob.glob('*/step_*.sh'))
problems = []
for path in files:
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().splitlines()
    code = [line for line in lines if line.strip() and not line.lstrip().startswith('#')]
    if not code or not re.match(r'exit\b', code[-1]):
        problems.append(f"{path} does not end with an exit line (ends with: {code[-1] if code else 'nothing'})")
    for number, line in enumerate(lines, 1):
        if re.match(r'return\b', line):
            problems.append(f"{path}:{number} returns at the top level; end with exit instead")
        if 'BASH_SOURCE[0]}" != "${0}"' in line:
            problems.append(f"{path}:{number} tests whether it is sourced; the shim always sources it, so end with exit")
print(f"checked {len(files)} step script(s)")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f23_rc=0 || _f23_rc=$?
if [[ "${_f23_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f23_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f23_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F24 — the module workflows name the App access a repository lacks.
#
# The App's variable and secret are the organisation's; a repository without access to them saw
# only the token action's "client-id must be set". Before each ORG_TF_CICD token step a check,
# under the same condition, names the variable or secret missing; the token step may fail, and the
# step after it explains that failure (installation or key) and fails the job. The check's run
# block is executed here for every combination, from the workflow text itself.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F24 - the module workflows name the App access a repository lacks${NC}"
echo -e "${BLUE}========================================${NC}"
_f24_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import os, re, subprocess, sys, yaml

WORKFLOWS = [".github/workflows/terraform-module-ci.yaml", ".github/workflows/terraform-module-release.yaml"]
CHECK, TOKEN, EXPLAIN = "🔐 Check the App's variable and secret", "🔑 Create GitHub App token", "🔐 Explain the failed App token"
problems, checked = [], 0

def run(script, env):
    done = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], env={"PATH": os.environ["PATH"], **env},
                          capture_output=True, text=True)
    return done.returncode, done.stdout

for path in WORKFLOWS:
    with open(path, encoding="utf-8") as fh:
        jobs = yaml.safe_load(fh)["jobs"]
    for job_name, job in jobs.items():
        steps = job.get("steps", [])
        names = [step.get("name") for step in steps]
        for index, step in enumerate(steps):
            with_ = step.get("with") or {}
            if not str(step.get("uses", "")).startswith("actions/create-github-app-token@") \
                    or "ORG_TF_CICD_APP_ID" not in str(with_.get("client-id", "")):
                continue
            checked += 1
            where = f"{path} job {job_name}"
            before = steps[index - 1] if index > 0 else {}
            after = steps[index + 1] if index + 1 < len(steps) else {}
            if before.get("name") != CHECK:
                problems.append(f"{where}: the step before '{TOKEN}' is not '{CHECK}'")
                continue
            if str(before.get("if", "")).split() != str(step.get("if", "")).split():
                problems.append(f"{where}: '{CHECK}' does not run under the token step's condition")
            if step.get("continue-on-error") is not True:
                problems.append(f"{where}: '{TOKEN}' does not continue on error, so '{EXPLAIN}' never runs")
            if after.get("name") != EXPLAIN or after.get("if") != "steps.app-token.outcome == 'failure'":
                problems.append(f"{where}: the step after '{TOKEN}' is not '{EXPLAIN}' on its failure")
            env = before.get("env") or {}
            if env.get("APP_ID") != "${{ vars.ORG_TF_CICD_APP_ID }}" \
                    or env.get("PRIVATE_KEY_SET") != "${{ secrets.ORG_TF_CICD_APP_PRIVATE_KEY != '' }}":
                problems.append(f"{where}: '{CHECK}' does not read the variable and the secret's presence")
            cases = [("", "false", 1, ["ORG_TF_CICD_APP_ID", "ORG_TF_CICD_APP_PRIVATE_KEY"]),
                     ("123", "false", 1, ["ORG_TF_CICD_APP_PRIVATE_KEY"]),
                     ("", "true", 1, ["ORG_TF_CICD_APP_ID"]),
                     ("123", "true", 0, [])]
            for app_id, key_set, want_rc, want_named in cases:
                rc, out = run(before["run"], {"APP_ID": app_id, "PRIVATE_KEY_SET": key_set})
                errors = [line for line in out.splitlines() if line.startswith("::error")]
                named = sorted({m.group(1) for line in errors
                                for m in [re.search(r"cannot read the organisation (?:variable|secret) (\S+?)\.", line)] if m})
                if rc != want_rc or len(errors) != len(want_named) or named != sorted(want_named):
                    problems.append(f"{where}: with APP_ID='{app_id}' and the key {'set' if key_set == 'true' else 'unset'}, "
                                    f"the check exited {rc} with {len(errors)} error(s) naming {named}; expected {want_rc}, {sorted(want_named)}")
            # The docs job and the auto-merge job also run on an admitted Dependabot pull request, which reads
            # Dependabot secrets only, so their check names the Dependabot secret there (docs/Dependabot-admission.md
            # D22, docs/Module-auto-merge.md §6).
            if job_name in ("generate-docs", "automerge"):
                if env.get("ACTOR") != "${{ github.actor }}":
                    problems.append(f"{where}: '{CHECK}' does not read the actor")
                for key_set, want_rc in (("false", 1), ("true", 0)):
                    rc, out = run(before["run"], {"APP_ID": "123", "PRIVATE_KEY_SET": key_set, "ACTOR": "dependabot[bot]"})
                    errors = [line for line in out.splitlines() if line.startswith("::error")]
                    if rc != want_rc or len(errors) != want_rc or (errors and (
                            "cannot read the organisation secret ORG_TF_CICD_APP_PRIVATE_KEY." not in errors[0]
                            or "Dependabot secret" not in errors[0])):
                        problems.append(f"{where}: on a Dependabot run with the key {'set' if key_set == 'true' else 'unset'}, "
                                        f"the check exited {rc} with {errors}; expected {want_rc} and the Dependabot secret named")
            if after.get("name") == EXPLAIN:
                rc, out = run(after["run"], {})
                if rc != 1 or "ORG_TF_CICD_APP_ID" not in out or not out.startswith("::error"):
                    problems.append(f"{where}: '{EXPLAIN}' does not fail with an error naming the App")
if checked != 3:
    problems.append(f"expected 3 ORG_TF_CICD token steps (docs job, auto-merge job, release job), found {checked}")
print(f"checked {checked} token step(s), 4 cases each")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f24_rc=0 || _f24_rc=$?
if [[ "${_f24_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f24_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f24_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F25 — the Dependabot admission is wired as the spec says (docs/Dependabot-admission.md §10).
#
# Both workflows declare its two inputs with their defaults, check out the merge commit's parent for the
# change the engine judges, and fail the conclusion on a refused run before anything else is judged, so
# allow-failing never softens it (D19); the conclusion's run block is executed here on a refused run. The
# project workflow's environment init reads the lock only on a Dependabot run the admission judges (D10),
# and the module workflow validates a Dependabot pull request only once create-matrix admitted it (D16).
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F25 - the Dependabot admission's inputs, checkout, init lock and conclusions are wired${NC}"
echo -e "${BLUE}========================================${NC}"
_f25_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import os, subprocess, sys, yaml

PROJECT, MODULE = ".github/workflows/terraform-ci-cd-default.yml", ".github/workflows/terraform-module-ci.yaml"
LOCK = "${{ github.actor == 'dependabot[bot]' && inputs.dependabot-admission-enabled && 'readonly' || 'default' }}"
problems = []

def load(path):
    return yaml.safe_load(open(path, encoding="utf-8"))

def run(script, env):
    done = subprocess.run(["bash", "-c", script], env={"PATH": os.environ["PATH"], **env}, capture_output=True,
                          text=True)
    return done.returncode, done.stdout

for path, default in ((PROJECT, True), (MODULE, False)):
    workflow = load(path)
    inputs = workflow[True]["workflow_call"]["inputs"]
    switch, policy = inputs.get("dependabot-admission-enabled", {}), inputs.get("dependabot-admission-yml", {})
    if (switch.get("type"), switch.get("default")) != ("boolean", default):
        problems.append(f"{path}: dependabot-admission-enabled is not a boolean defaulting to {default}")
    if (policy.get("type"), policy.get("default")) != ("string", ""):
        problems.append(f"{path}: dependabot-admission-yml is not a string defaulting to ''")
    create = workflow["jobs"]["create-matrix"]
    checkouts = [step for step in create["steps"] if str(step.get("uses", "")).startswith("actions/checkout")]
    if len(checkouts) != 1 or checkouts[0].get("with", {}).get("fetch-depth") != 2:
        problems.append(f"{path}: create-matrix does not check out with fetch-depth 2")
    for name in ("admission-refused", "admission-reason"):
        if create.get("outputs", {}).get(name) != f"${{{{ steps.create-matrix.outputs.{name} }}}}":
            problems.append(f"{path}: create-matrix does not output {name}")
    step = workflow["jobs"]["conclusion"]["steps"][0]
    env = step.get("env", {})
    if env.get("ADMISSION_REFUSED") != "${{ needs.create-matrix.outputs.admission-refused }}" \
            or env.get("ADMISSION_REASON") != "${{ needs.create-matrix.outputs.admission-reason }}":
        problems.append(f"{path}: the conclusion does not read the admission's outputs")
    green = {name: "success" for name in env if name.endswith("_RESULT")}
    case = {**green, "CREATE_MATRIX_RESULT": "success", "ADMISSION_REFUSED": "true",
            "ADMISSION_REASON": "1 of 2 dependencies failed", "STAGE_1_COUNT": "0", "STAGE_2_COUNT": "0",
            "STAGE_3_COUNT": "0", "AFFECTED_COUNT": "0", "DOCS_PUSHED": "false", "TESTS_ACTIVE": "false",
            "TESTS_REQUIRED_MISSING": "false", "GITHUB_STEP_SUMMARY": os.devnull}
    rc, out = run(step["run"], case)
    if rc != 1 or "Dependabot pull request not admitted: 1 of 2 dependencies failed; see the admission comment" \
            not in out:
        problems.append(f"{path}: the conclusion does not fail a refused run with its reason (exit {rc}): {out!r}")
    rc, out = run(step["run"], {**case, "ADMISSION_REFUSED": "false", "ADMISSION_REASON": ""})
    if "not admitted" in out:
        problems.append(f"{path}: the conclusion speaks of the admission on a run it did not refuse")

jobs = load(PROJECT)["jobs"]
inits = [step for name in ("terraform-ci-cd", "terraform-ci-cd-2", "terraform-ci-cd-3") for step in jobs[name]["steps"]
         if str(step.get("uses", "")).startswith("dsb-norge/github-actions-terraform/terraform-init@")]
if len(inits) != 3 or any(step.get("with", {}).get("lockfile-mode") != LOCK for step in inits):
    problems.append(f"the environment init's lockfile-mode is not {LOCK}")
validate = load(MODULE)["jobs"]["validate"]
condition = " ".join(str(validate.get("if", "")).split())
if "create-matrix" not in validate.get("needs", []) or (
        "github.actor != 'dependabot[bot]' || (needs.create-matrix.result == 'success' && "
        "needs.create-matrix.outputs.admission-refused != 'true')") not in condition:
    problems.append("the module's validate does not wait for the admission on a Dependabot run")
print(f"checked both workflows' inputs, checkout, outputs and conclusion, and {len(inits)} environment init(s)")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f25_rc=0 || _f25_rc=$?
if [[ "${_f25_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f25_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f25_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F26 — the module docs job updates Dependabot's pull request only when the admission admitted it.
#
# docs/Dependabot-admission.md D22: the App's docs commit starts a run that is the App's, which
# nobody judges, so on Dependabot's pull request the docs job pushes only when create-matrix judged
# and admitted the run, whoever started it (docs/Module-auto-merge.md M4), and only on top of the
# commit the run evaluated (P23). The commit message keeps
# Dependabot rebasing ('[dependabot skip]'), and the terraform-docs action passes it on. The pin
# step's run block is executed here against real repositories.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F26 - the module docs job pushes to Dependabot's pull request only when admitted${NC}"
echo -e "${BLUE}========================================${NC}"
_f26_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import os, subprocess, sys, tempfile, yaml

problems = []
with open(".github/workflows/terraform-module-ci.yaml", encoding="utf-8") as fh:
    jobs = yaml.safe_load(fh)["jobs"]
create, docs = jobs["create-matrix"], jobs["generate-docs"]
if create.get("outputs", {}).get("admission-admitted") != "${{ steps.create-matrix.outputs.admission-admitted }}":
    problems.append("create-matrix does not output admission-admitted")
if docs.get("needs") != "create-matrix" or docs.get("if") != "${{ !cancelled() }}":
    problems.append(f"the docs job does not wait for create-matrix whatever its result: needs {docs.get('needs')}, if {docs.get('if')}")
steps = {step.get("id"): step for step in docs["steps"]}
gate = ("((github.event.pull_request.user.login != 'dependabot[bot]' && github.actor != 'dependabot[bot]') "
        "|| needs.create-matrix.outputs.admission-admitted == 'true')")
for step_id in ("app-access", "app-token"):
    condition = " ".join(str(steps.get(step_id, {}).get("if", "")).split())
    if gate not in condition:
        problems.append(f"the docs job's {step_id} step does not require an admitted run on Dependabot's: {condition!r}")
order = [step.get("id") or step.get("name") for step in docs["steps"]]
pin = steps.get("pin", {})
if "pin" not in order or order.index("pin") != order.index("docs") - 1 or "⬇ Checkout" not in order[:order.index("pin")]:
    problems.append(f"the pin step does not sit between the checkout and the docs step: {order}")
if pin.get("if") != "steps.app-token.outcome == 'success'" \
        or (pin.get("env") or {}).get("HEAD_SHA") != "${{ github.event.pull_request.head.sha }}":
    problems.append("the pin step does not compare against the pull request's head on every pushing run")
with_ = steps.get("docs", {}).get("with") or {}
if with_.get("push") != "${{ steps.app-token.outcome == 'success' && steps.pin.outputs.at-head == 'true' && 'true' || 'false' }}":
    problems.append(f"the docs step pushes without the pin: {with_.get('push')}")
if with_.get("commit-message") != ("${{ github.actor == 'dependabot[bot]' && 'terraform-docs: automated action "
                                   "[dependabot skip]' || 'terraform-docs: automated action' }}"):
    problems.append(f"the docs commit message does not keep Dependabot rebasing: {with_.get('commit-message')}")

def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()

with tempfile.TemporaryDirectory() as work:
    git(work, "init", "-q")
    git(work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "evaluated")
    evaluated = git(work, "rev-parse", "HEAD")
    git(work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "newer")
    newer = git(work, "rev-parse", "HEAD")
    for head, want in ((newer, "true"), (evaluated, "false")):
        output = os.path.join(work, "output")
        open(output, "w").close()
        done = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", pin.get("run", "")], cwd=work, capture_output=True,
                              text=True, env={"PATH": os.environ["PATH"], "HEAD_SHA": head, "GITHUB_OUTPUT": output})
        got = open(output).read().strip()
        if done.returncode != 0 or got != f"at-head={want}":
            problems.append(f"the pin step with the tip {'at' if want == 'true' else 'past'} the evaluated head wrote "
                            f"{got!r} (exit {done.returncode}); expected at-head={want}")

with open("terraform-docs/action.yaml", encoding="utf-8") as fh:
    action = yaml.safe_load(fh)
if action["inputs"].get("commit-message", {}).get("default") != "terraform-docs: automated action":
    problems.append("the terraform-docs action has no commit-message input defaulting to upstream's message")
passed = [step.get("with", {}).get("git-commit-message") for step in action["runs"]["steps"]
          if str(step.get("uses", "")).startswith("terraform-docs/gh-actions@")]
if passed != ["${{ inputs.commit-message }}"] * 2:
    problems.append(f"the terraform-docs steps do not both take the commit message: {passed}")
print("checked the docs job's gate, pin, push and commit message, and the action's input")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f26_rc=0 || _f26_rc=$?
if [[ "${_f26_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f26_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f26_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F27 — the module auto-merge job merges only what the engine ruled eligible, as the CI App.
#
# docs/Module-auto-merge.md §6: create-matrix lists the commits (pull-requests: read) and outputs the
# verdict; the job needs the conclusion, the docs job and validation, runs only on an eligible pull
# request run the docs job pushed nothing in, holds no permission of its own, checks the App like the
# docs job, confirms the actor is the App when docs commits are at the head, and pins the merge.
# The confirmation's run block is executed here for the App, another bot and a missing slug. The
# docs job's message on a Dependabot run is the engine's DEPENDABOT_DOCS_MESSAGE.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F27 - the module auto-merge job is gated, unprivileged, confirms the App and pins the merge${NC}"
echo -e "${BLUE}========================================${NC}"
_f27_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import os, re, subprocess, sys, yaml

problems = []
with open(".github/workflows/terraform-module-ci.yaml", encoding="utf-8") as fh:
    workflow = yaml.safe_load(fh)
inputs, jobs = workflow[True]["workflow_call"]["inputs"], workflow["jobs"]
for name, kind, default in (("pr-auto-merge-enabled", "boolean", False), ("pr-auto-merge-from-actors-yml", "string", "[]")):
    declared = inputs.get(name, {})
    if (declared.get("type"), declared.get("default")) != (kind, default):
        problems.append(f"input {name} is {declared.get('type')} defaulting to {declared.get('default')!r}; expected {kind}, {default!r}")
create = jobs["create-matrix"]
if create.get("permissions") != {"contents": "read", "pull-requests": "read"}:
    problems.append(f"create-matrix cannot list the pull request's commits: {create.get('permissions')}")
for output in ("automerge-eligible", "automerge-confirm-app"):
    if create.get("outputs", {}).get(output) != f"${{{{ steps.create-matrix.outputs.{output} }}}}":
        problems.append(f"create-matrix does not output {output}")
job = jobs.get("automerge", {})
if job.get("needs") != ["create-matrix", "generate-docs", "validate", "conclusion"]:
    problems.append(f"the job's needs are {job.get('needs')}")
if job.get("permissions") != {}:
    problems.append(f"the job holds permissions of its own: {job.get('permissions')}")
condition = [line.strip() for line in str(job.get("if", "")).strip().splitlines()]
wanted = ["!cancelled()", "&& needs.conclusion.result == 'success'", "&& needs.create-matrix.result == 'success'",
          "&& needs.generate-docs.result == 'success'", "&& (needs.validate.result == 'success'",
          "|| (needs.validate.result == 'skipped' && needs.create-matrix.outputs.affected-count == '0'))",
          "&& needs.generate-docs.outputs.pushed != 'true'", "&& needs.create-matrix.outputs.automerge-eligible == 'true'",
          "&& inputs.pr-auto-merge-enabled == true", "&& github.event_name == 'pull_request'",
          "&& github.event.action != 'closed'", "&& github.event.action != 'converted_to_draft'",
          "&& github.event.pull_request.draft != true", "&& github.base_ref == github.event.repository.default_branch",
          "&& github.event.pull_request.head.repo.full_name == github.repository"]
if condition != wanted:
    problems.append(f"the job's condition is {condition}")
steps = job.get("steps", [])
names = [step.get("name") for step in steps]
expected = ["🔐 Check the App's variable and secret", "🔑 Create GitHub App token", "🔐 Explain the failed App token",
            "🤖 Confirm the run is the CI App's", "🤖 Auto merge PR"]
if names != expected:
    problems.append(f"the job's steps are {names}")
else:
    docs = {step.get("id"): step for step in jobs["generate-docs"]["steps"]}
    if steps[0].get("run") != docs["app-access"].get("run") or steps[0].get("env") != docs["app-access"].get("env"):
        problems.append("the App check is not the docs job's")
    token = steps[1].get("with") or {}
    if (token.get("permission-contents"), token.get("permission-pull-requests")) != ("write", "write"):
        problems.append(f"the App token cannot merge: {token}")
    confirm = steps[3]
    if confirm.get("if") != "needs.create-matrix.outputs.automerge-confirm-app == 'true'" \
            or confirm.get("env") != {"ACTOR": "${{ github.actor }}", "APP_SLUG": "${{ steps.app-token.outputs.app-slug }}"}:
        problems.append(f"the confirmation does not compare the actor with the App's slug: {confirm.get('if')}, {confirm.get('env')}")
    for actor, slug, want in (("ci-app[bot]", "ci-app", 0), ("other-app[bot]", "ci-app", 1), ("ci-app", "ci-app", 1),
                              ("[bot]", "", 1)):
        done = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", confirm.get("run", "")], capture_output=True, text=True,
                              env={"PATH": os.environ["PATH"], "ACTOR": actor, "APP_SLUG": slug})
        if done.returncode != want or (want and "::error title=PR auto merger::" not in done.stdout):
            problems.append(f"the confirmation with actor {actor} and slug {slug!r} exited {done.returncode}; expected {want}")
    merge = steps[4]
    if not str(merge.get("uses", "")).startswith("dsb-norge/github-actions-terraform/auto-merge-pr@") \
            or merge.get("with") != {"github-token": "${{ steps.app-token.outputs.token }}",
                                     "github-event-context-json": "${{ toJSON(github.event) }}",
                                     "head-sha": "${{ github.event.pull_request.head.sha }}", "merge-sha": "${{ github.sha }}"}:
        problems.append(f"the merge is not auto-merge-pr pinned to the evaluated head and base: {merge.get('with')}")
# On Dependabot's pull request the rule accepts a docs commit only with the message the docs job writes in Dependabot's
# own run (docs/Module-auto-merge.md §3, rule 5): the engine's constant and the workflow's must be one text.
message = str(((next((step for step in jobs["generate-docs"]["steps"] if step.get("id") == "docs"), {}).get("with")
                or {}).get("commit-message", "")))
written = re.search(r"github\.actor == 'dependabot\[bot\]' && '([^']+)'", message)
with open("engine/dsb_tf_engine/automerge.py", encoding="utf-8") as fh:
    engine = fh.read()
if not written or f'DEPENDABOT_DOCS_MESSAGE = "{written.group(1)}"' not in engine:
    problems.append(f"the engine's DEPENDABOT_DOCS_MESSAGE is not the docs job's message on a Dependabot run: {message}")
print("checked the inputs, create-matrix, the job's needs, condition, permissions and steps, the confirmation and the "
      "docs message")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f27_rc=0 || _f27_rc=$?
if [[ "${_f27_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f27_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f27_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# F28 — the module workflow's path relevance and run summary are wired as the spec says.
#
# docs/Module-ci.md §5.1 and §7.1: two inputs; create-matrix publishes the module's relevance; validation is
# skipped for a change the module is not affected by and publishes its steps' outcomes; the conclusion's run
# block, executed here, says green for such a change and hands its line on; the tests summary job publishes
# its counts in both workflows; the run summary job reads every job as toJSON(needs), never fails the run,
# and stays out of the conclusion's needs.
# ============================================================================
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TEST ${TESTS_RUN}: F28 - the module workflow's path relevance and run summary are wired${NC}"
echo -e "${BLUE}========================================${NC}"
_f28_out=$(cd "${_this_script_dir}/.." && python3 - <<'PYEOF'
import os, subprocess, sys, tempfile, yaml

problems = []
with open(".github/workflows/terraform-module-ci.yaml", encoding="utf-8") as fh:
    workflow = yaml.safe_load(fh)
with open(".github/workflows/terraform-ci-cd-default.yml", encoding="utf-8") as fh:
    project = yaml.safe_load(fh)
inputs, jobs = workflow[True]["workflow_call"]["inputs"], workflow["jobs"]
for name, kind, default in (("path-relevance-enabled", "boolean", True), ("paths-ignore-yml", "string", "")):
    declared = inputs.get(name, {})
    if (declared.get("type"), declared.get("default")) != (kind, default):
        problems.append(f"input {name} is {declared.get('type')} defaulting to {declared.get('default')!r}; expected {kind}, {default!r}")
for output in ("relevance-mode", "relevance-reason", "affected-count"):
    if jobs["create-matrix"].get("outputs", {}).get(output) != f"${{{{ steps.create-matrix.outputs.{output} }}}}":
        problems.append(f"create-matrix does not output {output}")
validate = jobs["validate"]
if "&& needs.create-matrix.outputs.affected-count != '0'" not in [line.strip() for line in str(validate.get("if", "")).splitlines()]:
    problems.append("validation is not skipped for a change the module is not affected by")
wanted = {"init": "${{ steps.init.outcome }}", "fmt": "${{ steps.fmt.outcome }}", "validate": "${{ steps.validate.outcome }}",
          "lint": "${{ steps.lint.outcome }}", "warning-count": "${{ steps.warnings.outputs.warning-count }}"}
if validate.get("outputs") != wanted:
    problems.append(f"the validate job's outputs are {validate.get('outputs')}")
counts = {f"{name}-count": f"${{{{ steps.summary.outputs.{name}-count }}}}" for name in ("passed", "failed", "tolerated", "not-run")}
for label, flow in (("module", workflow), ("project", project)):
    if flow["jobs"]["terraform-test-summary"].get("outputs") != counts:
        problems.append(f"the {label} workflow's tests summary job does not publish its counts")
conclusion = jobs["conclusion"]
if conclusion.get("outputs") != {"line": "${{ steps.verdict.outputs.line }}"}:
    problems.append(f"the conclusion does not hand its line on: {conclusion.get('outputs')}")
step = next((s for s in conclusion["steps"] if s.get("id") == "verdict"), {})
if (step.get("env") or {}).get("AFFECTED_COUNT") != "${{ needs.create-matrix.outputs.affected-count }}":
    problems.append("the conclusion does not read affected-count")
base = {"CREATE_MATRIX_RESULT": "success", "DOCS_RESULT": "success", "DOCS_PUSHED": "false", "VALIDATE_RESULT": "skipped",
        "TESTS_ACTIVE": "false", "TESTS_COUNT": "0", "TESTS_REQUIRED_MISSING": "false", "TESTS_RESULT": "skipped",
        "ADMISSION_REFUSED": "false", "ADMISSION_REASON": "", "AFFECTED_COUNT": "0"}
with tempfile.TemporaryDirectory() as work:
    for overrides, want_rc, want_line in (
            ({}, 0, "conclusion: green — the module is not affected by this change; nothing to validate or test; tests: 0"),
            ({"DOCS_RESULT": "failure"}, 1, "conclusion: red — the documentation check's result is failure; tests: 0"),
            ({"AFFECTED_COUNT": "1"}, 1, "conclusion: red — validation's result is skipped; tests: 0")):
        output, summary = os.path.join(work, "out"), os.path.join(work, "summary")
        open(output, "w").close(); open(summary, "w").close()
        done = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step.get("run", "")], capture_output=True, text=True,
                              env={"PATH": os.environ["PATH"], **base, **overrides, "GITHUB_OUTPUT": output, "GITHUB_STEP_SUMMARY": summary})
        got = open(output).read().strip()
        if done.returncode != want_rc or got != f"line={want_line}":
            problems.append(f"the conclusion with {overrides or 'nothing affected'} exited {done.returncode} and wrote {got!r}; expected {want_rc}, line={want_line}")
summary_job = jobs.get("run-summary", {})
if summary_job.get("needs") != ["create-matrix", "generate-docs", "validate", "terraform-test-summary", "conclusion", "automerge"] \
        or summary_job.get("if") != "always()" or summary_job.get("permissions") != {}:
    problems.append(f"the run summary job's needs, condition or permissions: {summary_job.get('needs')}, {summary_job.get('if')}, {summary_job.get('permissions')}")
writer = next((s for s in summary_job.get("steps", []) if str(s.get("uses", "")).startswith("dsb-norge/github-actions-terraform/create-run-summary@")), {})
if writer.get("with") != {"mode": "module", "relevance-file": "${{ runner.temp }}/relevance/relevance.json",
                          "module-results-json": "${{ toJSON(needs) }}"} or writer.get("continue-on-error") is not True:
    problems.append(f"the run summary step: {writer.get('with')}, continue-on-error {writer.get('continue-on-error')}")
if "run-summary" in conclusion.get("needs", []):
    problems.append("the conclusion waits for the run summary")
print("checked the inputs, the relevance outputs, validation, the conclusion's verdicts, the counts and the run summary job")
for problem in problems:
    print(f"PROBLEM {problem}")
sys.exit(1 if problems else 0)
PYEOF
) && _f28_rc=0 || _f28_rc=$?
if [[ "${_f28_rc}" -eq 0 ]]; then
  echo -e "${GREEN}✓ PASSED${NC}: $(echo "${_f28_out}" | head -n1)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"
  echo "${_f28_out}" | grep '^PROBLEM ' | sed 's/^PROBLEM /    /'
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

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
