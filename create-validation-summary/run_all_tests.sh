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
  export input_apply_count_import="0"
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
  # output-file-suffix: empty default → files named tf-comment-<env>-head.md
  # / -plan.md. The suffix tests override this.
  export input_output_file_suffix=""
  # Operation blocks (docs/Apply-and-destroy-reporting.md §8.1): every
  # gating status empty, every count 'N/A', every warning count 0 — the
  # action.yml defaults. With these, the head must be byte-identical to
  # the pre-feature output; every golden above asserts exactly that (C1).
  export input_status_apply=""
  export input_status_destroy_plan=""
  export input_status_destroy=""
  export input_apply_time="N/A"
  export input_destroy_plan_time="N/A"
  export input_destroy_time="N/A"
  export input_apply_count_add="N/A"
  export input_apply_count_change="N/A"
  export input_apply_count_destroy="N/A"
  export input_apply_count_total="N/A"
  export input_apply_completed=""
  export input_destroy_plan_count_add="N/A"
  export input_destroy_plan_count_change="N/A"
  export input_destroy_plan_count_destroy="N/A"
  export input_destroy_plan_count_import="N/A"
  export input_destroy_plan_count_move="N/A"
  export input_destroy_plan_count_remove="N/A"
  export input_destroy_plan_count_total="N/A"
  export input_destroy_count_destroy="N/A"
  export input_destroy_count_total="N/A"
  export input_destroy_completed=""
  export input_apply_warning_count="0"
  export input_destroy_plan_warning_count="0"
  export input_destroy_warning_count="0"
  # The init+validate+plan warning inputs were never part of reset_defaults;
  # tests that set them used to be ordered so the leak was harmless. They
  # are reset here so a warning set by one test cannot appear in another's
  # plan tag. The goldens all ran with these empty, so nothing changes for them.
  export input_warning_count="0"
  export input_warnings_markdown_file=""
  # Mode row / banner / extracts / Links (L4a)
  export input_goals_json=""
  export input_apply_console_file=""
  export input_destroy_plan_console_file=""
  export input_destroy_plan_txt_output_file=""
  export input_destroy_console_file=""
  export input_apply_extract_include_outputs="false"
  export input_apply_warnings_markdown_file=""
  export input_destroy_plan_warnings_markdown_file=""
  export input_destroy_warnings_markdown_file=""
  export input_apply_tag_comment_id=""
  export input_destroy_plan_tag_comment_id=""
  export input_destroy_tag_comment_id=""
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

  # Set up fresh GITHUB_OUTPUT and a fresh RUNNER_TEMP (the body files land
  # there; a fresh dir per test means a stale file from a previous test can
  # never satisfy an assertion).
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${_this_script_dir}"

  # Run step in a subshell. No allexport — the action.yml shim deliberately
  # omits it (see the shim comment); the harness matches production.
  local exit_code
  (
    source "${_this_script_dir}/step_create_validation_summary.sh"
  ) > /tmp/test_output.txt 2>&1
  exit_code=$?

  local failed=0
  local failures=""

  if [[ "${exit_code}" -ne 0 ]]; then
    failed=1
    failures+="  exit code: expected 0, got ${exit_code}\n"
  fi

  # Get the two bodies by reading the files named by the *-file outputs.
  # Most assertions look for substring presence/absence and are agnostic to
  # which body a thing lives in — we pass them a `summary` that concatenates
  # both. Byte-exact golden tests use the explicit head/plan args (3 and 4).
  # $(cat) strips trailing newlines exactly as the old multiline-output
  # reader did, so every golden written against the string outputs still
  # holds against the files.
  local actual_head actual_plan head_file plan_file
  head_file=$(get_output "head-summary-file")
  plan_file=$(get_output "plan-extract-file")
  actual_head=""; [ -n "${head_file}" ] && [ -f "${head_file}" ] && actual_head=$(cat "${head_file}")
  actual_plan=""; [ -n "${plan_file}" ] && [ -f "${plan_file}" ] && actual_plan=$(cat "${plan_file}")
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
  rm -rf "${RUNNER_TEMP}"
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

  # Should contain the Plan details row
  if [[ "${summary}" != *"Plan details"* ]]; then
    fails+="  summary: expected to contain 'Plan details'\n"
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

  # Should NOT contain the Plan details row
  if [[ "${summary}" == *"Plan details"* ]]; then
    fails+="  summary: should not contain 'Plan details' when disabled\n"
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
  if [[ "${summary}" != *'| <span title="Lock file">🔒</span> | Lock file | `success` |'* ]]; then
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
  if [[ "${summary}" != *'| <span title="Lock file">🔒</span> | Lock file | <kbd>failure</kbd> |'* ]]; then
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
| <span title="Initialization">⚙️</span> | Initialization | `success` |
| <span title="Lock file">🔒</span> | Lock file | `success` |
| <span title="Format and Style">🖌</span> | Format and Style | `success` |
| <span title="Validate">✔</span> | Validate | `success` |
| <span title="TFLint">🧹</span> | TFLint | `success` |
| <span title="Plan">📖</span> | Plan | `success` |
| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">—</span> |

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
    '| <span title="Initialization">⚙️</span> | Initialization | '
    '| <span title="Lock file">🔒</span> | Lock file | '
    '| <span title="Format and Style">🖌</span> | Format and Style | '
    '| <span title="Validate">✔</span> | Validate | '
    '| <span title="TFLint">🧹</span> | TFLint | '
    '| <span title="Plan">📖</span> | Plan | '
    '| <span title="Plan time">⏱</span> | Plan time | '
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
  local expected='| <span title="Plan details">📊</span> | Plan details | <div align="left"><span title="Resources to be added">`💫 0` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span></div> |'
  if [[ "${summary}" != *"${expected}"* ]]; then
    fails+="  summary: Plan details row not byte-exact\n"
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
    '| <span title="Initialization">⚙️</span> | Initialization |'
    '| <span title="Lock file">🔒</span> | Lock file |'
    '| <span title="Format and Style">🖌</span> | Format and Style |'
    '| <span title="Validate">✔</span> | Validate |'
    '| <span title="TFLint">🧹</span> | TFLint |'
    '| <span title="Plan">📖</span> | Plan |'
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
  if [[ "${summary}" == *"Plan details"* ]]; then
    echo "  summary: grouped mode must NOT render the Plan details row even when include-plan-details=true"
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
  if [[ "${summary}" != *'| <span title="Initialization">⚙️</span> | Initialization |'* ]]; then
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
  local expected='<details><summary>Plan: 4 to add, 2 to change, 1 to destroy ℹ️</summary>'
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
export input_plan_count_add="4"; export input_plan_count_change="2"; export input_plan_count_destroy="1"
run_test "count-total=N>0 → '<details><summary>Plan: A to add, C to change, D to destroy ℹ️</summary>'" assert_changes_summary_with_count
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
  if [[ "${summary}" == *'| <span title="Initialization">⚙️</span> | Initialization'* ]]; then
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
| <span title="Initialization">⚙️</span> | Initialization | `success` |
| <span title="Lock file">🔒</span> | Lock file | `success` |
| <span title="Format and Style">🖌</span> | Format and Style | `success` |
| <span title="Validate">✔</span> | Validate | `success` |
| <span title="TFLint">🧹</span> | TFLint | `success` |
| <span title="Plan">📖</span> | Plan | `success` |
| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">—</span> |

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
  if [[ "${summary}" != *'<details><summary>Plan: 3 to add, 0 to change, 0 to destroy ℹ️</summary>'* ]]; then
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
export input_plan_count_add="3"; export input_plan_count_change="0"; export input_plan_count_destroy="0"
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
  if [[ "${summary}" == *'| <span title="Initialization">⚙️</span> | Initialization'* ]]; then
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
  if [[ "${summary}" != *'| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">`1:23`</span> |'* ]]; then
    echo "  summary: expected backtick-wrapped value cell with format tooltip"
    return 1
  fi
  return 0
}
reset_defaults
export input_plan_time="1:23"
run_test "Plan time row renders backtick-wrapped mm:ss value with tooltip" assert_plan_time_row_with_value

# Plan time row: defaults to the em-dash '—' (not backtick-wrapped) when
# caller passes nothing — matching the grouped head's _render_plan_time_cell.
# The action.yml input default is the literal 'N/A', which the renderer maps
# to '—'. Tooltip wrapper applies to the em-dash branch too so hover-
# discovery works even when there's no timing recorded.
assert_plan_time_row_default_na() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">—</span> |'* ]]; then
    echo "  summary: expected default em-dash cell with format tooltip"
    return 1
  fi
  return 0
}
reset_defaults
run_test "Plan time row defaults to em-dash with tooltip when input not supplied" assert_plan_time_row_default_na

# Plan time row: rendered even when Plan Details is off (Plan time row is
# always emitted in ungrouped mode; Plan Details row is conditional).
assert_plan_time_without_plan_details() {
  local prefix="${1}"
  local summary="${2}"
  local fails=""
  if [[ "${summary}" != *'| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">`0:45`</span> |'* ]]; then
    fails+="  summary: expected Plan time row (with tooltip) to render without Plan details\n"
  fi
  if [[ "${summary}" == *"Plan details"* ]]; then
    fails+="  summary: Plan details row should NOT appear when include-plan-details=false\n"
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
  pd_pos=$(echo "${summary}" | grep -n '| Plan details |' | head -n1 | cut -d: -f1)
  pt_pos=$(echo "${summary}" | grep -n '| Plan time |'   | head -n1 | cut -d: -f1)
  if [ -z "${pd_pos}" ] || [ -z "${pt_pos}" ]; then
    echo "  summary: expected both Plan details and Plan time rows present (pd=${pd_pos}, pt=${pt_pos})"
    return 1
  fi
  if [ "${pt_pos}" -le "${pd_pos}" ]; then
    echo "  summary: Plan time row (line ${pt_pos}) must appear AFTER Plan details (line ${pd_pos})"
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
  local expected_cell='| <span title="Links">🔗</span> | Links | [log extract](#issuecomment-99887766)<br>[job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs) |'
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
  if [[ "${head}" == *'| <span title="Links">🔗</span> | Links |'* ]]; then
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
  if [[ "${head}" == *'| <span title="Links">🔗</span> | Links |'* ]]; then
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
  pt_pos=$(echo "${head}" | grep -n '| Plan time |' | head -n1 | cut -d: -f1)
  lk_pos=$(echo "${head}" | grep -n '| Links |'   | head -n1 | cut -d: -f1)
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
  if [[ "${head}" != *'| <span title="Warnings">⚠️</span> | Warnings |'* ]]; then
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
  if [[ "${head}" == *'| <span title="Warnings">⚠️</span> | Warnings |'* ]]; then
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
  if [[ "${head}" == *'| <span title="Warnings">⚠️</span> | Warnings |'* ]]; then
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
  if [[ "${head}" == *'| <span title="Warnings">⚠️</span> | Warnings |'* ]]; then
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
  if [[ "${head}" == *'| <span title="Warnings">⚠️</span> | Warnings |'* ]]; then
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

assert_warnings_included_in_concatenated_bodies() {
  local prefix="${1}"
  local summary="${2}"
  if [[ "${summary}" != *'⚠️ 2 warnings</summary>'* ]]; then
    echo "  head + plan bodies together must include the warnings collapser"
    return 1
  fi
  return 0
}
reset_defaults
export input_warning_count="2"
export input_warnings_markdown_file=$(make_warnings_md multi)
run_test "Head + plan bodies together carry the warnings collapser" assert_warnings_included_in_concatenated_bodies

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
# Body files replace the string outputs (docs/Apply-and-destroy-reporting.md
# §7.10, tests C16–C18). The bodies must reach the PR via pr-comment's
# body-file only; a body string in $GITHUB_OUTPUT is the defect.
# --------------------------------------------------

# C17: only paths, counts and flags in GITHUB_OUTPUT — no body text.
assert_no_body_strings_in_github_output() {
  local fails=""
  # Every output line is a single `key=value` line: no multiline delimiters.
  if grep -qE '^[a-z-]+<<' "${GITHUB_OUTPUT}"; then
    fails+="  GITHUB_OUTPUT: multiline output present — a body string leaked\n"
  fi
  if grep -qF '### Terraform' "${GITHUB_OUTPUT}"; then
    fails+="  GITHUB_OUTPUT: a rendered heading is present — a body string leaked\n"
  fi
  if grep -qF '| Step | Result |' "${GITHUB_OUTPUT}"; then
    fails+="  GITHUB_OUTPUT: table markup present — a body string leaked\n"
  fi
  local n
  n=$(wc -l < "${GITHUB_OUTPUT}")
  if [ "${n}" -ne 6 ]; then
    fails+="  GITHUB_OUTPUT: expected exactly 6 lines (head, plan, apply, destroy-plan, destroy, step-summary *-file), got ${n}\n"
  fi
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
_plan_file=$(mktemp); echo "some plan body" > "${_plan_file}"
export input_plan_txt_output_file="${_plan_file}"
run_test "C17: GITHUB_OUTPUT holds only the six file paths, never a body" assert_no_body_strings_in_github_output
rm -f "${_plan_file}"

# C18: the deleted outputs are gone by name.
assert_deleted_outputs_absent() {
  local fails=""
  for k in summary prefix head-summary plan-extract; do
    if grep -qE "^${k}(=|<<)" "${GITHUB_OUTPUT}"; then
      fails+="  GITHUB_OUTPUT: deleted output '${k}' is still emitted\n"
    fi
  done
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
run_test "C18: summary / prefix / head-summary / plan-extract outputs are gone" assert_deleted_outputs_absent

# File paths: under RUNNER_TEMP, env-named, default (no suffix) shape.
assert_body_files_default_names() {
  local head_file plan_file
  head_file=$(get_output "head-summary-file")
  plan_file=$(get_output "plan-extract-file")
  local fails=""
  [[ "${head_file}" == "${RUNNER_TEMP}/tf-comment-dev-head.md" ]] || fails+="  head-summary-file: expected '${RUNNER_TEMP}/tf-comment-dev-head.md', got '${head_file}'\n"
  [[ "${plan_file}" == "${RUNNER_TEMP}/tf-comment-dev-plan.md" ]] || fails+="  plan-extract-file: expected '${RUNNER_TEMP}/tf-comment-dev-plan.md', got '${plan_file}'\n"
  [ -s "${head_file}" ] || fails+="  head file missing or empty\n"
  [ -s "${plan_file}" ] || fails+="  plan file missing or empty\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
run_test "Body files land under RUNNER_TEMP with env-scoped default names" assert_body_files_default_names

# Files have no trailing newline — byte-identical to the string the
# multiline output used to carry (which the delimiter reader stripped).
assert_body_files_have_no_trailing_newline() {
  local head_file
  head_file=$(get_output "head-summary-file")
  if [ "$(tail -c1 "${head_file}" | wc -l)" -ne 0 ]; then
    echo "  head file ends with a newline; must be byte-identical to the former string output"
    return 1
  fi
  return 0
}
reset_defaults
run_test "Body files carry no trailing newline (byte-identical to former strings)" assert_body_files_have_no_trailing_newline

# C16: output-file-suffix — four invocations in one job write four distinct
# files and none overwrites another. Simulated by running the step four
# times against ONE RUNNER_TEMP with the suffixes the workflow passes, then
# checking all four pairs exist with the content each invocation rendered.
test_c16_suffix_isolation() {
  local shared_tmp; shared_tmp=$(mktemp -d)
  local -a suffixes=(phase1 phase1-final phase2 phase2-final)
  local sfx
  for sfx in "${suffixes[@]}"; do
    reset_defaults
    export input_output_file_suffix="${sfx}"
    # Make each render distinguishable: the plan-tag id lands in the head body.
    export input_plan_tag_comment_id="id-${sfx}"
    export GITHUB_OUTPUT=$(mktemp)
    export RUNNER_TEMP="${shared_tmp}"
    export GITHUB_ACTION_PATH="${_this_script_dir}"
    export GITHUB_WORKSPACE="${_this_script_dir}"
    ( source "${_this_script_dir}/step_create_validation_summary.sh" ) > /tmp/test_output.txt 2>&1 || { echo "  invocation '${sfx}' failed"; rm -rf "${shared_tmp}"; return 1; }
    rm -f "${GITHUB_OUTPUT}"
  done
  local fails=""
  for sfx in "${suffixes[@]}"; do
    local f="${shared_tmp}/tf-comment-dev-head-${sfx}.md"
    [ -s "${f}" ] || fails+="  missing head file for suffix '${sfx}'\n"
    grep -qF "#issuecomment-id-${sfx}" "${f}" 2>/dev/null || fails+="  head file for '${sfx}' does not hold that invocation's body (overwritten?)\n"
    [ -s "${shared_tmp}/tf-comment-dev-plan-${sfx}.md" ] || fails+="  missing plan file for suffix '${sfx}'\n"
  done
  local count
  count=$(ls "${shared_tmp}"/tf-comment-dev-*.md | wc -l)
  [ "${count}" -eq 24 ] || fails+="  expected 24 body files (4 invocations × 6 bodies), found ${count}\n"
  rm -rf "${shared_tmp}"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "${BLUE}TEST ${TESTS_RUN}: C16: four suffixed invocations in one RUNNER_TEMP write 24 distinct files, none overwritten${NC}"
if _c16_err=$(test_c16_suffix_isolation 2>&1); then
  echo -e "${GREEN}✓ PASSED${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}:"; echo -e "${_c16_err}"; TESTS_FAILED=$((TESTS_FAILED + 1))
fi


# --------------------------------------------------
# P30 — 'skipped' is what GitHub sets for a step whose if: was false. It must
# gate exactly like empty. Found in the first real run: every plan-only env
# rendered three skipped blocks.
# --------------------------------------------------
reset_defaults
export input_status_apply="skipped"; export input_status_destroy_plan="skipped"; export input_status_destroy="skipped"
run_test "P30: all three statuses 'skipped' → head byte-identical to the plan-only golden" assert_full_body_golden_all_success_no_plan

assert_skipped_apply_shows_mode_not_block() {
  local head="${3}"
  [[ "${head}" == *'| Mode |'* ]] || { echo "  Mode row must still render (goal-driven)"; return 1; }
  [[ "${head}" != *'| <span title="Apply">🐙</span> | Apply |'* ]] || { echo "  a skipped apply must not render the Apply block"; return 1; }
  [[ "${head}" != *'Apply details'* ]] || { echo "  no Apply details for a skipped apply"; return 1; }
  return 0
}
reset_defaults
export input_goals_json='["all","apply-on-pr"]'
export input_status_plan="failure"; export input_status_apply="skipped"
run_test "P30: plan failed → apply skipped → Mode row yes, Apply block no" assert_skipped_apply_shows_mode_not_block

# --------------------------------------------------
# Operation blocks — apply / destroy-plan / destroy rows appended below
# Plan time (docs/Apply-and-destroy-reporting.md §8.1, tests C1b–C6, C14,
# C15). The plan-only rendering is asserted byte-identical by every golden
# above (C1); these pin what the blocks add and that they add it below.
# --------------------------------------------------

# Shared "apply-on-pr, succeeded" fixture inputs.
set_apply_success_inputs() {
  export input_status_apply="success"
  export input_apply_time="1:07"
  export input_apply_count_add="1"
  export input_apply_count_change="0"
  export input_apply_count_destroy="0"
  export input_apply_count_total="1"
  export input_apply_completed="true"
  export input_include_plan_details="true"
  export input_plan_count_add="1"
  export input_plan_count_change="0"
  export input_plan_count_destroy="0"
  export input_plan_count_total="1"
  export input_plan_time="0:04"
}

# The head as rendered with NO operation blocks, for prefix comparisons.
# Captured once from the current defaults so C1b compares against the real
# rendering rather than a hand-typed copy.
_capture_plan_only_head() {
  reset_defaults
  export input_include_plan_details="true"
  export input_plan_count_add="1"; export input_plan_count_change="0"; export input_plan_count_destroy="0"
  export input_plan_count_total="1"; export input_plan_time="0:04"
  export GITHUB_OUTPUT=$(mktemp); export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"; export GITHUB_WORKSPACE="${_this_script_dir}"
  ( source "${_this_script_dir}/step_create_validation_summary.sh" ) >/dev/null 2>&1
  cat "$(get_output head-summary-file)"
  rm -f "${GITHUB_OUTPUT}"; rm -rf "${RUNNER_TEMP}"
}
PLAN_ONLY_HEAD="$(_capture_plan_only_head)"
# Everything up to and including the Plan time row — the part that must be
# a prefix of every rendering. The footer ([Job log]) follows the table and
# is what the blocks are inserted BEFORE, so it is excluded from the prefix.
# The heading is deliberately NOT part of the prefix: it names what the
# environment did, so it reads "Terraform summary" once an operation has run
# and "Terraform validation summary" when none has. That a plan-only
# environment keeps the original heading byte for byte is asserted separately,
# by the head-title tests. Everything from the table header down to the Plan
# time row is what must be identical.
PLAN_ONLY_TABLE_PREFIX="$(printf '%s' "${PLAN_ONLY_HEAD}" | sed -n '2,/| Plan time |/p')"

# C1b: with every block present, the plan-only table is a strict PREFIX.
assert_plan_only_is_strict_prefix() {
  local head; head="$(printf '%s' "${3}" | tail -n +2)"
  if [[ "${head}" != "${PLAN_ONLY_TABLE_PREFIX}"* ]]; then
    echo "  head-summary: plan-only table (through Plan time) is NOT a prefix of the full rendering"
    diff <(printf '%s' "${PLAN_ONLY_TABLE_PREFIX}") <(printf '%s' "${head}" | head -n "$(printf '%s\n' "${PLAN_ONLY_TABLE_PREFIX}" | wc -l)") | sed 's/^/    /'
    return 1
  fi
  if [[ "${head}" == "${PLAN_ONLY_TABLE_PREFIX}" ]]; then
    echo "  head-summary: expected rows BELOW Plan time, got none"
    return 1
  fi
  # And nothing new above Plan time: the first row after the header rows
  # that is not one of the ten plan-block labels must come after Plan time.
  local pt_line first_new
  pt_line=$(printf '%s\n' "${head}" | grep -n '| Plan time |' | head -n1 | cut -d: -f1)
  first_new=$(printf '%s\n' "${head}" | grep -nE '\| (Apply|Destroy plan|Destroy)( warnings| details| time)? \|' | head -n1 | cut -d: -f1)
  if [ -n "${first_new}" ] && [ "${first_new}" -le "${pt_line}" ]; then
    echo "  head-summary: an operation row (line ${first_new}) was inserted ABOVE Plan time (line ${pt_line})"
    return 1
  fi
  return 0
}
reset_defaults
set_apply_success_inputs
export input_status_destroy_plan="success"; export input_destroy_plan_time="0:31"
export input_destroy_plan_count_add="0"; export input_destroy_plan_count_change="0"; export input_destroy_plan_count_destroy="2"
export input_destroy_plan_count_import="0"; export input_destroy_plan_count_move="0"; export input_destroy_plan_count_remove="0"; export input_destroy_plan_count_total="2"
export input_status_destroy="success"; export input_destroy_time="0:44"
export input_destroy_count_destroy="2"; export input_destroy_count_total="2"; export input_destroy_completed="true"
export input_apply_warning_count="3"; export input_destroy_plan_warning_count="1"; export input_destroy_warning_count="2"
run_test "C1b: plan-only table is a strict prefix of the full rendering; nothing inserted above Plan time" assert_plan_only_is_strict_prefix

# C6 + C15: full row order with every block and every optional row present.
assert_full_row_order() {
  local head="${3}"
  local labels
  labels=$(printf '%s\n' "${head}" | grep -oE '^\| <span title="[^"]+">' | sed -E 's/^\| <span title="([^"]+)">/\1/')
  local expected='Initialization
Lock file
Format and Style
Validate
TFLint
Plan
Warnings
Plan details
Plan time
Apply
Apply warnings
Apply details
Apply time
Destroy plan
Destroy plan warnings
Destroy plan details
Destroy plan time
Destroy
Destroy warnings
Destroy details
Destroy time
Links'
  if [[ "${labels}" != "${expected}" ]]; then
    echo "  row order mismatch"
    diff <(echo "${expected}") <(echo "${labels}") | sed 's/^/    /'
    return 1
  fi
  return 0
}
reset_defaults
set_apply_success_inputs
export input_warning_count="2"; export input_warnings_markdown_file=$(make_warnings_md default)
export input_status_destroy_plan="success"; export input_destroy_plan_time="0:31"
export input_destroy_plan_count_add="0"; export input_destroy_plan_count_change="0"; export input_destroy_plan_count_destroy="2"
export input_destroy_plan_count_import="0"; export input_destroy_plan_count_move="0"; export input_destroy_plan_count_remove="0"; export input_destroy_plan_count_total="2"
export input_status_destroy="success"; export input_destroy_time="0:44"
export input_destroy_count_destroy="2"; export input_destroy_count_total="2"; export input_destroy_completed="true"
export input_apply_warning_count="3"; export input_destroy_plan_warning_count="1"; export input_destroy_warning_count="2"
export input_plan_tag_comment_id="1"
run_test "C6/C15: all 22 rows render in §8.1 order — blocks in execution order, each status·warnings·details·time, Links last" assert_full_row_order

# C2 + golden: the apply block, byte-exact (apply-on-pr, success).
assert_apply_block_golden() {
  local head="${3}"
  local expected
  expected=$(cat <<'EOF'
| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">`0:04`</span> |
| <span title="Apply">🐙</span> | Apply | `success` |
| <span title="Apply details">📊</span> | Apply details | <div align="left"><span title="Applied / planned">`💫 1/1` added</span><br><span title="Applied / planned">`🛠️ 0/0` changed</span><br><span title="Applied / planned">`💥 0/0` destroyed</span></div> |
| <span title="Apply time">⏱</span> | Apply time | <span title="mm:ss (minutes:seconds)">`1:07`</span> |
EOF
)
  if [[ "${head}" != *"${expected}"* ]]; then
    echo "  head-summary: apply block not byte-exact (expected the four lines below, contiguous, right after Plan time)"
    echo "${expected}" | sed 's/^/    /'
    echo "  --- got ---"
    printf '%s\n' "${head}" | grep -E 'Plan time|Apply' | sed 's/^/    /'
    return 1
  fi
  return 0
}
reset_defaults
set_apply_success_inputs
run_test "C2: apply block (status, details, time) is byte-exact and sits right after Plan time" assert_apply_block_golden

# C3: apply failure renders <kbd>failure</kbd>.
assert_apply_failure_kbd() {
  local head="${3}"
  [[ "${head}" == *'| <span title="Apply">🐙</span> | Apply | <kbd>failure</kbd> |'* ]] || { echo "  expected Apply row with <kbd>failure</kbd>"; return 1; }
  return 0
}
reset_defaults
set_apply_success_inputs
export input_status_apply="failure"
run_test "C3: status-apply=failure → Apply row renders <kbd>failure</kbd>" assert_apply_failure_kbd

# C4: apply did not complete → every applied count is '?', never 0 (P2).
assert_incomplete_apply_renders_question_marks() {
  local head="${3}"
  local expected='<span title="Applied / planned">`💫 ?/9` added</span><br><span title="Applied / planned">`🛠️ ?/2` changed</span><br><span title="Applied / planned">`💥 ?/1` destroyed</span>'
  [[ "${head}" == *"${expected}"* ]] || { echo "  expected '?/planned' badges for an incomplete apply, got:"; printf '%s\n' "${head}" | grep 'Apply details' | sed 's/^/    /'; return 1; }
  [[ "${head}" != *'`💫 0/9`'* ]] || { echo "  a failed apply must NEVER render 0/N (P2)"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="failure"
export input_apply_completed="false"
# Even if a caller wired zeros (a parser that regressed to zeros), they must not show.
export input_apply_count_add="0"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
export input_include_plan_details="true"
export input_plan_count_add="9"; export input_plan_count_change="2"; export input_plan_count_destroy="1"; export input_plan_count_total="12"
run_test "C4: apply-completed=false → details render '?/N', never '0/N' (P2)" assert_incomplete_apply_renders_question_marks

# C4b: partial apply where the parser reported '?' and completed=false.
assert_partial_apply_question_marks() {
  local head="${3}"
  [[ "${head}" == *'`💫 ?/9` added'* ]] || { echo "  expected '?/9' for parser-reported '?'"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="failure"; export input_apply_completed="false"
export input_apply_count_add="?"; export input_apply_count_change="?"; export input_apply_count_destroy="?"
export input_plan_count_add="9"; export input_plan_count_change="0"; export input_plan_count_destroy="0"
run_test "C4: parser '?' counts render as '?/N'" assert_partial_apply_question_marks

# Planned side unknown (plan counts N/A) → '?' denominator, no crash.
assert_unknown_planned_renders_question_mark_denominator() {
  local head="${3}"
  [[ "${head}" == *'`💫 1/?` added'* ]] || { echo "  expected '1/?' when the plan count is N/A"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"
export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
# The action.yml default for the plan counts is 'N/A' (reset_defaults uses
# '0' for the older tests' sake) — set it explicitly to hit this branch.
export input_plan_count_add="N/A"; export input_plan_count_change="N/A"; export input_plan_count_destroy="N/A"
run_test "Apply details: unknown planned count renders '?' denominator" assert_unknown_planned_renders_question_mark_denominator

# C5: each block appears independently of the others.
assert_only_destroy_plan_block() {
  local head="${3}"
  local fails=""
  [[ "${head}" == *'| Destroy plan |'* ]] || fails+="  expected Destroy plan row\n"
  [[ "${head}" == *'| Destroy plan details |'* ]] || fails+="  expected Destroy plan details row\n"
  [[ "${head}" == *'| Destroy plan time |'* ]] || fails+="  expected Destroy plan time row\n"
  [[ "${head}" != *'| Apply |'* ]] || fails+="  Apply row must be absent when status-apply is empty\n"
  [[ "${head}" != *'| <span title="Destroy">☠</span> | Destroy |'* ]] || fails+="  Destroy row must be absent when status-destroy is empty\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_status_destroy_plan="success"
export input_destroy_plan_count_add="0"; export input_destroy_plan_count_change="0"; export input_destroy_plan_count_destroy="2"
run_test "C5: status-destroy-plan alone → only the Destroy plan block appears" assert_only_destroy_plan_block

assert_only_destroy_block() {
  local head="${3}"
  local fails=""
  [[ "${head}" == *'| <span title="Destroy">☠</span> | Destroy | `success` |'* ]] || fails+="  expected Destroy row\n"
  [[ "${head}" == *'| <span title="Destroy details">📊</span> | Destroy details | <div align="left"><span title="Applied / planned">`💥 2/2` destroyed</span></div> |'* ]] || fails+="  expected byte-exact Destroy details row\n"
  [[ "${head}" != *'| Apply |'* ]] || fails+="  Apply row must be absent\n"
  [[ "${head}" != *'| Destroy plan |'* ]] || fails+="  Destroy plan row must be absent\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_status_destroy="success"; export input_destroy_completed="true"
export input_destroy_count_destroy="2"; export input_destroy_plan_count_destroy="2"
run_test "C5: status-destroy alone → only the Destroy block appears, details byte-exact" assert_only_destroy_block

# Destroy plan details is a PLAN: plan badge set, present tense, optional badges.
assert_destroy_plan_details_is_plan_shaped() {
  local head="${3}"
  local expected='| <span title="Destroy plan details">📊</span> | Destroy plan details | <div align="left"><span title="Resources to be added">`💫 0` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 5` destroy</span><br><span title="Resources to be removed">`⛓️‍💥 1` remove</span></div> |'
  [[ "${head}" == *"${expected}"* ]] || { echo "  expected plan-shaped Destroy plan details with the optional remove badge:"; echo "    ${expected}"; printf '%s\n' "${head}" | grep 'Destroy plan details' | sed 's/^/    got: /'; return 1; }
  [[ "${head}" != *'`🔀 0`'* ]] || { echo "  zero move badge must be omitted"; return 1; }
  return 0
}
reset_defaults
export input_status_destroy_plan="success"
export input_destroy_plan_count_add="0"; export input_destroy_plan_count_change="0"; export input_destroy_plan_count_destroy="5"
export input_destroy_plan_count_import="0"; export input_destroy_plan_count_move="0"; export input_destroy_plan_count_remove="1"
run_test "Destroy plan details uses the plan badge set (present tense, optional badges)" assert_destroy_plan_details_is_plan_shaped

# C14: four independent warning rows, each gated by its own count.
assert_four_warning_rows_independent() {
  local head="${3}"
  local fails=""
  [[ "${head}" == *'| <span title="Warnings">⚠️</span> | Warnings | <span title="Warnings from init+validate+plan">⚠️ 2</span> |'* ]] || fails+="  Warnings row (init+validate+plan) wrong or missing\n"
  [[ "${head}" == *'| <span title="Apply warnings">⚠️</span> | Apply warnings | <span title="Warnings from apply">⚠️ 3</span> |'* ]] || fails+="  Apply warnings row wrong or missing\n"
  [[ "${head}" != *'| Destroy plan warnings |'* ]] || fails+="  Destroy plan warnings row must be absent at count 0\n"
  [[ "${head}" == *'| <span title="Destroy warnings">⚠️</span> | Destroy warnings | <span title="Warnings from destroy">⚠️ 1</span> |'* ]] || fails+="  Destroy warnings row wrong or missing\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
set_apply_success_inputs
export input_warning_count="2"; export input_warnings_markdown_file=$(make_warnings_md default)
export input_apply_warning_count="3"
export input_status_destroy_plan="success"; export input_destroy_plan_warning_count="0"
export input_status_destroy="success"; export input_destroy_warning_count="1"
run_test "C14: four warning rows are independent; each gated by its own count, none summed" assert_four_warning_rows_independent

# Warnings row for an operation is absent when its count is '?' / 'N/A'.
assert_apply_warnings_row_absent_for_non_numeric() {
  local head="${3}"
  [[ "${head}" != *'| Apply warnings |'* ]] || { echo "  Apply warnings row must be absent for count '?'"; return 1; }
  return 0
}
reset_defaults
set_apply_success_inputs
export input_apply_warning_count="?"
run_test "Apply warnings row absent when the count is '?'" assert_apply_warnings_row_absent_for_non_numeric

# Time cells: N/A → em-dash with tooltip, same as Plan time.
assert_apply_time_em_dash() {
  local head="${3}"
  [[ "${head}" == *'| <span title="Apply time">⏱</span> | Apply time | <span title="mm:ss (minutes:seconds)">—</span> |'* ]] || { echo "  expected em-dash Apply time cell"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"   # a step that ran; its time input left at N/A
run_test "Apply time renders em-dash when N/A (same shape as Plan time)" assert_apply_time_em_dash

# Grouped mode: operation blocks live in the table, which grouped mode omits.
assert_grouped_omits_operation_blocks() {
  local head="${3}"
  [[ "${head}" != *'| Apply |'* && "${head}" != *'Apply details'* ]] || { echo "  grouped mode must omit the operation blocks along with the rest of the table"; return 1; }
  return 0
}
reset_defaults
set_apply_success_inputs
export input_pr_comment_group="dev-group"
run_test "Grouped mode omits the operation blocks with the rest of the table" assert_grouped_omits_operation_blocks


# --------------------------------------------------
# Mode row, plan-tag banner, operation tag bodies and the Links row
# (docs/Apply-and-destroy-reporting.md §8.2, §8.5, §8.6; tests C7–C13,
# C19–C24). The extra bodies are read from the *-file outputs.
# --------------------------------------------------
body_of() { local f; f=$(get_output "${1}-file"); [ -n "${f}" ] && [ -f "${f}" ] && cat "${f}"; }

# A realistic tick-filtered apply console with an Outputs section.
make_apply_console() {
  local tmp; tmp=$(mktemp)
  cat >"${tmp}" <<'EOF'
azurerm_resource_group.rg: Creating...
azurerm_resource_group.rg: Creation complete after 2s [id=/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

resource_group_name = "rg-example"
connection_hint = "OUTPUT_VALUE_MUST_NOT_LEAK"
EOF
  echo "${tmp}"
}

# C7: apply-on-pr → Mode row first, byte-exact; banner in the plan tag.
assert_mode_row_and_banner_apply() {
  local head="${3}" plan="${4}"
  local fails=""
  local expected_rows
  expected_rows=$(cat <<'EOF'
|  | Step | Result |
|:---:|---|---|
| <span title="Mode">🐙</span> | Mode | <span title="This environment mutates infrastructure on pull request">applies on PR</span> |
| <span title="Initialization">⚙️</span> | Initialization | `success` |
EOF
)
  [[ "${head}" == *"${expected_rows}"* ]] || fails+="  head: Mode row not byte-exact / not first:\n$(printf '%s\n' "${head}" | sed -n '2,5p' | sed 's/^/    /')\n"
  local expected_banner='### Terraform plan for environment: `dev`

> 🐙 This environment applies on pull request — the plan below was applied to real infrastructure. The result is in the 🐙 apply comment.

Plan not available 🤷‍♀️'
  [[ "${plan}" == "${expected_banner}" ]] || fails+="  plan: banner not byte-exact:\n$(diff <(echo "${expected_banner}") <(echo "${plan}") | sed 's/^/    /')\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_goals_json='["all","apply-on-pr"]'
run_test "C7: apply-on-pr → Mode row is row 1 (byte-exact) and the plan tag carries the banner" assert_mode_row_and_banner_apply

# C8: both on-PR goals → 🐙☠ icon, two value lines, two banner lines.
assert_mode_row_both() {
  local head="${3}" plan="${4}"
  local fails=""
  local expected='| <span title="Mode">🐙☠</span> | Mode | <span title="This environment mutates infrastructure on pull request">applies on PR</span><br><span title="This environment mutates infrastructure on pull request">destroys on PR</span> |'
  [[ "${head}" == *"${expected}"* ]] || fails+="  head: expected 🐙☠ Mode row with both lines\n"
  [[ "${plan}" == *'> 🐙 This environment applies on pull request'* ]] || fails+="  plan: apply banner missing\n"
  [[ "${plan}" == *'> ☠ This environment destroys on pull request'* ]] || fails+="  plan: destroy banner missing\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_goals_json='["init","plan","apply-on-pr","destroy-plan","destroy-on-pr"]'
run_test "C8: apply-on-pr + destroy-on-pr → 🐙☠ Mode row, both value lines, both banners" assert_mode_row_both

# destroy-on-pr alone → ☠ only.
assert_mode_row_destroy_only() {
  local head="${3}"
  [[ "${head}" == *'| <span title="Mode">☠</span> | Mode | <span title="This environment mutates infrastructure on pull request">destroys on PR</span> |'* ]] || { echo "  expected ☠-only Mode row"; return 1; }
  [[ "${head}" != *'applies on PR'* ]] || { echo "  'applies on PR' must be absent"; return 1; }
  return 0
}
reset_defaults
export input_goals_json='["all","destroy-plan","destroy-on-pr"]'
run_test "Mode row: destroy-on-pr alone → ☠ / destroys on PR" assert_mode_row_destroy_only

# C9: malformed / empty / non-qualifying goals → no Mode row, no banner, exit 0.
assert_no_mode_no_banner() {
  local head="${3}" plan="${4}"
  [[ "${head}" != *'| Mode |'* ]] || { echo "  Mode row must be absent"; return 1; }
  [[ "${plan}" != *'> 🐙'* && "${plan}" != *'> ☠'* ]] || { echo "  banner must be absent"; return 1; }
  return 0
}
reset_defaults
export input_goals_json='{not json'
run_test "C9: malformed goals-json → no Mode row, no banner, no crash" assert_no_mode_no_banner
reset_defaults
export input_goals_json='["all","apply"]'
run_test "C9: goals without an on-PR goal → no Mode row, no banner" assert_no_mode_no_banner
reset_defaults
export input_goals_json='"apply-on-pr"'
run_test "C9: goals-json that is a string, not an array → ignored" assert_no_mode_no_banner

# C10: Outputs section stripped by default, omission note present, no leak.
assert_apply_extract_strips_outputs() {
  local body; body="$(body_of apply-extract)"
  local fails=""
  [[ "${body}" != *'OUTPUT_VALUE_MUST_NOT_LEAK'* ]] || fails+="  apply extract leaks an output value (P3)\n"
  [[ "${body}" != *$'\nOutputs:\n'* ]] || fails+="  Outputs header must be stripped\n"
  [[ "${body}" == *'_(outputs section omitted)_'* ]] || fails+="  omission note missing\n"
  [[ "${body}" == *'Creation complete after 2s'* ]] || fails+="  console above Outputs must be kept\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="1"
export input_apply_console_file=$(make_apply_console)
run_test "C10: apply extract strips the Outputs section by default and says so (P3)" assert_apply_extract_strips_outputs

# C11: opt-in keeps it, no note.
assert_apply_extract_keeps_outputs() {
  local body; body="$(body_of apply-extract)"
  [[ "${body}" == *'OUTPUT_VALUE_MUST_NOT_LEAK'* ]] || { echo "  opted-in Outputs section missing"; return 1; }
  [[ "${body}" != *'_(outputs section omitted)_'* ]] || { echo "  omission note must be absent when kept"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="1"
export input_apply_console_file=$(make_apply_console)
export input_apply_extract_include_outputs="true"
run_test "C11: apply-extract-include-outputs=true keeps the Outputs section" assert_apply_extract_keeps_outputs

# §8.6 shape 2: completed, N changes — byte-exact heading + summary + fence.
assert_apply_shape_changes_golden() {
  local body; body="$(body_of apply-extract)"
  local expected='### Terraform apply for environment: `dev`

<details><summary>Apply: 1/1 added, 0/0 changed, 0/0 destroyed ✅</summary>

```terraform
azurerm_resource_group.rg: Creating...
azurerm_resource_group.rg: Creation complete after 2s [id=/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

_(outputs section omitted)_
</details>'
  [[ "${body}" == "${expected}" ]] || { echo "  apply extract (shape 2) not byte-exact:"; diff <(echo "${expected}") <(echo "${body}") | sed 's/^/    /'; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="1"
export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
export input_plan_count_add="1"; export input_plan_count_change="0"; export input_plan_count_destroy="0"
export input_apply_console_file=$(make_apply_console)
run_test "§8.6 shape 2: 'Apply: A/P added, C/P changed, D/P destroyed ✅' collapser is byte-exact" assert_apply_shape_changes_golden

# Shape 2 with no plan counts (plan parsing failed or N/A): numerators stay,
# denominators read '?' — never '0', which would claim "nothing was planned".
assert_apply_shape_unknown_denominator() {
  local body; body="$(body_of apply-extract)"
  [[ "${body}" == *'<details><summary>Apply: 1/? added, 0/? changed, 0/? destroyed ✅</summary>'* ]] || { echo "  expected '1/? added, 0/? changed, 0/? destroyed'; got: $(printf '%s' "${body}" | sed -n 3p)"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="1"
export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
export input_plan_count_add="N/A"; export input_plan_count_change="N/A"; export input_plan_count_destroy="N/A"
export input_apply_console_file=$(make_apply_console)
run_test "§8.6 shape 2: unknown plan counts → '?' denominators in the apply summary" assert_apply_shape_unknown_denominator

# §8.6 shape 1: completed, no changes → plain line, no collapser.
assert_apply_shape_no_changes() {
  local body; body="$(body_of apply-extract)"
  [[ "${body}" == *$'\n\nApply: no changes ✅' ]] || { echo "  expected 'Apply: no changes ✅' line; got: ${body}"; return 1; }
  [[ "${body}" != *'<details'* ]] || { echo "  no collapser for no changes"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="0"
_c=$(mktemp); echo "Apply complete! Resources: 0 added, 0 changed, 0 destroyed." >"${_c}"; export input_apply_console_file="${_c}"
run_test "§8.6 shape 1: completed with 0 changes → 'Apply: no changes ✅'" assert_apply_shape_no_changes

# C21 / §8.6 shape 3: failed apply → <details open>, the only open collapser.
assert_apply_shape_failed_open() {
  local body; body="$(body_of apply-extract)"
  [[ "${body}" == *'<details open><summary>❌ Apply failed — infrastructure may be partially applied</summary>'* ]] || { echo "  expected the open failure collapser; got: $(printf '%s' "${body}" | head -n4)"; return 1; }
  [[ "${body}" == *'Error: creating Key Vault'* ]] || { echo "  console tail (the error) must be inside"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="failure"; export input_apply_completed="false"; export input_apply_count_total="?"
_c=$(mktemp); printf 'azurerm_resource_group.rg: Creation complete after 1s [id=x]\n╷\n│ Error: creating Key Vault (kv-example): 409 Conflict\n╵\n' >"${_c}"; export input_apply_console_file="${_c}"
run_test "C21 / §8.6 shape 3: failed apply → '<details open>❌ Apply failed — …'" assert_apply_shape_failed_open

# C20 / §8.6 shape 4: no console → not available.
assert_apply_not_available() {
  local body; body="$(body_of apply-extract)"
  [[ "${body}" == '### Terraform apply for environment: `dev`

Apply not available 🤷‍♀️' ]] || { echo "  expected 'Apply not available 🤷‍♀️'; got: ${body}"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_console_file="/nonexistent/apply.txt"
run_test "C20 / §8.6 shape 4: missing apply console → 'Apply not available 🤷‍♀️', no crash" assert_apply_not_available

# Destroy wording.
assert_destroy_shapes() {
  local body; body="$(body_of destroy-extract)"
  [[ "${body}" == *'### Terraform destroy for environment: `dev`'* ]] || { echo "  destroy heading"; return 1; }
  [[ "${body}" == *'<details><summary>Destroy: 3/3 destroyed ✅</summary>'* ]] || { echo "  expected 'Destroy: 3/3 destroyed ✅'; got: $(printf '%s' "${body}" | head -n4)"; return 1; }
  return 0
}
reset_defaults
export input_status_destroy="success"; export input_destroy_completed="true"; export input_destroy_count_total="3"
export input_destroy_count_destroy="3"; export input_destroy_plan_count_destroy="3"
_c=$(mktemp); echo "Destroy complete! Resources: 3 destroyed." >"${_c}"; export input_destroy_console_file="${_c}"
run_test "§8.6 shape 5: destroy wording — 'Destroy: D/P destroyed ✅'" assert_destroy_shapes

assert_destroy_failed_wording() {
  local body; body="$(body_of destroy-extract)"
  [[ "${body}" == *'<details open><summary>❌ Destroy failed — infrastructure may be partially destroyed</summary>'* ]] || { echo "  expected destroy failure wording"; return 1; }
  return 0
}
reset_defaults
export input_status_destroy="failure"; export input_destroy_completed="false"
_c=$(mktemp); echo "Error: deleting" >"${_c}"; export input_destroy_console_file="${_c}"
run_test "§8.6 shape 5: '❌ Destroy failed — infrastructure may be partially destroyed'" assert_destroy_failed_wording

# Q4: the head title says what the environment actually did.
assert_title_plan_only() {
  local head; head="$(body_of head-summary)"
  [[ "${head}" == '### Terraform validation summary for environment: `dev`'* ]] ||
    { echo "  plan-only env must keep the original title; got: $(printf '%s' "${head}" | head -n1)"; return 1; }
  return 0
}
reset_defaults
run_test "Head title: a plan-only env keeps 'Terraform validation summary' (C1 invariant)" assert_title_plan_only

assert_title_mutating() {
  local head; head="$(body_of head-summary)"
  local step; step="$(body_of step-summary)"
  local fails=""
  [[ "${head}" == '### Terraform summary for environment: `dev`'* ]] ||
    fails+="  head: got $(printf '%s' "${head}" | head -n1)\n"
  [[ "${step}" == '### Terraform summary for environment: `dev`'* ]] ||
    fails+="  step summary: got $(printf '%s' "${step}" | head -n1)\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_goals_json='["all","apply-on-pr"]'
run_test "Head title: an env that applies on PR drops the word 'validation'" assert_title_mutating

# The case a real nightly hit: goal is plain `apply` (not apply-on-pr), so the
# goals say nothing, but the run applied and the Apply rows are right there.
assert_title_applied_without_on_pr_goal() {
  local head; head="$(body_of head-summary)"
  local fails=""
  [[ "${head}" == '### Terraform summary for environment: `dev`'* ]] ||
    fails+="  title: got $(printf '%s' "${head}" | head -n1)\n"
  [[ "${head}" == *'| Apply |'* ]] || fails+="  expected an Apply row in the same table\n"
  [[ "${head}" != *'| Mode |'* ]] || fails+="  Mode row is about mutating on PR — it must stay absent here\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_goals_json='["init","plan","apply"]'
export input_status_apply="success"; export input_apply_completed="true"
export input_apply_count_total="0"; export input_apply_count_add="0"
export input_apply_count_change="0"; export input_apply_count_destroy="0"
run_test "Head title: an apply that ran drops 'validation' even without apply-on-pr" assert_title_applied_without_on_pr_goal

# A skipped operation must not flip the title — that is the P30 rule again.
assert_title_skipped_apply_stays_validation() {
  local head; head="$(body_of head-summary)"
  [[ "${head}" == '### Terraform validation summary for environment: `dev`'* ]] ||
    { echo "  a skipped apply must leave the title alone; got: $(printf '%s' "${head}" | head -n1)"; return 1; }
  return 0
}
reset_defaults
export input_goals_json='["init","plan","apply"]'
export input_status_apply="skipped"
run_test "Head title: a skipped apply leaves 'validation summary' in place (P30)" assert_title_skipped_apply_stays_validation

assert_title_destroy_only() {
  local head; head="$(body_of head-summary)"
  [[ "${head}" == '### Terraform summary for environment: `dev`'* ]] ||
    { echo "  destroy-on-pr must also drop it; got: $(printf '%s' "${head}" | head -n1)"; return 1; }
  return 0
}
reset_defaults
export input_goals_json='["all","destroy-plan","destroy","destroy-on-pr"]'
run_test "Head title: destroy-on-pr alone is enough to drop it" assert_title_destroy_only

# Extra kinds appear in the summary line only when non-zero, in the head's order.
assert_plan_summary_extra_kinds() {
  local body; body="$(body_of plan-extract)"
  [[ "${body}" == *'<details><summary>Plan: 1 to add, 0 to change, 0 to destroy, 5 to import, 2 to move ℹ️</summary>'* ]] ||
    { echo "  got: $(printf '%s' "${body}" | sed -n 3p)"; return 1; }
  return 0
}
reset_defaults
_c=$(mktemp); echo "PLAN_BODY" >"${_c}"; export input_plan_txt_output_file="${_c}"
export input_plan_count_total="8"
export input_plan_count_add="1"; export input_plan_count_change="0"; export input_plan_count_destroy="0"
export input_plan_count_import="5"; export input_plan_count_move="2"; export input_plan_count_remove="0"
run_test "Plan summary lists import / move only when non-zero, remove omitted at 0" assert_plan_summary_extra_kinds

# A non-numeric count must not render 'N/A to add' — fall back to the bare total.
assert_plan_summary_falls_back() {
  local body; body="$(body_of plan-extract)"
  [[ "${body}" == *'<details><summary>Plan: 9 changes ℹ️</summary>'* ]] ||
    { echo "  expected the bare-total fallback; got: $(printf '%s' "${body}" | sed -n 3p)"; return 1; }
  return 0
}
reset_defaults
_c=$(mktemp); echo "PLAN_BODY" >"${_c}"; export input_plan_txt_output_file="${_c}"
export input_plan_count_total="9"
export input_plan_count_add="N/A"; export input_plan_count_change="N/A"; export input_plan_count_destroy="N/A"
run_test "Plan summary falls back to the bare total when a count is not numeric" assert_plan_summary_falls_back

# P32: imports reach both the apply summary line and the head's details row.
assert_apply_imports_rendered() {
  local body; body="$(body_of apply-extract)"
  local head; head="$(body_of head-summary)"
  local fails=""
  [[ "${body}" == *'<details><summary>Apply: 0/0 added, 1/1 changed, 0/0 destroyed, 5/5 imported ✅</summary>'* ]] ||
    fails+="  apply summary: got $(printf '%s' "${body}" | sed -n 3p)\n"
  [[ "${head}" == *'`📥 5/5` imported'* ]] || fails+="  head Apply details row is missing the imported badge\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="6"
export input_apply_count_add="0"; export input_apply_count_change="1"; export input_apply_count_destroy="0"
export input_apply_count_import="5"
export input_plan_count_add="0"; export input_plan_count_change="1"; export input_plan_count_destroy="0"
export input_plan_count_import="5"
_c=$(mktemp); printf 'x\nApply complete! Resources: 5 imported, 0 added, 1 changed, 0 destroyed.\n' >"${_c}"
export input_apply_console_file="${_c}"
run_test "P32: imports render in the apply summary and the head details row" assert_apply_imports_rendered

# ... and stay out of both when there are none.
assert_apply_no_imports_no_badge() {
  local body; body="$(body_of apply-extract)"
  local head; head="$(body_of head-summary)"
  [[ "${body}" != *'imported'* ]] || { echo "  apply summary must not mention imports at 0"; return 1; }
  [[ "${head}" != *'📥'* ]] || { echo "  head must not carry an import badge at 0"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="1"
export input_apply_count_add="1"; export input_apply_count_change="0"; export input_apply_count_destroy="0"
export input_apply_count_import="0"
_c=$(mktemp); printf 'x\nApply complete! Resources: 1 added, 0 changed, 0 destroyed.\n' >"${_c}"
export input_apply_console_file="${_c}"
run_test "P32: no import segment → no imported text and no 📥 badge" assert_apply_no_imports_no_badge

# P34: the tag's shape must never contradict the head's status row. A parse
# failure on a successful apply used to post "❌ Apply failed — infrastructure
# may be partially applied" beside a head row reading `success`, which is both
# self-contradictory and untrue. Reported in review.
assert_unparsed_success_does_not_claim_failure() {
  local body; body="$(body_of apply-extract)"
  local head; head="$(body_of head-summary)"
  local fails=""
  [[ "${body}" == *'<details><summary>⚠️ Apply finished, but its counts could not be read</summary>'* ]] ||
    fails+="  tag: got $(printf '%s' "${body}" | sed -n 3p)\n"
  [[ "${body}" != *'partially applied'* ]] || fails+="  tag must not claim partial application when the step succeeded\n"
  [[ "${body}" != *'❌'* ]] || fails+="  tag must not be red when the step succeeded\n"
  [[ "${head}" == *'| Apply | `success` |'* ]] || fails+="  head should still report the real status\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="false"; export input_apply_count_total="?"
_c=$(mktemp); printf 'Apply complete! Resources: 1 added (in a grammar we cannot read)\n' >"${_c}"
export input_apply_console_file="${_c}"
run_test "P34: a successful apply whose output could not be parsed is not reported as failed" assert_unparsed_success_does_not_claim_failure

# ... and a genuinely failed apply keeps the red, open, partial-state shape.
assert_failed_apply_still_red() {
  local body; body="$(body_of apply-extract)"
  [[ "${body}" == *'<details open><summary>❌ Apply failed — infrastructure may be partially applied</summary>'* ]] ||
    { echo "  expected the failure shape; got: $(printf '%s' "${body}" | sed -n 3p)"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="failure"; export input_apply_completed="false"; export input_apply_count_total="?"
_c=$(mktemp); printf 'Error: quota exceeded\n' >"${_c}"; export input_apply_console_file="${_c}"
run_test "P34: a failed apply still gets the red, open, partial-state shape" assert_failed_apply_still_red

# Destroy travels the same road.
assert_unparsed_destroy_success() {
  local body; body="$(body_of destroy-extract)"
  [[ "${body}" == *'<details><summary>⚠️ Destroy finished, but its counts could not be read</summary>'* ]] ||
    { echo "  got: $(printf '%s' "${body}" | sed -n 3p)"; return 1; }
  [[ "${body}" != *'partially destroyed'* ]] || { echo "  must not claim partial destruction"; return 1; }
  return 0
}
reset_defaults
export input_status_destroy="success"; export input_destroy_completed="false"; export input_destroy_count_total="?"
_c=$(mktemp); printf 'Destroy complete! (unreadable)\n' >"${_c}"; export input_destroy_console_file="${_c}"
run_test "P34: the same rule for destroy" assert_unparsed_destroy_success

# C24: destroy-plan extract uses the plan's five shapes.
assert_destroy_plan_extract_plan_shaped() {
  local body; body="$(body_of destroy-plan-extract)"
  [[ "${body}" == *'### Terraform destroy plan for environment: `dev`'* ]] || { echo "  heading"; return 1; }
  [[ "${body}" == *'<details><summary>Destroy plan: 0 to add, 0 to change, 2 to destroy ℹ️</summary>'* ]] || { echo "  expected 'Destroy plan: 0 to add, 0 to change, 2 to destroy ℹ️'; got: $(printf '%s' "${body}" | head -n4)"; return 1; }
  [[ "${body}" == *'DESTROY_PLAN_BODY'* ]] || { echo "  destroy plan body missing"; return 1; }
  return 0
}
reset_defaults
export input_status_destroy_plan="success"; export input_destroy_plan_count_total="2"
export input_destroy_plan_count_add="0"; export input_destroy_plan_count_change="0"; export input_destroy_plan_count_destroy="2"
_c=$(mktemp); echo "DESTROY_PLAN_BODY - azurerm_resource_group.rg will be destroyed" >"${_c}"; export input_destroy_plan_txt_output_file="${_c}"
run_test "C24: destroy-plan extract reuses the plan's shapes, labelled 'Destroy plan'" assert_destroy_plan_extract_plan_shaped

# The plan tag itself is untouched by destroy-plan inputs (no cross-talk).
assert_plan_extract_unaffected_by_destroy_plan() {
  local plan="${4}"
  [[ "${plan}" == '### Terraform plan for environment: `dev`

Plan not available 🤷‍♀️' ]] || { echo "  plan extract changed by destroy-plan inputs: ${plan}"; return 1; }
  return 0
}
reset_defaults
export input_status_destroy_plan="success"; export input_destroy_plan_count_total="2"
_c=$(mktemp); echo "DESTROY_PLAN_BODY" >"${_c}"; export input_destroy_plan_txt_output_file="${_c}"
run_test "Plan extract is unaffected by destroy-plan inputs" assert_plan_extract_unaffected_by_destroy_plan

# C12: each extract > 65000 bytes → ≤ 65000, line-aligned, valid UTF-8.
assert_apply_extract_capped() {
  local body; body="$(body_of apply-extract)"
  local size; size=$(printf '%s' "${body}" | wc -c)
  [ "${size}" -le 65000 ] || { echo "  apply extract is ${size} bytes"; return 1; }
  printf '%s' "${body}" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || { echo "  apply extract is not valid UTF-8"; return 1; }
  local first; first=$(printf '%s' "${body}" | awk '/^```terraform$/{f=1;next} f{print; exit}')
  [[ "${first}" == "module.big.x[\""* ]] || { echo "  cut is not line-aligned; first fence line: '${first}'"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="2000"
_c=$(mktemp); { for i in $(seq 1 1500); do printf 'module.big.x["%04d"]: Creation complete after 1s — — — — — — — — — — — — — — — — — — — —\n' "${i}"; done; echo "Apply complete! Resources: 2000 added, 0 changed, 0 destroyed."; } >"${_c}"; export input_apply_console_file="${_c}"
run_test "C12: oversize apply extract is capped ≤65000, line-aligned, valid UTF-8" assert_apply_extract_capped

# C13: budgets are independent — a 64k plan extract does not shrink the apply extract.
assert_budgets_independent() {
  local plan="${4}"; local apply; apply="$(body_of apply-extract)"
  local ps as
  ps=$(printf '%s' "${plan}" | wc -c); as=$(printf '%s' "${apply}" | wc -c)
  [ "${ps}" -ge 60000 ] || { echo "  plan extract unexpectedly small (${ps})"; return 1; }
  [ "${as}" -ge 60000 ] || { echo "  apply extract shrank to ${as} — budgets are not independent (P17)"; return 1; }
  [ "${ps}" -le 65000 ] && [ "${as}" -le 65000 ] || { echo "  an extract exceeds 65000 (plan ${ps}, apply ${as})"; return 1; }
  return 0
}
reset_defaults
export input_plan_count_total="1"
_p=$(mktemp); yes "  + foo_resource.bar = \"a reasonably long line of plan text to pad things out nicely\"" | head -c 100000 >"${_p}"; export input_plan_txt_output_file="${_p}"
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="1"
_c=$(mktemp); yes 'module.x.y["z"]: Creation complete after 1s [id=/some/long/identifier/here]' | head -c 100000 >"${_c}"; echo >>"${_c}"; echo "Apply complete! Resources: 1 added, 0 changed, 0 destroyed." >>"${_c}"; export input_apply_console_file="${_c}"
run_test "C13: plan and apply extracts have independent 65k budgets (P17)" assert_budgets_independent

# Apply warnings collapser in the apply tag, not the plan tag.
assert_apply_warnings_in_apply_tag_only() {
  local plan="${4}"; local apply; apply="$(body_of apply-extract)"
  [[ "${apply}" == *'<details><summary>⚠️ 2 warnings</summary>'* ]] || { echo "  apply tag must carry its warnings collapser"; return 1; }
  [[ "${plan}" != *'⚠️ 2 warnings'* ]] || { echo "  plan tag must NOT carry the apply warnings"; return 1; }
  return 0
}
reset_defaults
export input_status_apply="success"; export input_apply_completed="true"; export input_apply_count_total="0"
_c=$(mktemp); echo "Apply complete! Resources: 0 added, 0 changed, 0 destroyed." >"${_c}"; export input_apply_console_file="${_c}"
export input_apply_warning_count="2"; export input_apply_warnings_markdown_file=$(make_warnings_md multi)
run_test "Apply warnings collapser lives in the apply tag, not the plan tag (P18)" assert_apply_warnings_in_apply_tag_only

# C19: all four tag ids → Links row with five lines in operation order; footer dropped.
assert_links_row_all_tags() {
  local head="${3}"
  local expected='| <span title="Links">🔗</span> | Links | [log extract](#issuecomment-11)<br>[apply log](#issuecomment-22)<br>[destroy plan log](#issuecomment-33)<br>[destroy log](#issuecomment-44)<br>[job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs) |'
  [[ "${head}" == *"${expected}"* ]] || { echo "  Links row not byte-exact:"; printf '%s\n' "${head}" | grep 'Links' | sed 's/^/    got: /'; echo "    expected: ${expected}"; return 1; }
  [[ "${head}" != *$'\n\n[Job log]('* ]] || { echo "  footer must be dropped when Links row renders"; return 1; }
  return 0
}
reset_defaults
export input_plan_tag_comment_id="11"; export input_apply_tag_comment_id="22"; export input_destroy_plan_tag_comment_id="33"; export input_destroy_tag_comment_id="44"
run_test "C19: four tag ids → five-line Links row in operation order, footer dropped" assert_links_row_all_tags

# Links row renders on an apply id alone (no plan id) — 'any tag id' gate.
assert_links_row_apply_id_only() {
  local head="${3}"
  [[ "${head}" == *'| Links | [apply log](#issuecomment-22)<br>[job log]('* ]] || { echo "  expected Links row from apply id alone"; return 1; }
  [[ "${head}" != *'[log extract]'* ]] || { echo "  no plan line without a plan id"; return 1; }
  return 0
}
reset_defaults
export input_apply_tag_comment_id="22"
run_test "Links row renders when only the apply tag id is supplied" assert_links_row_apply_id_only

# C23: grouped mode — head omits the table (incl. Mode); all five bodies produced.
assert_grouped_all_bodies_produced() {
  local head="${3}"
  [[ "${head}" != *'| Mode |'* ]] || { echo "  grouped head must omit the Mode row with the table"; return 1; }
  for k in apply-extract destroy-plan-extract destroy-extract; do
    [ -n "$(body_of "${k}")" ] || { echo "  ${k} body missing in grouped mode"; return 1; }
  done
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"; export input_goals_json='["all","apply-on-pr"]'
run_test "C23: grouped mode omits the table (incl. Mode) but produces all five bodies" assert_grouped_all_bodies_produced

# Op bodies always written — 'not available' when the operation did not run.
assert_op_bodies_default_not_available() {
  [[ "$(body_of apply-extract)" == *'Apply not available 🤷‍♀️' ]] || { echo "  default apply body"; return 1; }
  [[ "$(body_of destroy-extract)" == *'Destroy not available 🤷‍♀️' ]] || { echo "  default destroy body"; return 1; }
  [[ "$(body_of destroy-plan-extract)" == *'Destroy plan not available 🤷‍♀️' ]] || { echo "  default destroy-plan body"; return 1; }
  return 0
}
reset_defaults
run_test "Operation bodies are always written; 'not available' when the operation did not run" assert_op_bodies_default_not_available


# --------------------------------------------------
# step-summary-file (§8.7): the head's table, ungrouped shape, [Job log]
# footer instead of a Links row — on every event, for every env.
# --------------------------------------------------
assert_step_summary_shape() {
  local head="${3}"; local ss; ss="$(body_of step-summary)"
  local fails=""
  [[ "${ss}" == *'| <span title="Apply">🐙</span> | Apply | `success` |'* ]] || fails+="  step summary must carry the operation blocks\n"
  [[ "${ss}" == *'| <span title="Mode">🐙</span> | Mode |'* ]] || fails+="  step summary must carry the Mode row\n"
  [[ "${ss}" != *'| Links |'* ]] || fails+="  step summary must NOT have a Links row\n"
  [[ "${ss}" == *$'\n\n[Job log](https://github.com/dsb-norge/github-actions-terraform/actions/runs/12345678/job/87654321#logs)' ]] || fails+="  step summary must end with the [Job log] footer\n"
  # The head (with tag ids) has a Links row — the two differ only there.
  [[ "${head}" == *'| Links |'* ]] || fails+="  (precondition) head should have a Links row in this scenario\n"
  local head_no_links; head_no_links=$(printf '%s\n' "${head}" | grep -v '| Links |' | sed '$ d')
  [[ "${ss}" == "${head_no_links}"* ]] || fails+="  step summary table must equal the head's table minus the Links row\n$(diff <(echo "${head_no_links}") <(echo "${ss}") | sed 's/^/    /')\n"
  if [[ -n "${fails}" ]]; then echo -e "${fails}"; return 1; fi
  return 0
}
reset_defaults
set_apply_success_inputs
export input_goals_json='["all","apply-on-pr"]'
export input_plan_tag_comment_id="11"; export input_apply_tag_comment_id="22"
run_test "step-summary-file: head's table (incl. Mode + blocks), Links row → [Job log] footer" assert_step_summary_shape

assert_step_summary_has_table_in_grouped_mode() {
  local head="${3}"; local ss; ss="$(body_of step-summary)"
  [[ "${head}" != *'| Step | Result |'* ]] || { echo "  (precondition) grouped head must omit the table"; return 1; }
  [[ "${ss}" == *'| Step | Result |'* && "${ss}" == *'| Initialization |'* ]] || { echo "  step summary must carry the full table even for a grouped env"; return 1; }
  return 0
}
reset_defaults
export input_pr_comment_group="dev-group"
run_test "step-summary-file: grouped env still gets the full table on the job page" assert_step_summary_has_table_in_grouped_mode

assert_step_summary_small() {
  local ss; ss="$(body_of step-summary)"
  local n; n=$(printf '%s' "${ss}" | wc -c)
  [ "${n}" -lt 8192 ] || { echo "  step summary is ${n} bytes; must stay well under the 1 MiB cap (P19) — no extract may leak in"; return 1; }
  [[ "${ss}" != *'```'* ]] || { echo "  no code fence (console extract) may appear in the step summary"; return 1; }
  return 0
}
reset_defaults
set_apply_success_inputs
export input_apply_console_file=$(make_apply_console)
export input_status_destroy_plan="success"; export input_status_destroy="success"
run_test "step-summary-file: < 8 KiB and never carries a console extract (P19)" assert_step_summary_small

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
