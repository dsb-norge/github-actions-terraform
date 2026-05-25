#!/bin/env bash
#
# Source for the parse-terraform-warnings step.
#
# Scans a terraform console-output file for 'Warning:' blocks, emits one
# GitHub workflow ::warning annotation per block (with file=,line= when
# terraform printed source context), and renders a markdown block listing
# every warning for inclusion in the PR plan-tag comment.
#
# Required environment variables:
#   input_console_output_file - Path to the file to scan. Empty / missing
#                               / unreadable file is not an error: count=0,
#                               markdown file empty.
#   input_step_label          - One of 'init' | 'validate' | 'plan'. Used
#                               in annotation titles and as the markdown
#                               subheader so reviewers can tell which
#                               step a warning came from.
#   input_environment_name    - Used in the output markdown file name.
#
# Outputs:
#   warning-count           - Integer total: sum of (1 + suppressed_count)
#                             across all detected blocks. Suppressed entries
#                             come from terraform's '(and N more similar
#                             warnings elsewhere)' aggregator suffix.
#   warnings-markdown-file  - Path of the rendered markdown file. Always
#                             populated (the file is empty when count=0).
#
# Side effects:
#   Emits one ::warning workflow command per detected block to stdout.
#   GitHub picks these up as run-page annotations.
#
# IMPORTANT: do NOT expose the rendered markdown content as a step output
# — only the file path. Past incident: large step-output values blew
# ARG_MAX in downstream forks. See capture-matrix-job-meta/action.yml.
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  local console_file="${input_console_output_file:-}"
  local step_label="${input_step_label:-unknown}"
  local env_name="${input_environment_name:-}"

  local md_file="${GITHUB_WORKSPACE}/tf-warnings-${env_name}-${step_label}.md"
  : > "${md_file}"  # always create, even when empty
  set-output 'warnings-markdown-file' "${md_file}"

  if [ -z "${console_file}" ] || [ ! -s "${console_file}" ]; then
    log-info "no console-output file to scan (label='${step_label}'); count=0"
    set-output 'warning-count' "0"
    return 0
  fi

  log-info "scanning '${console_file}' for warnings (label='${step_label}')"

  # awk does the heavy lifting: state machine over the file, emits
  # annotations to stdout and writes markdown blocks to a tmp file. Bash
  # then prepends the per-step header and the per-block separators get
  # collapsed into the final md_file.
  local annotations_tmp="${RUNNER_TEMP:-/tmp}/warnings-annot-$$.txt"
  local md_blocks_tmp="${RUNNER_TEMP:-/tmp}/warnings-md-$$.txt"
  local count_tmp="${RUNNER_TEMP:-/tmp}/warnings-count-$$.txt"

  awk -v step_label="${step_label}" \
      -v md_out="${md_blocks_tmp}" \
      -v annot_out="${annotations_tmp}" \
      -v count_out="${count_tmp}" \
      -f "${GITHUB_ACTION_PATH}/parse_warnings.awk" \
      "${console_file}"

  # Echo annotations to stdout so GitHub captures them. Writing them via
  # awk -> tmp -> cat instead of awk -> stdout directly keeps them out of
  # the interleaved log-info stream above.
  if [ -s "${annotations_tmp}" ]; then
    cat "${annotations_tmp}"
  fi

  # Compose the final markdown file: header (only when there's content)
  # followed by the per-block bodies.
  local count="0"
  [ -s "${count_tmp}" ] && count="$(cat "${count_tmp}")"

  if [ "${count}" -gt 0 ] && [ -s "${md_blocks_tmp}" ]; then
    {
      printf '### From terraform %s\n\n' "${step_label}"
      cat "${md_blocks_tmp}"
    } > "${md_file}"
  fi

  set-output 'warning-count' "${count}"

  log-info "warning-count=${count}, markdown-file=${md_file}"

  rm -f "${annotations_tmp}" "${md_blocks_tmp}" "${count_tmp}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
