#!/bin/env bash
#
# Tests for step_parse_warnings.sh
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
_test_data_dir="${_this_script_dir}/test-data"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

setup_workdir() {
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_WORKSPACE="${RUNNER_TEMP}"

  export input_step_label="plan"
  export input_environment_name="testenv"
  unset input_console_output_file
}

run_step() {
  (
    set -o allexport
    source "${_this_script_dir}/step_parse_warnings.sh"
  ) >/tmp/test_output_parse_warnings.txt 2>&1
  LAST_EXIT=$?
}

get_output() {
  local key="${1}"
  grep "^${key}=" "${GITHUB_OUTPUT}" | head -n1 | cut -d= -f2-
}

assert() {
  local name="${1}"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name}${NC}"
  if "$@"; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}"
    echo "--- step output ---"
    cat /tmp/test_output_parse_warnings.txt 2>/dev/null || true
    echo "--- GITHUB_OUTPUT ---"
    cat "${GITHUB_OUTPUT}" 2>/dev/null || true
    echo "--- markdown ---"
    cat "$(get_output warnings-markdown-file)" 2>/dev/null || true
    echo "--- /markdown ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

count_annotations() {
  # Counts ::warning lines in the step's stdout. grep -c always prints a
  # number; it exits 1 when count is 0, hence the '|| true' rather than
  # '|| echo 0' which would emit a second "0" line.
  grep -c '^::warning' /tmp/test_output_parse_warnings.txt 2>/dev/null || true
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}    PARSE-TERRAFORM-WARNINGS STEP TESTS    ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ----------------------------------------------------------------------
# t01: clean file, no warnings
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file="${_test_data_dir}/t01_no_warnings.log"
run_step
assert "t01: exits 0" test "${LAST_EXIT}" -eq 0
assert "t01: warning-count is 0" test "$(get_output warning-count)" = "0"
assert "t01: no ::warning emitted" test "$(count_annotations)" -eq 0
assert "t01: markdown file is empty" test ! -s "$(get_output warnings-markdown-file)"

# ----------------------------------------------------------------------
# t02: single warning with file/line context
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file="${_test_data_dir}/t02_single_warning_with_context.log"
run_step
assert "t02: exits 0" test "${LAST_EXIT}" -eq 0
assert "t02: warning-count is 1" test "$(get_output warning-count)" = "1"
assert "t02: one ::warning emitted" test "$(count_annotations)" -eq 1
assert "t02: annotation has file=" \
  grep -q "::warning file=.terraform/modules/foo/main.tf" /tmp/test_output_parse_warnings.txt
assert "t02: annotation has line=176" \
  grep -q "line=176" /tmp/test_output_parse_warnings.txt
assert "t02: annotation title includes step label" \
  grep -q "title=terraform plan warning" /tmp/test_output_parse_warnings.txt
assert "t02: markdown contains source line" \
  grep -q "source: .*main.tf:176" "$(get_output warnings-markdown-file)"
assert "t02: markdown contains step header" \
  grep -q "### From terraform plan" "$(get_output warnings-markdown-file)"

# ----------------------------------------------------------------------
# t03: single warning without file/line context (provider-level)
# ----------------------------------------------------------------------
setup_workdir
export input_step_label="init"
export input_console_output_file="${_test_data_dir}/t03_single_warning_no_context.log"
run_step
assert "t03: exits 0" test "${LAST_EXIT}" -eq 0
assert "t03: warning-count is 1" test "$(get_output warning-count)" = "1"
assert "t03: one ::warning emitted" test "$(count_annotations)" -eq 1
assert "t03: annotation has NO file=" \
  bash -c "! grep -q '::warning file=' /tmp/test_output_parse_warnings.txt"
assert "t03: annotation has title=" \
  grep -q "::warning title=terraform init warning" /tmp/test_output_parse_warnings.txt
assert "t03: markdown step header reflects init label" \
  grep -q "### From terraform init" "$(get_output warnings-markdown-file)"

# ----------------------------------------------------------------------
# t04: aggregator suffix '(and N more similar warnings elsewhere)'
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file="${_test_data_dir}/t04_aggregator_suppression.log"
run_step
assert "t04: warning-count is 3 (1 shown + 2 suppressed)" \
  test "$(get_output warning-count)" = "3"
assert "t04: exactly 1 ::warning emitted (aggregator doesn't multiply annotations)" \
  test "$(count_annotations)" -eq 1
assert "t04: markdown mentions 'and 2 more'" \
  grep -q "and 2 more similar warnings elsewhere" "$(get_output warnings-markdown-file)"

# ----------------------------------------------------------------------
# t05: three distinct warning blocks
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file="${_test_data_dir}/t05_multiple_blocks.log"
run_step
# 1 + 2 + 1 + 2 + 1 + 0 = 7 (block1: 1+2, block2: 1+2, block3: 1+0)
assert "t05: warning-count sums all blocks including suppressed" \
  test "$(get_output warning-count)" = "7"
assert "t05: three ::warning annotations emitted" \
  test "$(count_annotations)" -eq 3
assert "t05: markdown contains '---' separators between blocks" \
  bash -c "[[ \$(grep -c '^---$' '$(get_output warnings-markdown-file)') -ge 3 ]]"

# ----------------------------------------------------------------------
# t05 regression: 'with module …' context line must NOT leak into the
# message body of the second warning. (Bug observed during initial
# implementation: indented context lines other than 'on … line N' and
# the code-excerpt line were being collected as part of the message.)
# ----------------------------------------------------------------------
assert "t05 regression: second annotation does not contain 'with module'" \
  bash -c "! grep -q 'with module' /tmp/test_output_parse_warnings.txt"

# ----------------------------------------------------------------------
# t06: Warning followed by Error — error body should NOT bleed in
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file="${_test_data_dir}/t06_warning_then_error.log"
run_step
assert "t06: warning-count is 1" test "$(get_output warning-count)" = "1"
assert "t06: exactly 1 ::warning emitted" test "$(count_annotations)" -eq 1
assert "t06: annotation does NOT include error text" \
  bash -c "! grep -q 'undeclared resource' /tmp/test_output_parse_warnings.txt"
assert "t06: markdown body does NOT contain 'Reference to undeclared resource'" \
  bash -c "! grep -q 'undeclared resource' '$(get_output warnings-markdown-file)'"

# ----------------------------------------------------------------------
# t07: non-ASCII characters in message
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file="${_test_data_dir}/t07_non_ascii_message.log"
run_step
assert "t07: warning-count is 1" test "$(get_output warning-count)" = "1"
assert "t07: markdown contains em-dash from source" \
  grep -q "formerly known as" "$(get_output warnings-markdown-file)"
assert "t07: markdown file is valid UTF-8" \
  iconv -f UTF-8 -t UTF-8 "$(get_output warnings-markdown-file)" >/dev/null

# ----------------------------------------------------------------------
# t08: empty file → count=0, no crash
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file="${_test_data_dir}/t08_empty_file.log"
run_step
assert "t08: exits 0" test "${LAST_EXIT}" -eq 0
assert "t08: warning-count is 0" test "$(get_output warning-count)" = "0"
assert "t08: no annotations" test "$(count_annotations)" -eq 0

# ----------------------------------------------------------------------
# t09: init provider deprecation
# ----------------------------------------------------------------------
setup_workdir
export input_step_label="init"
export input_console_output_file="${_test_data_dir}/t09_init_provider_deprecation.log"
run_step
assert "t09: warning-count is 1" test "$(get_output warning-count)" = "1"
assert "t09: annotation has file=" \
  grep -q "::warning file=" /tmp/test_output_parse_warnings.txt
assert "t09: file path is providers.tf" \
  grep -q "providers.tf" /tmp/test_output_parse_warnings.txt
assert "t09: line is 8" grep -q "line=8" /tmp/test_output_parse_warnings.txt

# ----------------------------------------------------------------------
# Missing input_console_output_file → count=0, no crash
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file=""
run_step
assert "missing input: exits 0" test "${LAST_EXIT}" -eq 0
assert "missing input: warning-count is 0" test "$(get_output warning-count)" = "0"
assert "missing input: markdown file exists but is empty" \
  bash -c "[ -e '$(get_output warnings-markdown-file)' ] && [ ! -s '$(get_output warnings-markdown-file)' ]"

# ----------------------------------------------------------------------
# Nonexistent input file → count=0
# ----------------------------------------------------------------------
setup_workdir
export input_console_output_file="${RUNNER_TEMP}/does-not-exist.log"
run_step
assert "nonexistent input: exits 0" test "${LAST_EXIT}" -eq 0
assert "nonexistent input: warning-count is 0" test "$(get_output warning-count)" = "0"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}       step_parse_warnings.sh SUMMARY       ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
