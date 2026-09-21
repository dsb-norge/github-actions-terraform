#!/bin/env bash
#
# Action-specific helpers for parse-terraform-apply.
# Auto-loaded by helpers.sh.
#

# Escape a value for the message part of a GitHub workflow command
# (everything after '::'). Only %, CR and LF are special there.
# https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions
function escape-annotation-message {
  local s="${1}"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "${s}"
}

# The one run-page signal this parser owns: terraform's console did not look
# the way this parser expects, and somebody should send it in. Emitted as a
# ::warning so it lands on the run page and in the PR checks pane, where the
# log line it accompanies would never be read.
function warn-output-not-recognised {
  echo "::warning title=Terraform output not recognised::$(escape-annotation-message "${1}")"
}
