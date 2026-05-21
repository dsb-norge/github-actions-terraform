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
