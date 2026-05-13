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
  export input_status_verify_lock="success"
  export input_status_fmt="success"
  export input_status_validate="success"
  export input_status_lint="success"
  export input_status_plan="success"
  export input_pr_comment_group=""
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

# Test 8: Large plan file (verifies no E2BIG / 'Argument list too long' error)
# With 'set -o allexport', large variables get exported to the environment.
# When the env exceeds ARG_MAX (~2MB), forking external commands fails with E2BIG.
# This test generates a plan file >200KB to verify the fix works.
reset_defaults
_large_plan_file=$(mktemp)
{
  echo "Terraform used the selected providers to generate the following execution plan."
  echo "Resource actions are indicated with the following symbols:"
  echo "  + create"
  echo ""
  # Generate ~250KB of plan content to exceed typical E2BIG thresholds
  for i in $(seq 1 5000); do
    echo "  # module.example.azurerm_resource.item[\"item-${i}\"] will be created"
    echo "  + resource \"azurerm_resource\" \"item\" {"
    echo "      + id   = (known after apply)"
    echo "      + name = \"item-${i}\""
    echo "    }"
    echo ""
  done
  echo "Plan: 5000 to add, 0 to change, 0 to destroy."
} > "${_large_plan_file}"

assert_large_plan_file() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""

  # Should contain plan output (it will be the tail end due to 65k char cap)
  if [[ "${summary}" == *"Plan not available"* ]]; then
    fails+="  summary: should not say 'Plan not available' for large plan file\n"
  fi

  # The output should be capped at 65k characters
  local plan_section
  plan_section=$(echo "${summary}" | sed -n '/```terraform/,/```/p')
  local plan_length=${#plan_section}
  if [[ ${plan_length} -gt 66000 ]]; then
    fails+="  summary: plan section too long (${plan_length} chars), should be capped at ~65k\n"
  fi

  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}

export input_plan_txt_output_file="${_large_plan_file}"
run_test "Large plan file (>200KB) does not cause E2BIG error" assert_large_plan_file
rm -f "${_large_plan_file}"

# Test 9: Custom environment name in prefix
reset_defaults
export input_environment_name="production"
run_test "Environment name appears in prefix" assert_environment_name_in_prefix

# Test 10: Job URL is correct in summary footer
reset_defaults
run_test "Job URL is correctly constructed" assert_job_url_in_summary

# Test 11: Lock file row renders success in table
assert_lock_row_success() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  if [[ "${summary}" != *"| 🔒 | Lock file | \`success\` |"* ]]; then
    fails+="  summary: expected lock file row with success status\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
run_test "Lock file row renders success" assert_lock_row_success

# Test 12: Lock file row renders failure with <kbd>
assert_lock_row_failure() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  if [[ "${summary}" != *"| 🔒 | Lock file | <kbd>failure</kbd> |"* ]]; then
    fails+="  summary: expected lock file row with <kbd>failure</kbd>\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
export input_status_verify_lock="failure"
run_test "Lock file row renders failure with <kbd>" assert_lock_row_failure

# --------------------------------------------------
# Backwards-compatibility tests for ungrouped per-env comment shape.
# These tests pin down the EXACT byte-level output of the historical
# (ungrouped) per-env comment. They are the contract enforced by
# docs/Workflow-pr-comments.md §6.1 ("Default-mode shape unchanged")
# — any future change to comment rendering that breaks one of these
# tests breaks the backwards-compat contract.
# --------------------------------------------------

# Test 13: Prefix is exactly "### Terraform validation summary for environment: `<env>`"
assert_prefix_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local expected='### Terraform validation summary for environment: `dev`'
  if [[ "${prefix}" != "${expected}" ]]; then
    echo "  prefix: byte-exact mismatch"
    echo "    expected: ${expected}"
    echo "    actual:   ${prefix}"
    return 1
  fi
  return 0
}
reset_defaults
run_test "Prefix is byte-exact '### Terraform validation summary for environment: \`<env>\`'" assert_prefix_byte_exact

# Test 14: Full body byte-exact for the canonical all-success-no-plan scenario.
# This is the strongest backwards-compat assert: any change to the
# rendered output breaks this test immediately.
assert_full_body_golden_all_success_no_plan() {
  local prefix="${1}"
  local summary="${2}"
  # don't touch the indentation / newlines in the heredoc below
  local expected
  expected=$(cat <<'EOF'
### Terraform validation summary for environment: `dev`
|  | Step | Result |
|:---:|---|---|
| ⚙️ | Initialization | `success` |
| 🔒 | Lock file | `success` |
| 🖌 | Format and Style | `success` |
| ✔ | Validate | `success` |
| 🧹 | TFLint | `success` |
| 📖 | Plan | `success` |

Plan not available 🤷‍♀️

*Pusher: @test-user, Action: `pull_request`, Workflow: `Terraform CI`, Job log: [link](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)*
EOF
)
  if [[ "${summary}" != "${expected}" ]]; then
    echo "  summary: byte-exact mismatch (diff below)"
    diff <(echo "${expected}") <(echo "${summary}") | sed 's/^/    /'
    return 1
  fi
  return 0
}
reset_defaults
run_test "Golden full body — all success, no plan details, no plan file" assert_full_body_golden_all_success_no_plan

# Test 15: Every standard row's emoji+label is byte-exact (locks against accidental edits)
assert_all_row_labels_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  local rows=(
    "| ⚙️ | Initialization | "
    "| 🔒 | Lock file | "
    "| 🖌 | Format and Style | "
    "| ✔ | Validate | "
    "| 🧹 | TFLint | "
    "| 📖 | Plan | "
  )
  for row in "${rows[@]}"; do
    if [[ "${summary}" != *"${row}"* ]]; then
      fails+="  summary: missing byte-exact row prefix '${row}'\n"
    fi
  done
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
run_test "Every standard row's emoji+label is byte-exact" assert_all_row_labels_byte_exact

# Test 16: Table header line and alignment line are byte-exact
assert_table_header_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  if [[ "${summary}" != *$'|  | Step | Result |\n|:---:|---|---|'* ]]; then
    fails+="  summary: expected exact header lines '|  | Step | Result |' followed by '|:---:|---|---|'\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
run_test "Table header and alignment line are byte-exact" assert_table_header_byte_exact

# Test 17: Plan Details row uses the documented <span title="..."> badge format
assert_plan_details_row_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  local expected='| 📊 | Plan Details | <span title="Resources to be added">`💫 0` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span> |'
  if [[ "${summary}" != *"${expected}"* ]]; then
    fails+="  summary: Plan Details row not byte-exact\n"
    fails+="    expected substring: ${expected}\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
export input_include_plan_details="true"
run_test "Plan Details row badges are byte-exact <span title=...> shape" assert_plan_details_row_byte_exact

# Test 18: Plan Details with non-zero move/import/remove appends exact <br>… badge lines
assert_plan_details_extras_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  local expected_move='<br><span title="Resources to be moved">`🔀 2` move</span>'
  local expected_import='<br><span title="Resources to be imported">`📥 1` import</span>'
  local expected_remove='<br><span title="Resources to be removed">`⛓️‍💥 3` remove</span>'
  if [[ "${summary}" != *"${expected_move}"* ]]; then
    fails+="  summary: move badge byte-exact mismatch\n"
  fi
  if [[ "${summary}" != *"${expected_import}"* ]]; then
    fails+="  summary: import badge byte-exact mismatch\n"
  fi
  if [[ "${summary}" != *"${expected_remove}"* ]]; then
    fails+="  summary: remove badge byte-exact mismatch\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
export input_include_plan_details="true"
export input_plan_count_move="2"
export input_plan_count_import="1"
export input_plan_count_remove="3"
run_test "Plan Details optional badges (move/import/remove) byte-exact" assert_plan_details_extras_byte_exact

# Test 19: <details>/<summary> heading line is byte-exact
assert_details_heading_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local expected='<details><summary>Show Plan (last 65k characters)</summary>'
  if [[ "${summary}" != *"${expected}"* ]]; then
    echo "  summary: expected exact '<details><summary>...' heading"
    return 1
  fi
  # also lock the terraform code fence language tag
  if [[ "${summary}" != *'```terraform'* ]]; then
    echo "  summary: expected '\`\`\`terraform' code fence language tag"
    return 1
  fi
  return 0
}
reset_defaults
_plan_file=$(mktemp)
echo "Resource actions are indicated with the following symbols:" > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
run_test "<details> heading and 'terraform' code fence tag are byte-exact" assert_details_heading_byte_exact
rm -f "${_plan_file}"

# Test 20: Footer line is byte-exact (down to the comma/space separators and backtick escapes)
assert_footer_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local expected='*Pusher: @test-user, Action: `pull_request`, Workflow: `Terraform CI`, Job log: [link](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)*'
  if [[ "${summary}" != *"${expected}"* ]]; then
    echo "  summary: footer byte-exact mismatch"
    echo "    expected: ${expected}"
    return 1
  fi
  return 0
}
reset_defaults
run_test "Footer line is byte-exact" assert_footer_byte_exact

# Test 21: "Plan not available 🤷‍♀️" is the byte-exact fallback (incl. emoji)
assert_plan_not_available_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local expected='Plan not available 🤷‍♀️'
  if [[ "${summary}" != *"${expected}"* ]]; then
    echo "  summary: expected exact fallback 'Plan not available 🤷‍♀️' (incl. emoji)"
    return 1
  fi
  return 0
}
reset_defaults
run_test "'Plan not available 🤷‍♀️' fallback is byte-exact (incl. emoji)" assert_plan_not_available_byte_exact

# Test 22: 'cancelled' outcome renders as <kbd>cancelled</kbd>
assert_cancelled_kbd() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'<kbd>cancelled</kbd>'* ]]; then
    echo "  summary: expected '<kbd>cancelled</kbd>'"
    return 1
  fi
  return 0
}
reset_defaults
export input_status_plan="cancelled"
run_test "Non-success outcome 'cancelled' renders as <kbd>cancelled</kbd>" assert_cancelled_kbd

# Test 23: 'skipped' outcome renders as <kbd>skipped</kbd>
assert_skipped_kbd() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'<kbd>skipped</kbd>'* ]]; then
    echo "  summary: expected '<kbd>skipped</kbd>'"
    return 1
  fi
  return 0
}
reset_defaults
export input_status_plan="skipped"
run_test "Non-success outcome 'skipped' renders as <kbd>skipped</kbd>" assert_skipped_kbd

# Test 24: empty outcome string still passes through format-status as <kbd></kbd>
# (Non-success branch is taken; the raw value is whatever was passed.)
assert_empty_outcome_kbd() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'<kbd></kbd>'* ]]; then
    echo "  summary: expected '<kbd></kbd>' for empty outcome string"
    return 1
  fi
  return 0
}
reset_defaults
export input_status_plan=""
run_test "Empty outcome string renders as <kbd></kbd> (non-success branch)" assert_empty_outcome_kbd

# Test 25: Plan extract source precedence — txt file wins over console file
assert_txt_wins_over_console() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *"FROM_TXT"* ]]; then
    echo "  summary: expected txt-file content 'FROM_TXT' to win"
    return 1
  fi
  if [[ "${summary}" == *"FROM_CONSOLE"* ]]; then
    echo "  summary: console-file content 'FROM_CONSOLE' must not appear when txt file is present"
    return 1
  fi
  return 0
}
reset_defaults
_txt_file=$(mktemp)
_console_file=$(mktemp)
echo "FROM_TXT line of plan content" > "${_txt_file}"
cat > "${_console_file}" <<'EOF'
Terraform used the selected providers to generate the following execution plan.
FROM_CONSOLE line of plan content
EOF
export input_plan_txt_output_file="${_txt_file}"
export input_plan_console_file="${_console_file}"
run_test "Plan extract source precedence: txt file wins over console file" assert_txt_wins_over_console
rm -f "${_txt_file}" "${_console_file}"

# Test 26: Plan extract is capped at 65000 chars regardless of source
assert_plan_capped_at_65k() {
  local prefix="${1}"
  local summary="${2}"
  # Extract only the code-fence content
  local code_block
  code_block=$(echo "${summary}" | awk '/^```terraform$/{flag=1;next}/^```$/{flag=0}flag')
  local len=${#code_block}
  if [[ ${len} -gt 65000 ]]; then
    echo "  summary: plan code block exceeded 65000 chars (got ${len})"
    return 1
  fi
  # Should be exactly 65000 or just under (tail -c trims at byte boundary; emoji-free content so chars == bytes)
  if [[ ${len} -lt 64000 ]]; then
    echo "  summary: plan code block unexpectedly short (got ${len}, expected near 65000)"
    return 1
  fi
  return 0
}
reset_defaults
_huge_file=$(mktemp)
# Generate ~100k of single-byte-per-char content
yes "abcdefghij" | head -c 100000 > "${_huge_file}"
export input_plan_txt_output_file="${_huge_file}"
run_test "Plan extract is capped at 65000 chars" assert_plan_capped_at_65k
rm -f "${_huge_file}"

# Test 27: Refresh-line stripping in console-file path uses the exact sed pattern
# Lines before "Terraform used the selected providers to generate the following execution"
# must be dropped; the marker line itself and everything after kept.
assert_console_refresh_stripping_exact() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  if [[ "${summary}" == *"NOISE_BEFORE_MARKER"* ]]; then
    fails+="  summary: refresh-noise line was NOT stripped (NOISE_BEFORE_MARKER leaked through)\n"
  fi
  if [[ "${summary}" != *"Terraform used the selected providers"* ]]; then
    fails+="  summary: marker line itself must be retained\n"
  fi
  if [[ "${summary}" != *"AFTER_MARKER_LINE"* ]]; then
    fails+="  summary: lines AFTER the marker must be retained\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
_console_file=$(mktemp)
cat > "${_console_file}" <<'EOF'
NOISE_BEFORE_MARKER azurerm_resource.foo: Reading...
NOISE_BEFORE_MARKER azurerm_resource.foo: Read complete after 1s

Terraform used the selected providers to generate the following execution plan.
AFTER_MARKER_LINE will appear in the output.
EOF
export input_plan_console_file="${_console_file}"
run_test "Console-file refresh-stripping retains marker + after, drops before" assert_console_refresh_stripping_exact
rm -f "${_console_file}"

# --------------------------------------------------
# Grouped-mode tests (pr-comment-group is non-empty).
# Verify the new branch: validation table omitted, "Part of group ..."
# note prepended, prefix unchanged. See docs/Workflow-pr-comments.md §3.2.
# --------------------------------------------------

# Test 28: Grouped mode — prefix is byte-identical to ungrouped mode
# This is the §6.2 prefix-continuity invariant.
assert_grouped_prefix_unchanged() {
  local prefix="${1}"
  local summary="${2}"
  local expected='### Terraform validation summary for environment: `dev`'
  if [[ "${prefix}" != "${expected}" ]]; then
    echo "  prefix: byte-exact mismatch — grouped mode must keep the same prefix as ungrouped"
    echo "    expected: ${expected}"
    echo "    actual:   ${prefix}"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
run_test "Grouped mode: prefix is byte-identical to ungrouped mode" assert_grouped_prefix_unchanged

# Test 29: Grouped mode — validation table is OMITTED from body
assert_grouped_table_omitted() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  # No standard row labels should appear
  local forbidden_rows=(
    "| ⚙️ | Initialization |"
    "| 🔒 | Lock file |"
    "| 🖌 | Format and Style |"
    "| ✔ | Validate |"
    "| 🧹 | TFLint |"
    "| 📖 | Plan |"
    "|  | Step | Result |"
    "|:---:|---|---|"
  )
  for row in "${forbidden_rows[@]}"; do
    if [[ "${summary}" == *"${row}"* ]]; then
      fails+="  summary: grouped mode must NOT contain row '${row}'\n"
    fi
  done
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
run_test "Grouped mode: validation table is omitted from per-env body" assert_grouped_table_omitted

# Test 30: Grouped mode — "Part of group ..." pointer is prepended (byte-exact)
assert_grouped_note_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local expected='> Part of group `dev-group` — see the grouped summary below.'
  if [[ "${summary}" != *"${expected}"* ]]; then
    echo "  summary: expected byte-exact pointer"
    echo "    expected: ${expected}"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
run_test "Grouped mode: 'Part of group <name>' pointer is byte-exact" assert_grouped_note_byte_exact

# Test 31: Grouped mode — group name is properly escaped in the note (different group name)
assert_grouped_note_uses_input_group() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'> Part of group `prod-norge` — see the grouped summary below.'* ]]; then
    echo "  summary: grouped note should reflect the configured group name 'prod-norge'"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="prod-norge"
run_test "Grouped mode: note carries the configured group name" assert_grouped_note_uses_input_group

# Test 32: Grouped mode — plan extract still rendered when plan file present
assert_grouped_plan_extract_kept() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  if [[ "${summary}" != *'<details><summary>Show Plan (last 65k characters)</summary>'* ]]; then
    fails+="  summary: grouped mode must still render the <details> plan extract block\n"
  fi
  if [[ "${summary}" != *'GROUPED_PLAN_BODY'* ]]; then
    fails+="  summary: grouped mode must still include plan body content\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
_plan_file=$(mktemp)
echo "GROUPED_PLAN_BODY content of the plan" > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
run_test "Grouped mode: plan extract is kept" assert_grouped_plan_extract_kept
rm -f "${_plan_file}"

# Test 33: Grouped mode — "Plan not available" fallback works (no plan file)
assert_grouped_plan_not_available() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'Plan not available 🤷‍♀️'* ]]; then
    echo "  summary: grouped mode should still produce the 'Plan not available 🤷‍♀️' fallback"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
run_test "Grouped mode: 'Plan not available 🤷‍♀️' fallback still works" assert_grouped_plan_not_available

# Test 34: Grouped mode — footer is unchanged
assert_grouped_footer_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local expected='*Pusher: @test-user, Action: `pull_request`, Workflow: `Terraform CI`, Job log: [link](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)*'
  if [[ "${summary}" != *"${expected}"* ]]; then
    echo "  summary: grouped mode footer byte-exact mismatch"
    echo "    expected: ${expected}"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
run_test "Grouped mode: footer is byte-exact (same as ungrouped)" assert_grouped_footer_byte_exact

# Test 35: Grouped mode — include-plan-details=true does NOT cause Plan Details row to appear
# (plan-details belong in the per-group comment, not the per-env grouped comment)
assert_grouped_plan_details_row_omitted() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" == *"Plan Details"* ]]; then
    echo "  summary: grouped mode must NOT render the Plan Details row even when include-plan-details=true"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
export input_include_plan_details="true"
export input_plan_count_add="5"
export input_plan_count_change="2"
export input_plan_count_destroy="1"
run_test "Grouped mode: Plan Details row is omitted even when include-plan-details=true" assert_grouped_plan_details_row_omitted

# Test 36: Grouped mode — full body byte-exact (no plan file, default counts)
# Strongest grouped-mode contract guard, parallel to test #14 for ungrouped.
assert_grouped_full_body_golden() {
  local prefix="${1}"
  local summary="${2}"
  local expected
  expected=$(cat <<'EOF'
### Terraform validation summary for environment: `dev`

> Part of group `dev-group` — see the grouped summary below.

Plan not available 🤷‍♀️

*Pusher: @test-user, Action: `pull_request`, Workflow: `Terraform CI`, Job log: [link](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)*
EOF
)
  if [[ "${summary}" != "${expected}" ]]; then
    echo "  summary: grouped mode byte-exact mismatch (diff below)"
    diff <(echo "${expected}") <(echo "${summary}") | sed 's/^/    /'
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
run_test "Grouped mode: full body byte-exact golden" assert_grouped_full_body_golden

# Test 37: Empty pr-comment-group falls back to ungrouped behavior
# This is the §6 backwards-compat invariant — the default value must not change behavior.
assert_empty_group_acts_ungrouped() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  # Must contain the full table (ungrouped shape)
  if [[ "${summary}" != *"| ⚙️ | Initialization |"* ]]; then
    fails+="  summary: empty pr-comment-group must render full validation table (got grouped shape?)\n"
  fi
  # Must NOT contain the grouped "Part of group" note
  if [[ "${summary}" == *"Part of group"* ]]; then
    fails+="  summary: empty pr-comment-group must NOT add 'Part of group' note\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group=""
run_test "Empty pr-comment-group falls back to ungrouped behavior" assert_empty_group_acts_ungrouped

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
