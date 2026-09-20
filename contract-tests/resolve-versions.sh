#!/bin/env bash
#
# Resolve the terraform version matrix for the contract tests.
#
# Reads contract-tests/versions.json — the ONE place the version window lives:
#
#   newest-minors  how many of the newest minor series to test, each at its
#                  latest patch. The newest minor is always among them, so
#                  'latest' is always covered. Six covers every version the
#                  calling repositories pin today.
#   extra          exact versions to test in addition — for a caller pinned
#                  below the window. Usually empty.
#
# Nothing here is hardcoded to a release: the window is resolved against the
# HashiCorp releases API at run time, so a new minor enters the matrix on the
# next run (the weekly schedule catches it without anyone pushing) and the
# oldest drops out. Pre-releases are skipped.
#
# Pagination: the API lists releases newest first, 20 per page, and pages with
# ?after=<timestamp_created of the last item>. The latest patch of a minor is
# the first release of that minor in this order (patches are never released
# out of order within a minor), so paging stops once two minors beyond the
# window have been seen — everything the window needs is above that point.
# Capped at 20 pages regardless.
#
# Outputs (to $GITHUB_OUTPUT when set, else stdout):
#   matrix   JSON array of exact versions, newest first
#
# Fails loudly — this workflow is not on the required-check path, so a silent
# empty matrix would be a green run that tested nothing.
#

set -o nounset
set -o pipefail
set -o errexit

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
API_URL="${RELEASES_API_URL:-https://api.releases.hashicorp.com/v1/releases/terraform}"
PAGE_SIZE=20
MAX_PAGES=20

function die {
  echo "::error title=Terraform version resolution failed::${*}"
  exit 1
}

function main {
  local policy="${_this_script_dir}/versions.json"
  [ -f "${policy}" ] || die "policy file ${policy} is missing"
  local newest extra
  newest=$(jq -er '."newest-minors"' "${policy}") || die "versions.json: 'newest-minors' must be an integer"
  [[ "${newest}" =~ ^[1-9][0-9]*$ ]] || die "versions.json: 'newest-minors' must be a positive integer, got '${newest}'"
  extra=$(jq -ec '.extra // [] | if type == "array" then . else error("extra must be an array") end' "${policy}") \
    || die "versions.json: 'extra' must be an array of exact versions"
  # An entry that is not X.Y.Z would reach setup-terraform as a version
  # constraint or a typo and fail one matrix leg with a message that never
  # mentions versions.json.
  if ! jq -e 'all(.[]; type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<<"${extra}" >/dev/null; then
    local bad
    bad=$(jq -r '.[] | select(type != "string" or (tostring | test("^[0-9]+\\.[0-9]+\\.[0-9]+$") | not)) | tostring' <<<"${extra}" | head -n1)
    die "versions.json: every 'extra' entry must be an exact version X.Y.Z, got '${bad}'"
  fi

  declare -A latest_by_minor=()
  local page=0 after="" url n version pre minor current newer
  # Not local: the EXIT trap runs after main has returned, under nounset.
  body=$(mktemp)
  trap 'rm -f "${body:-}"' EXIT
  while :; do
    # license_class=oss is what every Terraform release carries (the API also
    # serves BSL-licensed products); it narrows nothing here and is kept so a
    # future enterprise/other class never enters the window unnoticed.
    url="${API_URL}?license_class=oss&limit=${PAGE_SIZE}"
    [ -n "${after}" ] && url="${url}&after=${after}"
    if ! curl --fail --silent --show-error --retry 3 --retry-delay 5 --max-time 30 -o "${body}" "${url}"; then
      die "the HashiCorp releases API is unreachable (${url})"
    fi
    jq -e 'type == "array"' "${body}" >/dev/null 2>&1 || die "unexpected response shape from ${url}"
    n=$(jq -r 'length' "${body}")
    [ "${n}" -eq 0 ] && break

    while IFS=$'\t' read -r version pre; do
      [ "${pre}" = 'true' ] && continue
      [[ "${version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
      minor="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
      current="${latest_by_minor[${minor}]:-}"
      newer=$(printf '%s\n%s\n' "${current:-0.0.0}" "${version}" | sort -V | tail -n1)
      [ "${newer}" = "${version}" ] && latest_by_minor["${minor}"]="${version}"
    done < <(jq -r '.[] | [.version, (.is_prerelease | tostring)] | @tsv' "${body}")

    after=$(jq -r '.[-1].timestamp_created' "${body}")
    page=$((page + 1))
    [ "${#latest_by_minor[@]}" -ge $((newest + 2)) ] && break
    [ "${page}" -ge "${MAX_PAGES}" ] && break
    [ "${n}" -lt "${PAGE_SIZE}" ] && break
  done

  local selected
  selected=$(printf '%s\n' "${latest_by_minor[@]}" | sort -V -r | head -n "${newest}")
  local count
  count=$(printf '%s\n' "${selected}" | grep -c . || true)
  [ "${count}" -ge "${newest}" ] || die "resolved only ${count} of the ${newest} newest minors after ${page} page(s): $(printf '%s' "${selected}" | paste -sd, -)"

  local matrix
  matrix=$(printf '%s\n' "${selected}" | jq -R . | jq -sc --argjson extra "${extra}" '. + $extra | unique | sort_by(split(".") | map(tonumber)) | reverse')

  echo "window: newest ${newest} minor(s) at their latest patch, plus extra ${extra}"
  echo "resolved after ${page} page(s): ${matrix}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "matrix=${matrix}" >>"${GITHUB_OUTPUT}"
  else
    echo "matrix=${matrix}"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### Terraform versions under contract\n\n'
      printf 'Newest %s minors at their latest patch (resolved from the HashiCorp releases API), plus `extra` from `contract-tests/versions.json`:\n\n' "${newest}"
      jq -r '.[] | "- `" + . + "`"' <<<"${matrix}"
      printf '\n'
    } >>"${GITHUB_STEP_SUMMARY}"
  fi
}

main
_main_exit_code=$?
exit ${_main_exit_code}
