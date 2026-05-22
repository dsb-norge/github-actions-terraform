#!/bin/env bash
#
# Action-specific helpers for pr-comment.
#
# Generic, terraform-agnostic. Sourced automatically by helpers.sh.
#

# Inline marker placed on line 2 of every body this action writes. Lets
# the action recognize its own writes and short-circuit no-op PATCHes when
# the existing comment's hash matches the body about to be written.
declare -gr COMMENT_HASH_MARKER_PREFIX='<!-- comment-hash:'

# Compute the canonical hash of a body. Strips a single trailing newline
# before hashing so heredoc/yaml whitespace drift doesn't bust the hash.
function _compute_body_hash {
  local body="${1}"
  # Strip exactly one trailing newline if present
  printf '%s' "${body%$'\n'}" | sha256sum | awk '{print $1}'
}

# Render the inline hash marker for a given body hash.
function _hash_marker {
  local hash="${1}"
  echo "${COMMENT_HASH_MARKER_PREFIX}${hash} -->"
}

# Assemble the full rendered body: <user-marker>\n<hash-marker>\n\n<user-body>
function _render_full_body {
  local marker="${1}"
  local user_body="${2}"
  local hash
  hash=$(_compute_body_hash "${user_body}")
  printf '%s\n%s\n\n%s' "${marker}" "$(_hash_marker "${hash}")" "${user_body}"
}

# Extract the hash from an existing comment body. Empty if absent.
# Looks for the literal '<!-- comment-hash:<sha> -->' substring anywhere
# (robust to leading whitespace / line shifts).
function _extract_existing_hash {
  local body="${1}"
  echo "${body}" | grep -oE "${COMMENT_HASH_MARKER_PREFIX}[a-f0-9]+ -->" | head -n1 | sed -E "s|${COMMENT_HASH_MARKER_PREFIX}([a-f0-9]+) -->|\1|"
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
