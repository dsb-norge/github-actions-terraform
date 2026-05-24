#!/bin/env bash
#
# Action-specific helpers for pr-comments-reconcile.
#
# Generic, terraform-agnostic. Mirrors pr-comment/helpers_additional.sh so
# each action is self-contained (per action-implementation-guide.md). When
# touching one, audit the other.
#

# Assemble the full rendered body: <marker>\n\n<user-body>. The HTML
# marker is line 1 (load-bearing for upsert identity); a blank separator
# line follows; then the visible body.
function _render_full_body {
  local marker="${1}"
  local user_body="${2}"
  printf '%s\n\n%s' "${marker}" "${user_body}"
}

# gh-api wrappers. Tests shadow these by putting a fake `gh` script on PATH
# ahead of the real one.

function _gh_list_pr_comments {
  local repo="${1}" issue="${2}"
  gh api --paginate "repos/${repo}/issues/${issue}/comments"
}

function _gh_delete_comment {
  local repo="${1}" comment_id="${2}"
  gh api -X DELETE "repos/${repo}/issues/comments/${comment_id}"
}

function _gh_post_comment {
  local repo="${1}" issue="${2}" body_file="${3}"
  gh api -X POST "repos/${repo}/issues/${issue}/comments" -F "body=@${body_file}" --jq '.id'
}

function _gh_patch_comment {
  local repo="${1}" comment_id="${2}" body_file="${3}"
  gh api -X PATCH "repos/${repo}/issues/comments/${comment_id}" -F "body=@${body_file}" --jq '.id'
}
