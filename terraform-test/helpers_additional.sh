#!/bin/env bash
#
# Helpers for step_run_tests.sh. Loaded by helpers.sh.
#

# The Terraform version below which the action refuses to run tests
# (docs/Terraform-tests.md §3.5): 1.13 accepts the variable blocks a test file
# needs for lane variables, which 1.12 refuses. -junit-xml exists from 1.11.
TT_VERSION_FLOOR="1.13.0"
TT_JUNIT_FROM="1.11.0"

# GitHub caps error annotations at ten per step (P17).
TT_MAX_ANNOTATIONS=10
# failed-runs-json stays well under capture-matrix-job-meta's 4 KiB cap.
TT_FAILED_RUNS_BYTES=3000
# The text report is uploaded for humans and quoted by comment renderers.
TT_REPORT_BYTES=65000
# Bullets in the per-job step summary.
TT_SUMMARY_BULLETS=50

# jq with this action's definitions (terraform_test.jq) available.
function tt-jq {
  jq -L "${GITHUB_ACTION_PATH}" "$@"
}

# 0 when version $1 >= version $2. Pre-release and build suffixes are
# ignored, so 1.13.0-rc1 counts as 1.13.0.
function tt-version-ge {
  local have="${1%%[-+]*}" need="${2%%[-+]*}"
  local -a h n
  IFS=. read -r -a h <<<"${have}"
  IFS=. read -r -a n <<<"${need}"
  local i
  for i in 0 1 2; do
    local hv="${h[i]:-0}" nv="${n[i]:-0}"
    [[ "${hv}" =~ ^[0-9]+$ ]] || return 1
    ((10#${hv} > 10#${nv})) && return 0
    ((10#${hv} < 10#${nv})) && return 1
  done
  return 0
}

# The runner's platform as Terraform names it: linux_amd64, darwin_arm64, …
function tt-runner-platform {
  local os arch
  os="$(tr '[:upper:]' '[:lower:]' <<<"${RUNNER_OS:-}")"
  case "${os}" in
    macos) os="darwin" ;;
  esac
  case "${RUNNER_ARCH:-}" in
    X64) arch="amd64" ;;
    ARM64) arch="arm64" ;;
    X86) arch="386" ;;
    ARM) arch="arm" ;;
    *) arch="$(tr '[:upper:]' '[:lower:]' <<<"${RUNNER_ARCH:-}")" ;;
  esac
  if [ -n "${os}" ] && [ -n "${arch}" ]; then
    echo "${os}_${arch}"
  fi
}

# The slug of docs/Terraform-tests.md §4.6 for root $1 and file $2 (relative
# to the root): '<root, / as ->--<basename without .tftest.hcl/.tftest.json>',
# '.' as 'root', reduced to [A-Za-z0-9._-] and 100 characters. Only a
# fallback: the workflow passes the matrix row's slug.
function tt-slug {
  local root="${1}" file="${2}"
  local base="${file##*/}"
  base="${base%.tftest.hcl}"
  base="${base%.tftest.json}"
  local root_part="${root//\//-}"
  [ "${root}" == "." ] && root_part="root"
  local slug="${root_part}--${base}"
  slug="$(LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g' <<<"${slug}")"
  echo "${slug:0:100}"
}

# Writes [{name, version}] for the providers of lock file $1 to file $2.
function tt-lock-to-json {
  local lock="${1}" out="${2}"
  awk '
    /^provider "/ { name = $2; gsub(/"/, "", name); next }
    /^[[:space:]]*version[[:space:]]*=/ && name != "" {
      v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v)
      print name "\t" v
      name = ""
    }
  ' "${lock}" | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], version: .[1]})' >"${out}"
}

# One-line explanation of a status/reason pair, for the report, the step
# summary and the annotation of errors that carry no diagnostic.
function tt-reason-message {
  local reason="${1}"
  case "${reason}" in
    no-credentials) echo "The lane's credentials are not set (ARM_TENANT_ID, ARM_CLIENT_ID); init and test were skipped. See the credential check step for the bring-up commands." ;;
    lock-platform) echo "The lock file records no checksum for this runner's platform (${TT_RUNNER_PLATFORM:-<os>_<arch>}); init and test were skipped. Fix: terraform providers lock -platform=${TT_RUNNER_PLATFORM:-<os>_<arch>} in the environment the lock comes from." ;;
    init) echo "terraform init did not succeed (outcome '${input_status_init}'); the test was not run." ;;
    terraform-version) echo "${TT_VERSION_MESSAGE}" ;;
    not-initialised) echo "The test root is not initialised for this configuration; run terraform init in it (see the diagnostics)." ;;
    invalid) echo "Terraform did not run the tests: the configuration or a test file in the root is invalid (see the diagnostics; the file may be a sibling)." ;;
    not-discovered) echo "Terraform did not discover '${TT_REL}' from '${TT_ROOT}': -filter matched no test file." ;;
    file) echo "The test file failed before its run blocks ran (see the diagnostics)." ;;
    run) echo "A run block errored; later run blocks were skipped." ;;
    assertion) echo "A test assertion failed." ;;
    *) echo "" ;;
  esac
}
