#!/bin/env bash
#
# Action-specific helpers for terraform-plan.
# Auto-loaded by helpers.sh.
#

# Format an integer seconds count as 'mm:ss'.
# Minutes are zero-padded only to width 1 (so '0:07', '1:23'); seconds are
# always zero-padded to width 2. Minutes may exceed 99 — CI plans rarely
# do, but the format degrades gracefully (e.g. '120:05'). No hours field
# on purpose: keeps the renderer trivial and the display unambiguous.
function format-duration-mmss {
  local total="${1:-0}"
  local minutes=$((total / 60))
  local seconds=$((total % 60))
  printf '%d:%02d' "${minutes}" "${seconds}"
}

# Split a whitespace-delimited argument string into the array named by $1.
#
#   $1 - name of the array variable to populate
#   $2 - the argument string (may be empty, may contain newlines)
#
# The 'extra-global-args' / 'extra-plan-args' inputs are documented as strings
# of arguments the caller injects verbatim, so splitting on whitespace is their
# contract and is preserved here. What changes is everything around it: the
# command used to be assembled into one string and then re-split by the shell
# at invocation time, which also glob-expanded every element against the
# working directory and turned an empty input into an empty argv element in
# some shells. Splitting once, here, and invoking as "${cmd[@]}" keeps the
# caller's words intact while the paths the action itself builds are never
# split or expanded.
#
# Note: quoting inside the argument string is NOT shell-parsed —
# '-var=msg=a b' is two arguments, not one. Honoring quotes would mean 'eval'
# or 'xargs', both of which change behaviour for existing callers (an
# unbalanced apostrophe currently passes through fine and would start failing).
function split-args-to-array {
  local -n _args_out="${1}"
  # Newlines and tabs are whitespace for this purpose too; 'read' without -d
  # would otherwise stop at the first newline and silently drop the rest.
  local _str="${2//[$'\n\t']/ }"

  _args_out=()
  read -r -a _args_out <<<"${_str}"
}
