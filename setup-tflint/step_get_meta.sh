#!/bin/env bash
#
# Source for the get-meta step of setup-tflint.
#
# Resolves the requested tflint version to:
#   - tag-name        — the resolved release tag (e.g. v0.61.0)
#   - download-url    — direct URL to the linux_amd64 .zip asset
#   - install-dir     — directory under runner.tool_cache where tflint lives
#   - install-bin-path — full path to the tflint binary
#   - cache-key       — actions/cache key for this binary
#
# Behavior:
#   'latest'          → fetches /releases/latest from the GitHub API
#                       (this branch must hit the API; the cache key only
#                       invalidates when latest moves, so we need the
#                       freshly-resolved tag).
#   specific version  → short-circuit: tag-name = the input, download-url
#                       constructed deterministically from the stable
#                       'tflint_linux_amd64.zip' asset name pattern. No
#                       GitHub Releases API call. Cache lookup then runs
#                       without any network dependency — cache hits are
#                       fully offline.
#
# Required environment variables:
#   input_tflint_version    - 'latest' or a specific tag like 'v0.61.0'
#   input_github_token      - token for the GH API call (auth raises rate-limit)
#   input_runner_tool_cache - $RUNNER_TOOL_CACHE (where the binary lives)
#   input_runner_os         - $RUNNER_OS, used in cache-key
#   input_runner_arch       - $RUNNER_ARCH, used in cache-key
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# Hardcoded to linux_amd64 — matches the only platform DSB runs CI on. The
# release asset name pattern is stable across tflint versions.
declare -gr TFLINT_ASSET_NAME='tflint_linux_amd64.zip'

function main {
  local tag_name dl_url install_dir

  if [ "latest" = "${input_tflint_version}" ]; then
    # 'latest' genuinely needs the API — we don't know the version yet, and
    # we want the cache key to invalidate when 'latest' moves.
    if ! _resolve_latest_from_api tag_name dl_url; then
      return 1
    fi
  else
    # Specific version: short-circuit the API. tag_name is the input itself,
    # and the release asset name/URL pattern is stable across tflint releases
    # so we can construct the download URL deterministically.
    #
    # Benefits over the pre-v0.24 unconditional API call:
    #   - No network dependency on the GitHub Releases API for specific
    #     versions → eliminates the curl-exit-92 / HTTP/2 stream-error
    #     class of transient failures (real-world repro:
    #     dsb-infra/azure-terraform-ikt-operations run 26083928306).
    #   - When the binary is already in actions/cache, the action completes
    #     with zero outbound network calls.
    #   - Faster — no 3 MB releases?per_page=100 download just to look up
    #     one tag.
    #
    # Trade-off: we trust the caller's input. A typo'd version like
    # "v9.99.99" used to fail in get-meta with "unable to find release with
    # tag_name 'v9.99.99'"; it now fails later in the install step when
    # curl can't fetch the constructed URL. That's an acceptable shift —
    # the failure is still loud and the error context (which version was
    # requested + the resolved URL) is still in the log.
    tag_name="${input_tflint_version}"
    dl_url="https://github.com/terraform-linters/tflint/releases/download/${tag_name}/${TFLINT_ASSET_NAME}"
    log-info "resolved specific version '${tag_name}' without hitting the GitHub Releases API"
    log-info "constructed download url: ${dl_url}"
  fi

  install_dir="${input_runner_tool_cache}/tflint_${tag_name}"

  set-output 'tag-name' "${tag_name}"
  set-output 'download-url' "${dl_url}"
  set-output 'install-dir' "${install_dir}"
  set-output 'install-bin-path' "${install_dir}/tflint"
  set-output 'cache-key' "tflint-binary-${tag_name}-${input_runner_os}-${input_runner_arch}"
  return 0
}

# Fetches the /releases/latest endpoint, parses tag-name and the linux_amd64
# asset URL, writes them into the named output variables passed by the caller.
# Args (by reference via nameref):
#   $1  - name of out var for tag-name
#   $2  - name of out var for download url
# Returns 0 on success, 1 on any parse/curl failure.
#
# NOTE on naming: the helper's locals are deliberately prefixed with an
# underscore so they don't shadow caller-scope variables of the same logical
# name. Bash namerefs look up the target variable by NAME, and a same-name
# local in this scope would intercept the lookup — making the assignment to
# the nameref silently update the local instead of the caller's variable.
function _resolve_latest_from_api {
  local -n _out_tag="${1}"
  local -n _out_url="${2}"

  local _release_url='https://api.github.com/repos/terraform-linters/tflint/releases/latest'
  log-info "get 'latest' release json from '${_release_url}' ..."

  local _release_json
  _release_json=$(
    curl -s --request GET \
      --url "${_release_url}" \
      --header "Accept: application/json" \
      --header "authorization: Bearer ${input_github_token}"
  )

  local _tag _asset_json _url

  _tag=$(echo "${_release_json}" | jq -r '.tag_name') || {
    log-error "jq failed to find 'tag_name' in release json!"
    log-multiline "release json" "${_release_json}"
    return 1
  }
  if [ -z "${_tag}" ] || [ "${_tag}" = 'null' ]; then
    log-error "release json contained no 'tag_name'!"
    log-multiline "release json" "${_release_json}"
    return 1
  fi
  log-info "found release tag '${_tag}'"

  _asset_json=$(echo "${_release_json}" | jq --arg n "${TFLINT_ASSET_NAME}" '.assets[] | select(.name == $n)') || {
    log-error "jq failed to find an asset named '${TFLINT_ASSET_NAME}' in release json!"
    log-multiline "release json" "${_release_json}"
    return 1
  }
  if [ -z "${_asset_json}" ]; then
    log-error "unable to find asset '${TFLINT_ASSET_NAME}' in release JSON!"
    log-multiline "release json" "${_release_json}"
    return 1
  fi

  _url=$(echo "${_asset_json}" | jq -r '.browser_download_url') || {
    log-error "jq failed to find 'browser_download_url' in asset json!"
    log-multiline "asset json" "${_asset_json}"
    return 1
  }
  if [ -z "${_url}" ] || [ "${_url}" = 'null' ]; then
    log-error "unable to get download url from asset json!"
    log-multiline "asset json" "${_asset_json}"
    return 1
  fi
  log-info "found release download url '${_url}'"

  _out_tag="${_tag}"
  _out_url="${_url}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
