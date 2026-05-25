#!/bin/env bash
#
# Local testing/debugging script for step_parse_warnings.sh.
# Uses the t05_multiple_blocks.log fixture; tweak input_console_output_file
# to try other fixtures.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${RUNNER_TEMP}"

export input_console_output_file="${_this_script_dir}/test-data/t05_multiple_blocks.log"
export input_step_label="plan"
export input_environment_name="sandbox"

source "${_this_script_dir}/step_parse_warnings.sh"

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
echo ""
echo "========================================"
echo "Rendered markdown:"
echo "========================================"
md_file=$(grep '^warnings-markdown-file=' "${GITHUB_OUTPUT}" | cut -d= -f2-)
cat "${md_file}" 2>/dev/null || echo "(missing)"
