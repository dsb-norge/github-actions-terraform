#!/bin/env bash
#
# Test runner for step_create_validation_summary.sh
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# Helper to get an output value from GITHUB_OUTPUT
# For multiline outputs, returns everything between the delimiter lines
get_output() {
  local key="${1}"
  local content=""
  local in_block=false
  local delimiter=""

  while IFS= read -r line; do
    if [[ "${in_block}" == true ]]; then
      if [[ "${line}" == "${delimiter}" ]]; then
        break
      fi
      if [[ -n "${content}" ]]; then
        content="${content}
${line}"
      else
        content="${line}"
      fi
    elif [[ "${line}" =~ ^${key}=(.*)$ ]]; then
      content="${BASH_REMATCH[1]}"
      break
    elif [[ "${line}" =~ ^${key}\<\<(.*)$ ]]; then
      delimiter="${BASH_REMATCH[1]}"
      in_block=true
    fi
  done < "${GITHUB_OUTPUT}"

  echo "${content}"
}

# Set default input values shared across tests
reset_defaults() {
  export input_environment_name="dev"
  export input_plan_console_file=""
  export input_plan_txt_output_file=""
  export input_status_init="success"
  export input_status_fmt="success"
  export input_status_validate="success"
  export input_status_lint="success"
  export input_status_plan="success"
  export input_include_plan_details="false"
  export input_plan_count_add="0"
  export input_plan_count_change="0"
  export input_plan_count_destroy="0"
  export input_plan_count_import="0"
  export input_plan_count_move="0"
  export input_plan_count_remove="0"
  export input_job_check_run_id="87654321"
  export input_github_actor="test-user"
  export input_github_event_name="pull_request"

  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="dsb-norge/github-actions-terraform"
  export GITHUB_RUN_ID="12345678"
  export GITHUB_WORKFLOW="Terraform CI"
}

# Generic test runner function
# Usage: run_test <test_name> <assertion_callback>
# The assertion callback receives the summary content and should return 0 for pass, 1 for fail
run_test() {
  local test_name="${1}"
  local assert_fn="${2}"

  TESTS_RUN=$((TESTS_RUN + 1))

  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"

  # Set up fresh GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${_this_script_dir}"

  # Run step in a subshell
  local exit_code
  (
    set -o allexport
    source "${_this_script_dir}/step_create_validation_summary.sh"
  ) > /tmp/test_output.txt 2>&1
  exit_code=$?

  local failed=0
  local failures=""

  if [[ "${exit_code}" -ne 0 ]]; then
    failed=1
    failures+="  exit code: expected 0, got ${exit_code}\n"
  fi

  # Get outputs
  local actual_prefix actual_summary
  actual_prefix=$(get_output "prefix")
  actual_summary=$(get_output "summary")

  # Run assertion callback
  local assert_result
  assert_result=$("${assert_fn}" "${actual_prefix}" "${actual_summary}" 2>&1)
  local assert_exit=$?

  if [[ ${assert_exit} -ne 0 ]]; then
    failed=1
    failures+="${assert_result}\n"
  fi

  if [[ ${failed} -eq 0 ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}:"
    echo -e "${failures}"
    echo "--- Step output ---"
    cat /tmp/test_output.txt
    echo "--- End step output ---"
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}"
    echo "--- End GITHUB_OUTPUT ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
}

# --------------------------------------------------
# Assertion functions
# --------------------------------------------------

assert_happy_path_all_success() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  if [[ "${prefix}" != *"dev"* ]]; then
    fails+="  prefix: expected to contain 'dev', got '${prefix}'\n"
  fi

  # Check all statuses render as backtick-wrapped (success)
  if [[ "${summary}" != *'`success`'* ]]; then
    fails+="  summary: expected to contain backtick-wrapped success status\n"
  fi

  # Should NOT contain <kbd> (no failures)
  if [[ "${summary}" == *'<kbd>'* ]]; then
    fails+="  summary: should not contain <kbd> tags when all steps succeed\n"
  fi

  # Should contain the footer
  if [[ "${summary}" != *"Pusher: @test-user"* ]]; then
    fails+="  summary: expected to contain 'Pusher: @test-user'\n"
  fi

  if [[ "${summary}" != *"pull_request"* ]]; then
    fails+="  summary: expected to contain 'pull_request' event name\n"
  fi

  if [[ "${summary}" != *"Plan not available"* ]]; then
    fails+="  summary: expected 'Plan not available' when no plan file\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

assert_failure_statuses() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  # Check that failure statuses render with <kbd> tags
  if [[ "${summary}" != *'<kbd>failure</kbd>'* ]]; then
    fails+="  summary: expected '<kbd>failure</kbd>' for failed steps\n"
  fi

  # Init should still be success
  if [[ "${summary}" != *'`success`'* ]]; then
    fails+="  summary: expected backtick-wrapped success for init\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

assert_plan_details_basic() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  # Should contain the Plan Details row
  if [[ "${summary}" != *"Plan Details"* ]]; then
    fails+="  summary: expected to contain 'Plan Details'\n"
  fi

  # Should contain add/change/destroy counts
  if [[ "${summary}" != *'💫 3'* ]]; then
    fails+="  summary: expected add count of 3\n"
  fi
  if [[ "${summary}" != *'🛠️ 1'* ]]; then
    fails+="  summary: expected change count of 1\n"
  fi
  if [[ "${summary}" != *'💥 2'* ]]; then
    fails+="  summary: expected destroy count of 2\n"
  fi

  # move=0 should NOT appear
  if [[ "${summary}" == *"move"* ]]; then
    fails+="  summary: move should not appear when count is 0\n"
  fi

  # import=0 should NOT appear
  if [[ "${summary}" == *"import"* ]]; then
    fails+="  summary: import should not appear when count is 0\n"
  fi

  # remove=0 should NOT appear
  if [[ "${summary}" == *"remove"* ]]; then
    fails+="  summary: remove should not appear when count is 0\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

assert_plan_details_with_move_import_remove() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  # Should contain move, import, remove
  if [[ "${summary}" != *'🔀 2'* ]]; then
    fails+="  summary: expected move count of 2\n"
  fi
  if [[ "${summary}" != *'📥 1'* ]]; then
    fails+="  summary: expected import count of 1\n"
  fi
  if [[ "${summary}" != *'⛓️‍💥 3'* ]]; then
    fails+="  summary: expected remove count of 3\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

assert_no_plan_details() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  # Should NOT contain the Plan Details row
  if [[ "${summary}" == *"Plan Details"* ]]; then
    fails+="  summary: should not contain 'Plan Details' when disabled\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

assert_plan_from_txt_file() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  # Should contain the plan output
  if [[ "${summary}" != *"Resource actions are indicated"* ]]; then
    fails+="  summary: expected plan output from txt file\n"
  fi

  # Should NOT contain "Plan not available"
  if [[ "${summary}" == *"Plan not available"* ]]; then
    fails+="  summary: should not say 'Plan not available' when plan file exists\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

assert_plan_from_console_file() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  # Should contain plan output but not the refresh lines (they get stripped)
  if [[ "${summary}" != *"Terraform used the selected providers"* ]]; then
    fails+="  summary: expected plan output starting from 'Terraform used the selected providers'\n"
  fi

  # Should NOT contain "Plan not available"
  if [[ "${summary}" == *"Plan not available"* ]]; then
    fails+="  summary: should not say 'Plan not available' when console file exists\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

assert_environment_name_in_prefix() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  if [[ "${prefix}" != *"production"* ]]; then
    fails+="  prefix: expected to contain 'production', got '${prefix}'\n"
  fi
  if [[ "${summary}" != *"production"* ]]; then
    fails+="  summary: expected to contain 'production' in header\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

assert_job_url_in_summary() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  if [[ "${summary}" != *"https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs"* ]]; then
    fails+="  summary: expected correct job URL in footer\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

# --------------------------------------------------
# Test cases
# --------------------------------------------------

# Test 1: Happy path — all steps success, no plan details, no plan file
reset_defaults
run_test "All success, no plan details, no plan file" assert_happy_path_all_success

# Test 2: Mixed statuses — some failures
reset_defaults
export input_status_fmt="failure"
export input_status_plan="failure"
run_test "Mixed success and failure statuses" assert_failure_statuses

# Test 3: Plan details enabled with basic counts (move/import/remove = 0)
reset_defaults
export input_include_plan_details="true"
export input_plan_count_add="3"
export input_plan_count_change="1"
export input_plan_count_destroy="2"
export input_plan_count_import="0"
export input_plan_count_move="0"
export input_plan_count_remove="0"
run_test "Plan details with basic counts (move/import/remove=0)" assert_plan_details_basic

# Test 4: Plan details with move, import, and remove non-zero
reset_defaults
export input_include_plan_details="true"
export input_plan_count_add="5"
export input_plan_count_change="2"
export input_plan_count_destroy="1"
export input_plan_count_import="1"
export input_plan_count_move="2"
export input_plan_count_remove="3"
run_test "Plan details with move, import, remove" assert_plan_details_with_move_import_remove

# Test 5: Plan details disabled
reset_defaults
export input_include_plan_details="false"
run_test "Plan details disabled" assert_no_plan_details

# Test 6: Plan output from txt file (preferred source)
reset_defaults
_plan_txt_file=$(mktemp)
cat > "${_plan_txt_file}" <<'PLAN'
Terraform used the selected providers to generate the following execution plan.
Resource actions are indicated with the following symbols:
  + create

Plan: 1 to add, 0 to change, 0 to destroy.
PLAN
export input_plan_txt_output_file="${_plan_txt_file}"
run_test "Plan output from txt file" assert_plan_from_txt_file
rm -f "${_plan_txt_file}"

# Test 7: Plan output from console file (fallback, with refresh stripping)
reset_defaults
_plan_console_file=$(mktemp)
cat > "${_plan_console_file}" <<'PLAN'
module.foo.data.azurerm_resource_group.rg: Reading...
module.foo.data.azurerm_resource_group.rg: Read complete after 1s

Terraform used the selected providers to generate the following execution plan.
Resource actions are indicated with the following symbols:
  + create

Plan: 2 to add, 0 to change, 0 to destroy.
PLAN
export input_plan_console_file="${_plan_console_file}"
run_test "Plan output from console file (with refresh stripping)" assert_plan_from_console_file
rm -f "${_plan_console_file}"

# Test 8: Custom environment name in prefix
reset_defaults
export input_environment_name="production"
run_test "Environment name appears in prefix" assert_environment_name_in_prefix

# Test 9: Job URL is correct in summary footer
reset_defaults
run_test "Job URL is correctly constructed" assert_job_url_in_summary

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "========================================"
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "========================================"

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
