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
# Faithful extraction of the pre-conversion inline-bash logic:
# unconditionally calls the GitHub Releases API to obtain TAG_NAME and
# asset URL. A subsequent commit short-circuits this for non-'latest'
# requests.
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
  local release_url release_json all_releases_json tag_name asset_json dl_url install_dir

  if [ "latest" = "${input_tflint_version}" ]; then
    release_url='https://api.github.com/repos/terraform-linters/tflint/releases/latest'
    log-info "get 'latest' release json from '${release_url}' ..."
    release_json=$(
      curl -s --request GET \
        --url "${release_url}" \
        --header "Accept: application/json" \
        --header "authorization: Bearer ${input_github_token}"
    )
  else
    release_url='https://api.github.com/repos/terraform-linters/tflint/releases?per_page=100'
    log-info "get '${input_tflint_version}' release json from '${release_url}' ..."
    all_releases_json=$(
      curl -s --request GET \
        --url "${release_url}" \
        --header "Accept: application/json" \
        --header "authorization: Bearer ${input_github_token}"
    )
    release_json=$(echo "${all_releases_json}" | jq --arg v "${input_tflint_version}" 'first(.[] | select(.tag_name == $v) )') || {
      log-error "jq failed to locate 'tag_name' = '${input_tflint_version}' in release json!"
      log-multiline "release json" "${all_releases_json}"
      return 1
    }
    if [ -z "${release_json}" ]; then
      log-error "unable to find release with tag_name '${input_tflint_version}' in response of '${release_url}'!"
      return 1
    fi
  fi

  tag_name=$(echo "${release_json}" | jq -r '.tag_name') || {
    log-error "jq failed to find 'tag_name' in release json!"
    log-multiline "release json" "${release_json}"
    return 1
  }
  if [ -z "${tag_name}" ] || [ "${tag_name}" = 'null' ]; then
    log-error "release json contained no 'tag_name'!"
    log-multiline "release json" "${release_json}"
    return 1
  fi
  log-info "found release tag '${tag_name}'"

  # NOTE: architecture hardcoded to linux amd64 (see TFLINT_ASSET_NAME).
  asset_json=$(echo "${release_json}" | jq --arg n "${TFLINT_ASSET_NAME}" '.assets[] | select(.name == $n)') || {
    log-error "jq failed to find an asset named '${TFLINT_ASSET_NAME}' in release json!"
    log-multiline "release json" "${release_json}"
    return 1
  }
  if [ -z "${asset_json}" ]; then
    log-error "unable to find asset '${TFLINT_ASSET_NAME}' in release JSON!"
    log-multiline "release json" "${release_json}"
    return 1
  fi

  dl_url=$(echo "${asset_json}" | jq -r '.browser_download_url') || {
    log-error "jq failed to find 'browser_download_url' in asset json!"
    log-multiline "asset json" "${asset_json}"
    return 1
  }
  if [ -z "${dl_url}" ] || [ "${dl_url}" = 'null' ]; then
    log-error "unable to get download url from asset json!"
    log-multiline "asset json" "${asset_json}"
    return 1
  fi
  log-info "found release download url '${dl_url}'"

  install_dir="${input_runner_tool_cache}/tflint_${tag_name}"

  set-output 'tag-name' "${tag_name}"
  set-output 'download-url' "${dl_url}"
  set-output 'install-dir' "${install_dir}"
  set-output 'install-bin-path' "${install_dir}/tflint"
  set-output 'cache-key' "tflint-binary-${tag_name}-${input_runner_os}-${input_runner_arch}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
