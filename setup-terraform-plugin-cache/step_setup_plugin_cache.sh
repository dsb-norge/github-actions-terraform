#!/bin/env bash
#
# Source for the setup-terraform-plugin-cache action (the 'setup' step).
#
# Configures Terraform's provider plugin cache: creates the cache directory
# and points the CLI configuration (~/.terraformrc) at it, then publishes
# the directory and a monthly rolling cache key for actions/cache.
#
# Inputs (environment):
#   HOME        - the runner's home; the cache and ~/.terraformrc live under it
#   RUNNER_OS   - e.g. 'Linux'; part of the cache key, lower-cased
#   RUNNER_ARCH - e.g. 'X64'; part of the cache key, lower-cased
#
# Outputs (GITHUB_OUTPUT):
#   plugin-cache-directory - "${HOME}/.terraform.d/plugin-cache"
#   monthly-rolling        - terraform-provider-plugin-cache-<os>-<arch>-<Mon>-<yy>,
#                            e.g. terraform-provider-plugin-cache-linux-x64-Sep-26
#
# The key keeps the month's abbreviated name (date +%b) it has always had:
# changing its format would start every caller's cache anew for no gain.
#

source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  local plugin_cache_dir="${HOME}/.terraform.d/plugin-cache"
  local cli_config_file="${HOME}/.terraformrc"

  log-info "creating plugin cache directory '${plugin_cache_dir}' ..."
  if [ -d "${plugin_cache_dir}" ]; then
    log-info "nothing to do, plugin cache directory already exists."
  elif ! mkdir -p "${plugin_cache_dir}"; then
    log-error "could not create the plugin cache directory '${plugin_cache_dir}'"
    return 1
  fi

  log-info "creating Terraform CLI Configuration file '${cli_config_file}' ..."
  if [ -f "${cli_config_file}" ]; then
    log-warn "Overwriting existing Terraform CLI Configuration file!"
    log-multiline "contents of .terraformrc before overwrite" "$(cat "${cli_config_file}")"
  fi
  if ! echo "plugin_cache_dir = \"${plugin_cache_dir}\"" >"${cli_config_file}"; then
    log-error "could not write the Terraform CLI Configuration file '${cli_config_file}'"
    return 1
  fi
  log-multiline "contents of .terraformrc is" "$(cat "${cli_config_file}")"
  set-output 'plugin-cache-directory' "${plugin_cache_dir}"

  log-info "Monthly rolling cache key format is: terraform-provider-plugin-cache-[os]-[arch]-[month]-[year num]"
  local cache_key="terraform-provider-plugin-cache-${RUNNER_OS,,}-${RUNNER_ARCH,,}-$(date +%b)-$(date +%y)"
  log-info "Monthly rolling cache key is: ${cache_key}"
  set-output 'monthly-rolling' "${cache_key}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
