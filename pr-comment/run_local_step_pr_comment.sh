#!/bin/env bash
#
# Local runner for step_pr_comment.sh.
# Sets up a simulated GitHub Actions environment with a fake `gh` that
# records calls and serves canned responses. Useful for manual smoke
# testing without hitting a real PR.
#

set -e

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

TEST_DIR=$(mktemp -d)
echo "Using test dir: ${TEST_DIR}"

# Fake gh. Returns one existing comment matching the marker so the run
# exercises the PATCH path. A POST-only run can be simulated by setting
# input_marker to something that doesn't match the canned response below.
mkdir -p "${TEST_DIR}/bin"
cat > "${TEST_DIR}/bin/gh" <<'FAKE_GH'
#!/bin/bash
LOG="${GH_FAKE_CALL_LOG:-/dev/null}"
echo "gh $*" >> "${LOG}"
case "$*" in
  *"--paginate"*"/comments")
    cat <<'COMMENTS'
[
  {"id": 1001, "created_at": "2026-05-22T09:00:00Z", "body": "<!-- tf:head:env:dev -->\n<!-- comment-hash:deadbeef -->\n\nold body"},
  {"id": 1002, "created_at": "2026-05-22T09:05:00Z", "body": "Unrelated comment from a human reviewer"}
]
COMMENTS
    ;;
  *"-X DELETE"*)
    echo '{"deleted": true}'
    ;;
  *"-X PATCH"*"/issues/comments/"*)
    for arg in "$@"; do
      if [[ "${arg}" == repos/*"/issues/comments/"* ]]; then
        echo "${arg##*/}"
        break
      fi
    done
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

# Standard GitHub Actions environment
export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${TEST_DIR}"
export GH_TOKEN="fake-token"

# Action inputs — upsert path against the canned existing comment
export input_repo="dsb-norge/test-repo"
export input_issue_number="295"
export input_mode="upsert"
export input_marker="<!-- tf:head:env:dev -->"
export input_body="### dev

⏳ Running (run #999)…
"

echo ""
echo "============================================================"
echo "Running step_pr_comment.sh (upsert)..."
echo "============================================================"

(
  set -o allexport
  source "${_this_script_dir}/step_pr_comment.sh"
)

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
