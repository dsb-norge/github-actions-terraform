#!/bin/env bash
#
# Action-specific helpers for post-teams-notification.
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

# Escape a value for a name=value property of a workflow command (the
# title). ':' and ',' are property delimiters there, so they are escaped
# too. '%' first, so later replacements are not re-escaped.
function escape-annotation-property {
  local s="${1}"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  s="${s//:/%3A}"
  s="${s//,/%2C}"
  printf '%s' "${s}"
}
