#!/bin/env bash
#
# Source for the inject-config-files step
#
# Gives terraform-docs a config where the repository has none: copies the action's default
# config to .terraform-docs.yml in the repository root and, when the repository has an
# examples/ folder, to examples/.terraform-docs.yml. An injected config is staged with
# 'git add', so the terraform-docs push commits it together with the docs. A config the
# repository already has is left alone.
#
# Publishes whether examples/ exists and the comma-separated list of its subfolders, the
# working directories of the examples step.
#
# Required environment variables:
#   GITHUB_WORKSPACE    - the repository checkout
#   GITHUB_ACTION_PATH  - this action's directory, which holds the default configs
#

set -o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Helper Functions (step-local)
# ============================================================================

# Copy one default config into the checkout unless the repository has its own.
#   $1 - the default config in this action's directory
#   $2 - the config's path relative to the checkout
function inject_config {
  local default_config="${1}"
  local config_path="${2}"

  if [[ -f "${GITHUB_WORKSPACE}/${config_path}" ]]; then
    log-info "${config_path} found. Nothing to do."
    return 0
  fi

  log-info "${config_path} not found. Creating the default config."
  cp "${default_config}" "${GITHUB_WORKSPACE}/${config_path}" || return 1
  log-info "${config_path} created."

  log-info "Adding ${config_path} to the git commit."
  git -C "${GITHUB_WORKSPACE}" add -- "${config_path}" || return 1
}

# Print the subfolders of examples/ as 'examples/<a>/,examples/<b>/,', relative to the
# checkout: the list terraform-docs/gh-actions takes as working-dir, trailing comma included.
function list_examples_subfolders {
  local folder list=""
  for folder in "${GITHUB_WORKSPACE}"/examples/*/; do
    [[ -d "${folder}" ]] || continue
    list+="${folder#"${GITHUB_WORKSPACE}/"},"
  done
  echo "${list}"
}

# ============================================================================
# Main Logic
# ============================================================================

function main {
  inject_config "${GITHUB_ACTION_PATH}/terraform-docs-module-root.yml" ".terraform-docs.yml" || {
    log-error "Could not create .terraform-docs.yml in the repository root."
    return 1
  }

  if [[ ! -d "${GITHUB_WORKSPACE}/examples" ]]; then
    log-info "examples folder not found in the repository root. Examples docs will not be generated."
    set-output "examples-folder-exists" "false"
    return 0
  fi

  log-info "examples folder found in the repository root."
  set-output "examples-folder-exists" "true"

  inject_config "${GITHUB_ACTION_PATH}/terraform-docs-module-examples.yml" "examples/.terraform-docs.yml" || {
    log-error "Could not create .terraform-docs.yml in the examples folder."
    return 1
  }

  log-multiline "examples directory content" "$(ls -la "${GITHUB_WORKSPACE}/examples/")"

  local subfolders
  subfolders="$(list_examples_subfolders)"
  log-info "examples subfolders: '${subfolders}'"
  set-output "examples-subfolders" "${subfolders}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
