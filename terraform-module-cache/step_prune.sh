#!/bin/env bash
#
# Source for the terraform-module-cache 'prune' step.
#
# Runs after the save gate and immediately before the cache save. Removes the
# git metadata terraform's module installs leave behind.
#
# Terraform installs any module with a git source by shelling out to 'git
# clone', and the clone's '.git' stays in the tree afterwards — as a directory
# for the module itself, and as a gitlink file for anything reached through
# 'git submodule update', which terraform also runs. That metadata is the larger
# half of what would otherwise be archived: a single AVM module measures 1.5 MB
# installed, 580 KB of it the module and 932 KB of it '.git'.
#
# Terraform never reads it again. Reconciliation is against the manifest and the
# module directories (§2.1, §2.6), which is why a pruned tree restores and skips
# the download exactly like an unpruned one — verified before this was written,
# both in place and through a full archive/restore cycle.
#
# Only runs when the save is actually going to happen, so a run that is not
# saving keeps its tree exactly as init produced it.
#
# Outputs:
#   pruned-count - how many '.git' entries were removed.
#   freed-kib    - how much smaller the cache paths got, in KiB.
#
# Required environment variables:
#   input_cache_paths - newline-separated cache paths from the resolve step.
#

set +o nounset

source "${GITHUB_ACTION_PATH}/helpers.sh"

# Refuse a path that is not what the resolve step emits. This step runs 'rm -rf'
# over whatever it is handed, so it does not take that on trust: '<dir>/../..'
# would otherwise resolve to somewhere outside the workspace entirely, and the
# repository's own '.git' is one such somewhere.
function _path_is_sane {
  local path="${1}" abs resolved workspace

  # Every path the resolve step emits ends this way — './.terraform/modules' for
  # a project at the repository root, '<dir>/.terraform/modules' otherwise.
  case "${path}" in
    *'.terraform/modules') ;;
    *)
      log-warn "'${path}' is not a '.terraform/modules' path, refusing to prune it"
      return 1
      ;;
  esac

  abs="${GITHUB_WORKSPACE}/${path}"
  # '|| true' throughout this step: the runner sources it in a 'bash -e -o
  # pipefail' shell, where any of these exiting non-zero would end the step —
  # and the step's whole contract is that it can never be what fails a run.
  resolved="$(realpath -m -- "${abs}" 2>/dev/null || true)"
  workspace="$(realpath -m -- "${GITHUB_WORKSPACE}" 2>/dev/null || true)"
  if [ -z "${resolved}" ] || [ -z "${workspace}" ] || [ "${resolved}" == "${workspace}" ] ||
    [ "${resolved#"${workspace}/"}" == "${resolved}" ]; then
    log-warn "'${path}' resolves outside the workspace, refusing to prune it"
    return 1
  fi

  return 0
}

function main {
  local path abs before after count total_count=0 total_freed=0

  if [ -z "${input_cache_paths}" ]; then
    log-info "no cache paths, nothing to prune"
    set-output 'pruned-count' '0'
    set-output 'freed-kib' '0'
    return 0
  fi

  while IFS= read -r path; do
    [ -z "${path}" ] && continue
    _path_is_sane "${path}" || continue

    abs="${GITHUB_WORKSPACE}/${path}"
    if [ ! -d "${abs}" ]; then
      log-info "'${path}' does not exist, nothing to prune there"
      continue
    fi

    # -name matches the directory a plain clone leaves and the gitlink file a
    # submodule checkout leaves alike. -prune keeps find from descending into
    # what it has already handed to rm.
    count="$( { find "${abs}" -name .git -prune -print 2>/dev/null || true; } | wc -l)"
    if [ "${count}" -eq 0 ]; then
      log-info "'${path}' holds no git metadata"
      continue
    fi

    before="$( { du -sk "${abs}" 2>/dev/null || true; } | cut -f1)"
    find "${abs}" -name .git -prune -exec rm -rf {} + 2>/dev/null || true
    after="$( { du -sk "${abs}" 2>/dev/null || true; } | cut -f1)"
    # A du that produced nothing must not turn the arithmetic below into a
    # syntax error and take the step with it.
    before="${before:-0}"
    after="${after:-0}"

    total_count=$((total_count + count))
    total_freed=$((total_freed + before - after))
    log-info "'${path}': removed ${count} git metadata entr$([ "${count}" -eq 1 ] && echo 'y' || echo 'ies'), $((before - after)) KiB"
  done <<<"${input_cache_paths}"

  log-info "pruned ${total_count} git metadata entr$([ "${total_count}" -eq 1 ] && echo 'y' || echo 'ies'), freeing ${total_freed} KiB before the save"
  set-output 'pruned-count' "${total_count}"
  set-output 'freed-kib' "${total_freed}"
  return 0
}

main
_main_exit_code=$?
exit ${_main_exit_code}
