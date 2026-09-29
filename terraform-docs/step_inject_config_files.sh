#!/bin/env bash
#
# Source for the inject-config-files step
#
# Gives terraform-docs a config where the repository has none: copies the action's default
# config to .terraform-docs.yml in the repository root and, when the repository has an
# examples/ folder, to examples/.terraform-docs.yml. A config the repository already has is
# left alone.
#
# What happens to an injected config depends on push:
#   true  - it is staged with 'git add', so the terraform-docs push commits it with the docs.
#   false - it stays in the working tree only, and is listed in the checkout's
#           .git/info/exclude. terraform-docs/gh-actions stages each working directory whole
#           ('git add <dir>/') and counts every staged file as a change, so an untracked
#           injected config would count as drift and fail its fail-on-diff check. Excluded, it
#           is neither staged nor counted: a repository without a config of its own is judged
#           on its READMEs alone, against the default config, and nothing is committed.
#
# Publishes whether examples/ exists and the comma-separated list of its subfolders, the
# working directories of the examples step.
#
# Required environment variables:
#   input_push          - 'true' to stage injected configs for the push, 'false' to exclude them
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

  if [[ "${input_push}" == "true" ]]; then
    log-info "Adding ${config_path} to the git commit."
    git -C "${GITHUB_WORKSPACE}" add -- "${config_path}" || return 1
  else
    log-info "Not pushing: keeping ${config_path} out of git, so it is neither committed nor counted as a change."
    exclude_from_git "${config_path}" || return 1
  fi
}

# List a path in the checkout's info/exclude, anchored at the repository root.
#   $1 - the path relative to the checkout
function exclude_from_git {
  local config_path="${1}"
  local exclude_file
  # --git-path resolves info/exclude in a linked worktree too; relative to the checkout.
  exclude_file="$(git -C "${GITHUB_WORKSPACE}" rev-parse --git-path info/exclude)" || return 1
  [[ "${exclude_file}" == /* ]] || exclude_file="${GITHUB_WORKSPACE}/${exclude_file}"
  mkdir -p "$(dirname "${exclude_file}")" || return 1
  echo "/${config_path}" >>"${exclude_file}" || return 1
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
  case "${input_push:-}" in
    true | false) ;;
    *)
      log-error "Input 'push' must be 'true' or 'false', got '${input_push:-}'."
      return 1
      ;;
  esac

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
