#!/bin/env bash
#
# Local runner for step_aggregate.sh.
# Sets up a simulated GitHub Actions environment with two fixture matrix-job-meta
# files (one group with two envs) and a fake `gh` that records and returns canned
# API responses. Useful for manual end-to-end smoke testing without a real PR.
#

set -e

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

TEST_DIR=$(mktemp -d)
echo "Using test dir: ${TEST_DIR}"
cd "${TEST_DIR}"

# Fake gh binary that records calls and serves a canned list-comments
# response. Production code uses _gh_list_pr_comments / _gh_delete_comment /
# _gh_post_comment which thinly wrap the `gh` CLI; replacing `gh` on PATH is
# enough to exercise the full code path.
mkdir -p "${TEST_DIR}/bin"
cat > "${TEST_DIR}/bin/gh" <<'FAKE_GH'
#!/bin/bash
LOG="${GH_FAKE_CALL_LOG:-/dev/null}"
echo "gh $*" >> "${LOG}"
case "$*" in
  *"--paginate"*"/actions/runs/"*"/jobs"*)
    # Jobs API: production code uses --jq '.jobs', so we return a flat array.
    # Names mirror the real-world "<caller-job> / <reusable-job> (<env>)"
    # rendering that GitHub does when this workflow is called as reusable.
    cat <<'JOBS'
[
  {"id": 5001, "name": "tf / Terraform (sub-a-dev)", "html_url": "https://github.com/dsb-norge/test-repo/actions/runs/21494130907/job/5001"},
  {"id": 5002, "name": "tf / Terraform (sub-b-dev)", "html_url": "https://github.com/dsb-norge/test-repo/actions/runs/21494130907/job/5002"},
  {"id": 5003, "name": "tf / PR comment aggregator", "html_url": "https://github.com/dsb-norge/test-repo/actions/runs/21494130907/job/5003"}
]
JOBS
    ;;
  *"--paginate"*"/comments")
    cat <<'COMMENTS'
[
  {"id": 100, "body": "### Terraform validation summary for group: `legacy-group`\nold body\n"},
  {"id": 200, "body": "### Terraform validation summary for environment: `sub-a-dev`\nplan content\n"},
  {"id": 201, "body": "### Terraform validation summary for environment: `sub-b-dev`\nplan content\n"}
]
COMMENTS
    ;;
  *"-X DELETE"*)
    echo '{"deleted": true}'
    ;;
  *"-X POST"*)
    echo "9999"
    ;;
esac
FAKE_GH
chmod +x "${TEST_DIR}/bin/gh"
export PATH="${TEST_DIR}/bin:${PATH}"
export GH_FAKE_CALL_LOG="${TEST_DIR}/gh-calls.log"
: > "${GH_FAKE_CALL_LOG}"

# Two matrix-job-meta fixture files, both in the same group 'dev'.
cat > matrix-job-meta-sub-a-dev.json <<'JSON'
{
  "metadata": {"environment": "sub-a-dev", "captured_at": "2026-01-30T12:28:54Z", "schema_version": "2.0.0"},
  "workflow": {
    "run_id": "21494130907", "run_number": "102", "run_attempt": "1",
    "workflow_name": "Terraform CI", "job_name": "terraform-ci-cd",
    "actor": "peder", "event_name": "pull_request",
    "ref": "refs/pull/295/merge", "sha": "abc123"
  },
  "matrix_context": {
    "environment": "sub-a-dev",
    "vars": {"environment": "sub-a-dev", "pr-comment-group": "dev"}
  },
  "github_context": {"actor": "peder"},
  "steps": {
    "init":        {"outcome": "success", "conclusion": "success", "outputs": {}},
    "verify-lock": {"outcome": "success", "conclusion": "success", "outputs": {}},
    "fmt":         {"outcome": "success", "conclusion": "success", "outputs": {}},
    "validate":    {"outcome": "success", "conclusion": "success", "outputs": {}},
    "lint":        {"outcome": "success", "conclusion": "success", "outputs": {}},
    "plan":        {"outcome": "success", "conclusion": "success", "outputs": {}},
    "parse-plan":  {"outcome": "success", "conclusion": "success",
                    "outputs": {"count-add": "0", "count-change": "0", "count-destroy": "0",
                                "count-import": "0", "count-move": "0", "count-remove": "0"}}
  }
}
JSON

cat > matrix-job-meta-sub-b-dev.json <<'JSON'
{
  "metadata": {"environment": "sub-b-dev", "captured_at": "2026-01-30T12:28:54Z", "schema_version": "2.0.0"},
  "workflow": {
    "run_id": "21494130907", "run_number": "102", "run_attempt": "1",
    "workflow_name": "Terraform CI", "job_name": "terraform-ci-cd",
    "actor": "peder", "event_name": "pull_request",
    "ref": "refs/pull/295/merge", "sha": "abc123"
  },
  "matrix_context": {
    "environment": "sub-b-dev",
    "vars": {"environment": "sub-b-dev", "pr-comment-group": "dev"}
  },
  "github_context": {"actor": "peder"},
  "steps": {
    "init":        {"outcome": "success", "conclusion": "success", "outputs": {}},
    "verify-lock": {"outcome": "success", "conclusion": "success", "outputs": {}},
    "fmt":         {"outcome": "failure", "conclusion": "failure", "outputs": {}},
    "validate":    {"outcome": "skipped", "conclusion": "skipped", "outputs": {}},
    "lint":        {"outcome": "skipped", "conclusion": "skipped", "outputs": {}},
    "plan":        {"outcome": "success", "conclusion": "success", "outputs": {}},
    "parse-plan":  {"outcome": "success", "conclusion": "success",
                    "outputs": {"count-add": "1", "count-change": "0", "count-destroy": "0",
                                "count-import": "2", "count-move": "0", "count-remove": "0"}}
  }
}
JSON

# Standard GitHub Actions environment plumbing
export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${TEST_DIR}"
export GITHUB_REPOSITORY="dsb-norge/test-repo"
export GITHUB_SERVER_URL="https://github.com"
export GITHUB_RUN_ID="21494130907"
export GITHUB_WORKFLOW="Terraform CI"
export GITHUB_ACTOR="peder"
export GITHUB_EVENT_NAME="pull_request"
export GH_TOKEN="fake-token"

export input_metadata_files_pattern="matrix-job-meta-*.json"
export input_pr_number="295"

echo ""
echo "============================================================"
echo "Running step_aggregate.sh..."
echo "============================================================"

set -o allexport
source "${_this_script_dir}/step_aggregate.sh"
set +o allexport

echo ""
echo "============================================================"
echo "GITHUB_OUTPUT contents:"
echo "============================================================"
cat "${GITHUB_OUTPUT}"

echo ""
echo "============================================================"
echo "gh calls recorded:"
echo "============================================================"
cat "${GH_FAKE_CALL_LOG}"

# Cleanup
rm -rf "${TEST_DIR}"
