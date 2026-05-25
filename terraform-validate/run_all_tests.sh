#!/bin/env bash
#
# Orchestrates the per-step test suites for terraform-validate.
# See docs/Testing-in-ci.md §4.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

YELLOW='\033[1;33m'
NC='\033[0m'

overall_exit=0

run_suite() {
  local script="${1}"
  local label="${2}"

  echo ""
  echo -e "${YELLOW}>>> Running ${label}${NC}"
  bash "${script}" || overall_exit=1
}

run_suite "${_this_script_dir}/run_tests_step_validate.sh" "step_validate.sh tests"

exit ${overall_exit}
