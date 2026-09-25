#!/bin/env bash
#
# Source for the verify-lock step
#
# Verifies that the committed .terraform.lock.hcl in the working directory
# contains h1: hashes for every required platform. Catches single-platform
# lock bumps (e.g. someone running 'terraform init' on macOS) before they
# break runs on other platforms.
#
# How it works:
#   1. Saves a copy of the committed lock file to a tempfile
#   2. Runs 'terraform providers lock' for the required platforms in the
#      working directory; this updates the file in-place if any platform
#      hashes were missing
#   3. Compares the result to the saved copy
#   4. Fails with a clear remediation message if they differ
#
# Note that we deliberately let 'terraform providers lock' overwrite the
# committed file:
#   - 'terraform providers lock' only ADDS missing platform hashes; it
#     never changes provider versions or removes existing hashes. The
#     result is always a superset of the original.
#   - Downstream steps in the same job (plan, apply) read the lock file
#     for hash verification and work correctly with a superset.
#   - The 'actions/cache@v5' key was computed earlier in the job, so a
#     mid-job rewrite does not affect cache restore/save.
#   - The CI rewrite never makes it back to the repo — when verification
#     fails, the user fixes the lock file locally and pushes a new commit.
#   - Bonus: provider binaries fetched for the additional platforms warm
#     the '.terraform/providers/' cache for subsequent terraform steps.
#
# Lock-only mode (input_lock_only=true) checks the lock file on its own,
# before any init: the providers the lock records, at their locked versions,
# become a throwaway configuration in a temporary directory, and step 2 runs
# there against a copy of the lock. The committed file is never touched, and
# the directory's own configuration and '.terraform/' play no part. Lock
# rewrites the copy's 'constraints' to the exact version, so the comparison
# ignores that line. When input_plugin_cache_directory holds the package of
# every locked provider for every required platform, the hashes are computed
# from those packages (-fs-mirror) instead of downloading them.
#
# Required environment variables:
#   input_working_directory - Directory containing .terraform.lock.hcl
#   input_platforms         - Newline-separated list of os_arch platforms
#
# Optional environment variables:
#   input_lock_only              - 'true' for lock-only mode
#   input_plugin_cache_directory - Plugin cache to hash from in lock-only mode
#
#   TF_BIN - Path to the terraform binary (defaults to 'terraform' on PATH).
#            Used by tests to inject a stub.
#

set -o nounset

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Helper Functions (step-local)
# ============================================================================

# Parse the newline-separated platforms input into a global array.
# Trims whitespace and skips empty lines. Sets:
#   REQUIRED_PLATFORMS - array of "os_arch" strings
#   PLATFORM_ARGS      - array of "-platform=os_arch" strings
function parse_platforms {
  REQUIRED_PLATFORMS=()
  PLATFORM_ARGS=()
  local p
  while IFS= read -r p; do
    p="$(echo "${p}" | xargs)"
    [ -z "${p}" ] && continue
    REQUIRED_PLATFORMS+=("${p}")
    PLATFORM_ARGS+=("-platform=${p}")
  done <<<"${input_platforms}"
}

# Print one '<address> <version>' line per provider block of the lock file $1.
function locked_providers {
  awk '
    /^provider "/ { address = $2; gsub(/"/, "", address); next }
    address != "" && /^[[:space:]]*version[[:space:]]*=/ {
      version = $0; sub(/^[^"]*"/, "", version); sub(/".*$/, "", version)
      print address, version; address = ""
    }
  ' "${1}"
}

# Write a configuration requiring exactly the providers listed in file $1
# ('<address> <version>' lines) into directory $2. Local names are positional,
# so two providers of one type from different namespaces cannot collide.
function write_lock_only_config {
  local providers="${1}" dir="${2}" address version index=0
  {
    echo 'terraform {'
    echo '  required_providers {'
    while read -r address version; do
      index=$((index + 1))
      echo "    p${index} = { source = \"${address}\", version = \"${version}\" }"
    done <"${providers}"
    echo '  }'
    echo '}'
  } >"${dir}/versions.tf"
}

# Return 0 when plugin cache $1 holds the unpacked package of every provider in
# file $2 for every required platform, so '-fs-mirror' can hash all of them.
function plugin_cache_covers {
  local cache="${1}" providers="${2}" address version platform
  [ -n "${cache}" ] && [ -d "${cache}" ] || return 1
  while read -r address version; do
    for platform in "${REQUIRED_PLATFORMS[@]}"; do
      [ -d "${cache}/${address}/${version}/${platform}" ] || return 1
    done
  done <"${providers}"
  return 0
}

# The lock file $1 without its 'constraints' lines, for a lock-only comparison.
function without_constraints {
  grep -v '^[[:space:]]*constraints[[:space:]]*=' "${1}" || true
}

# Write the success block to $GITHUB_STEP_SUMMARY (if set).
function write_success_summary {
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] && return 0
  {
    echo "### ✅ Terraform lock file verification passed"
    echo ""
    echo "**Directory:** \`${input_working_directory}\`"
    echo ""
    echo "**Verified platforms:**"
    local p
    for p in "${REQUIRED_PLATFORMS[@]}"; do echo "- \`${p}\`"; done
  } >>"${GITHUB_STEP_SUMMARY}"
}

# Write the failure block to $GITHUB_STEP_SUMMARY (if set).
# Args:
#   $1 - path to the saved copy of the original lock file
#   $2 - path to the (now updated) committed lock file
function write_failure_summary {
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] && return 0
  local committed="${1}"
  local updated="${2}"

  local fix_cmd="terraform providers lock"
  local p
  for p in "${REQUIRED_PLATFORMS[@]}"; do
    fix_cmd+=" \\
  -platform=${p}"
  done

  {
    echo "### ❌ Terraform lock file is missing platform hashes"
    echo ""
    echo "**Directory:** \`${input_working_directory}\`"
    echo ""
    echo "**Required platforms:**"
    for p in "${REQUIRED_PLATFORMS[@]}"; do echo "- \`${p}\`"; done
    echo ""
    echo "This usually happens when someone runs \`terraform init\` on a single platform (e.g. their Mac or Windows machine) and commits the resulting lock file. Other platforms — including the Linux CI runner — will then fail provider checksum verification."
    echo ""
    echo "**Fix locally:**"
    echo ""
    echo '```bash'
    echo "cd ${input_working_directory}"
    echo "${fix_cmd}"
    echo "git add .terraform.lock.hcl && git commit -m 'fix: lock providers for all required platforms'"
    echo '```'
    echo ""
    echo "<details><summary>Diff (committed vs expected)</summary>"
    echo ""
    echo '```diff'
    diff -u "${committed}" "${updated}" || true
    echo '```'
    echo ""
    echo "</details>"
  } >>"${GITHUB_STEP_SUMMARY}"
}

# ============================================================================
# Main Logic
# ============================================================================

function main {
  local tf_bin="${TF_BIN:-terraform}"
  local lock_only="${input_lock_only:-false}"
  local plugin_cache="${input_plugin_cache_directory:-}"

  log-info "starting lock file verification ..."

  if [ -z "${input_working_directory}" ]; then
    log-error "input 'working-directory' is required"
    return 1
  fi

  if [ ! -d "${input_working_directory}" ]; then
    log-error "working directory '${input_working_directory}' does not exist"
    return 1
  fi

  # Resolved before the cd below, which would otherwise re-root a relative path.
  [ -n "${plugin_cache}" ] && plugin_cache="$(realpath -m "${plugin_cache}")"

  cd "${input_working_directory}"

  if [ ! -f .terraform.lock.hcl ]; then
    echo "::error title=No lock file::No .terraform.lock.hcl found in '${input_working_directory}'"
    return 1
  fi

  if [ "${lock_only}" != "true" ] && [ ! -d .terraform ]; then
    echo "::error title=No .terraform directory::Expected '.terraform/' to exist in '${input_working_directory}' from a prior 'terraform init' step. This action must run after init succeeds."
    return 1
  fi

  parse_platforms
  if [ ${#PLATFORM_ARGS[@]} -eq 0 ]; then
    echo "::error title=No platforms specified::Input 'platforms' must contain at least one os_arch entry"
    return 1
  fi

  log-info "verifying lock file in '${input_working_directory}' covers: ${REQUIRED_PLATFORMS[*]}"

  # Snapshot the committed lock file so we can produce a useful diff if
  # 'terraform providers lock' ends up modifying it.
  local committed_snapshot
  committed_snapshot="$(mktemp)"
  cp .terraform.lock.hcl "${committed_snapshot}"

  local run_dir="." mirror_args=() lock_only_dir=""
  if [ "${lock_only}" == "true" ]; then
    lock_only_dir="$(mktemp -d)"
    locked_providers .terraform.lock.hcl >"${lock_only_dir}/providers.list"
    if [ ! -s "${lock_only_dir}/providers.list" ]; then
      log-info "the lock file records no providers; nothing to verify"
      write_success_summary
      set-output "is-complete" "true"
      rm -rf "${committed_snapshot}" "${lock_only_dir}"
      return 0
    fi
    run_dir="${lock_only_dir}/config"
    mkdir "${run_dir}"
    write_lock_only_config "${lock_only_dir}/providers.list" "${run_dir}"
    cp .terraform.lock.hcl "${run_dir}/.terraform.lock.hcl"
    if plugin_cache_covers "${plugin_cache}" "${lock_only_dir}/providers.list"; then
      log-info "hashing the packages in the plugin cache '${plugin_cache}'"
      mirror_args=("-fs-mirror=${plugin_cache}")
    else
      log-info "the plugin cache does not hold every package; downloading them to hash"
    fi
  fi

  start-group "running 'terraform providers lock' for required platforms"
  set +e
  (cd "${run_dir}" && "${tf_bin}" providers lock -no-color "${mirror_args[@]}" "${PLATFORM_ARGS[@]}")
  local lock_exit=$?
  set -e
  end-group

  if [ "${lock_exit}" -ne 0 ]; then
    log-error "'terraform providers lock' failed with exit code ${lock_exit}"
    rm -rf "${committed_snapshot}" "${lock_only_dir}"
    return "${lock_exit}"
  fi

  local complete="false" expected=".terraform.lock.hcl"
  if [ "${lock_only}" == "true" ]; then
    expected="${run_dir}/.terraform.lock.hcl"
    cmp -s <(without_constraints "${committed_snapshot}") <(without_constraints "${expected}") && complete="true"
  else
    cmp -s "${committed_snapshot}" .terraform.lock.hcl && complete="true"
  fi

  if [ "${complete}" == "true" ]; then
    echo "::notice title=Lock file OK::All required platform hashes are present"
    log-info "lock file is complete for all required platforms"
    write_success_summary
    set-output "is-complete" "true"
    rm -rf "${committed_snapshot}" "${lock_only_dir}"
    return 0
  fi

  echo "::error title=Lock file incomplete::.terraform.lock.hcl in '${input_working_directory}' is missing hashes for one or more required platforms"
  log-error "lock file is missing hashes for one or more required platforms"
  log-multiline "Diff (committed vs expected)" "$(diff -u "${committed_snapshot}" "${expected}" || true)"
  write_failure_summary "${committed_snapshot}" "${expected}"
  set-output "is-complete" "false"
  rm -rf "${committed_snapshot}" "${lock_only_dir}"
  return 1
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
