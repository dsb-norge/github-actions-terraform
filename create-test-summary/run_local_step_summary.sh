#!/bin/env bash
#
# Local testing/debugging script for step_summary.sh
# Simulates the summary job: two metadata files (one pass, one assertion
# failure), a matrix with a third row that left no metadata, a Jobs API
# fixture and a relevance.json with one misplaced file. Prints the body.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/step-summary.md"
export GITHUB_SERVER_URL="https://github.com"
export GITHUB_REPOSITORY="dsb-norge/test-repo"
export GITHUB_RUN_ID="12345678"
export GITHUB_ACTOR="test-user"
export GITHUB_WORKFLOW="CI"

cd "${RUNNER_TEMP}" || exit 1

cat >matrix.json <<'JSON'
{"include": [
  {"slug": "root--unit-app", "test": {"file": "tests/unit-app.tftest.hcl", "root": ".", "rel": "tests/unit-app.tftest.hcl", "lane": "unit", "allow-failing-terraform-tests": false, "github-environment": "", "root-kind": "repo-root", "provider-set": "a1b2c3", "provider-set-lock": "envs/prod/.terraform.lock.hcl", "provider-set-environments": ["prod"]}},
  {"slug": "modules-group--integration-directory-group", "test": {"file": "modules/group/tests/integration-directory-group.tftest.hcl", "root": "modules/group", "rel": "tests/integration-directory-group.tftest.hcl", "lane": "directory", "allow-failing-terraform-tests": false, "github-environment": "tftest-directory", "root-kind": "module", "provider-set": "a1b2c3", "provider-set-lock": "envs/prod/.terraform.lock.hcl", "provider-set-environments": ["prod"]}},
  {"slug": "modules-rg--unit-rg", "test": {"file": "modules/rg/tests/unit-rg.tftest.hcl", "root": "modules/rg", "rel": "tests/unit-rg.tftest.hcl", "lane": "unit", "allow-failing-terraform-tests": false, "github-environment": "", "root-kind": "module", "provider-set": "a1b2c3", "provider-set-lock": "envs/prod/.terraform.lock.hcl", "provider-set-environments": ["prod"]}}
]}
JSON

for slug in root--unit-app modules-group--integration-directory-group; do
  jq --arg s "${slug}" '{
      metadata: {environment: $s, schema_version: "2.0.0"},
      matrix_context: (.include[] | select(.slug == $s)),
      steps: {
        init: {outcome: "success", conclusion: "success", outputs: {}},
        test: {outcome: "success", conclusion: "success", outputs: (
          if $s == "root--unit-app" then
            {status: "pass", reason: "", passed: "8", failed: "0", errored: "0", skipped: "0", total: "8", "elapsed-ms": "12000", "providers-summary": "azuread 3.9.0 environments"}
          else
            {status: "fail", reason: "assertion", passed: "5", failed: "1", errored: "0", skipped: "0", total: "6", "elapsed-ms": "160000",
             "failed-runs-json": "[{\"run\":\"group_is_created\",\"status\":\"fail\",\"file\":\"modules/group/tests/integration-directory-group.tftest.hcl\",\"line\":42,\"summary\":\"Test assertion failed\",\"detail\":\"group display name must start with `tftest-`\"}]",
             "failed-runs-omitted": "0"}
          end)},
        "upload-test-output": {outcome: "success", conclusion: "success", outputs: {"artifact-url": "https://github.com/dsb-norge/test-repo/actions/runs/12345678/artifacts/\($s)"}}
      }
    }' matrix.json >"terraform-test-meta-${slug}.json"
done

cat >jobs.json <<'JSON'
[{"id": 1, "name": "tf / Terraform test (tests/unit-app.tftest.hcl)", "status": "completed", "conclusion": "success", "html_url": "https://github.com/dsb-norge/test-repo/actions/runs/12345678/job/1", "started_at": "2026-09-25T10:00:00Z", "completed_at": "2026-09-25T10:00:20Z", "steps": [{"name": "🧪 Terraform test", "number": 12}]},
 {"id": 2, "name": "tf / Terraform test (modules/group/tests/integration-directory-group.tftest.hcl)", "status": "completed", "conclusion": "success", "html_url": "https://github.com/dsb-norge/test-repo/actions/runs/12345678/job/2", "started_at": "2026-09-25T10:00:01Z", "completed_at": "2026-09-25T10:02:50Z", "steps": [{"name": "🧪 Terraform test", "number": 12}]},
 {"id": 3, "name": "tf / Terraform test (modules/rg/tests/unit-rg.tftest.hcl)", "status": "completed", "conclusion": "cancelled", "html_url": "https://github.com/dsb-norge/test-repo/actions/runs/12345678/job/3", "started_at": "2026-09-25T10:00:01Z", "completed_at": "2026-09-25T10:00:02Z", "steps": []}]
JSON

echo '{"tests": {"not_run": [{"file": "tests/setup/helper.tftest.hcl", "lane": "", "reason": "misplaced"}]}}' >relevance.json

export input_metadata_files_pattern="terraform-test-meta-*.json"
export input_not_run_file="${RUNNER_TEMP}/relevance.json"
export input_jobs_json_file="${RUNNER_TEMP}/jobs.json"
export input_run_url=""
export input_output_file_suffix=""

# Source the step in a subshell so 'exit' doesn't terminate this runner. The
# matrix is captured shell-local as toJSON of the output string, as the shim
# does, and never exported.
(
  input_tests_matrix_json="$(jq -c '.' matrix.json | jq -Rs 'rtrimstr("\n")')"
  set -o allexport
  source "${_this_script_dir}/step_summary.sh"
)

echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
echo ""
echo "========================================"
echo "Body file:"
echo "========================================"
cat "$(grep '^body-file=' "${GITHUB_OUTPUT}" | cut -d= -f2-)"
