#!/bin/env bash
#
# Source for the install step of setup-tflint.
#
# Downloads the resolved tflint zip and extracts it into install-dir.
# Verifies the binary exists at install-bin-path after extraction.
#
# Required environment variables:
#   input_download_url      - direct .zip download URL
#   input_install_dir       - where to extract
#   input_install_bin_path  - expected binary path after extraction
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  log-info "download tflint from: ${input_download_url}"
  log-info "install tflint to   : ${input_install_dir}"

  curl -L "${input_download_url}" -o tflint.zip \
    && unzip tflint.zip -d "${input_install_dir}" \
    && rm tflint.zip

  if [ ! -f "${input_install_bin_path}" ]; then
    log-error "binary not found at '${input_install_bin_path}' after installation!"
    return 1
  fi
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
