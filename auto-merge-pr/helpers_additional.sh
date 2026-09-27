#!/bin/env bash
#
# Action-specific helpers for auto-merge-pr.
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
