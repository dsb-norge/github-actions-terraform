#!/bin/env bash
#
# Orchestrates the per-step test suites for terraform-plan.
#
# Each per-step script (run_tests_step_*.sh) emits the canonical
#   Tests run:    <N>
#   Tests passed: <N>
#   Tests failed: <N>
# lines that the action-tests workflow parses (docs/Testing-in-ci.md §4).
# The workflow SUMS those lines across all matches in the orchestrator's
# stdout, so this script must NOT emit a fourth aggregate block —
# doing so would double-count (see docs/Testing-in-ci.md §4 paragraph on
# multi-step orchestrators).
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

run_suite "${_this_script_dir}/run_tests_step_plan.sh"      "step_plan.sh tests"
run_suite "${_this_script_dir}/run_tests_step_plan_show.sh" "step_plan_show.sh tests"
run_suite "${_this_script_dir}/run_tests_step_plan_json.sh" "step_plan_json.sh tests"

exit ${overall_exit}
