#!/bin/env bash
#
# Source for the create-test-report step.
#
# Renders the PR comment body for one `terraform test` file and writes it to
# a file under RUNNER_TEMP. The path is published as `body-file`; the body
# itself never becomes a step output, so it stays out of the steps context
# and out of every downstream fork's envp.
#
# The rendered body is byte-identical to the legacy inline-bash action's for
# every report within the 65k budget — pinned by the golden fixtures in
# test-data/. The one intentional divergence: a report over budget is cut on
# a line boundary and never mid-codepoint (see line_anchored_tail).
#
# Required environment variables:
#   input_test_file     - File name of the test file (heading + body file name)
#   input_status_init   - Outcome of the init step
#   input_status_test   - Outcome of the test step
#   input_test_summary  - Summary line from terraform-test (✅ when it
#                         contains 'Success!', ❌ otherwise)
#   input_test_report   - Path of the plain-text report; missing file renders
#                         'Test report not available 🤷‍♀️'
#
# Standard GitHub environment variables used:
#   GITHUB_ACTOR, GITHUB_EVENT_NAME, GITHUB_WORKFLOW - footer line
#   RUNNER_TEMP                                      - body file location
#

set +o nounset # optional inputs are checked explicitly

# Load helpers (provides format-status and line_anchored_tail)
source "${GITHUB_ACTION_PATH}/helpers.sh"

# GitHub's comment-body limit is 65536. The cap leaves headroom for the
# heading, table, collapser markup and footer around the report.
REPORT_BUDGET=65000

# ============================================================================
# Renderer
# ============================================================================

# Body shape (kept byte-identical to the legacy action, see file header):
#   ### Terraform test summary for file: `<file>`
#   <two-row table>
#   <blank>
#   <b>Test summary: ✅|❌ <summary></b>          ┐ when the report exists
#   <details><summary>Show Test Report</summary>  │
#   <blank>                                       │
#   ```terraform                                  │
#   <report, trailing newlines stripped>          │
#   ```                                           │
#   </details>                                    ┘
#   Test report not available 🤷‍♀️                 — otherwise
#   <blank>
#   *Pusher: @<actor>, Action: `<event>`, Workflow: `<workflow>`*
function render_body {
  local prefix="### Terraform test summary for file: \`${input_test_file}\`"

  # don't touch the indenting here
  local body="${prefix}
|  | Step | Result |
|:---:|---|---|
| ⚙️ | Initialization | $(format-status "${input_status_init}") |
| 🧪 | Tests | $(format-status "${input_status_test}") |"

  local comment_summary
  if [[ "${input_test_summary}" == *"Success!"* ]]; then
    comment_summary="✅ ${input_test_summary}"
  else
    comment_summary="❌ ${input_test_summary}"
  fi

  if [ -f "${input_test_report}" ]; then
    # $(...) strips trailing newlines, which is what puts the closing fence
    # directly under the report's last line — as the legacy action did.
    local test_out
    test_out=$(line_anchored_tail "${input_test_report}" "${REPORT_BUDGET}")

    # don't touch the indenting here
    body="${body}

<b>Test summary: ${comment_summary}</b>
<details><summary>Show Test Report</summary>

\`\`\`terraform
${test_out}
\`\`\`
</details>"
  else
    # don't touch the indenting here
    body="${body}

Test report not available 🤷‍♀️"
  fi

  # don't touch the indenting here
  body="${body}

*Pusher: @${GITHUB_ACTOR}, Action: \`${GITHUB_EVENT_NAME}\`, Workflow: \`${GITHUB_WORKFLOW}\`*"

  printf '%s' "${body}"
}

# ============================================================================
# Main
# ============================================================================

function main {
  log-info "rendering test report body for '${input_test_file}' ..."

  if [ -z "${input_test_file}" ]; then
    log-error "input_test_file is required"
    return 1
  fi

  # Test file names can carry path separators; flatten them so the body file
  # name stays a single path segment under RUNNER_TEMP.
  local safe_name="${input_test_file//\//_}"
  local body_file="${RUNNER_TEMP:-/tmp}/tf-test-report-${safe_name}.md"

  render_body >"${body_file}"

  log-multiline "test report body" "$(cat "${body_file}")"
  log-info "body written to '${body_file}' ($(wc -c <"${body_file}") bytes)"

  set-output 'body-file' "${body_file}"

  log-info "create-test-report completed."
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
