#!/bin/env bash
#
# Source for the create-matrix step
#
# Resolves every environment's variables into the job matrix. The decisions are made by the
# engine in ../engine (docs/Decision-engine.md); this step gathers what the engine may not
# read itself, runs it, and publishes the matrix.
#
# Required environment variables:
#   input_inputs_json     - toJSON(inputs) of the calling workflow; shell-local, never exported
#   input_repository      - github.repository
#   input_event_name      - github.event_name
#   input_ref_name        - github.ref_name
#   input_default_branch  - github.event.repository.default_branch, may be empty
#   GH_TOKEN              - for the default-branch fallback through the API
#

set -o nounset

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Main Logic
# ============================================================================

function main {
  local work engine_exit
  work="$(mktemp -d)"

  require-python || return 1
  require-yq || return 1

  # Builtin printf: the inputs never reach an exec'd argv or envp.
  printf '%s' "${input_inputs_json}" >"${work}/inputs.json"
  start-group "input 'inputs-json'"
  cat "${work}/inputs.json"
  echo
  end-group

  resolve-default-branch "${input_default_branch}" "${work}/default-branch" || return 1
  build-input-document "${work}/inputs.json" "${work}/input-document.json" "${work}/default-branch"

  start-group "decision engine input document"
  jq . "${work}/input-document.json"
  end-group

  # `|| engine_exit=$?`: the runner sources this under `bash -e`, which would end the step at
  # a non-zero exit before the code could be read.
  engine_exit=0
  PYTHONPATH="${GITHUB_ACTION_PATH}/../engine" python3 -B -m dsb_tf_engine decide \
    --input "${work}/input-document.json" --output "${work}/output-document.json" \
    2>"${work}/engine-stderr.txt" || engine_exit=$?

  if [[ ${engine_exit} -eq 2 ]]; then
    # One annotation per message, its data escaped as the workflow-command syntax requires, so a
    # newline in a caller's value can neither split the message nor start a command.
    jq -r '.errors[] | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A")' "${work}/output-document.json" \
      | while IFS= read -r message; do
        echo "::error title=create-tf-vars-matrix::${message}"
      done
    return 2
  elif [[ ${engine_exit} -ne 0 ]]; then
    log-error "the decision engine failed (exit code ${engine_exit}):"
    print-verbatim "${work}/engine-stderr.txt"
    return 1
  fi

  jq -r '.record[]' "${work}/output-document.json" >"${work}/record.txt"
  start-group "decision record"
  print-verbatim "${work}/record.txt"
  end-group

  jq -c '.matrices["1"]' "${work}/output-document.json" >"${work}/matrix.json"
  start-group "matrix-json"
  jq . "${work}/matrix.json"
  end-group
  set-multiline-output-from-file 'matrix-json' "${work}/matrix.json"

  rm -rf "${work}"
  return 0
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
