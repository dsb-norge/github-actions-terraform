#!/bin/env bash
#
# Source for the report step
#
# Totals the files the two terraform-docs steps changed and fails the action when the README
# validation failed. A terraform-docs step that did not succeed changed nothing it pushed, so
# only a successful step's num_changed counts; an empty or non-numeric one counts as zero.
#
# Required environment variables:
#   input_validate_outcome       - outcome of the validate-root-readme step
#   input_examples_outcome       - outcome of the generate-example-docs step
#   input_examples_num_changed   - its num_changed output (empty when it did not run)
#   input_project_outcome        - outcome of the generate-project-docs step
#   input_project_num_changed    - its num_changed output (empty when it did not run)
#

set -o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Helper Functions (step-local)
# ============================================================================

# Set _files_changed to what one terraform-docs step changed.
#   $1 - label for the log
#   $2 - the step's outcome
#   $3 - the step's num_changed output
function count_files_changed {
  local label="${1}" outcome="${2}" num_changed="${3}"
  _files_changed=0
  if [[ "${outcome}" != "success" || -z "${num_changed}" ]]; then
    return 0
  fi
  if [[ ! "${num_changed}" =~ ^[0-9]+$ ]]; then
    log-warn "${label}: num_changed '${num_changed}' is not a number, counting it as 0."
    return 0
  fi
  _files_changed=$((10#${num_changed}))
}

# ============================================================================
# Main Logic
# ============================================================================

function main {
  local project_files_changed example_files_changed total_files_changed

  count_files_changed "project" "${input_project_outcome:-}" "${input_project_num_changed:-}"
  project_files_changed="${_files_changed}"
  log-info "Project files changed: ${project_files_changed}"

  count_files_changed "examples" "${input_examples_outcome:-}" "${input_examples_num_changed:-}"
  example_files_changed="${_files_changed}"
  log-info "Example files changed: ${example_files_changed}"

  total_files_changed=$((project_files_changed + example_files_changed))
  log-info "Total files changed: ${total_files_changed}"
  set-output "number-of-files-changed" "${total_files_changed}"

  case "${input_validate_outcome:-}" in
    failure | cancelled)
      log-error "README validation did not succeed (outcome '${input_validate_outcome}')."
      return 1
      ;;
  esac
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
