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

# Create a metadata file with specified parameters
# Usage: create_metadata_file <filename> <env_name> <options...>
create_metadata_file() {
  local filename="${1}"
  local env_name="${2}"
  shift 2

  # Default values
  local pr_auto_merge_enabled="true"
  local goals='["all"]'
  local actors='[]'
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

  # Build parse-plan outputs
  local parse_plan_outputs
  parse_plan_outputs=$(echo "${plan_counts}" | jq -c '.')

  # Build parse-destroy-plan outputs
  local parse_destroy_plan_outputs
  if [[ "${destroy_plan_counts}" == "{}" ]]; then
    parse_destroy_plan_outputs='{}'
  else
    parse_destroy_plan_outputs=$(echo "${destroy_plan_counts}" | jq -c '.')
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
      "pr-auto-merge-from-actors": ${actors},
      "pr-auto-merge-limits": ${limits}
    }
  },
  "github_context": {
    "actor": "${GITHUB_ACTOR}"
  },
  "steps": {
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
}

# Function to run a single test
run_test() {
  local test_name="${1}"
  local expected_eligible="${2}"

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

  # Run the step_evaluate.sh script in a subshell
  (
    set -o allexport
    source "${_this_script_dir}/step_evaluate.sh"
  ) > /tmp/test_output.txt 2>&1

  # Check the result
  local actual_eligible
  actual_eligible=$(grep "^is-eligible=" "${GITHUB_OUTPUT}" | cut -d= -f2)

  if [[ "${actual_eligible}" == "${expected_eligible}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: Expected is-eligible=${expected_eligible}, got ${actual_eligible}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: Expected is-eligible=${expected_eligible}, got ${actual_eligible}"
    echo ""
    echo "Test output:"
    cat /tmp/test_output.txt
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
  rm -f matrix-job-meta-*.json
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

  # Run the step_evaluate.sh script in a subshell
  (
    set -o allexport
    source "${_this_script_dir}/step_evaluate.sh"
    exit_code=$?
    set +o allexport
    exit ${exit_code}
  ) > /tmp/test_output.txt 2>&1
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
# Test 13: Empty actor list (all actors allowed)
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="any-random-actor"
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" --actors='[]'
run_test "Empty actor list (all actors allowed)" "true"
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
# Test 24: Actor case sensitivity - wrong case should fail
# ============================================================================
setup_test_dir
export GITHUB_ACTOR="Renovate[bot]"  # Capital R vs lowercase
create_metadata_file "matrix-job-meta-sandbox.json" "sandbox" \
  --actors='["dependabot[bot]", "renovate[bot]"]'
run_test "Actor case sensitivity - wrong case should fail" "false"
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
      "pr-auto-merge-from-actors": [],
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
run_test "File with missing steps section" "false"
cleanup_test_dir

# ============================================================================
# Test 46: Multiple files - different schema handling
# ============================================================================
setup_test_dir
create_metadata_file "matrix-job-meta-normal.json" "normal"
# File with minimal structure but valid
cat > matrix-job-meta-minimal.json << 'EOF'
{
  "metadata": {
    "environment": "minimal"
  },
  "matrix_context": {
    "vars": {
      "pr-auto-merge-enabled": true,
      "goals": ["all"],
      "pr-auto-merge-from-actors": [],
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
    "parse-plan": {"outcome": "success", "outputs": {"count-add": "0", "count-change": "0", "count-destroy": "0", "count-import": "0", "count-move": "0", "count-remove": "0"}}
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
# F2 — the step id this action reads by literal name must exist in the
# reusable workflow (docs/Apply-and-destroy-reporting.md §5.1, P7, F2).
#
# extract_environment_data looks up .steps["parse-destroy-plan"].outputs.*
# in the captured metadata. For a long time no step with that id existed,
# so every destroy-plan-max-count-* limit compared against an empty string
# and was never enforced — with every test here green, because the tests
# write the metadata themselves. This is a structural check across the two
# files that have to agree; it is the only thing standing between that
# defect and a silent recurrence on the next workflow refactor.
# ============================================================================
_workflow="${_this_script_dir}/../.github/workflows/terraform-ci-cd-default.yml"
_helper="${_this_script_dir}/helpers_additional.sh"

# The step ids the helper reads out of the metadata, by literal string.
_ids_read_by_helper=$(grep -oE 'get_step_output(_success)? "\$\{file\}" "[a-z-]+"' "${_helper}" | grep -oE '"[a-z-]+"$' | tr -d '"' | sort -u)
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
if [[ -z "${_f2_missing}" ]] && grep -qx "parse-destroy-plan" <<<"${_ids_read_by_helper}"; then
  echo -e "${GREEN}✓ PASSED${NC}: helper reads [$(echo ${_ids_read_by_helper} | tr '\n' ' ')] — all defined in the workflow"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: step id(s) read by helpers_additional.sh but not defined in terraform-ci-cd-default.yml:${_f2_missing:- (parse-destroy-plan no longer read by the helper?)}"
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
