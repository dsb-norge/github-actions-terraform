#!/bin/env bash
#
# Action-specific helpers for lint-with-tflint.
# Auto-loaded by helpers.sh.
#

# Read the module directories terraform recorded in
# '<project-dir>/.terraform/modules/modules.json' into the array named by $1.
#
#   $1 - name of the array variable to populate
#   $2 - path to modules.json
#   $3 - prefix to prepend to each relative directory (usually "$(pwd)/")
#
# NUL-delimited (jq --raw-output0 + read -d '') rather than newline-joined into
# a single string: the previous form iterated that string as '${DIRS[*]}', which
# is not array iteration but word-splitting — so a module path containing a
# space silently visited two directories that do not exist instead of the one
# that does. Requires jq 1.7, ref. docs/Per-goal-environment-variables.md §9.2.
function read-terraform-module-dirs {
  local -n _dirs_out="${1}"
  local _modules_file="${2}"
  local _prefix="${3}"
  local _dir

  _dirs_out=()
  while IFS= read -r -d '' _dir; do
    _dirs_out+=("${_dir}")
  done < <(jq --raw-output0 --arg pwd "${_prefix}" \
    '[ .Modules[].Dir | select( startswith(".terraform") | not) ] | unique | sort | $pwd + .[]' \
    "${_modules_file}")
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
