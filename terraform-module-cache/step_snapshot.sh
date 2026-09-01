#!/bin/env bash
#
# Source for the terraform-module-cache 'snapshot' step.
#
# Runs after the cache restore and before 'terraform init'. Copies each
# included directory's restored modules.json aside so the verify step has a
# before-image to compare against (§4.4.2).
#
# A no-op when the restore missed — there is nothing to compare against, and
# the verify step skips the comparison rather than reporting a phantom change.
#
# Outputs:
#   snapshot-dir - directory holding the before-images.
#
# Required environment variables:
#   input_cache_paths - newline-separated cache paths from the resolve step.
#
# Optional environment variables:
#   input_cache_hit - 'true' when the restore was an exact hit.
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  local snapshot_dir path manifest taken=0

  snapshot_dir="${RUNNER_TEMP:-/tmp}/module-cache-manifests"
  mkdir -p "${snapshot_dir}"
  set-output 'snapshot-dir' "${snapshot_dir}"

  if [ "${input_cache_hit}" != 'true' ]; then
    log-info "restore was not an exact hit, nothing to snapshot"
    return 0
  fi

  while IFS= read -r path; do
    [ -z "${path}" ] && continue
    manifest="${GITHUB_WORKSPACE}/${path}/modules.json"
    if [ -f "${manifest}" ]; then
      cp "${manifest}" "${snapshot_dir}/$(manifest-slug "${path}").json"
      taken=$((taken + 1))
    else
      log-warn "no restored manifest at '${path}/modules.json'"
    fi
  done <<<"${input_cache_paths}"

  log-info "took ${taken} manifest snapshot(s) into '${snapshot_dir}'"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
