#!/bin/env bash
#
# Action-specific helpers for pr-comments-reconcile.
#
# Generic, terraform-agnostic. Mirrors pr-comment/helpers_additional.sh so
# each action is self-contained (per action-implementation-guide.md). When
# touching one, audit the other.
#

# Inline marker placed on line 2 of every body this action writes. Lets
# the action recognize its own writes and short-circuit no-op PATCHes when
# the existing comment's hash matches the body about to be written.
declare -gr COMMENT_HASH_MARKER_PREFIX='<!-- comment-hash:'

# Compute the canonical hash of a body. Strips a single trailing newline
# before hashing so heredoc/yaml whitespace drift doesn't bust the hash.
function _compute_body_hash {
  local body="${1}"
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

# Extract the hash from an existing comment body. Empty when no
# '<!-- comment-hash:<sha> -->' marker is present (e.g. legacy bodies, or
# bodies written by other tools that don't emit the marker). Uses a bash
# regex match instead of a grep pipeline so the no-match case stays
# pipefail-safe — the shim runs under `bash -eo pipefail`, so a non-zero
# grep exit would otherwise kill the whole step.
function _extract_existing_hash {
  local body="${1}"
  local re="${COMMENT_HASH_MARKER_PREFIX}([a-f0-9]+) -->"
  if [[ "${body}" =~ ${re} ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
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
