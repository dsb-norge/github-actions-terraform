#!/bin/env bash
#
# Contract tests for the terraform console parsers.
#
# Runs every scenario under contract-tests/scenarios/ against the terraform
# binary on PATH — a local-only configuration, no providers, no network —
# captures the console output exactly the way terraform-plan and terraform-apply
# do, feeds it through parse-terraform-plan and parse-terraform-apply (their
# step scripts, unmodified), and asserts the parsed counts and flags against the
# scenario's expected.json. Then it compares the summary-bearing lines of the
# captured console with the fixture pinned under the parser's test-data/, so a
# wording change in a new terraform release fails loudly and names the line.
#
# The unit suites of the two parsers pin the fixtures; this script is what
# proves the fixtures are still what terraform prints. See
# docs/Apply-and-destroy-reporting.md §16 and docs/Testing-in-ci.md §13.
#
# Usage:
#   contract-tests/run.sh [--capture] [<scenario> ...]
#
#   --capture   overwrite the pinned fixtures with this run's console output —
#               for pinning a new terraform version's wording on purpose. Update
#               the README next to the fixtures with the version afterwards.
#   <scenario>  one or more scenario directory names; default: all of them.
#
# Environment:
#   TF_BIN               terraform binary (default: 'terraform' on PATH)
#   RUNNER_TEMP          scratch root (default: a fresh mktemp -d)
#   GITHUB_STEP_SUMMARY  when set, a per-scenario table is appended to it
#
# Emits the canonical 'Tests run / passed / failed' lines. This is NOT an
# action suite: contract-tests/ has no action.yml, so action-tests.yml does
# not discover it. It runs from .github/workflows/terraform-contract-tests.yml
# and by hand.
#

set -o nounset
set -o pipefail

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${_this_script_dir}/.." &>/dev/null && pwd)"
SCENARIOS_DIR="${_this_script_dir}/scenarios"
PLAN_ACTION="${REPO_ROOT}/parse-terraform-plan"
APPLY_ACTION="${REPO_ROOT}/parse-terraform-apply"

TF_BIN="${TF_BIN:-terraform}"
CAPTURE="false"

# Scratch root. Under GitHub Actions it is ${RUNNER_TEMP}/contract-tests, which
# the workflow uploads as an artifact on failure. By hand it is a fresh
# mktemp -d that this script owns and removes on exit — unless a scenario
# failed, in which case it stays for inspection and the failure output names
# it. A caller-supplied RUNNER_TEMP is never removed.
if [ -n "${RUNNER_TEMP:-}" ]; then
  SCRATCH="${RUNNER_TEMP}/contract-tests"
else
  _own_scratch_root="$(mktemp -d)"
  SCRATCH="${_own_scratch_root}/contract-tests"
  trap '[ "${TESTS_FAILED:-0}" -eq 0 ] && rm -rf "${_own_scratch_root}"' EXIT
fi

# What the actions' shims set: no "run this command to apply" hints, no
# version-check call home, no colour, and no prompts unless a scenario asks.
export TF_IN_AUTOMATION="true"
export CHECKPOINT_DISABLE="1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
SUMMARY_ROWS=""

# Escape a value for the message part of a GitHub workflow command — the same
# three substitutions parse-terraform-apply/helpers_additional.sh makes. A
# raw '%' or newline in a console line would otherwise truncate or corrupt
# the ::error on the run page.
function escape_annotation {
  local s="${1}"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "${s}"
}

# Lines whose wording the parsers (and the renderers downstream of them)
# depend on. Everything else in a console — resource ids, durations, the
# order two parallel creates finish in — is noise for this comparison.
# Elapsed times inside progress ticks are normalised so the tick's *shape* is
# compared without its value.
function signature_of {
  grep -E \
    -e '^(Apply|Destroy) complete! Resources: ' \
    -e '^Plan: ' \
    -e '^No changes\.' \
    -e 'without changing any real infrastructure' \
    -e '^Changes to Outputs:' \
    -e '^Apply cancelled\.' \
    -e '^Outputs:$' \
    -e '^Warning: ' \
    -e '^Error: ' \
    -e '^Interrupt received\.' \
    -e 'will be imported$' \
    -e ' has moved to ' \
    -e '\(moved from ' \
    -e 'will no longer be managed by Terraform' \
    -e 'must be replaced$' \
    -e 'will be created$' \
    -e 'will be updated in-place$' \
    -e 'will be destroyed$' \
    -e ': Still (creating|destroying|modifying|reading)\.\.\. \[' \
    "${1}" 2>/dev/null \
    | sed -E 's/^[[:space:]]+//; s/\[(id=[^]]*, )?[0-9hms]+ elapsed\]/[<elapsed> elapsed]/' \
    | sort -u
}

# Source a parser step script the way its action.yml shim does, in a subshell,
# with the console file as its input. $1 action dir, $2 step script, $3 work
# dir, $4 GITHUB_OUTPUT file, $5 log file, then NAME=VALUE input assignments.
function run_parser {
  local action_dir="${1}" step="${2}" work="${3}" out="${4}" log="${5}"
  shift 5
  : >"${out}"
  (
    export GITHUB_ACTION_PATH="${action_dir}"
    export GITHUB_WORKSPACE="${work}"
    export RUNNER_TEMP="${work}"
    export GITHUB_OUTPUT="${out}"
    local kv
    for kv in "$@"; do export "${kv}"; done
    set -o allexport
    # shellcheck disable=SC1090
    source "${action_dir}/${step}"
  ) >"${log}" 2>&1
}

function get_out { grep "^${2}=" "${1}" | head -n1 | cut -d= -f2-; }

# Run terraform in the work dir, console to a file. Prints nothing; returns
# terraform's exit code.
function tf_in {
  local work="${1}" console="${2}"
  shift 2
  (cd "${work}" && "${TF_BIN}" "$@") >"${console}" 2>&1
}

# As tf_in, for an arbitrary command line (used to wrap terraform in timeout).
function cmd_in {
  local work="${1}" console="${2}"
  shift 2
  (cd "${work}" && "$@") >"${console}" 2>&1
}

# Compare the signature of a captured console with a pinned fixture. Appends
# one failure line per differing line to the caller's FAILURES array and emits
# one ::error listing the lines terraform emits that the fixture lacks and the
# lines the fixture has that terraform no longer emits — two lists, not pairs:
# the sorted signatures give no way to tell which new line replaced which old
# one. $1 scenario, $2 captured, $3 fixture path (repo-relative), $4 'plan' |
# 'apply'.
function check_signature {
  local name="${1}" captured="${2}" fixture_rel="${3}" what="${4}"
  local fixture="${REPO_ROOT}/${fixture_rel}"
  if [ ! -f "${fixture}" ]; then
    FAILURES+=("${what}: fixture ${fixture_rel} does not exist — run 'contract-tests/run.sh --capture ${name}' to pin it")
    return 0
  fi
  local sig_new sig_old
  sig_new=$(mktemp); sig_old=$(mktemp)
  signature_of "${captured}" >"${sig_new}"
  signature_of "${fixture}" >"${sig_old}"
  if cmp -s "${sig_new}" "${sig_old}"; then
    rm -f "${sig_new}" "${sig_old}"
    return 0
  fi
  local -a only_new=() only_old=()
  mapfile -t only_new < <(comm -23 "${sig_new}" "${sig_old}")
  mapfile -t only_old < <(comm -13 "${sig_new}" "${sig_old}")
  rm -f "${sig_new}" "${sig_old}"
  local line msg=""
  for line in "${only_new[@]}"; do
    FAILURES+=("${what} wording drift: Terraform ${TF_VERSION} emits '${line}', which the fixture ${fixture_rel} does not have")
  done
  for line in "${only_old[@]}"; do
    FAILURES+=("${what} wording drift: the fixture ${fixture_rel} has '${line}', which Terraform ${TF_VERSION} does not emit")
  done
  [ ${#only_new[@]} -gt 0 ] && msg+="Terraform ${TF_VERSION} emits, and the fixture ${fixture_rel} does not have:"$'\n'"$(printf '  %s\n' "${only_new[@]}")"$'\n'
  [ ${#only_old[@]} -gt 0 ] && msg+="The fixture ${fixture_rel} has, and Terraform ${TF_VERSION} does not emit:"$'\n'"$(printf '  %s\n' "${only_old[@]}")"$'\n'
  msg+="Update the fixture (contract-tests/run.sh --capture ${name}) if intended."
  echo "::error title=Terraform output drift (${name}, ${what})::$(escape_annotation "${msg}")"
}

# $1 scenario, $2 what, $3 key, $4 expected, $5 actual
function expect_eq {
  [ "${4}" = "${5}" ] && return 0
  FAILURES+=("${2} ${3}: expected '${4}', got '${5}'")
}

function run_scenario {
  local name="${1}"
  local dir="${SCENARIOS_DIR}/${name}" expected="${SCENARIOS_DIR}/${name}/expected.json"
  local work="${SCRATCH}/${name}"
  FAILURES=()

  # A language feature newer than the oldest version in the window: below the
  # scenario's floor there is nothing to compare, so it is neither a pass nor
  # a failure — but it is said out loud, and counted, so a window that never
  # reaches the floor is visible rather than a silently thinner run.
  local min_tf
  min_tf=$(jq -r '."min-terraform" // empty' "${expected}")
  if [ -n "${min_tf}" ] && [ "$(printf '%s\n%s\n' "${min_tf}" "${TF_VERSION}" | sort -V | head -n1)" != "${min_tf}" ]; then
    echo -e "${YELLOW}⏭ SKIPPED${NC}: ${name} needs terraform >= ${min_tf}; this is ${TF_VERSION}"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    SUMMARY_ROWS+="| \`${name}\` | ⏭️ skipped | needs terraform ≥ ${min_tf} | — |"$'\n'
    return 0
  fi

  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "${BLUE}TEST ${TESTS_RUN}: ${name} — $(jq -r '.description' "${expected}")${NC}"

  rm -rf "${work}"; mkdir -p "${work}"
  local operation
  operation=$(jq -r '.operation' "${expected}")

  # Prior state, when the scenario needs one: the setup configuration is
  # applied, then swapped for the scenario's own files. The state stays.
  if [ -d "${dir}/setup" ]; then
    cp "${dir}"/setup/*.tf "${work}/"
    if ! tf_in "${work}" "${work}/setup-init.log" init -input=false -no-color \
      || ! tf_in "${work}" "${work}/setup-apply.log" apply -input=false -auto-approve -no-color; then
      FAILURES+=("setup apply failed — see ${work}/setup-*.log")
    fi
    rm -f "${work}"/*.tf
  fi
  cp "${dir}"/*.tf "${work}/"
  if ! tf_in "${work}" "${work}/init.log" init -input=false -no-color; then
    FAILURES+=("terraform init failed — see ${work}/init.log")
  fi

  # Console files named as the actions name them.
  local plan_console="${work}/tf-plan-console-output-${name}.txt"
  local apply_console="${work}/tf-apply-console-output-${name}.txt"
  local plan_rc="" apply_rc=""
  local -a plan_extra=()

  if [ ${#FAILURES[@]} -eq 0 ]; then
    case "${operation}" in
      apply|refresh-only|destroy-plan|interrupt)
        [ "${operation}" = 'refresh-only' ] && plan_extra+=(-refresh-only)
        [ "${operation}" = 'destroy-plan' ] && plan_extra+=(-destroy)
        # Exactly terraform-plan's command line.
        tf_in "${work}" "${plan_console}" plan -detailed-exitcode -input=false -no-color "-out=${work}/tfplan" ${plan_extra[@]+"${plan_extra[@]}"}
        plan_rc=$?
        if [ "${operation}" = 'interrupt' ]; then
          # A cancelled job delivers SIGINT; terraform gets five seconds of a
          # thirty-second provisioner before it arrives (long enough for the
          # provisioner to be running on a slow runner, short of the 10 s
          # progress tick). Through coreutils timeout, which signals
          # terraform's own pid: the first attempt backgrounded a
          # "( cd … && terraform … )" subshell and sent kill -INT to THAT pid,
          # and a subshell does not forward the signal to its child, so the
          # apply ran to completion (P36). It is not that a background
          # terraform ignores SIGINT — Go re-installs its handler either way.
          cmd_in "${work}" "${apply_console}" timeout --preserve-status --signal=INT --kill-after=60 5 \
            "${TF_BIN}" apply -input=false -auto-approve -no-color "${work}/tfplan"
          apply_rc=$?
        else
          # Exactly terraform-apply's command line.
          tf_in "${work}" "${apply_console}" apply -input=false -auto-approve -no-color "${work}/tfplan"
          apply_rc=$?
        fi
        ;;
      destroy)
        tf_in "${work}" "${apply_console}" destroy -input=false -auto-approve -no-color
        apply_rc=$?
        ;;
      prompt-decline)
        (cd "${work}" && echo no | "${TF_BIN}" apply -input=true -no-color) >"${apply_console}" 2>&1
        apply_rc=$?
        ;;
      *)
        FAILURES+=("unknown operation '${operation}' in expected.json")
        ;;
    esac
  fi

  # ---- plan side -----------------------------------------------------------
  local plan_fixture="" apply_fixture=""
  if [ ${#FAILURES[@]} -eq 0 ] && [ "$(jq -r '.plan' "${expected}")" != 'null' ]; then
    plan_fixture=$(jq -r '.plan.fixture' "${expected}")
    expect_eq "${name}" plan exitcode "$(jq -r '.plan.exitcode' "${expected}")" "${plan_rc}"
    local plan_out="${work}/parse-plan.out" plan_log="${work}/parse-plan.log"
    run_parser "${PLAN_ACTION}" step_parse_plan_output.sh "${work}" "${plan_out}" "${plan_log}" \
      "input_plan_console_file=${plan_console}"
    local k
    for k in import add change destroy move remove total; do
      expect_eq "${name}" plan "${k}-count" "$(jq -r ".plan.\"${k}\"" "${expected}")" "$(get_out "${plan_out}" "${k}-count")"
    done
    expect_eq "${name}" plan has-output-only-changes "$(jq -r '.plan."has-output-only-changes"' "${expected}")" "$(get_out "${plan_out}" has-output-only-changes)"
    [ "${CAPTURE}" = 'true' ] || check_signature "${name}" "${plan_console}" "${plan_fixture}" plan
  fi

  # ---- apply side ----------------------------------------------------------
  if [ ${#FAILURES[@]} -eq 0 ] || [ -n "${apply_rc}" ]; then
    apply_fixture=$(jq -r '.apply.fixture' "${expected}")
    expect_eq "${name}" apply exitcode "$(jq -r '.apply.exitcode' "${expected}")" "${apply_rc}"
    local apply_out="${work}/parse-apply.out" apply_log="${work}/parse-apply.log"
    run_parser "${APPLY_ACTION}" step_parse_apply_output.sh "${work}" "${apply_out}" "${apply_log}" \
      "input_apply_console_file=${apply_console}" "input_apply_exitcode=${apply_rc}"
    local k
    for k in import add change destroy total; do
      expect_eq "${name}" apply "${k}-count" "$(jq -r ".apply.\"${k}\"" "${expected}")" "$(get_out "${apply_out}" "${k}-count")"
    done
    expect_eq "${name}" apply completed "$(jq -r '.apply.completed' "${expected}")" "$(get_out "${apply_out}" completed)"
    expect_eq "${name}" apply apply-kind "$(jq -r '.apply.kind' "${expected}")" "$(get_out "${apply_out}" apply-kind)"
    # A recognised console never triggers the "not recognised" warning; if a
    # new terraform wording ever does, the counts assertion above fails too,
    # and this line says why.
    if [ "$(jq -r '.apply.completed' "${expected}")" = 'true' ] && grep -q '^::warning title=Terraform output not recognised' "${apply_log}"; then
      FAILURES+=("apply: parser emitted '::warning title=Terraform output not recognised' for a console this scenario expects to be recognised")
    fi
    if [ "$(jq -r '.apply.ticks // false' "${expected}")" = 'true' ]; then
      local filtered; filtered=$(get_out "${apply_out}" filtered-console-file)
      grep -qE ': Still creating\.\.\. \[' "${apply_console}" || FAILURES+=("apply: expected a real 'Still creating...' tick line in the console; terraform printed none")
      if [ -f "${filtered}" ] && grep -qE ': Still (creating|destroying|modifying|reading)\.\.\. \[' "${filtered}"; then
        FAILURES+=("apply: the tick filter left a progress line in the filtered console — the tick format has drifted (P5): $(grep -E ': Still ' "${filtered}" | head -n1)")
      fi
    fi
    [ "${CAPTURE}" = 'true' ] || check_signature "${name}" "${apply_console}" "${apply_fixture}" apply
  fi

  # ---- capture -------------------------------------------------------------
  if [ "${CAPTURE}" = 'true' ] && [ ${#FAILURES[@]} -eq 0 ]; then
    if [ -n "${plan_fixture}" ]; then
      mkdir -p "$(dirname "${REPO_ROOT}/${plan_fixture}")"
      cp "${plan_console}" "${REPO_ROOT}/${plan_fixture}"
      echo "  captured ${plan_fixture}"
    fi
    mkdir -p "$(dirname "${REPO_ROOT}/${apply_fixture}")"
    cp "${apply_console}" "${REPO_ROOT}/${apply_fixture}"
    echo "  captured ${apply_fixture}"
  fi

  local summary_line plan_sig apply_sig
  plan_sig=$(grep -E '^(Plan: |No changes\.)' "${plan_console}" 2>/dev/null | head -n1)
  apply_sig=$(grep -E '^(Apply|Destroy) complete!|^Apply cancelled\.|^Error: ' "${apply_console}" 2>/dev/null | head -n1)
  if [ ${#FAILURES[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ PASSED${NC}  plan: ${plan_sig:-—}  apply: ${apply_sig:-—}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    SUMMARY_ROWS+="| \`${name}\` | ✅ | \`${plan_sig:-—}\` | \`${apply_sig:-—}\` |"$'\n'
  else
    echo -e "${RED}✗ FAILED${NC}"
    local f
    for f in "${FAILURES[@]}"; do echo "    ${f}"; done
    echo "::error title=Contract test failed (${name})::$(escape_annotation "${FAILURES[0]}")"
    # The tails put the actual wording in the job log; the full consoles are
    # in the work dir, which the workflow uploads as an artifact.
    local c
    for c in "${plan_console}" "${apply_console}"; do
      [ -f "${c}" ] || continue
      echo "--- last 40 lines of $(basename "${c}") ---"
      tail -n 40 "${c}"
      echo "--- end of $(basename "${c}") ---"
    done
    echo "--- work dir: ${work} ---"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    SUMMARY_ROWS+="| \`${name}\` | ❌ | \`${plan_sig:-—}\` | \`${apply_sig:-—}\` |"$'\n'
  fi
}

function main {
  local -a wanted=()
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --capture) CAPTURE="true" ;;
      -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) wanted+=("${arg}") ;;
    esac
  done

  if ! command -v "${TF_BIN}" >/dev/null 2>&1; then
    echo "::error title=terraform not found::'${TF_BIN}' is not on PATH; install terraform or set TF_BIN"
    return 1
  fi
  TF_VERSION=$("${TF_BIN}" version -json | jq -r '.terraform_version')
  mkdir -p "${SCRATCH}"

  if [ ${#wanted[@]} -eq 0 ]; then
    local d
    for d in "${SCENARIOS_DIR}"/*/; do wanted+=("$(basename "${d}")"); done
  fi

  echo ""
  echo -e "${YELLOW}============================================${NC}"
  echo -e "${YELLOW}   TERRAFORM CONTRACT TESTS — terraform ${TF_VERSION}${NC}"
  echo -e "${YELLOW}============================================${NC}"
  [ "${CAPTURE}" = 'true' ] && echo "capture mode: fixtures will be overwritten with this run's output"

  local name
  for name in "${wanted[@]}"; do
    # The name becomes a path that is rm -rf'd under SCRATCH; only a plain
    # directory name may get there.
    if ! [[ "${name}" =~ ^[A-Za-z0-9_-]+$ ]] || [ ! -f "${SCENARIOS_DIR}/${name}/expected.json" ]; then
      TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
      echo -e "${RED}✗ FAILED${NC}: no such scenario '${name}'"
      continue
    fi
    run_scenario "${name}"
  done

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### Terraform contract tests — terraform `%s`\n\n' "${TF_VERSION}"
      if [ "${TESTS_SKIPPED}" -gt 0 ]; then
        printf '**%d scenarios · %d passed · %d failed · %d skipped below their `min-terraform` floor**\n\n' "${TESTS_RUN}" "${TESTS_PASSED}" "${TESTS_FAILED}" "${TESTS_SKIPPED}"
      else
        printf '**%d scenarios · %d passed · %d failed**\n\n' "${TESTS_RUN}" "${TESTS_PASSED}" "${TESTS_FAILED}"
      fi
      printf '| Scenario | Result | Plan line | Apply line |\n|---|:---:|---|---|\n'
      printf '%s' "${SUMMARY_ROWS}"
      printf '\n'
    } >>"${GITHUB_STEP_SUMMARY}"
  fi

  echo ""
  echo "========================================"
  echo "Tests run:    ${TESTS_RUN}"
  echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  [ "${TESTS_SKIPPED}" -gt 0 ] && echo -e "Tests skipped: ${YELLOW}${TESTS_SKIPPED}${NC} (below a scenario's min-terraform; neither passed nor failed)"
  echo "========================================"
  [ "${TESTS_FAILED}" -eq 0 ]
}

main "$@"
_main_exit_code=$?
exit ${_main_exit_code}
