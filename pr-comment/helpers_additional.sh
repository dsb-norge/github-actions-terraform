#!/bin/env bash
#
# Action-specific helpers for pr-comment.
#
# Generic, terraform-agnostic. Sourced automatically by helpers.sh.
#

# Assemble the full rendered body: <marker>\n\n<user-body>. The HTML
# marker is line 1 (load-bearing for upsert identity); a blank separator
# line follows; then the visible body. Used by both POST and PATCH paths
# so every body the action writes carries the marker on line 1.
function _render_full_body {
  local marker="${1}"
  local user_body="${2}"
  printf '%s\n\n%s' "${marker}" "${user_body}"
}

# gh-api wrappers. Tests shadow these by putting a fake `gh` script on
# PATH ahead of the real one — the wrappers are thin so the test surface
# is just the `gh` invocations.

function _gh_list_pr_comments {
  local repo="${1}" issue="${2}"
  # --paginate to get all comments regardless of page count
  gh api --paginate "repos/${repo}/issues/${issue}/comments"
}

function _gh_delete_comment {
  local repo="${1}" comment_id="${2}"
  gh api -X DELETE "repos/${repo}/issues/comments/${comment_id}"
}

# POST a fresh comment, return the new comment ID on stdout.
# Body passed via -F body=@file so multi-line content + arbitrary
# markdown is preserved without shell-quoting concerns.
function _gh_post_comment {
  local repo="${1}" issue="${2}" body_file="${3}"
  gh api -X POST "repos/${repo}/issues/${issue}/comments" -F "body=@${body_file}" --jq '.id'
}

# PATCH an existing comment in place.
function _gh_patch_comment {
  local repo="${1}" comment_id="${2}" body_file="${3}"
  gh api -X PATCH "repos/${repo}/issues/comments/${comment_id}" -F "body=@${body_file}" --jq '.id'
}
