#!/bin/env bash
#
# Comprehensive test runner for step_capture.sh
# Tests various scenarios including edge cases and missing data handling
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# Function to run a single test
run_test() {
  local test_name="${1}"
  local expected_field_check="${2}"  # jq expression to validate
  local expected_result="${3}"

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Set up GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)

  # Required system variables
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  export GITHUB_RUN_ID="12345678"
  export GITHUB_RUN_NUMBER="42"
  export GITHUB_RUN_ATTEMPT="1"
  export GITHUB_WORKFLOW="Terraform CI/CD"
  export GITHUB_JOB="terraform-ci-cd"
  export GITHUB_ACTOR="test-user"
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_REF="refs/pull/123/merge"
  export GITHUB_SHA="abc123def456"

  # Run the step_capture.sh script in a subshell. No allexport, and the
  # three JSON inputs are deliberately NOT exported by reset_defaults —
  # both to match the action.yml shim, which heredoc-captures them as
  # shell-locals precisely so they never reach envp (see the shim's
  # comment on the production E2BIG incident). A harness that exported
  # them would E2BIG the step's own jq on the oversize fixtures below and
  # test the harness, not the cap.
  (
    source "${_this_script_dir}/step_capture.sh"
  ) > /tmp/test_output.txt 2>&1
  local exit_code=$?

  # Get the result file path
  local result_file
  result_file=$(grep "^result-json-file=" "${GITHUB_OUTPUT}" | cut -d= -f2)

  # Validate
  local actual_result=""
  if [[ -f "${result_file}" ]]; then
    actual_result=$(cat "${result_file}" | jq -r "${expected_field_check}" 2>/dev/null)
  fi

  if [[ "${exit_code}" -eq 0 && "${actual_result}" == "${expected_result}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}: Exit code=${exit_code}, field check passed"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: Expected '${expected_result}', got '${actual_result}', exit code=${exit_code}"
    echo ""
    echo "Test output:"
    cat /tmp/test_output.txt
    if [[ -f "${result_file}" ]]; then
      echo ""
      echo "Result file:"
      cat "${result_file}" | jq '.'
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${RUNNER_TEMP}"
}

# Function to reset all variables to defaults
reset_defaults() {
  export input_environment_name="test-env"
  unset input_entity_name input_artifact_name
  # Plain assignments, not exports — see run_test.
  input_matrix_context_json='{
    "environment": "test-env",
    "vars": {
      "github-environment": "test-env",
      "goals": ["all"]
    }
  }'
  input_github_context_json='{"repository": "test/repo"}'
  input_steps_context_json='{
    "init": {"outputs": {}, "outcome": "success", "conclusion": "success"},
    "fmt": {"outputs": {}, "outcome": "success", "conclusion": "success"},
    "validate": {"outputs": {}, "outcome": "success", "conclusion": "success"},
    "plan": {"outputs": {}, "outcome": "success", "conclusion": "success"}
  }'
}

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}     MATRIX JOB METADATA CAPTURE TESTS     ${NC}"
echo -e "${YELLOW}============================================${NC}"

# ============================================================================
# Test 1: Basic capture with minimal inputs
# ============================================================================
reset_defaults
run_test "Basic capture with minimal inputs" '.metadata.environment' "test-env"

# ============================================================================
# Test 2: Capture with step outcomes
# ============================================================================
reset_defaults
input_steps_context_json='{
  "init": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "plan": {"outputs": {}, "outcome": "failure", "conclusion": "failure"}
}'
run_test "Capture with step outcomes" '.steps["plan"].outcome' "failure"

# ============================================================================
# Test 3: Handle missing/empty JSON gracefully
# ============================================================================
reset_defaults
input_matrix_context_json=""
run_test "Handle missing matrix context JSON" '.matrix_context' "{}"

# ============================================================================
# Test 4: Capture step outputs correctly
# ============================================================================
reset_defaults
input_steps_context_json='{
  "parse-plan": {"outputs": {"count-add": "5", "count-change": "2"}, "outcome": "success", "conclusion": "success"}
}'
run_test "Capture step outputs" '.steps["parse-plan"].outputs["count-add"]' "5"

# ============================================================================
# Test 5: Filter sensitive data from matrix context
# ============================================================================
reset_defaults
input_matrix_context_json='{
  "environment": "test",
  "vars": {
    "github-environment": "test",
    "secret-value": "should-be-removed",
    "password": "hidden"
  }
}'
run_test "Filter sensitive data from matrix context" '.matrix_context.vars | has("secret-value")' "false"

# ============================================================================
# Test 6: Schema version is set (updated to 2.0.0)
# ============================================================================
reset_defaults
run_test "Schema version is set" '.metadata.schema_version' "2.0.0"

# ============================================================================
# Test 7: Steps are captured dynamically
# ============================================================================
reset_defaults
input_steps_context_json='{
  "step1": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step2": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step3": {"outputs": {}, "outcome": "success", "conclusion": "success"}
}'
run_test "Steps captured dynamically (count)" '.steps | keys | length' "3"

# ============================================================================
# Test 8: Handle empty steps context gracefully
# ============================================================================
reset_defaults
input_steps_context_json='{}'
run_test "Handle empty steps context" '.steps | keys | length' "0"

# ============================================================================
# Test 9: Workflow metadata is captured
# ============================================================================
reset_defaults
run_test "Workflow run_id captured" '.workflow.run_id' "12345678"

# ============================================================================
# Test 10: Filter password fields from context
# ============================================================================
reset_defaults
input_github_context_json='{"repository": "test/repo", "token": "secret-token-value"}'
run_test "Filter token from github context" '.github_context | has("token")' "false"

# ============================================================================
# Test 11: Preserve non-sensitive fields
# ============================================================================
reset_defaults
input_github_context_json='{"repository": "test/repo", "event_name": "pull_request", "ref": "refs/heads/main"}'
run_test "Preserve event_name field" '.github_context.event_name' "pull_request"

# ============================================================================
# Test 12: Handle null JSON input
# ============================================================================
reset_defaults
input_matrix_context_json="null"
run_test "Handle null JSON input" '.matrix_context' "{}"

# ============================================================================
# Test 13: Capture step conclusion (different from outcome)
# ============================================================================
reset_defaults
input_steps_context_json='{
  "init": {"outputs": {}, "outcome": "failure", "conclusion": "success"}
}'
run_test "Capture step conclusion" '.steps["init"].conclusion' "success"

# ============================================================================
# Test 14: Environment name in metadata
# ============================================================================
reset_defaults
export input_environment_name="production"
run_test "Environment name used" '.metadata.environment' "production"

# ============================================================================
# Test 15: Timestamp is present
# ============================================================================
reset_defaults
run_test "Timestamp is present" '.metadata.captured_at | length > 0' "true"

# ============================================================================
# Test 16: Step names are preserved correctly
# ============================================================================
reset_defaults
input_steps_context_json='{
  "setup-terraform-cache": {"outputs": {"plugin-cache-directory": "/cache"}, "outcome": "success", "conclusion": "success"}
}'
run_test "Step names preserved" '.steps["setup-terraform-cache"].outputs["plugin-cache-directory"]' "/cache"

# ============================================================================
# Test 17: Handle null steps context
# ============================================================================
reset_defaults
input_steps_context_json="null"
run_test "Handle null steps context" '.steps | keys | length' "0"

# ============================================================================
# Test 18: Many steps are captured
# ============================================================================
reset_defaults
input_steps_context_json='{
  "step1": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step2": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step3": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step4": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step5": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step6": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step7": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step8": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step9": {"outputs": {}, "outcome": "success", "conclusion": "success"},
  "step10": {"outputs": {}, "outcome": "success", "conclusion": "success"}
}'
run_test "Many steps captured" '.steps | keys | length' "10"

# ============================================================================
# Per-output size cap (docs/Apply-and-destroy-reporting.md §7.12, I1–I3)
# ============================================================================
reset_defaults
_big=$(head -c 6000 </dev/zero | tr '\0' 'x')
input_steps_context_json="{\"cvs\": {\"outputs\": {\"big\": \"${_big}\", \"small\": \"ok\"}, \"outcome\": \"success\", \"conclusion\": \"success\"}}"
run_test "I1: output over the cap is replaced by a <truncated: N bytes> marker" '.steps.cvs.outputs.big' "<truncated: 6000 bytes>"
reset_defaults
input_steps_context_json="{\"cvs\": {\"outputs\": {\"big\": \"${_big}\", \"small\": \"ok\"}, \"outcome\": \"success\", \"conclusion\": \"success\"}}"
run_test "I2: output under the cap passes through byte-identically" '.steps.cvs.outputs.small' "ok"
reset_defaults
input_steps_context_json="{\"cvs\": {\"outputs\": {\"path\": \"/tmp/tf-comment-dev-head.md\"}, \"outcome\": \"success\", \"conclusion\": \"success\"}}"
run_test "I2: a file path (the normal large-body carrier now) is untouched" '.steps.cvs.outputs.path' "/tmp/tf-comment-dev-head.md"
# Exactly at the cap is kept; one byte over is truncated.
reset_defaults
_at=$(head -c 4096 </dev/zero | tr '\0' 'y'); _over=$(head -c 4097 </dev/zero | tr '\0' 'z')
input_steps_context_json="{\"s\": {\"outputs\": {\"at\": \"${_at}\", \"over\": \"${_over}\"}, \"outcome\": \"success\", \"conclusion\": \"success\"}}"
run_test "I1: 4096 bytes is kept, 4097 is truncated (boundary)" '[(.steps.s.outputs.at | length), .steps.s.outputs.over] | @json' '[4096,"<truncated: 4097 bytes>"]'
# Multi-byte: the cap counts bytes, not characters.
reset_defaults
_mb=$(python3 -c "print('—' * 2000, end='')")  # 2000 chars × 3 bytes = 6000 bytes
input_steps_context_json="{\"s\": {\"outputs\": {\"mb\": \"${_mb}\"}, \"outcome\": \"success\", \"conclusion\": \"success\"}}"
run_test "I1: cap is measured in bytes — 2000 em-dashes (6000 bytes) are truncated" '.steps.s.outputs.mb' "<truncated: 6000 bytes>"
# I3: every output oversize → still valid JSON, no E2BIG, outcomes intact.
reset_defaults
_huge=$(head -c 200000 </dev/zero | tr '\0' 'h')
input_steps_context_json="{\"a\": {\"outputs\": {\"x\": \"${_huge}\", \"y\": \"${_huge}\"}, \"outcome\": \"failure\", \"conclusion\": \"failure\"}, \"b\": {\"outputs\": {\"z\": \"${_huge}\"}, \"outcome\": \"success\", \"conclusion\": \"success\"}}"
run_test "I3: every output oversize (3 × 200k) → result parses, outcomes intact" '[.steps.a.outcome, .steps.b.outcome, (.steps.a.outputs.x | startswith("<truncated"))] | @json' '["failure","success",true]'
# Non-string outputs (numbers/bools/null) are left alone.
reset_defaults
input_steps_context_json='{"s": {"outputs": {"n": 42, "b": true, "nul": null}, "outcome": "success", "conclusion": "success"}}'
run_test "cap leaves non-string output values alone" '[.steps.s.outputs.n, .steps.s.outputs.b, .steps.s.outputs.nul] | @json' '[42,true,null]'

# ============================================================================
# Entity and artifact names (the 'entity-name' and 'artifact-name' inputs)
#
# The file basename is what the aggregator, the run summary and the auto-merge
# evaluator glob ('matrix-job-meta-*.json'), and the artifact name is what their
# download steps match; a caller that must stay out of their input sets both
# through 'artifact-name'.
# ============================================================================

# Runs the step and checks exit code, the result file's basename, the
# 'artifact-name' output, and '.metadata.environment'. An expected basename of
# '-' means the step must fail and publish neither output.
run_naming_test() {
  local test_name="${1}" expected_basename="${2}" expected_artifact="${3}" expected_entity="${4}"

  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  echo -e "${BLUE}========================================${NC}"

  export GITHUB_OUTPUT=$(mktemp)
  export RUNNER_TEMP=$(mktemp -d)
  export GITHUB_ACTION_PATH="${_this_script_dir}"

  (
    source "${_this_script_dir}/step_capture.sh"
  ) > /tmp/test_output.txt 2>&1
  local exit_code=$?

  local result_file artifact_output actual_entity="" ok="false"
  result_file=$(grep "^result-json-file=" "${GITHUB_OUTPUT}" | cut -d= -f2-)
  artifact_output=$(grep "^artifact-name=" "${GITHUB_OUTPUT}" | cut -d= -f2-)
  if [[ -f "${result_file}" ]]; then
    actual_entity=$(jq -r '.metadata.environment' "${result_file}" 2>/dev/null)
  fi

  if [[ "${expected_basename}" == "-" ]]; then
    [[ "${exit_code}" -ne 0 && -z "${result_file}" && -z "${artifact_output}" ]] && ok="true"
  else
    [[ "${exit_code}" -eq 0 && -f "${result_file}" &&
      "$(dirname "${result_file}")" == "${RUNNER_TEMP}" &&
      "$(basename "${result_file}")" == "${expected_basename}" &&
      "${artifact_output}" == "${expected_artifact}" &&
      "${actual_entity}" == "${expected_entity}" ]] && ok="true"
  fi

  if [[ "${ok}" == "true" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: exit=${exit_code} file='${result_file}' artifact='${artifact_output}' entity='${actual_entity}'"
    echo "Expected: basename='${expected_basename}' artifact='${expected_artifact}' entity='${expected_entity}'"
    echo ""
    echo "Test output:"
    cat /tmp/test_output.txt
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  rm -f "${GITHUB_OUTPUT}"
  rm -rf "${RUNNER_TEMP}"
}

# A log line the last naming test's step printed.
assert_last_log() {
  local test_name="${1}" pattern="${2}" want="${3:-present}"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"
  local found="absent"
  grep -qF -- "${pattern}" /tmp/test_output.txt && found="present"
  if [[ "${found}" == "${want}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: expected '${pattern}' ${want} in the step output"
    cat /tmp/test_output.txt
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# Golden for every existing caller: only 'environment-name'.
reset_defaults
export input_environment_name="production"
run_naming_test "names: environment-name alone keeps today's file and artifact name (golden)" \
  "matrix-job-meta-production.json" "matrix-job-meta-production" "production"
assert_last_log "names: environment-name alone logs no disagreement" "differ; using 'entity-name'" absent

reset_defaults
unset input_environment_name
export input_entity_name="production"
run_naming_test "names: entity-name alone names the file like environment-name did" \
  "matrix-job-meta-production.json" "matrix-job-meta-production" "production"

reset_defaults
export input_environment_name="production" input_entity_name="production"
run_naming_test "names: both given and equal" \
  "matrix-job-meta-production.json" "matrix-job-meta-production" "production"
assert_last_log "names: both equal logs no disagreement" "differ; using 'entity-name'" absent

reset_defaults
export input_environment_name="sandbox" input_entity_name="production"
run_naming_test "names: both given and different, entity-name wins" \
  "matrix-job-meta-production.json" "matrix-job-meta-production" "production"
assert_last_log "names: the disagreement is logged as a warning" \
  "inputs 'entity-name' ('production') and 'environment-name' ('sandbox') differ; using 'entity-name'."

reset_defaults
export input_environment_name="" input_entity_name="production"
run_naming_test "names: an empty environment-name does not shadow entity-name" \
  "matrix-job-meta-production.json" "matrix-job-meta-production" "production"

reset_defaults
unset input_environment_name
export input_entity_name="tests-unit-net" input_artifact_name="terraform-test-meta-tests-unit-net"
run_naming_test "names: artifact-name sets both the file basename and the artifact name" \
  "terraform-test-meta-tests-unit-net.json" "terraform-test-meta-tests-unit-net" "tests-unit-net"

reset_defaults
export input_environment_name="production" input_artifact_name="custom-meta"
run_naming_test "names: artifact-name works with the environment-name alias too" \
  "custom-meta.json" "custom-meta" "production"

reset_defaults
export input_environment_name="production" input_artifact_name=""
run_naming_test "names: an empty artifact-name falls back to the default" \
  "matrix-job-meta-production.json" "matrix-job-meta-production" "production"

# Neither name: the random fallback, and the artifact name follows it.
reset_defaults
unset input_environment_name
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}TEST ${TESTS_RUN}: names: neither name gives matching unknown-XXXXXX file and artifact names${NC}"
export GITHUB_OUTPUT=$(mktemp) RUNNER_TEMP=$(mktemp -d) GITHUB_ACTION_PATH="${_this_script_dir}"
( source "${_this_script_dir}/step_capture.sh" ) > /tmp/test_output.txt 2>&1
_rc=$?
_file=$(grep "^result-json-file=" "${GITHUB_OUTPUT}" | cut -d= -f2-)
_art=$(grep "^artifact-name=" "${GITHUB_OUTPUT}" | cut -d= -f2-)
if [[ "${_rc}" -eq 0 && "${_art}" =~ ^matrix-job-meta-unknown-[a-zA-Z0-9]{6}$ && "$(basename "${_file}")" == "${_art}.json" ]]; then
  echo -e "${GREEN}✓ PASSED${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}: exit=${_rc} file='${_file}' artifact='${_art}'"; cat /tmp/test_output.txt
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -f "${GITHUB_OUTPUT}"; rm -rf "${RUNNER_TEMP}"

# Names upload-artifact refuses fail the step with the reason, whether the
# caller spelled them out or they came from the entity name.
for _bad in 'meta/tests' 'meta:x' 'meta"x' 'meta<x' 'meta>x' 'meta|x' 'meta*x' 'meta?x' 'meta\x' $'meta\nx' $'meta\rx'; do
  reset_defaults
  export input_artifact_name="${_bad}"
  run_naming_test "names: artifact-name '$(printf '%q' "${_bad}")' fails the step" "-" "" ""
done
assert_last_log "names: the failure names the offending artifact name" "contains a character artifact names may not contain"
reset_defaults
export input_entity_name="tests/unit"
run_naming_test "names: a default artifact name built from an unusable entity fails the step" "-" "" ""

# The upload must use the step's resolved name, or the artifact and the file
# inside it drift apart.
TESTS_RUN=$((TESTS_RUN + 1))
echo ""
echo -e "${BLUE}TEST ${TESTS_RUN}: names: the upload step names the artifact from the capture step's output${NC}"
if python3 - "${_this_script_dir}/action.yml" <<'PYEOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
upload = [s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
ok = len(upload) == 1 and upload[0]["with"]["name"] == "${{ steps.capture.outputs.artifact-name }}"
out = yaml.safe_load(open(sys.argv[1]))["outputs"]["artifact-name"]["value"]
ok = ok and out == "${{ steps.capture.outputs.artifact-name }}"
sys.exit(0 if ok else 1)
PYEOF
then
  echo -e "${GREEN}✓ PASSED${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "${RED}✗ FAILED${NC}"; TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}               TEST SUMMARY                ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  echo -e "${RED}SOME TESTS FAILED!${NC}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED!${NC}"
  exit 0
fi
