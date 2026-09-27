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

  # Run the step_evaluate.sh script in a subshell
  (
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
    exit_code=$?
    set +o allexport
    exit ${exit_code}
  ) > "${_test_output}" 2>&1
  local exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: Script exited with error code ${exit_code}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: Script should have exited with error"
    echo ""
    echo "Test output:"
    cat /tmp/test_output.txt
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
    call_sites = []
    for job_name, job in (doc.get('jobs') or {}).items():
        if isinstance(job.get('uses'), str):
            call_sites.append((job_name, job['uses'], job.get('with') or {}))
        for step in (job.get('steps') or []):
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
    steps = list(((doc.get('runs') or {}).get('steps')) or [])
    for job in (doc.get('jobs') or {}).values():
        steps += job.get('steps') or []
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
# whenever the matrix is skipped. The conclusion's script is also run, one case
# per row of §7.2.
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
               "needs.create-matrix.outputs.affected-count != '0'"):
    if clause not in condition:
        problems.append(f"terraform-ci-cd's if lacks {clause}")
if "seed-pr-comments.result" in condition:
    problems.append("terraform-ci-cd's if tests the seed's result")

conclusion = jobs["conclusion"]
if str(conclusion.get("if")).strip() != "always()":
    problems.append(f"conclusion's if is {conclusion.get('if')!r}, expected always()")
if conclusion.get("needs") != ["create-matrix", "terraform-ci-cd", "terraform-test"]:
    problems.append(f"conclusion needs {conclusion.get('needs')}, expected [create-matrix, terraform-ci-cd, terraform-test]")
steps = conclusion.get("steps", [])
env = steps[0].get("env", {}) if steps else {}
expected_env = {
    "CREATE_MATRIX_RESULT": "${{ needs.create-matrix.result }}",
    "AFFECTED_COUNT": "${{ needs.create-matrix.outputs.affected-count }}",
    "ENVIRONMENTS_RESULT": "${{ needs.terraform-ci-cd.result }}",
    "TESTS_ACTIVE": "${{ needs.create-matrix.outputs.tests-active }}",
    "TESTS_RESULT": "${{ needs.terraform-test.result }}",
}
for name, value in expected_env.items():
    if env.get(name) != value:
        problems.append(f"conclusion's step env {name} is {env.get(name)!r}, expected {value!r}")

automerge = jobs["automerge"]
if set(automerge.get("needs", [])) != {"create-matrix", "terraform-ci-cd", "conclusion"}:
    problems.append(f"automerge needs {automerge.get('needs')}, expected create-matrix, terraform-ci-cd, conclusion")
condition = " ".join(str(automerge.get("if", "")).split())
for clause in ("!cancelled()", "needs.conclusion.result == 'success'", "needs.terraform-ci-cd.result == 'success'",
               "(needs.terraform-ci-cd.result == 'skipped' && needs.create-matrix.outputs.affected-count == '0')"):
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

# The conclusion's script, one case per row of §7.2.
script = steps[0]["run"] if steps else "exit 3"
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
    with tempfile.NamedTemporaryFile("w+") as summary:
        run_env = dict(os.environ, CREATE_MATRIX_RESULT=create_matrix, AFFECTED_COUNT=affected, UNAFFECTED_COUNT="1",
                       RELEVANCE_MODE="diff", RELEVANCE_REASON="diff", ENVIRONMENTS_RESULT=environments,
                       TESTS_RESULT=tests, TESTS_ACTIVE=active, TESTS_COUNT="3" if active == "true" else "0",
                       GITHUB_STEP_SUMMARY=summary.name)
        done = subprocess.run(["bash", "-e", "-c", script], env=run_env, capture_output=True, text=True)
        written = open(summary.name, encoding="utf-8").read()
    verdict = "green" if expected == 0 else "red"
    annotation = "::notice title=Terraform conclusion::" if expected == 0 else "::error title=Terraform conclusion::"
    label = f"create-matrix={create_matrix} affected={affected or '-'} environments={environments} tests={tests}/{active}"
    if done.returncode != expected:
        problems.append(f"conclusion exits {done.returncode} for {label}, expected {expected}")
    if f"conclusion: {verdict} — " not in written or annotation + f"conclusion: {verdict} — " not in done.stdout:
        problems.append(f"conclusion does not report {verdict} in the step summary and an annotation for {label}")

print(f"checked the conclusion, the matrix gate, automerge, the relevance downloads and {len(cases)} conclusion cases")
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
names = ["matrix-json", "affected-count", "unaffected-count", "relevance-mode", "relevance-reason", "changed-count",
         "tests-matrix-json", "tests-count", "tests-active"]
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
# restored so a warm cache spares the download (§5.2 step 6).
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
    match = re.fullmatch(r"\$\{\{ steps\.create-matrix\.outputs\.([a-z-]+) \}\}", str(value))
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
for job_id, job in jobs.items():
    for step in job.get("steps", []):
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
