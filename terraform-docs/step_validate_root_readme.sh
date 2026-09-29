#!/bin/env bash
#
# Source for the validate-root-readme step
#
# Makes sure the README terraform-docs injects into has the BEGIN_TF_DOCS / END_TF_DOCS
# delimiters. A README without both gets them appended, with a note not to edit between
# them. A README whose delimiters are in the wrong order, or that holds one of them more than
# once, fails the step: terraform-docs cannot tell where the generated part is. A missing
# README is fine; terraform-docs creates it.
#
# Required environment variables:
#   input_readme_file_path  - the directory holding README.md, relative to the checkout or absolute
#

set -o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

readonly BEGIN_DELIMITER='<!-- BEGIN_TF_DOCS -->'
readonly END_DELIMITER='<!-- END_TF_DOCS -->'

# ============================================================================
# Helper Functions (step-local)
# ============================================================================

function append_delimiters {
  local readme_file="${1}"
  log-info "Adding delimiters to ${readme_file}"
  printf "\nBelow is a placeholder for Terraform-docs generated documentation. Do not edit between the delimiters.\n" >>"${readme_file}"
  {
    echo "${BEGIN_DELIMITER}"
    echo " "
    echo "${END_DELIMITER}"
  } >>"${readme_file}"
  log-info "Delimiters added to ${readme_file}"
}

# ============================================================================
# Main Logic
# ============================================================================

function main {
  local readme_file="${input_readme_file_path:-}/README.md"

  if [[ ! -f "${readme_file}" ]]; then
    log-info "File ${readme_file} does not exist. Terraform-docs will create a new README.md file."
    return 0
  fi

  log-info "Checking if delimiters exist in ${readme_file}"
  if ! grep -qF -- "${BEGIN_DELIMITER}" "${readme_file}" || ! grep -qF -- "${END_DELIMITER}" "${readme_file}"; then
    log-info "Delimiters do not exist in ${readme_file}"
    append_delimiters "${readme_file}"
    return 0
  fi

  local begin_lines end_lines
  begin_lines="$(grep -nF -- "${BEGIN_DELIMITER}" "${readme_file}" | cut -d: -f1)"
  end_lines="$(grep -nF -- "${END_DELIMITER}" "${readme_file}" | cut -d: -f1)"
  log-info "BEGIN_TF_DOCS found on line(s): ${begin_lines//$'\n'/ }"
  log-info "END_TF_DOCS found on line(s): ${end_lines//$'\n'/ }"

  if [[ "${begin_lines}" == *$'\n'* || "${end_lines}" == *$'\n'* ]]; then
    log-error "A delimiter appears more than once, verify ${readme_file}"
    return 1
  fi

  if [[ "${begin_lines}" -ge "${end_lines}" ]]; then
    log-error "Delimiters are not in the correct order, verify ${readme_file}"
    return 1
  fi

  log-info "Delimiters are in the correct order"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
