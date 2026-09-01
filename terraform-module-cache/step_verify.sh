#!/bin/env bash
#
# Source for the terraform-module-cache 'verify' step.
#
# Runs after 'terraform init' and before the cache save. Does both post-init
# jobs in one pass over the same manifests:
#
# The two are not equally important. Completeness is a diagnostic and is skipped
# whenever the before-image is unavailable for any reason; the gate is a safety
# control and always runs.
#
#   1. Digest completeness (§4.4.2). On an exact cache hit the resolved module
#      set must not have changed. If it did, the key missed an input, and
#      because a hit skips the save the entry is now permanently stale —
#      restored, reconciled and never written back. Silent, so it warns.
#
#   2. The save gate (§4.5.2). Every Source in the resolved graph is classified
#      through the same function the pre-init audit used. Any mutable one and
#      the entry is not written at all: a tree that is never written is never
#      restored. All-or-nothing across the entry, because one archive covers
#      every included directory under one key.
#
# Outputs:
#   safe-to-save - 'true' only when every included directory's resolved graph
#                  is immutable. Fails closed.
#
# Required environment variables:
#   input_cache_paths  - newline-separated cache paths from the resolve step.
#   input_snapshot_dir - where the snapshot step put the before-images.
#
# Optional environment variables:
#   input_cache_hit - 'true' when the restore was an exact hit.
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# Warn when an exact hit did not imply an unchanged module set.
function _check_completeness {
  local path="${1}" manifest="${2}"
  local before after

  [ "${input_cache_hit}" == 'true' ] || return 0

  # The snapshot step is a diagnostic aid and is allowed to fail; the save gate
  # below is not. Losing the before-image costs the completeness warning and
  # nothing else.
  if [ -z "${input_snapshot_dir}" ] || [ ! -d "${input_snapshot_dir}" ]; then
    log-info "no snapshot directory, skipping completeness check for '${path}'"
    return 0
  fi

  before="${input_snapshot_dir}/$(manifest-slug "${path}").json"
  if [ ! -f "${before}" ]; then
    log-info "no before-image for '${path}', skipping completeness check"
    return 0
  fi

  after="$(mktemp)"
  normalize-manifest "${manifest}" >"${after}"

  if ! diff -q <(normalize-manifest "${before}") "${after}" >/dev/null 2>&1; then
    echo "::warning::terraform-module-cache: module cache digest is incomplete for '${path%/.terraform/modules}' — the module set changed on an exact cache hit. The cache is not helping for this directory."
    log-multiline "resolved module set changed under an unchanged key" "$(diff <(normalize-manifest "${before}") "${after}" || true)"
  fi
  rm -f "${after}"
}

# Classify every resolved Source. Echoes a description of the first mutable
# one found, or nothing.
function _first_mutable {
  local manifest="${1}"
  local key src ver

  while IFS=$'\t' read -r key src ver; do
    [ -z "${src}" ] && continue
    if [ "$(classify-source manifest "${src}" "${ver}")" == 'mutable' ]; then
      printf '%s (%s)' "${key}" "${src}"
      return 0
    fi
  done < <(jq -r '.Modules[]? | [.Key, (.Source // ""), (.Version // "")] | @tsv' "${manifest}" 2>/dev/null)
}

function main {
  local path manifest mutable safe='true' checked=0

  if [ -z "${input_cache_paths}" ]; then
    log-info "no cache paths, nothing to verify"
    set-output 'safe-to-save' 'false'
    return 0
  fi

  while IFS= read -r path; do
    [ -z "${path}" ] && continue
    manifest="${GITHUB_WORKSPACE}/${path}/modules.json"

    if [ ! -f "${manifest}" ]; then
      # Fails closed: without the resolved graph there is no way to show the
      # tree is safe, and invariant 8.3 says an unsafe tree must never be
      # written.
      log-warn "no manifest at '${path}/modules.json', refusing to save"
      safe='false'
      continue
    fi

    if ! jq -e . "${manifest}" >/dev/null 2>&1; then
      # A manifest terraform itself would reject (§2.5). No resolved graph
      # means no way to show the tree is safe — invariant 8.3.
      log-warn "manifest at '${path}/modules.json' is not parseable, refusing to save"
      safe='false'
      continue
    fi

    _check_completeness "${path}" "${manifest}"

    mutable="$(_first_mutable "${manifest}")"
    if [ -n "${mutable}" ]; then
      echo "::warning::terraform-module-cache: not saving the module cache — '${path%/.terraform/modules}' resolves module ${mutable}, which can move. Caching it would freeze that module at the commit fetched now."
      safe='false'
    fi
    checked=$((checked + 1))
  done <<<"${input_cache_paths}"

  log-info "verified ${checked} manifest(s), safe-to-save=${safe}"
  set-output 'safe-to-save' "${safe}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
