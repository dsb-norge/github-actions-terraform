#!/bin/env bash
#
# Discovery script for the action-tests workflow.
#
# Scans top-level composite actions (directories containing action.yml at
# repo-root + 1 level deep) and partitions them into:
#   - tests-matrix:  JSON array of action names that have run_all_tests.sh
#   - no-tests-list: JSON array of action names that do not (or are excluded)
#
# Outputs are written to $GITHUB_OUTPUT when set (workflow use), otherwise
# printed to stdout (standalone smoke testing).
#
# See docs/Testing-in-ci.md §2.1 and §3 for the contract this implements.
#
# Environment:
#   GITHUB_OUTPUT (optional) - GitHub Actions outputs file path
#   REPO_ROOT     (optional) - defaults to `git rev-parse --show-toplevel`
#

set -o nounset
set -o pipefail
set -o errexit

# Hard exclusions: actions skipped regardless of whether run_all_tests.sh exists.
# Keep this list in sync with docs/Testing-in-ci.md §3.
EXCLUDED=(
  create-tf-vars-matrix
)

function is_excluded {
  local name="${1}"
  local entry
  for entry in "${EXCLUDED[@]}"; do
    [[ "${entry}" == "${name}" ]] && return 0
  done
  return 1
}

function main {
  local repo_root
  repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"

  local with_tests="" without_tests=""
  local action_yml dir name
  while IFS= read -r action_yml; do
    dir="$(dirname "${action_yml}")"
    name="$(basename "${dir}")"

    if is_excluded "${name}"; then
      without_tests+="${name}"$'\n'
      continue
    fi

    if [[ -f "${dir}/run_all_tests.sh" ]]; then
      with_tests+="${name}"$'\n'
    else
      without_tests+="${name}"$'\n'
    fi
  done < <(find "${repo_root}" -mindepth 2 -maxdepth 2 -name action.yml -not -path '*/.github/*' | sort)

  local tests_matrix no_tests_list
  tests_matrix="$(printf '%s' "${with_tests}" | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')"
  no_tests_list="$(printf '%s' "${without_tests}" | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')"

  echo "Discovery results:" >&2
  echo "  with tests    ($(echo "${tests_matrix}" | jq -r 'length')): ${tests_matrix}" >&2
  echo "  without tests ($(echo "${no_tests_list}" | jq -r 'length')): ${no_tests_list}" >&2

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "tests-matrix=${tests_matrix}"
      echo "no-tests-list=${no_tests_list}"
    } >> "${GITHUB_OUTPUT}"
  else
    echo "tests-matrix=${tests_matrix}"
    echo "no-tests-list=${no_tests_list}"
  fi
}

main
_main_exit_code=$?
exit ${_main_exit_code}
