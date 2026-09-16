#!/bin/env bash
#
# Rewrite every internal `uses: dsb-norge/github-actions-terraform/<path>@<ref>` in the
# consumable workflow files of this repo to one given ref.
#
# Two callers:
#   - .github/workflows/pr-preview.yml, which passes the immutable per-push tag
#     `preview/pr-<N>-<sha7>` and then points that tag at the commit containing these
#     rewrites, so the published tree is self-referential (docs/Preview-refs.md §3, §4);
#   - a developer running the fallback procedure by hand (docs/Development-and-release.md).
#
# Only `.github/workflows/*.yml|yaml` minus EXCLUDED_WORKFLOWS are touched — README, docs
# and action.yml examples are meant to keep saying @v0. Any current ref is rewritten, not
# just @v0, so a branch still carrying an old-style manual swap publishes a correct preview.
#
# Usage:
#   rewrite-internal-refs.sh <new-ref>       rewrite in place, print per-file counts
#   rewrite-internal-refs.sh --list-files    print the file set (repo-relative, sorted),
#                                            touch nothing
#
# The guard in pr-preview.yml scopes its check with --list-files, so the rewrite and the
# check can never disagree about which files are in play.
#
# Environment:
#   REPO_ROOT (optional) - defaults to `git rev-parse --show-toplevel`
#

set -o nounset
set -o pipefail
set -o errexit

# Workflows calling repos never consume. pr-preview.yml is here because its sticky-comment
# template contains `uses: …@<placeholder>` lines that are templates, not references —
# rewriting them corrupts the comment and trips the guard on its own prose.
EXCLUDED_WORKFLOWS=(pr-preview.yml action-tests.yml)

# `(/…)?` right after the repo name keeps a hypothetical dsb-norge/github-actions-terraform-other
# repo out of the match; `[^[:space:]]+` for the ref stops before a trailing comment.
REF_PATTERN='uses:[[:space:]]+dsb-norge/github-actions-terraform(/[^@[:space:]]*)?@[^[:space:]]+'

function usage {
  cat >&2 <<'USAGE'
usage:
  rewrite-internal-refs.sh <new-ref>       rewrite internal uses-refs in place
  rewrite-internal-refs.sh --list-files    print the affected file set, change nothing
USAGE
}

function is_excluded {
  local name="${1}"
  local entry
  for entry in "${EXCLUDED_WORKFLOWS[@]}"; do
    [[ "${entry}" == "${name}" ]] && return 0
  done
  return 1
}

# Repo-relative paths, sorted, one per line.
function list_files {
  local repo_root="${1}"
  local file
  while IFS= read -r file; do
    is_excluded "$(basename "${file}")" && continue
    echo "${file#"${repo_root}"/}"
  done < <(find "${repo_root}/.github/workflows" -mindepth 1 -maxdepth 1 -type f \
    \( -name '*.yml' -o -name '*.yaml' \) | sort)
}

function count_refs {
  grep -cE "${REF_PATTERN}" "${1}" || true
}

# Refs already pointing at the target — these are not "rewritten" even though sed would
# match them, which is what makes a second run report zero.
function count_refs_at {
  local file="${1}" ref="${2}"
  local escaped_ref="${ref//./\\.}"
  grep -cE "uses:[[:space:]]+dsb-norge/github-actions-terraform(/[^@[:space:]]*)?@${escaped_ref}([[:space:]]|\$)" "${file}" || true
}

function main {
  local mode="${1:-}"
  if [[ -z "${mode}" ]]; then
    usage
    return 2
  fi

  local repo_root
  repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"

  if [[ "${mode}" == '--list-files' ]]; then
    list_files "${repo_root}"
    return 0
  fi

  local new_ref="${mode}"
  # The ref is spliced into a sed replacement — restrict it to what git allows in a plain
  # tag/branch name anyway, which also keeps `|`, `&` and `\` out of the sed expression.
  if ! [[ "${new_ref}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "error: ref '${new_ref}' contains characters outside [A-Za-z0-9._/-]" >&2
    return 2
  fi

  local total_refs=0 total_rewritten=0 files=0
  local rel file before at_ref rewritten
  while IFS= read -r rel; do
    file="${repo_root}/${rel}"
    before="$(count_refs "${file}")"
    at_ref="$(count_refs_at "${file}" "${new_ref}")"
    rewritten=$((before - at_ref))
    # Only touch files that change: an idempotent run leaves bytes and mtimes alone.
    if ((rewritten > 0)); then
      sed -i -E "s|(uses:[[:space:]]+dsb-norge/github-actions-terraform(/[^@[:space:]]*)?)@[^[:space:]]+|\1@${new_ref}|g" "${file}"
    fi
    echo "${rel}: ${rewritten} of ${before} ref(s) rewritten"
    total_refs=$((total_refs + before))
    total_rewritten=$((total_rewritten + rewritten))
    files=$((files + 1))
  done < <(list_files "${repo_root}")

  echo "Rewrote ${total_rewritten} reference(s) in ${files} file(s) to @${new_ref} (${total_refs} internal reference(s) in the set)."
}

main "$@"
_main_exit_code=$?
exit ${_main_exit_code}
