#!/bin/env bash
#
# Source for the add-to-path step of setup-tflint.
#
# Appends install-dir to $GITHUB_PATH so subsequent steps can run `tflint`
# directly. Best-effort tflint --version smoke check at the end is allowed
# to fail (it usually succeeds, but we don't want a missing binary or PATH
# issue at this point to fail the whole action — install-step verification
# already guarantees the binary exists).
#
# Required environment variables:
#   input_install_dir       - dir to prepend to PATH
#   GITHUB_PATH             - file the runner appends to actual PATH between steps
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  log-info "add binary to PATH at '${input_install_dir}'"
  echo "${input_install_dir}" >> "${GITHUB_PATH}"
  # NOTE: faithful to pre-conversion behavior — tflint isn't on PATH yet
  # (GITHUB_PATH is consumed between steps, not within one) so this echo
  # almost always emits just "  successfully installed and added to path 🥳"
  # with an empty version. The `|| :` swallows the resulting command-not-found.
  # Worth a follow-up to call via absolute path instead, but kept here for
  # behavior-preserving conversion.
  echo "$(tflint --version) successfully installed and added to path 🥳" || :
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
