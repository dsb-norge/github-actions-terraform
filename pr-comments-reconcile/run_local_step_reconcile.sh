#!/bin/env bash
#
# Local runner for step_reconcile.sh.
# Simulates a real GitHub Actions environment with a fake `gh` returning
# canned list-comments + POST/PATCH/DELETE responses. Drives a small heads
# + GC scenario so the end-to-end code path is exercised.
#

set -e

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

TEST_DIR=$(mktemp -d)
echo "Using test dir: ${TEST_DIR}"

mkdir -p "${TEST_DIR}/bin"
cat > "${TEST_DIR}/bin/gh" <<'FAKE_GH'
#!/bin/bash
LOG="${GH_FAKE_CALL_LOG:-/dev/null}"
echo "gh $*" >> "${LOG}"
case "$*" in
  *"--paginate"*"/comments")
    cat <<'COMMENTS'
[
  {"id": 2001, "created_at": "2026-05-22T08:00:00Z", "body": "<!-- tf:head:group:dev -->\n<!-- comment-hash:aaa111 -->\n\nold group body"},
  {"id": 2002, "created_at": "2026-05-22T08:01:00Z", "body": "<!-- tf:tag:plan:dev-app:run-id-999 -->\nold plan from prior run"},
  {"id": 2003, "created_at": "2026-05-22T08:02:00Z", "body": "Unrelated reviewer comment"}
]
COMMENTS
    ;;
  *"-X DELETE"*) echo '{"deleted": true}' ;;
  *"-X PATCH"*"/issues/comments/"*)
    for arg in "$@"; do
      if [[ "${arg}" == repos/*"/issues/comments/"* ]]; then
        echo "${arg##*/}"; break
      fi
    done
    ;;
  *"-X POST"*)
    echo "$((RANDOM + 9000))"
    ;;
esac
FAKE_GH
chmod +x "${TEST_DIR}/bin/gh"
export PATH="${TEST_DIR}/bin:${PATH}"
export GH_FAKE_CALL_LOG="${TEST_DIR}/gh-calls.log"
: > "${GH_FAKE_CALL_LOG}"

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_WORKSPACE="${TEST_DIR}"
export GH_TOKEN="fake-token"

export input_repo="dsb-norge/test-repo"
export input_issue_number="295"

# Three heads in declared order; one of them is the existing dev group (will PATCH),
# two are brand new (will POST).
export input_heads_yml='- marker: "<!-- tf:head:summary:all -->"
  body: |
    ## Terraform CI Summary
    ⏳ Running (run #1000)…
- marker: "<!-- tf:head:group:dev -->"
  body: |
    ### Terraform validation summary for group: `dev`
    ⏳ Running…
- marker: "<!-- tf:head:env:dev-app -->"
  body: |
    ### dev-app
    ⏳ Running…'

# GC rule: prune plan tags from prior runs (run-id != 1000).
export input_gc_yml='- marker-prefix: "<!-- tf:tag:plan:"
  keep-marker-substring: "run-id-1000"'

echo ""
echo "============================================================"
echo "Running step_reconcile.sh..."
echo "============================================================"

(
  set -o allexport
  source "${_this_script_dir}/step_reconcile.sh"
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

rm -rf "${TEST_DIR}"
