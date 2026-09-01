#!/bin/env bash
#
# Source for the terraform-module-cache 'resolve' step.
#
# Runs BEFORE 'terraform init'. Decides which init directories may be cached,
# where their module trees live, and under what key — see
# docs/Terraform-module-cache.md §4.3-§4.5.
#
# Outputs:
#   cache-enabled      - 'true' when at least one directory qualifies.
#   cache-paths        - newline-separated '<dir>/.terraform/modules' paths,
#                        consumed by both cache steps and by the snapshot and
#                        verify steps.
#   cache-key          - the one and only key. Computed here, once, and passed
#                        to restore AND save (§4.2, invariant 8.7).
#   excluded-dirs-file - path to a file listing excluded directories and the
#                        reason for each. A PATH, never a payload (ARG_MAX).
#
# Required environment variables:
#   input_project_dir          - The environment's terraform directory.
#   input_additional_dirs_json - JSON array of extra directories to init.
#   input_environment          - Matrix environment name, for the key.
#
# Optional environment variables:
#   RUNNER_OS - Lowercased into the key. Defaults to 'linux'.
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# Collect '<dir>' entries: project-dir first, then the additional dirs, each
# normalised and de-duplicated. './main' and 'main' are the same directory and
# must not become two cache paths or two digest entries (§4.3).
function _collect_dirs {
  local out_file="${1}"
  local d
  {
    normalize-dir "${input_project_dir}"
    printf '%s' "${input_additional_dirs_json:-[]}" |
      jq -r '.[]?' 2>/dev/null |
      while IFS= read -r d; do
        [ -z "${d}" ] && continue
        normalize-dir "${d}"
      done
    # De-duplicate after normalising and keep first-seen order, so project-dir
    # leads and './main' plus 'main' collapse to one cache path and one digest
    # entry rather than two (§4.3).
  } | awk '!seen[$0]++' >"${out_file}"
}

function main {
  local dirs_file decls_file digest_file excluded_file paths_file
  local dir abs mutable_found dot_path src ver verdict
  local digest key env_slug included_count

  dirs_file="$(mktemp)"
  decls_file="$(mktemp)"
  digest_file="$(mktemp)"
  paths_file="$(mktemp)"
  excluded_file="${RUNNER_TEMP:-/tmp}/module-cache-excluded-dirs.txt"
  : >"${excluded_file}"

  _collect_dirs "${dirs_file}"

  included_count=0
  while IFS= read -r dir; do
    [ -z "${dir}" ] && continue

    start-group "auditing '${dir}'"

    abs="${GITHUB_WORKSPACE}/${dir}"
    if [ ! -d "${abs}" ]; then
      log-warn "directory does not exist, excluding"
      echo "${dir}: directory does not exist" >>"${excluded_file}"
      end-group
      continue
    fi

    reset-walk-state
    : >"${decls_file}"
    walk-remote-modules "${abs}" >"${decls_file}"

    if [ ! -s "${decls_file}" ]; then
      log-info "no remote modules reachable, nothing to cache"
      echo "${dir}: no remote modules reachable" >>"${excluded_file}"
      end-group
      continue
    fi

    # Any mutable source anywhere in the reachable set disqualifies the whole
    # directory. It then inits exactly as it does today (§3).
    mutable_found=''
    while IFS=$'\t' read -r dot_path src ver; do
      [ -z "${dot_path}" ] && continue
      verdict="$(classify-source config "${src}" "${ver}")"
      if [ "${verdict}" == 'mutable' ]; then
        mutable_found="${dot_path} (${src}${ver:+ ${ver}})"
        break
      fi
    done <"${decls_file}"

    if [ -n "${mutable_found}" ]; then
      log-warn "reachable module '${mutable_found}' can move, excluding"
      echo "${dir}: module '${mutable_found}' does not resolve to immutable content" >>"${excluded_file}"
      end-group
      continue
    fi

    log-info "included, $(wc -l <"${decls_file}") reachable remote module(s)"
    echo "${dir}/.terraform/modules" >>"${paths_file}"
    # Digest input: the declarations, not the file contents. Editing a
    # resource block must not move the key; bumping a pin must (§4.4.1).
    sed "s|^|${dir}\t|" "${decls_file}" >>"${digest_file}"
    included_count=$((included_count + 1))

    end-group
  done <"${dirs_file}"

  # One notice per exclusion, so a repo that silently gets no caching can find
  # out why from the run page (§4.5).
  while IFS= read -r dir; do
    [ -z "${dir}" ] && continue
    echo "::notice::terraform-module-cache: not caching ${dir}"
  done <"${excluded_file}"
  set-output 'excluded-dirs-file' "${excluded_file}"

  if [ "${included_count}" -eq 0 ]; then
    log-info "no directory qualifies for caching, the cache steps will be skipped"
    set-output 'cache-enabled' 'false'
    set-output 'cache-paths' ''
    set-output 'cache-key' ''
    return 0
  fi

  digest="$(sort "${digest_file}" | sha256sum | cut -c1-16)"
  env_slug="$(printf '%s' "${input_environment}" | sed 's/[^[:alnum:]]\+/-/g')"
  key="tf-modules-$(printf '%s' "${RUNNER_OS:-linux}" | tr '[:upper:]' '[:lower:]')-${env_slug}-${digest}"

  log-multiline "cache paths" "$(cat "${paths_file}")"
  log-info "cache key is '${key}'"

  set-output 'cache-enabled' 'true'
  set-multiline-output 'cache-paths' "$(cat "${paths_file}")"
  set-output 'cache-key' "${key}"

  rm -f "${dirs_file}" "${decls_file}" "${digest_file}" "${paths_file}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
