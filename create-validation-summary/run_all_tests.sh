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
  # plan-count-total: default to empty so old tests that don't set it
  # exercise the pre-v0.24 fallback "Show Plan (last 65k characters)" branch.
  # Tests that want the new no-changes / N-changes branches set this
  # explicitly.
  export input_plan_count_total=""
  # plan-has-output-only-changes: default to 'false'. Only the output-only
  # branch test overrides this.
  export input_plan_has_output_only_changes="false"
  # plan-time: default 'N/A' matches the action.yml default and is what the
  # Plan time row renders when terraform-plan didn't supply a duration.
  export input_plan_time="N/A"
  # plan-tag-comment-id: empty default → legacy footer-style head body.
  # Tests that exercise the Links-row branch override this with a fake id.
  export input_plan_tag_comment_id=""
  export input_job_check_run_id="87654321"

  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="dsb-norge/github-actions-terraform"
  export GITHUB_RUN_ID="12345678"
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

  # Get outputs (split: head-summary + plan-extract). Most assertions look
  # for substring presence/absence and are agnostic to which output a thing
  # lives in — we pass them a `summary` that concatenates both. Byte-exact
  # golden tests use the explicit head/plan args (3 and 4) instead.
  local actual_head actual_plan
  actual_head=$(get_output "head-summary")
  actual_plan=$(get_output "plan-extract")
  local actual_prefix actual_summary
  actual_prefix=$(echo "${actual_head}" | head -n1)
  actual_summary="${actual_head}
${actual_plan}"

  # Run assertion callback
  local assert_result
  assert_result=$("${assert_fn}" "${actual_prefix}" "${actual_summary}" "${actual_head}" "${actual_plan}" 2>&1)
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

  # Footer is now just the [Job log](url) line (v0.24+).
  if [[ "${summary}" != *'[Job log]('* ]]; then
    fails+="  summary: expected to contain '[Job log](' in footer\n"
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
# Byte-level shape tests for the ungrouped per-env comment.
# These tests pin down the EXACT spec'd output. Any change to comment
# rendering that breaks one of these tests must also update the test
# AND docs/Workflow-pr-comments.md — they exist to catch accidental
# format drift, not to lock the format forever.
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
  local head="${3}"
  local plan="${4}"
  # don't touch the indentation / newlines in the heredocs below
  local expected_head expected_plan
  expected_head=$(cat <<'EOF'
### Terraform validation summary for environment: `dev`
|  | Step | Result |
|:---:|---|---|
| ⚙️ | Initialization | `success` |
| 🔒 | Lock file | `success` |
| 🖌 | Format and Style | `success` |
| ✔ | Validate | `success` |
| 🧹 | TFLint | `success` |
| 📖 | Plan | `success` |
| ⏱ | Plan time | <span title="mm:ss (minutes:seconds)">`N/A`</span> |

[Job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)
EOF
)
  expected_plan=$(cat <<'EOF'
### Terraform plan for environment: `dev`

Plan not available 🤷‍♀️
EOF
)
  if [[ "${head}" != "${expected_head}" ]]; then
    echo "  head-summary: byte-exact mismatch (diff below)"
    diff <(echo "${expected_head}") <(echo "${head}") | sed 's/^/    /'
    return 1
  fi
  if [[ "${plan}" != "${expected_plan}" ]]; then
    echo "  plan-extract: byte-exact mismatch (diff below)"
    diff <(echo "${expected_plan}") <(echo "${plan}") | sed 's/^/    /'
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
    "| ⏱ | Plan time | "
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

# Test 20: Footer is byte-exact — single [Job log](url) line (v0.24+).
# Pusher/action/workflow data was dropped: it's already visible in the
# PR conversation header and on the linked job page.
assert_footer_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local expected='[Job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)'
  if [[ "${summary}" != *"${expected}"* ]]; then
    echo "  summary: footer byte-exact mismatch"
    echo "    expected: ${expected}"
    return 1
  fi
  # Negative: must NOT contain any of the dropped legacy fields.
  for stale in 'Pusher: @' 'Action: `pull_request`' 'Workflow: `'; do
    if [[ "${summary}" == *"${stale}"* ]]; then
      echo "  summary: stale legacy footer field still present: ${stale}"
      return 1
    fi
  done
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

# Test 30: Grouped mode — does NOT emit the legacy "Part of group ..." pointer
# (removed in v0.24; the grouped summary itself anchor-links back to per-env
# comments, so the back-pointer was redundant).
assert_grouped_no_legacy_pointer() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" == *"Part of group"* ]]; then
    echo "  summary: legacy 'Part of group' pointer must be absent in v0.24+"
    return 1
  fi
  # Sanity: the group name should NOT appear anywhere in the per-env body
  # either — the env doesn't carry group meta in its rendered comment.
  if [[ "${summary}" == *"dev-group"* ]]; then
    echo "  summary: group name should not leak into per-env body"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
run_test "Grouped mode: legacy 'Part of group' pointer absent" assert_grouped_no_legacy_pointer

# Test 31: Grouped mode — even with a different group name, no pointer is emitted
# (regression guard for the v0.23 → v0.24 transition; covers the case where the
# group name happened to overlap with a footer field in earlier formats).
assert_grouped_pointer_absent_other_group() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" == *"Part of group"* ]]; then
    echo "  summary: 'Part of group' pointer must be absent regardless of group name"
    return 1
  fi
  if [[ "${summary}" == *"prod-norge"* ]]; then
    echo "  summary: group name 'prod-norge' should not leak into per-env body"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="prod-norge"
run_test "Grouped mode: pointer absent regardless of group name" assert_grouped_pointer_absent_other_group

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

# Test 34: Grouped mode — footer is byte-exact and matches ungrouped (the
# condensed v0.24+ [Job log](url) line). No mode-dependent footer divergence.
assert_grouped_footer_byte_exact() {
  local prefix="${1}"
  local summary="${2}"
  local expected='[Job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)'
  if [[ "${summary}" != *"${expected}"* ]]; then
    echo "  summary: grouped mode footer byte-exact mismatch"
    echo "    expected: ${expected}"
    return 1
  fi
  for stale in 'Pusher: @' 'Action: `pull_request`' 'Workflow: `'; do
    if [[ "${summary}" == *"${stale}"* ]]; then
      echo "  summary: grouped mode still carrying legacy footer field: ${stale}"
      return 1
    fi
  done
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
  local head="${3}"
  local plan="${4}"
  local expected_head expected_plan
  expected_head=$(cat <<'EOF'
### Terraform validation summary for environment: `dev`

[Job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)
EOF
)
  expected_plan=$(cat <<'EOF'
### Terraform plan for environment: `dev`

Plan not available 🤷‍♀️
EOF
)
  if [[ "${head}" != "${expected_head}" ]]; then
    echo "  head-summary: grouped mode byte-exact mismatch (diff below)"
    diff <(echo "${expected_head}") <(echo "${head}") | sed 's/^/    /'
    return 1
  fi
  if [[ "${plan}" != "${expected_plan}" ]]; then
    echo "  plan-extract: grouped mode byte-exact mismatch (diff below)"
    diff <(echo "${expected_plan}") <(echo "${plan}") | sed 's/^/    /'
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
# Plan-count-total branching (v0.24+).
# Three rendering modes for the plan-extract block based on count-total:
#   numeric 0   → 'Plan: no changes ✅' (plain text, no <details>)
#   numeric N>0 → '<details><summary>Plan: N changes ℹ️</summary>…'
#   '' or '?'   → fallback to legacy 'Show Plan (last 65k characters)'
# --------------------------------------------------

# Test 38: count-total=0 → 'Plan: no changes ✅' replaces the <details> block
assert_no_changes_short_circuit() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *$'\n'$'\n'"Plan: no changes ✅"* ]]; then
    echo "  summary: expected 'Plan: no changes ✅' line"
    return 1
  fi
  # Must NOT contain a <details> block for the plan when count-total=0
  if [[ "${summary}" == *"<details><summary>Plan:"* ]] || [[ "${summary}" == *"<details><summary>Show Plan"* ]]; then
    echo "  summary: <details> block must be omitted when count-total=0"
    return 1
  fi
  return 0
}
reset_defaults
_plan_file=$(mktemp)
echo "No changes. Your infrastructure matches the configuration." > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total="0"
run_test "count-total=0 → 'Plan: no changes ✅' short-circuit" assert_no_changes_short_circuit
rm -f "${_plan_file}"

# Test 39: count-total=N>0 → <details> summary becomes 'Plan: N changes ℹ️'
assert_changes_summary_with_count() {
  local prefix="${1}"
  local summary="${2}"
  local expected='<details><summary>Plan: 7 changes ℹ️</summary>'
  if [[ "${summary}" != *"${expected}"* ]]; then
    echo "  summary: expected '${expected}'"
    return 1
  fi
  # Must NOT contain the legacy fallback summary
  if [[ "${summary}" == *'Show Plan (last 65k characters)'* ]]; then
    echo "  summary: legacy fallback summary should not appear when count-total>0"
    return 1
  fi
  return 0
}
reset_defaults
_plan_file=$(mktemp)
echo "some plan output body content here" > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total="7"
run_test "count-total=N>0 → '<details><summary>Plan: N changes ℹ️</summary>'" assert_changes_summary_with_count
rm -f "${_plan_file}"

# Test 40: count-total empty → legacy 'Show Plan (last 65k characters)' fallback
assert_count_empty_falls_back_to_legacy_summary() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'<details><summary>Show Plan (last 65k characters)</summary>'* ]]; then
    echo "  summary: expected legacy 'Show Plan (last 65k characters)' fallback when count-total is empty"
    return 1
  fi
  return 0
}
reset_defaults
_plan_file=$(mktemp)
echo "some plan body" > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total=""
run_test "count-total='' → legacy 'Show Plan (last 65k characters)' fallback" assert_count_empty_falls_back_to_legacy_summary
rm -f "${_plan_file}"

# Test 41: count-total='?' (parse failed) → legacy fallback too
assert_count_question_mark_falls_back_to_legacy_summary() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'<details><summary>Show Plan (last 65k characters)</summary>'* ]]; then
    echo "  summary: expected legacy fallback when count-total='?'"
    return 1
  fi
  return 0
}
reset_defaults
_plan_file=$(mktemp)
echo "some plan body" > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total="?"
run_test "count-total='?' → legacy 'Show Plan (last 65k characters)' fallback" assert_count_question_mark_falls_back_to_legacy_summary
rm -f "${_plan_file}"

# Test 42: count-total=0 in grouped mode also short-circuits
assert_grouped_no_changes_short_circuit() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *"Plan: no changes ✅"* ]]; then
    echo "  summary: grouped mode with count-total=0 should also short-circuit"
    return 1
  fi
  # And still no validation table (it's in the per-group comment)
  if [[ "${summary}" == *'| ⚙️ | Initialization'* ]]; then
    echo "  summary: grouped mode must still omit validation table"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
_plan_file=$(mktemp)
echo "No changes." > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total="0"
run_test "Grouped mode + count-total=0 → 'Plan: no changes ✅' short-circuit" assert_grouped_no_changes_short_circuit
rm -f "${_plan_file}"

# Test 43: count-total=0 but NO plan file → 'Plan not available' wins over 'no changes ✅'
assert_no_plan_file_beats_zero_total() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'Plan not available 🤷‍♀️'* ]]; then
    echo "  summary: 'Plan not available' must win when no plan file even if count-total=0"
    return 1
  fi
  if [[ "${summary}" == *'Plan: no changes ✅'* ]]; then
    echo "  summary: 'Plan: no changes ✅' must NOT appear when no plan file"
    return 1
  fi
  return 0
}
reset_defaults
export input_plan_count_total="0"
# Note: no plan file is set
run_test "count-total=0 + no plan file → 'Plan not available' wins" assert_no_plan_file_beats_zero_total

# Test 44: Golden no-changes body (ungrouped, count-total=0, with plan file)
assert_golden_no_changes_body() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local plan="${4}"
  local expected_head expected_plan
  expected_head=$(cat <<'EOF'
### Terraform validation summary for environment: `dev`
|  | Step | Result |
|:---:|---|---|
| ⚙️ | Initialization | `success` |
| 🔒 | Lock file | `success` |
| 🖌 | Format and Style | `success` |
| ✔ | Validate | `success` |
| 🧹 | TFLint | `success` |
| 📖 | Plan | `success` |
| ⏱ | Plan time | <span title="mm:ss (minutes:seconds)">`N/A`</span> |

[Job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)
EOF
)
  expected_plan=$(cat <<'EOF'
### Terraform plan for environment: `dev`

Plan: no changes ✅
EOF
)
  if [[ "${head}" != "${expected_head}" ]]; then
    echo "  head-summary: golden no-changes byte-exact mismatch (diff below)"
    diff <(echo "${expected_head}") <(echo "${head}") | sed 's/^/    /'
    return 1
  fi
  if [[ "${plan}" != "${expected_plan}" ]]; then
    echo "  plan-extract: golden no-changes byte-exact mismatch (diff below)"
    diff <(echo "${expected_plan}") <(echo "${plan}") | sed 's/^/    /'
    return 1
  fi
  return 0
}
reset_defaults
_plan_file=$(mktemp)
echo "No changes." > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total="0"
run_test "Golden body — ungrouped, count-total=0, all success" assert_golden_no_changes_body
rm -f "${_plan_file}"

# Test 45: count-total=0 + output-only changes → keep <details> with
# 'Plan: output-only changes ℹ️' summary (no short-circuit to 'no changes ✅').
# Regression guard for the v0.23→v0.24 transition: parse-terraform-plan zeros
# out resource counts in the output-only case, and a naive count-total==0
# check would otherwise hide the (useful) plan extract.
assert_output_only_keeps_details() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  if [[ "${summary}" != *'<details><summary>Plan: output-only changes ℹ️</summary>'* ]]; then
    fails+="  summary: expected output-only <details><summary> line\n"
  fi
  # Must NOT short-circuit to 'no changes ✅'
  if [[ "${summary}" == *'Plan: no changes ✅'* ]]; then
    fails+="  summary: must NOT short-circuit when output-only changes are present\n"
  fi
  # Plan extract content should still be present
  if [[ "${summary}" != *'OUTPUT_ONLY_BODY'* ]]; then
    fails+="  summary: plan body content should be inside the <details> block\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
_plan_file=$(mktemp)
cat > "${_plan_file}" <<'PLAN'
Changes to Outputs:
  ~ my_arn = (known after apply)

OUTPUT_ONLY_BODY marker for assertion.

You can apply this change to apply the configuration without changing any real infrastructure.
PLAN
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total="0"
export input_plan_has_output_only_changes="true"
run_test "count-total=0 + has-output-only-changes=true → keep <details>" assert_output_only_keeps_details
rm -f "${_plan_file}"

# Test 46: count-total=N>0 + has-output-only-changes=true (defensive — shouldn't
# happen in practice since parse-terraform-plan only sets output-only when
# resource counts are 0) → the N-changes branch wins. We test this so callers
# composing the inputs themselves get well-defined behavior.
assert_resource_changes_dominate_over_output_only() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'<details><summary>Plan: 3 changes ℹ️</summary>'* ]]; then
    echo "  summary: when count-total>0 the N-changes branch wins regardless of output-only flag"
    return 1
  fi
  if [[ "${summary}" == *'output-only changes'* ]]; then
    echo "  summary: must not render the output-only summary when count-total>0"
    return 1
  fi
  return 0
}
reset_defaults
_plan_file=$(mktemp)
echo "some plan body" > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total="3"
export input_plan_has_output_only_changes="true"
run_test "count-total>0 dominates over has-output-only-changes=true" assert_resource_changes_dominate_over_output_only
rm -f "${_plan_file}"

# Test 47: count-total=0 + has-output-only-changes=true + grouped mode
# → still keeps <details> with output-only summary (group mode doesn't suppress
# the output-only short-circuit decision).
assert_grouped_output_only_keeps_details() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'<details><summary>Plan: output-only changes ℹ️</summary>'* ]]; then
    echo "  summary: grouped mode with output-only changes must still show <details>"
    return 1
  fi
  # No validation table (group mode invariant)
  if [[ "${summary}" == *'| ⚙️ | Initialization'* ]]; then
    echo "  summary: grouped mode must still omit the validation table"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
_plan_file=$(mktemp)
echo "output diff content" > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
export input_plan_count_total="0"
export input_plan_has_output_only_changes="true"
run_test "Grouped + count-total=0 + output-only → keep <details>" assert_grouped_output_only_keeps_details
rm -f "${_plan_file}"

# --------------------------------------------------
# Plan time row (added in v0.X — terraform-plan now publishes wall-clock
# duration of the plan command; create-validation-summary renders it as
# a trailing row of the ungrouped validation table).
# --------------------------------------------------

# Plan time row: renders mm:ss when input provided, wrapped in a
# <span title="mm:ss (minutes:seconds)"> so desktop hover surfaces the unit.
assert_plan_time_row_with_value() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'| ⏱ | Plan time | <span title="mm:ss (minutes:seconds)">`1:23`</span> |'* ]]; then
    echo "  summary: expected backtick-wrapped value cell with format tooltip"
    return 1
  fi
  return 0
}
reset_defaults
export input_plan_time="1:23"
run_test "Plan time row renders backtick-wrapped mm:ss value with tooltip" assert_plan_time_row_with_value

# Plan time row: defaults to N/A when caller passes nothing (matches
# the create-validation-summary input default and plan-count-* convention).
# Tooltip wrapper applies to the N/A branch too so hover-discovery works
# even when there's no timing recorded.
assert_plan_time_row_default_na() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'| ⏱ | Plan time | <span title="mm:ss (minutes:seconds)">`N/A`</span> |'* ]]; then
    echo "  summary: expected default N/A cell with format tooltip"
    return 1
  fi
  return 0
}
reset_defaults
run_test "Plan time row defaults to 'N/A' with tooltip when input not supplied" assert_plan_time_row_default_na

# Plan time row: rendered even when Plan Details is off (Plan time row is
# always emitted in ungrouped mode; Plan Details row is conditional).
assert_plan_time_without_plan_details() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  if [[ "${summary}" != *'| ⏱ | Plan time | <span title="mm:ss (minutes:seconds)">`0:45`</span> |'* ]]; then
    fails+="  summary: expected Plan time row (with tooltip) to render without Plan Details\n"
  fi
  if [[ "${summary}" == *"Plan Details"* ]]; then
    fails+="  summary: Plan Details row should NOT appear when include-plan-details=false\n"
  fi
  if [[ -n "${fails}" ]]; then
    echo -e "${fails}"
    return 1
  fi
  return 0
}
reset_defaults
export input_plan_time="0:45"
export input_include_plan_details="false"
run_test "Plan time row renders even when Plan Details row is omitted" assert_plan_time_without_plan_details

# Plan time row: omitted in grouped mode (whole validation table is
# omitted from per-env body in grouped mode — see docs/Workflow-pr-comments.md §3).
assert_plan_time_omitted_in_grouped_mode() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" == *"Plan time"* ]]; then
    echo "  summary: Plan time row must NOT appear in grouped per-env body"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
export input_plan_time="2:00"
run_test "Plan time row omitted in grouped mode (table moves to per-group comment)" assert_plan_time_omitted_in_grouped_mode

# Plan time row placement: appears AFTER Plan Details when both are present
# (per design — Plan time goes below Plan Details).
assert_plan_time_after_plan_details() {
  local prefix="${1}"
  local summary="${2}"
  # Extract the bit between Plan Details opener and the blank line that
  # closes the table. Plan time row must be after Plan Details in that span.
  local pd_pos pt_pos
  pd_pos=$(echo "${summary}" | grep -n '| 📊 | Plan Details |' | head -n1 | cut -d: -f1)
  pt_pos=$(echo "${summary}" | grep -n '| ⏱ | Plan time |'   | head -n1 | cut -d: -f1)
  if [ -z "${pd_pos}" ] || [ -z "${pt_pos}" ]; then
    echo "  summary: expected both Plan Details and Plan time rows present (pd=${pd_pos}, pt=${pt_pos})"
    return 1
  fi
  if [ "${pt_pos}" -le "${pd_pos}" ]; then
    echo "  summary: Plan time row (line ${pt_pos}) must appear AFTER Plan Details (line ${pd_pos})"
    return 1
  fi
  return 0
}
reset_defaults
export input_include_plan_details="true"
export input_plan_count_add="1"
export input_plan_count_change="0"
export input_plan_count_destroy="0"
export input_plan_time="3:14"
run_test "Plan time row appears after Plan Details when both rendered" assert_plan_time_after_plan_details

# --------------------------------------------------
# Links row inside the per-env head table (added when caller supplies
# plan-tag-comment-id). Mirrors the per-group head's Links column shape
# so reviewers learn one navigation pattern. When the Links row is
# rendered, the standalone [Job log] footer is dropped (the same link
# lives inside the table cell).
# --------------------------------------------------

assert_links_row_rendered_ungrouped() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local expected_cell='| 🔗 | Links | [log extract](#issuecomment-99887766)<br>[job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs) |'
  if [[ "${head}" != *"${expected_cell}"* ]]; then
    echo "  head-summary: expected Links row with anchor + job log:"
    echo "    expected substring: ${expected_cell}"
    return 1
  fi
  return 0
}
reset_defaults
export input_plan_tag_comment_id="99887766"
run_test "Links row rendered in ungrouped head when plan-tag-comment-id supplied" assert_links_row_rendered_ungrouped

assert_footer_dropped_when_links_row_rendered() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  if [[ "${head}" == *'[Job log]('* ]]; then
    echo "  head-summary: '[Job log]' footer must NOT appear when Links row is rendered"
    echo "  (the same link lives inside the Links cell)"
    return 1
  fi
  # The job log URL should STILL be in the head — but inside the Links row cell.
  if [[ "${head}" != *'[job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)'* ]]; then
    echo "  head-summary: expected '[job log](url)' inside the Links cell"
    return 1
  fi
  return 0
}
reset_defaults
export input_plan_tag_comment_id="99887766"
run_test "[Job log] footer dropped when Links row is rendered" assert_footer_dropped_when_links_row_rendered

assert_links_row_omitted_when_no_id() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  if [[ "${head}" == *'| 🔗 | Links |'* ]]; then
    echo "  head-summary: Links row must NOT be rendered when plan-tag-comment-id is empty"
    return 1
  fi
  # Legacy footer must be there in this case
  if [[ "${head}" != *'[Job log]('* ]]; then
    echo "  head-summary: expected legacy '[Job log]' footer when no plan-tag-comment-id"
    return 1
  fi
  return 0
}
reset_defaults
# input_plan_tag_comment_id intentionally left at default ("")
run_test "Links row omitted (legacy footer kept) when plan-tag-comment-id is empty" assert_links_row_omitted_when_no_id

assert_links_row_omitted_in_grouped_mode() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  # In grouped mode the validation table is omitted entirely, so the Links
  # row has no table to live in. Caller supplies the id anyway (matrix
  # passes it uniformly) — action must ignore it for grouped envs and
  # keep the legacy minimal grouped-mode body (H3 + footer).
  if [[ "${head}" == *'| 🔗 | Links |'* ]]; then
    echo "  head-summary: Links row must NOT appear in grouped mode"
    return 1
  fi
  if [[ "${head}" != *'[Job log]('* ]]; then
    echo "  head-summary: grouped mode still emits the [Job log] footer"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
export input_plan_tag_comment_id="99887766"
run_test "Links row omitted in grouped mode even when plan-tag-comment-id supplied" assert_links_row_omitted_in_grouped_mode

assert_links_row_appears_after_plan_time() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local pt_pos lk_pos
  pt_pos=$(echo "${head}" | grep -n '| ⏱ | Plan time |' | head -n1 | cut -d: -f1)
  lk_pos=$(echo "${head}" | grep -n '| 🔗 | Links |'   | head -n1 | cut -d: -f1)
  if [ -z "${pt_pos}" ] || [ -z "${lk_pos}" ]; then
    echo "  expected both Plan time and Links rows present (pt=${pt_pos}, lk=${lk_pos})"
    return 1
  fi
  if [ "${lk_pos}" -le "${pt_pos}" ]; then
    echo "  Links row (line ${lk_pos}) must appear AFTER Plan time (line ${pt_pos})"
    return 1
  fi
  return 0
}
reset_defaults
export input_plan_tag_comment_id="42424242"
export input_plan_time="0:45"
run_test "Links row sits after Plan time row" assert_links_row_appears_after_plan_time

# --------------------------------------------------
# Warnings row in head + warnings <details> collapser in plan-extract.
# See docs/Plan-warnings.md §6 for the rendered shape.
# --------------------------------------------------

# Helper that writes the same canned warnings markdown to a temp file and
# returns the path, suitable for input_warnings_markdown_file.
make_warnings_md() {
  local content="${1:-default}"
  local tmp
  tmp=$(mktemp)
  case "${content}" in
    default)
      cat >"${tmp}" <<'MD'
### From terraform plan

**Warning: Deprecated attribute**
- source: `.terraform/modules/foo/main.tf:176`

> The attribute is deprecated.

---

MD
      ;;
    multi)
      cat >"${tmp}" <<'MD'
### From terraform init

**Warning: Provider deprecation**

> The provider is deprecated.

---

### From terraform plan

**Warning: Deprecated attribute**
- source: `main.tf:42`

> Body.

---

MD
      ;;
    huge)
      # >60k of dummy warning blocks to exercise the WARN_CAP truncation
      # (WARN_CAP = 60000; each block here is ~95 chars, 1000 blocks ≈ 95k).
      local i
      {
        printf '### From terraform plan\n\n'
        for i in $(seq 1 1000); do
          printf '**Warning: deprecated attribute number %d**\n\n> body line one of warning %d\n> body line two of warning %d\n\n---\n\n' "${i}" "${i}" "${i}"
        done
      } >"${tmp}"
      ;;
  esac
  echo "${tmp}"
}

# Per-test cleanup: created markdown / plan files left in tmp space, fine
# under CI.

assert_warnings_row_present_when_count_positive() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  if [[ "${head}" != *'| ⚠️ | Warnings |'* ]]; then
    echo "  head-summary: expected '⚠️ Warnings' row to be present"
    return 1
  fi
  if [[ "${head}" != *'⚠️ 3</span>'* ]]; then
    echo "  head-summary: expected count badge '⚠️ 3'"
    return 1
  fi
  return 0
}
reset_defaults
export input_warning_count="3"
export input_warnings_markdown_file=$(make_warnings_md default)
run_test "Warnings row rendered in ungrouped head when warning-count > 0" assert_warnings_row_present_when_count_positive

assert_warnings_row_absent_when_count_zero() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  if [[ "${head}" == *'| ⚠️ | Warnings |'* ]]; then
    echo "  head-summary: warnings row must be absent when count is 0"
    return 1
  fi
  return 0
}
reset_defaults
export input_warning_count="0"
export input_warnings_markdown_file=""
run_test "Warnings row absent when warning-count is 0" assert_warnings_row_absent_when_count_zero

assert_warnings_row_absent_when_count_unset() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  if [[ "${head}" == *'| ⚠️ | Warnings |'* ]]; then
    echo "  head-summary: warnings row must be absent when count is unset"
    return 1
  fi
  return 0
}
reset_defaults
unset input_warning_count
unset input_warnings_markdown_file
run_test "Warnings row absent when warning-count is unset" assert_warnings_row_absent_when_count_unset

assert_warnings_row_absent_when_count_question_mark() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  if [[ "${head}" == *'| ⚠️ | Warnings |'* ]]; then
    echo "  head-summary: warnings row must be absent when count is '?'"
    return 1
  fi
  return 0
}
reset_defaults
export input_warning_count="?"
run_test "Warnings row absent when warning-count is '?'" assert_warnings_row_absent_when_count_question_mark

assert_warnings_row_omitted_in_grouped_mode() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  # Grouped mode skips the entire validation table; the warnings row sits
  # inside that table so it must be absent. The warnings collapser still
  # appears in plan-extract though — checked separately below.
  if [[ "${head}" == *'| ⚠️ | Warnings |'* ]]; then
    echo "  head-summary: warnings row must NOT appear in grouped mode"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
export input_warning_count="3"
export input_warnings_markdown_file=$(make_warnings_md default)
run_test "Warnings row omitted in grouped mode" assert_warnings_row_omitted_in_grouped_mode

assert_warnings_collapser_in_plan_extract() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local plan="${4}"
  if [[ "${plan}" != *'<details><summary>⚠️ 3 warnings</summary>'* ]]; then
    echo "  plan-extract: expected '<details><summary>⚠️ 3 warnings</summary>'"
    return 1
  fi
  if [[ "${plan}" != *'From terraform plan'* ]]; then
    echo "  plan-extract: warning body content missing"
    return 1
  fi
  return 0
}
reset_defaults
export input_warning_count="3"
export input_warnings_markdown_file=$(make_warnings_md default)
run_test "Warnings collapser appended to plan-extract" assert_warnings_collapser_in_plan_extract

assert_warnings_collapser_absent_when_file_empty() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local plan="${4}"
  if [[ "${plan}" == *'⚠️'*' warnings</summary>'* ]]; then
    echo "  plan-extract: warnings collapser must be absent when markdown file is empty"
    return 1
  fi
  return 0
}
reset_defaults
export input_warning_count="0"
export input_warnings_markdown_file=$(mktemp)  # empty file
run_test "Warnings collapser absent when markdown file empty" assert_warnings_collapser_absent_when_file_empty

assert_warnings_collapser_rendered_in_grouped_mode() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local plan="${4}"
  # Per docs/Workflow-pr-comments.md §5.2 the plan-extract is still posted
  # for grouped envs — only the per-env head's validation table is dropped.
  # Warnings collapser must still appear inside plan-extract.
  if [[ "${plan}" != *'⚠️ 2 warnings</summary>'* ]]; then
    echo "  plan-extract: warnings collapser must still appear in grouped mode"
    return 1
  fi
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
export input_warning_count="2"
export input_warnings_markdown_file=$(make_warnings_md multi)
run_test "Warnings collapser appears in plan-extract even in grouped mode" assert_warnings_collapser_rendered_in_grouped_mode

assert_combined_body_under_65k_with_huge_warnings() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local plan="${4}"
  # When warnings exceed WARN_CAP they must be truncated with a clear
  # marker. plan-extract size (the largest of the two outputs) must
  # stay under 65000.
  local plan_size
  plan_size=$(printf '%s' "${plan}" | wc -c)
  if [ "${plan_size}" -gt 65000 ]; then
    echo "  plan-extract size ${plan_size} > 65000 (hard limit)"
    return 1
  fi
  if [[ "${plan}" != *'truncated, warnings exceed'* ]]; then
    echo "  plan-extract: expected truncation marker '_(truncated, warnings exceed …)'"
    return 1
  fi
  return 0
}
reset_defaults
export input_warning_count="700"
export input_warnings_markdown_file=$(make_warnings_md huge)
run_test "Combined body stays under 65k even with huge warnings (warnings truncated)" assert_combined_body_under_65k_with_huge_warnings

assert_plan_trimmed_when_warnings_present() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local plan="${4}"
  # Construct a 50k plan extract + ~5k warnings. Combined raw would be
  # 55k+. Budgeting must shrink the plan-extract to fit; warnings stay
  # intact.
  local plan_size
  plan_size=$(printf '%s' "${plan}" | wc -c)
  if [ "${plan_size}" -gt 65000 ]; then
    echo "  plan-extract size ${plan_size} > 65000"
    return 1
  fi
  # The warnings markdown ("Deprecated attribute") must be intact.
  if [[ "${plan}" != *'Deprecated attribute'* ]]; then
    echo "  warnings markdown should survive budgeting"
    return 1
  fi
  return 0
}
reset_defaults
# Build a ~50k plan extract
_huge_plan_file=$(mktemp)
{
  echo "Terraform used the selected providers to generate the following execution plan"
  yes "  + foo_resource.bar = \"some value here that pads each line to a comfortable width\"" | head -n 1000
  echo "Plan: 1 to add, 0 to change, 0 to destroy."
} >"${_huge_plan_file}"
export input_plan_txt_output_file="${_huge_plan_file}"
export input_plan_count_total="1"
export input_warning_count="3"
export input_warnings_markdown_file=$(make_warnings_md default)
run_test "Plan extract trimmed first when warnings + plan together exceed budget" assert_plan_trimmed_when_warnings_present

assert_warnings_collapser_after_plan_block() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local plan="${4}"
  # Warnings collapser is a SIBLING of the plan-block, positioned AFTER.
  # Find both positions in plan-extract output.
  local plan_block_pos warnings_pos
  plan_block_pos=$(printf '%s' "${plan}" | grep -n 'Plan: no changes ✅' | head -n1 | cut -d: -f1)
  warnings_pos=$(printf '%s' "${plan}" | grep -n '⚠️ 1 warnings</summary>' | head -n1 | cut -d: -f1)
  if [ -z "${plan_block_pos}" ] || [ -z "${warnings_pos}" ]; then
    echo "  expected both plan-block ('Plan: no changes ✅' line ${plan_block_pos:-?}) and warnings collapser (line ${warnings_pos:-?})"
    return 1
  fi
  if [ "${warnings_pos}" -le "${plan_block_pos}" ]; then
    echo "  warnings collapser (line ${warnings_pos}) must appear AFTER plan-block (line ${plan_block_pos})"
    return 1
  fi
  return 0
}
reset_defaults
# 'No changes' plan-block (count-total=0, no output-only). The shape is
# only produced when plan_out is non-empty AND count-total=0 — supply a
# minimal plan file so render_plan_extract doesn't fall back to
# "Plan not available 🤷‍♀️".
_no_changes_plan_file=$(mktemp)
echo "No changes. Your infrastructure matches the configuration." >"${_no_changes_plan_file}"
export input_plan_txt_output_file="${_no_changes_plan_file}"
export input_plan_count_total="0"
export input_warning_count="1"
export input_warnings_markdown_file=$(make_warnings_md default)
run_test "Warnings collapser sits AFTER plan-block in plan-extract" assert_warnings_collapser_after_plan_block

assert_warnings_included_in_legacy_summary() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'⚠️ 2 warnings</summary>'* ]]; then
    echo "  legacy 'summary' output must include the warnings collapser"
    return 1
  fi
  return 0
}
reset_defaults
export input_warning_count="2"
export input_warnings_markdown_file=$(make_warnings_md multi)
run_test "Legacy 'summary' output includes warnings collapser" assert_warnings_included_in_legacy_summary

assert_utf8_preserved_at_truncation_boundary() {
  local prefix="${1}"
  local summary="${2}"
  local head="${3}"
  local plan="${4}"
  # The plan extract must contain valid UTF-8 throughout. If the tail-cut
  # lands mid-codepoint without the line-anchored fix, iconv would fail.
  if ! printf '%s' "${plan}" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    echo "  plan-extract is not valid UTF-8 (truncation likely cut mid-codepoint)"
    return 1
  fi
  return 0
}
reset_defaults
# A plan file padded with em-dashes (3 bytes each in UTF-8) so a naive
# tail -c is overwhelmingly likely to cut mid-codepoint.
_utf8_plan_file=$(mktemp)
{
  echo "Terraform used the selected providers to generate the following execution plan"
  yes "— — — — — — — — — — — — — — — — — — — — — — — — — — — — — — — — — — — —" | head -n 1500
  echo "Plan: 1 to add, 0 to change, 0 to destroy."
} >"${_utf8_plan_file}"
export input_plan_txt_output_file="${_utf8_plan_file}"
export input_plan_count_total="1"
export input_warning_count="3"
export input_warnings_markdown_file=$(make_warnings_md default)
run_test "UTF-8 preserved at truncation boundary" assert_utf8_preserved_at_truncation_boundary

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
